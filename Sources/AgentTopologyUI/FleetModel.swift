#if canImport(SwiftUI)
import Foundation
import Observation
import AgentTopology

/// One tenant as the app is provisioned with it: the MDM payload, plus (for the demo) the simulated
/// deployment that answers at its host. `server == nil` means nothing answers there.
public struct TenantSeed: Sendable {
    public let displayName: String
    public let managedConfig: [String: any Sendable]
    public let server: SimulatedAgentServer.Profile?
    public let preloadedEvents: Int

    public init(displayName: String, managedConfig: [String: any Sendable], server: SimulatedAgentServer.Profile?, preloadedEvents: Int = 5) {
        self.displayName = displayName
        self.managedConfig = managedConfig
        self.server = server
        self.preloadedEvents = preloadedEvents
    }
}

public enum Scenario: String, Sendable, CaseIterable {
    case stream, restart, restore, outage, upgrade, misdirect

    public var title: String {
        switch self {
        case .misdirect: return "Off-tenant upload attempt"
        case .stream: return "New agent activity"
        case .restart: return "Restart server process"
        case .restore: return "Restore DB from backup"
        case .outage: return "Extended outage"
        case .upgrade: return "Upgrade server to 2.2.0"
        }
    }
}

public struct TranscriptLine: Identifiable, Sendable, Hashable {
    public let event: SessionEvent
    public let epoch: String
    public var id: String { "\(epoch)#\(event.sequence)" }
}

@MainActor @Observable
public final class TenantModel: Identifiable {
    public let id: String
    public let name: String
    public let configuration: Result<TenantConfiguration, ConfigurationError>
    public private(set) var report: ConnectionReport?
    public private(set) var connectionError: String?
    public private(set) var transcript: [TranscriptLine] = []
    public private(set) var log: [String] = []
    public private(set) var retractedTotal = 0
    public private(set) var cursor: EventCursor?
    public private(set) var isBusy = false
    public private(set) var approvalDecision: String?
    /// Bumped on every log line; views key launch-time scrolling on it (the log itself is capped).
    public private(set) var revision: UInt64 = 0

    let server: SimulatedAgentServer?
    let preloadedEvents: Int
    @ObservationIgnored private var guarded: ResidencyEnforcingClient?
    @ObservationIgnored private var transport: (any ManagedAgentsTransport)?
    @ObservationIgnored private var sync: SessionEventSync?

    static let transcriptCap = 200
    static let logCap = 40

    init(seed: TenantSeed, index: Int) {
        id = "t\(index)"
        name = seed.displayName
        configuration = ManagedConfigParser.parse(seed.managedConfig)
        server = seed.server.map(SimulatedAgentServer.init(profile:))
        preloadedEvents = seed.preloadedEvents
    }

    public var plan: CapabilityPlan? { report?.plan }

    func attach(network: any HTTPClient, audit: ResidencyAudit) {
        guard case let .success(config) = configuration else { return }
        guarded = ResidencyEnforcingClient(inner: network, configuration: config, audit: audit)
        let t = TransportFactory.make(for: config, network: network, credentials: StaticCredentials(token: "demo-user-token"), audit: audit)
        transport = t
        sync = SessionEventSync(transport: t, session: "s-1", policy: RetryPolicy(baseMilliseconds: 40, capMilliseconds: 400, maxAttempts: 5))
    }

    func connect() async {
        guard let transport else {
            if case let .failure(error) = configuration { note("configuration rejected: \(error)") }
            return
        }
        do {
            let r = try await TenantConnector.connect(transport)
            report = r
            connectionError = nil
            let cursorOK = r.plan.state(of: .eventCursor) == .available
            await sync?.setUsesCursor(cursorOK)
            note("connected: \(r.descriptor.topology.rawValue) \(r.descriptor.version), epoch \(r.descriptor.epoch)" + (cursorOK ? "" : "; cursor degraded → full-history polling"))
        } catch {
            report = nil
            connectionError = String(describing: error)
            note("connect failed: \(error)")
        }
    }

    public func approve(_ decision: String) { approvalDecision = decision }

    /// Retries discovery after a failed connect (for example a 503 during a restart), then syncs.
    public func reconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await connect()
        await performSync()
    }

    /// Whether the negotiated plan lets the client drive this server's session at all.
    public var canSync: Bool {
        guard let plan else { return false }
        if case .unsupported = plan.compatibility { return false }
        return plan.state(of: .sessionEvents).isUsable
    }

    /// Pumps until the sync reports nothing new, a failure, or 12 rounds (a bound, so a misbehaving
    /// server cannot spin the UI forever). `isBusy` serialises it against scenarios and reconnects.
    public func syncNow() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await performSync()
    }

    private func performSync() async {
        guard let sync, canSync else {
            if report != nil, !canSync { note("not syncing: server is outside what this client supports") }
            return
        }
        let attemptsBefore = await sync.attemptsMade
        var rounds = 0
        loop: while rounds < 12 {
            rounds += 1
            let outcome = await sync.pump()
            switch outcome {
            case let .applied(events, duplicates):
                let epoch = await sync.cursor?.epoch ?? "?"
                if !events.isEmpty {
                    transcript += events.map { TranscriptLine(event: $0, epoch: epoch) }
                    if transcript.count > Self.transcriptCap { transcript.removeFirst(transcript.count - Self.transcriptCap) }
                    let first = events.first?.sequence ?? 0, last = events.last?.sequence ?? 0
                    note("+\(events.count) event\(events.count == 1 ? "" : "s") (#\(first)–#\(last), \(epoch))")
                }
                if duplicates > 0 { note("dropped \(duplicates) duplicate\(duplicates == 1 ? "" : "s") already shown") }
                if events.isEmpty { break loop }
            case let .rebased(from, to, after):
                let before = transcript.count
                transcript.removeAll { $0.event.sequence > after }
                let removed = before - transcript.count
                retractedTotal = retractedTotal.addingReportingOverflow(removed).overflow ? .max : retractedTotal + removed
                note("⟲ history replaced \(from) → \(to): retracted \(removed) event\(removed == 1 ? "" : "s") after #\(after), refetching")
            case .resyncRequired:
                retractedTotal = retractedTotal.addingReportingOverflow(transcript.count).overflow ? .max : retractedTotal + transcript.count
                transcript.removeAll()
                note("cursor expired on the server: full resync")
            case let .exhausted(attempts, lastError):
                note("✕ gave up after \(attempts) attempts (\(lastError)); will retry on next sync")
                break loop
            case let .fatal(message):
                note("✕ stopped: \(message)")
                break loop
            case .busy, .discardedStale:
                break loop
            }
        }
        let used = await sync.attemptsMade - attemptsBefore
        if used > rounds { note("needed \(used) requests for \(rounds) round\(rounds == 1 ? "" : "s") (retries with jittered backoff)") }
        cursor = await sync.cursor
    }

    public func run(_ scenario: Scenario) async {
        guard let server, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch scenario {
        case .stream:
            await server.append(3)
        case .restart:
            note("server process restarting (history persists, epoch unchanged)")
            await server.restart(unavailableFor: 3)
            await server.append(2)
        case .restore:
            let count = await server.events.count
            note("server database restored from an older backup")
            await server.restoreBackup(keeping: max(0, count - 3))
        case .outage:
            note("server unreachable for 8 requests")
            await server.failNext(Array(repeating: 503, count: 8))
        case .upgrade:
            note("customer installs 2.2.0")
            await server.upgrade(to: ServerVersion(2, 2, 0), features: [.sessionEvents, .eventCursor, .toolConfirmation, .fileOutputs])
            await connect()
        case .misdirect:
            // A feature (here, a crash-log upload) tries to send session content to a third-party host.
            // It goes through the same guarded client as the agent traffic, so it never leaves the device.
            note("a feature tries to upload this session to telemetry.vendor.example")
            if let guarded, let url = Self.offTenantURL {
                do {
                    _ = try await guarded.send(HTTPRequest(method: "POST", url: url))
                    note("upload sent (unexpected)")
                } catch {
                    note("✕ refused by the residency guard: \(error)")
                }
            }
            return
        }
        await performSync()
    }

    static let offTenantURL = URL(string: "https://telemetry.vendor.example/v1/upload")

    private func note(_ line: String) {
        log.insert(line, at: 0)
        if log.count > Self.logCap { log.removeLast(log.count - Self.logCap) }
        revision &+= 1
    }
}

@MainActor @Observable
public final class FleetModel {
    public let tenants: [TenantModel]
    public let audit = ResidencyAudit()
    public var path: [String] = []
    public private(set) var refusedRequests = 0
    public private(set) var isReady = false
    let launchTenant: Int?
    let launchScenario: Scenario?
    /// Section the detail screen scrolls to once data has loaded ("session" or "log"); `nil` stays at the top.
    public let launchFocus: String?

    /// `launchTenant` / `launchScenario` / `launchFocus` let a headless run (simctl launch arguments) open a
    /// tenant, play a scenario and scroll to a section without taps.
    public init(seeds: [TenantSeed], launchTenant: Int? = nil, launchScenario: Scenario? = nil, launchFocus: String? = nil) {
        tenants = seeds.enumerated().map { TenantModel(seed: $0.element, index: $0.offset) }
        self.launchTenant = launchTenant
        self.launchScenario = launchScenario
        self.launchFocus = launchFocus
    }

    public func tenant(id: String) -> TenantModel? { tenants.first { $0.id == id } }

    @ObservationIgnored private var bootstrapStarted = false

    public func bootstrap() async {
        // Set before the first await: a re-fired `.task` must not seed and connect everything twice.
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        var servers: [SimulatedAgentServer] = []
        for t in tenants {
            if let s = t.server {
                await s.append(t.preloadedEvents)
                servers.append(s)
            }
        }
        let network = await SimulatedNetwork(servers: servers)
        for t in tenants {
            t.attach(network: network, audit: audit)
            await t.connect()
            await t.syncNow()
        }
        refusedRequests = await audit.totalRefused
        isReady = true
        if let i = launchTenant, tenants.indices.contains(i) {
            path = [tenants[i].id]
            if let s = launchScenario {
                await tenants[i].run(s)
                await refreshAudit()
            }
        }
    }

    public func refreshAudit() async { refusedRequests = await audit.totalRefused }
}
#endif
