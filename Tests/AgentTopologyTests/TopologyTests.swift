import XCTest
@testable import AgentTopology

/// Counts requests that reach the network, to prove refused requests never do.
actor CountingClient: HTTPClient {
    private(set) var sent: [URL] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request.url)
        return HTTPResponse(status: 200)
    }
}

final class ResidencyTests: XCTestCase {
    func config(_ extra: [String: any Sendable] = [:]) throws -> TenantConfiguration {
        var p: [String: any Sendable] = ["tenantID": "acme", "topology": "self-hosted",
                                          "baseURL": "https://agents.acme.example", "allowedHosts": ["agents.acme.example"]]
        for (k, v) in extra { p[k] = v }
        return try ManagedConfigParser.parse(p).get()
    }

    func testOnlyExactAllowlistedHostsOverHTTPSReachTheNetwork() async throws {
        let inner = CountingClient()
        let audit = ResidencyAudit()
        let client = ResidencyEnforcingClient(inner: inner, configuration: try config(), audit: audit)
        let allowed = ["https://agents.acme.example/v1/x", "https://AGENTS.acme.example/v1/x"]
        let refused = ["https://api.anthropic.com/v1/x", "https://agents.acme.example.attacker.io/v1/x",
                       "https://evil-agents.acme.example/v1/x", "http://agents.acme.example/v1/x",
                       "ftp://agents.acme.example/x", "https://acme.example/v1/x"]
        for u in allowed { _ = try await client.send(HTTPRequest(url: URL(string: u)!)) } // Test literals.
        for u in refused {
            do {
                _ = try await client.send(HTTPRequest(url: URL(string: u)!)) // Test literal.
                XCTFail("\(u) was sent")
            } catch let e as TransportError {
                guard case .residency = e else { return XCTFail("\(u): \(e)") }
            }
        }
        let sent = await inner.sent
        XCTAssertEqual(sent.count, allowed.count)
        let total = await audit.totalRefused
        XCTAssertEqual(total, refused.count)
    }

    func testLoopbackHTTPPassesOnlyWhenTheTenantOptedIn() async throws {
        let cfg = try config(["baseURL": "http://localhost:8080", "allowedHosts": ["localhost"], "allowLoopbackHTTP": true])
        let client = ResidencyEnforcingClient(inner: CountingClient(), configuration: cfg, audit: ResidencyAudit())
        XCTAssertNil(client.refusal(for: URL(string: "http://localhost:8080/v1")!)) // Test literal.
        let strict = ResidencyEnforcingClient(inner: CountingClient(), configuration: try config(["allowedHosts": ["agents.acme.example", "localhost"]]), audit: ResidencyAudit())
        XCTAssertNotNil(strict.refusal(for: URL(string: "http://localhost:8080/v1")!)) // Test literal.
    }

    func testAuditIsBounded() async {
        let audit = ResidencyAudit(capacity: 3)
        for i in 0..<10 { await audit.record(.init(tenantID: "t", host: "h\(i)", reason: "r")) }
        let entries = await audit.entries
        let total = await audit.totalRefused
        XCTAssertEqual(entries.map(\.host), ["h7", "h8", "h9"])
        XCTAssertEqual(total, 10)
    }

    func testFactoryBuildsTheAdapterForTheTopologyBehindTheGuard() async throws {
        let server = SimulatedAgentServer(profile: selfHostedProfile())
        let network = await SimulatedNetwork(servers: [server])
        let audit = ResidencyAudit()
        let cfg = try config(["pathPrefix": "/cma"])
        let transport = TransportFactory.make(for: cfg, network: network, credentials: StaticCredentials(token: "t"), audit: audit)
        XCTAssertEqual(transport.topology, .selfHosted)
        XCTAssertTrue((transport as? SelfHostedTransport)?.client is ResidencyEnforcingClient, "self-hosted adapter must sit behind the guard")
        let hosted = TransportFactory.make(for: try ManagedConfigParser.parse(["tenantID": "n", "topology": "hosted"]).get(),
                                           network: network, credentials: StaticCredentials(token: "t"), audit: audit)
        XCTAssertTrue((hosted as? HostedTransport)?.client is ResidencyEnforcingClient, "hosted adapter must sit behind the guard")
        let d = try await transport.describe()
        XCTAssertEqual(d.topology, .selfHosted)
        let refused = await audit.totalRefused
        XCTAssertEqual(refused, 0)
    }

    /// A self-hosted tenant's guard must stop a request to the hosted API even though the network can
    /// route it there: the refusal comes from the guard (audited), and the hosted server sees nothing.
    func testGuardStopsARoutableRequestToAHostOutsideTheTenant() async throws {
        let hostedServer = SimulatedAgentServer(profile: hostedProfile())
        let network = await SimulatedNetwork(servers: [hostedServer])
        let audit = ResidencyAudit()
        let guarded = ResidencyEnforcingClient(inner: network, configuration: try config(), audit: audit)
        let misdirected = HostedTransport(client: guarded, credentials: StaticCredentials(token: "t"))
        do {
            _ = try await misdirected.describe()
            XCTFail("should be refused")
        } catch let e as TransportError {
            guard case .residency = e else { return XCTFail("expected residency refusal, got \(e)") }
        }
        let refused = await audit.totalRefused
        let reached = await hostedServer.requestCount
        XCTAssertEqual(refused, 1)
        XCTAssertEqual(reached, 0)
        // Control: without the guard the same request is routable and succeeds.
        _ = try await HostedTransport(client: network, credentials: StaticCredentials(token: "t")).describe()
        let reachedUnguarded = await hostedServer.requestCount
        XCTAssertEqual(reachedUnguarded, 1)
    }
}

final class ContractTests: XCTestCase {
    func testBothAdaptersSatisfyTheContract() async {
        let selfHosted = await TransportContract.verify(profile: selfHostedProfile()) { selfHostedTransport($0) }
        XCTAssertEqual(selfHosted, [])
        let hosted = await TransportContract.verify(profile: hostedProfile()) { hostedTransport($0) }
        XCTAssertEqual(hosted, [])
    }

    func testContractCatchesAnOffByOneCursorAdapter() async {
        struct OffByOne: ManagedAgentsTransport {
            let inner: any ManagedAgentsTransport
            var topology: TopologyKind { inner.topology }
            func describe() async throws -> ServerDescriptor { try await inner.describe() }
            func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
                try await inner.events(session: session, after: after.map { $0 > 0 ? $0 - 1 : 0 }, limit: limit)
            }
        }
        let v = await TransportContract.verify(profile: selfHostedProfile()) { OffByOne(inner: selfHostedTransport($0)) }
        XCTAssertTrue(v.contains { $0.clause.hasPrefix("C2") }, "\(v)")
    }

    func testContractCatchesAnAdapterThatIgnoresTheLimit() async {
        // Correct for `after: nil` and `after: highWater`; wrong only for a bounded middle page.
        struct IgnoresLimit: ManagedAgentsTransport {
            let inner: any ManagedAgentsTransport
            var topology: TopologyKind { inner.topology }
            func describe() async throws -> ServerDescriptor { try await inner.describe() }
            func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
                try await inner.events(session: session, after: after, limit: 500)
            }
        }
        let v = await TransportContract.verify(profile: selfHostedProfile()) { IgnoresLimit(inner: selfHostedTransport($0)) }
        XCTAssertEqual(v.map(\.clause), ["C2 cursor semantics"], "\(v)")
    }

    func testContractCatchesAnAdapterThatRetriesEverything() async {
        struct EverythingRetryable: ManagedAgentsTransport {
            let inner: any ManagedAgentsTransport
            var topology: TopologyKind { inner.topology }
            func describe() async throws -> ServerDescriptor { try await inner.describe() }
            func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
                do { return try await inner.events(session: session, after: after, limit: limit) } catch {
                    throw TransportError.retryable("anything")
                }
            }
        }
        let v = await TransportContract.verify(profile: selfHostedProfile()) { EverythingRetryable(inner: selfHostedTransport($0)) }
        XCTAssertTrue(v.contains { $0.clause.hasPrefix("C4") }, "\(v)")
    }

    func testContractCatchesAnAdapterThatSendsUnsafeIDs() async {
        struct NoValidation: ManagedAgentsTransport {
            let server: SimulatedAgentServer
            var topology: TopologyKind { .selfHosted }
            func describe() async throws -> ServerDescriptor { try await selfHostedTransport(server).describe() }
            func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
                _ = try await server.send(HTTPRequest(url: acmeURL.appendingPathComponent("cma/v1/sessions/x/events")))
                throw TransportError.fatal("refused late")
            }
        }
        let v = await TransportContract.verify(profile: selfHostedProfile()) { NoValidation(server: $0) }
        XCTAssertTrue(v.contains { $0.clause.hasPrefix("C5") }, "\(v)")
    }

    func testContractCatchesAServerThatOmitsLineage() async {
        let v = await TransportContract.verify(profile: selfHostedProfile(), configureServer: { await $0.setLineageOmitted(true) }) { selfHostedTransport($0) }
        XCTAssertTrue(v.contains { $0.clause.hasPrefix("C3") }, "\(v)")
    }

    func testContractCatchesAnAdapterThatMisreportsItsTopology() async {
        struct Liar: ManagedAgentsTransport {
            let inner: any ManagedAgentsTransport
            var topology: TopologyKind { .hosted }
            func describe() async throws -> ServerDescriptor { try await inner.describe() }
            func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
                try await inner.events(session: session, after: after, limit: limit)
            }
        }
        let v = await TransportContract.verify(profile: selfHostedProfile()) { Liar(inner: selfHostedTransport($0)) }
        XCTAssertTrue(v.contains { $0.clause.hasPrefix("C1") }, "\(v)")
    }
}

/// End to end through the composition root: config → guarded transport → negotiation → sync, across a
/// restart and a restore from backup. The client's transcript must end identical to the server's history.
final class EndToEndTests: XCTestCase {
    func drain(_ sync: SessionEventSync, into transcript: inout [SessionEvent]) async -> [SyncOutcome] {
        var outcomes: [SyncOutcome] = []
        for _ in 0..<20 {
            let o = await sync.pump()
            outcomes.append(o)
            switch o {
            case let .applied(events, _):
                transcript += events
                if events.isEmpty { return outcomes }
            case let .rebased(_, _, after):
                transcript.removeAll { $0.sequence > after }
            case .resyncRequired:
                transcript.removeAll()
            default:
                return outcomes
            }
        }
        return outcomes
    }

    func testSelfHostedTenantSurvivesRestartAndRestoreWithAConsistentTranscript() async throws {
        let cfg = try ManagedConfigParser.parse([
            "tenantID": "acme", "topology": "self-hosted", "baseURL": "https://agents.acme.example",
            "allowedHosts": ["agents.acme.example"], "pathPrefix": "/cma",
        ]).get()
        let server = SimulatedAgentServer(profile: selfHostedProfile())
        let network = await SimulatedNetwork(servers: [server])
        let transport = TransportFactory.make(for: cfg, network: network, credentials: StaticCredentials(token: "t"), audit: ResidencyAudit())
        let report = try await TenantConnector.connect(transport)
        XCTAssertEqual(report.plan.state(of: .eventCursor), .available)
        XCTAssertFalse(report.plan.state(of: .memoryStores).isUsable)

        let sync = SessionEventSync(transport: transport, session: "s-1", policy: RetryPolicy(baseMilliseconds: 1, maxAttempts: 4),
                                    sleeper: RecordingSleeper(), random: MaxRandom(), pageLimit: 3)
        var transcript: [SessionEvent] = []
        await server.append(7)
        _ = await drain(sync, into: &transcript)
        var expected = await server.events
        XCTAssertEqual(transcript, expected)

        await server.restart(unavailableFor: 2)
        await server.append(2)
        _ = await drain(sync, into: &transcript)
        expected = await server.events
        XCTAssertEqual(transcript, expected, "restart: same epoch, resumed from the cursor")

        await server.restoreBackup(keeping: 4)
        let outcomes = await drain(sync, into: &transcript)
        XCTAssertTrue(outcomes.contains(.rebased(fromEpoch: "ep-1", toEpoch: "ep-2", retractAfter: 4)), "\(outcomes)")
        expected = await server.events
        XCTAssertEqual(transcript, expected, "restore: retracted after the fork point and refetched the new history")
    }

    func testLegacyServerWithoutCursorStillConvergesInDegradedMode() async throws {
        let server = SimulatedAgentServer(profile: selfHostedProfile(ServerVersion(1, 8, 2), features: [.sessionEvents]))
        let transport = selfHostedTransport(server)
        let report = try await TenantConnector.connect(transport)
        guard case .degraded = report.plan.state(of: .eventCursor) else { return XCTFail("expected degraded cursor") }
        let sync = SessionEventSync(transport: transport, session: "s-1", usesCursor: false,
                                    sleeper: RecordingSleeper(), random: MaxRandom())
        var transcript: [SessionEvent] = []
        await server.append(4)
        _ = await drain(sync, into: &transcript)
        await server.append(3)
        _ = await drain(sync, into: &transcript)
        let expected = await server.events
        XCTAssertEqual(transcript, expected)
    }
}
