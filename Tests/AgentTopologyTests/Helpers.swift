import Foundation
@testable import AgentTopology

func ev(_ seq: UInt64, _ text: String = "e") -> SessionEvent {
    SessionEvent(sequence: seq, kind: .agent, text: text)
}

func page(_ epoch: String, high: UInt64? = nil, prev: String? = nil, fork: UInt64? = nil, _ seqs: [UInt64]) -> EventPage {
    EventPage(epoch: epoch, highWater: high ?? (seqs.last ?? 0), previousEpoch: prev, forkPoint: fork, events: seqs.map { ev($0) })
}

func page(_ seqs: [UInt64]) -> EventPage { page("ep-1", seqs) }

func page(high: UInt64, _ seqs: [UInt64]) -> EventPage { page("ep-1", high: high, seqs) }

let acmeURL = URL(string: "https://agents.acme.example")! // Literal: cannot fail.

func selfHostedProfile(_ version: ServerVersion = ServerVersion(2, 2, 0),
                       features: Set<Feature> = [.sessionEvents, .eventCursor, .toolConfirmation, .fileOutputs]) -> SimulatedAgentServer.Profile {
    .init(version: version, features: features, topology: .selfHosted, baseURL: acmeURL, pathPrefix: "/cma", tenantID: "acme")
}

func hostedProfile(_ version: ServerVersion = ServerVersion(2, 3, 1)) -> SimulatedAgentServer.Profile {
    .init(version: version, features: Set(Feature.allCases), topology: .hosted, baseURL: TenantConfiguration.hostedBaseURL)
}

func selfHostedTransport(_ server: SimulatedAgentServer) -> any ManagedAgentsTransport {
    SelfHostedTransport(client: server, credentials: StaticCredentials(token: "t"), baseURL: acmeURL, pathPrefix: "/cma", tenantID: "acme")
}

func hostedTransport(_ server: SimulatedAgentServer) -> any ManagedAgentsTransport {
    HostedTransport(client: server, credentials: StaticCredentials(token: "t"))
}

/// Records sleeps instead of sleeping.
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Int] = []
    var sleeps: [Int] { lock.withLock { _sleeps } }
    func sleep(milliseconds: Int) async throws {
        lock.withLock { _sleeps.append(milliseconds) }
    }
}

/// Always returns the upper bound, so tests see the un-jittered ceiling.
struct MaxRandom: RandomSource {
    func next(upTo bound: Int) -> Int { bound }
}

/// Returns a value outside the requested range, to prove the policy clamps whatever a source returns.
struct HostileRandom: RandomSource {
    func next(upTo bound: Int) -> Int { bound == 0 ? -5 : Int.max }
}

/// A transport whose responses are scripted per call.
actor ScriptedTransport: ManagedAgentsTransport {
    nonisolated var topology: TopologyKind { .selfHosted }
    private var script: [Result<EventPage, TransportError>]
    private(set) var calls: [UInt64?] = []

    init(_ script: [Result<EventPage, TransportError>]) { self.script = script }

    func describe() async throws -> ServerDescriptor {
        ServerDescriptor(version: ServerVersion(2, 2, 0), advertised: [], epoch: "ep-1", topology: .selfHosted)
    }

    func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
        calls.append(after)
        guard !script.isEmpty else { throw TransportError.fatal("script exhausted") }
        return try script.removeFirst().get()
    }
}

actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// A transport that suspends inside `events` until released, so a test can act while a pump is in flight.
actor GatedTransport: ManagedAgentsTransport {
    nonisolated var topology: TopologyKind { .selfHosted }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var isOpen = false
    let result: EventPage

    init(result: EventPage) { self.result = result }

    func describe() async throws -> ServerDescriptor {
        ServerDescriptor(version: ServerVersion(2, 2, 0), advertised: [], epoch: "ep-1", topology: .selfHosted)
    }

    func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
        entered += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return result
    }

    var enteredCount: Int { entered }

    /// Bounded: returns after a fixed number of yields even if `n` is never reached, so a broken
    /// implementation fails its assertions instead of hanging the suite.
    func waitUntilEntered(_ n: Int) async {
        var spins = 0
        while entered < n && spins < 100_000 {
            spins += 1
            await Task.yield()
        }
    }

    /// Releases everyone waiting and opens the gate for good, so a late caller can never deadlock a test.
    func releaseAll() {
        isOpen = true
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
}
