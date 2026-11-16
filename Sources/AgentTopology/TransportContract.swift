import Foundation

public struct ContractViolation: Sendable, Hashable, CustomStringConvertible {
    public let clause: String
    public let detail: String
    public var description: String { "[\(clause)] \(detail)" }
}

/// The behaviour every `ManagedAgentsTransport` adapter must share, as an executable suite.
///
/// It returns violations instead of asserting, so the suite itself can be tested: the package's tests run
/// it against both real adapters (expecting none) and against deliberately broken adapters and servers
/// (expecting the right clause to fire). This package ships only the in-process fixture; running the same
/// clauses against a real local deployment would need a fixture that can drive that server's state.
public enum TransportContract {
    public typealias Factory = @Sendable (SimulatedAgentServer) async -> any ManagedAgentsTransport

    public static let clauses = [
        "C1 descriptor fidelity",
        "C2 cursor semantics",
        "C3 lineage passthrough",
        "C4 error classification",
        "C5 unsafe input refused before I/O",
    ]

    public static func verify(profile: SimulatedAgentServer.Profile, configureServer: (@Sendable (SimulatedAgentServer) async -> Void)? = nil,
                              makeTransport: Factory) async -> [ContractViolation] {
        var violations: [ContractViolation] = []
        func fail(_ index: Int, _ detail: String) {
            violations.append(ContractViolation(clause: clauses.indices.contains(index) ? clauses[index] : "?", detail: detail))
        }
        // Each clause gets a fresh server so one clause's state changes cannot mask another's failure.
        func fresh() async -> (SimulatedAgentServer, any ManagedAgentsTransport) {
            let server = SimulatedAgentServer(profile: profile)
            await configureServer?(server)
            return (server, await makeTransport(server))
        }

        // C1
        do {
            let (server, transport) = await fresh()
            do {
                let d = try await transport.describe()
                let p = await server.profile
                let epoch = await server.epoch
                if d.version != p.version { fail(0, "version \(d.version) != server \(p.version)") }
                if d.advertised != p.features { fail(0, "features differ from the server's") }
                if d.epoch != epoch { fail(0, "epoch \(d.epoch) != server \(epoch)") }
                if d.topology != transport.topology { fail(0, "descriptor topology differs from the adapter's") }
            } catch { fail(0, "describe threw \(error)") }
        }

        // C2 (only meaningful when the server supports the cursor)
        if profile.features.contains(.eventCursor) {
            let (server, transport) = await fresh()
            await server.append(6)
            do {
                let all = try await transport.events(session: "s-1", after: nil, limit: 100)
                if all.events.map(\.sequence) != Array(1...6) { fail(1, "after nil returned \(all.events.map(\.sequence)), expected 1...6") }
                if all.highWater != 6 { fail(1, "high-water \(all.highWater), expected 6") }
                let mid = try await transport.events(session: "s-1", after: 2, limit: 2)
                if mid.events.map(\.sequence) != [3, 4] { fail(1, "after 2 limit 2 returned \(mid.events.map(\.sequence)), expected [3, 4]") }
                let end = try await transport.events(session: "s-1", after: 6, limit: 10)
                if !end.events.isEmpty { fail(1, "after high-water returned \(end.events.count) events") }
            } catch { fail(1, "events threw \(error)") }
        }

        // C3
        do {
            let (server, transport) = await fresh()
            await server.append(5)
            let oldEpoch = await server.epoch
            await server.restoreBackup(keeping: 3)
            let newEpoch = await server.epoch
            do {
                let page = try await transport.events(session: "s-1", after: nil, limit: 100)
                if page.epoch != newEpoch { fail(2, "epoch \(page.epoch), expected \(newEpoch)") }
                if page.previousEpoch != oldEpoch { fail(2, "previous epoch \(page.previousEpoch ?? "nil"), expected \(oldEpoch)") }
                if page.forkPoint != 3 { fail(2, "fork point \(page.forkPoint.map(String.init) ?? "nil"), expected 3") }
            } catch { fail(2, "events threw \(error)") }
        }

        // C4
        let expectations: [(Int, TransportError)] = [
            (503, .retryable("HTTP 503")), (429, .retryable("HTTP 429")), (410, .cursorExpired), (403, .fatal("HTTP 403")),
        ]
        for (status, expected) in expectations {
            let (server, transport) = await fresh()
            await server.failNext([status])
            do {
                _ = try await transport.events(session: "s-1", after: nil, limit: 10)
                fail(3, "HTTP \(status) did not throw")
            } catch let error as TransportError {
                if error != expected { fail(3, "HTTP \(status) classified as \(error), expected \(expected)") }
            } catch { fail(3, "HTTP \(status) threw a non-transport error \(error)") }
        }

        // C5
        do {
            let (server, transport) = await fresh()
            let before = await server.requestCount
            for bad in ["../admin", "a/b", "", "s 1", "s?x=1"] {
                do {
                    _ = try await transport.events(session: bad, after: nil, limit: 10)
                    fail(4, "session id '\(bad)' was accepted")
                } catch {}
            }
            let after = await server.requestCount
            if after != before { fail(4, "\(after - before) request(s) reached the server for unsafe session ids") }
        }
        return violations
    }
}

/// Connects to one tenant: discover the server, negotiate capabilities. The result drives the UI.
public struct ConnectionReport: Sendable, Hashable {
    public let descriptor: ServerDescriptor
    public let plan: CapabilityPlan
}

public enum TenantConnector {
    public static func connect(_ transport: any ManagedAgentsTransport, negotiator: CapabilityNegotiator = .standard) async throws -> ConnectionReport {
        let descriptor = try await transport.describe()
        return ConnectionReport(descriptor: descriptor, plan: negotiator.negotiate(descriptor))
    }
}
