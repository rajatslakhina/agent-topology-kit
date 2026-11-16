/// Injected sleep, so tests run retries instantly and can count them.
public protocol Sleeper: Sendable {
    func sleep(milliseconds: Int) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
    }
}

/// Injected randomness for jitter. `next(upTo:)` returns a value in `0...bound`.
public protocol RandomSource: Sendable {
    func next(upTo bound: Int) -> Int
}

public struct SystemRandom: RandomSource {
    public init() {}
    public func next(upTo bound: Int) -> Int { bound <= 0 ? 0 : Int.random(in: 0...bound) }
}

/// Capped exponential backoff with full jitter.
///
/// Full jitter (a uniform delay in `0...ceiling`) is chosen over "exponential plus a little noise"
/// because a self-hosted server restart disconnects every device of that tenant at the same instant;
/// without spreading, they all reconnect in lockstep and the restarted server takes the whole fleet at once.
public struct RetryPolicy: Sendable, Hashable {
    public let baseMilliseconds: Int
    public let capMilliseconds: Int
    /// Total attempts including the first. Clamped to `1...20`.
    public let maxAttempts: Int

    public init(baseMilliseconds: Int = 200, capMilliseconds: Int = 10_000, maxAttempts: Int = 5) {
        self.baseMilliseconds = max(1, baseMilliseconds)
        self.capMilliseconds = max(self.baseMilliseconds, capMilliseconds)
        self.maxAttempts = Saturating.clamp(maxAttempts, to: 1...20)
    }

    /// The ceiling before jitter for the delay that follows failed attempt `attempt` (1-based):
    /// `min(cap, base × 2^(attempt-1))`. Never traps, for any `attempt`.
    public func ceiling(afterAttempt attempt: Int) -> Int {
        guard attempt >= 1 else { return 0 }
        var value = baseMilliseconds
        var step = 1
        while step < attempt && value < capMilliseconds {
            value = Saturating.multiply(value, 2)
            step += 1
        }
        return min(value, capMilliseconds)
    }

    public func delay(afterAttempt attempt: Int, random: any RandomSource) -> Int {
        let ceiling = ceiling(afterAttempt: attempt)
        return Saturating.clamp(random.next(upTo: ceiling), to: 0...ceiling)
    }
}

public enum SyncOutcome: Sendable, Hashable {
    case applied([SessionEvent], duplicatesDropped: Int)
    /// History was replaced on the server; retract shown events after `retractAfter`, then pump again.
    case rebased(fromEpoch: String, toEpoch: String, retractAfter: UInt64)
    /// The server pruned past our cursor; the sequencer was reset. Retract everything, then pump again.
    case resyncRequired
    /// Retries ran out. Nothing changed; the caller decides when to try again.
    case exhausted(attempts: Int, lastError: String)
    case fatal(String)
    /// Another pump for the same generation is already in flight.
    case busy
    /// `reset()` ran while this pump was suspended; its result was discarded unapplied.
    case discardedStale
}

/// Drives one session's event history: fetch, sequence, retry.
///
/// Concurrency rules (actor reentrancy is the trap here — every `await` lets other calls run):
/// - One pump per generation. A second concurrent `pump()` returns `.busy` rather than double-fetching.
/// - `reset()` bumps the generation. A pump that was suspended across the reset re-checks the generation
///   after every `await` and discards what it fetched, so a page from before a reset never lands after it.
public actor SessionEventSync {
    let transport: any ManagedAgentsTransport
    let session: String
    let policy: RetryPolicy
    let sleeper: any Sleeper
    let random: any RandomSource
    let pageLimit: Int
    /// `false` when negotiation degraded `eventCursor`: every pump asks for full history and the sequencer
    /// drops what was already applied.
    public private(set) var usesCursor: Bool

    public private(set) var sequencer = EventSequencer()
    private var generation: UInt64 = 0
    private var inFlightGeneration: UInt64?
    /// Total transport attempts, for diagnostics and tests.
    public private(set) var attemptsMade = 0

    public init(transport: any ManagedAgentsTransport, session: String, usesCursor: Bool = true,
                policy: RetryPolicy = RetryPolicy(), sleeper: any Sleeper = TaskSleeper(),
                random: any RandomSource = SystemRandom(), pageLimit: Int = 50) {
        self.transport = transport
        self.session = session
        self.usesCursor = usesCursor
        self.policy = policy
        self.sleeper = sleeper
        self.random = random
        self.pageLimit = Saturating.clamp(pageLimit, to: Wire.pageLimitRange)
    }

    public var cursor: EventCursor? { sequencer.cursor }

    public func setUsesCursor(_ value: Bool) { usesCursor = value }

    public func reset() {
        generation = Saturating.add(generation, 1)
        sequencer.reset()
    }

    public func pump() async -> SyncOutcome {
        let myGeneration = generation
        if inFlightGeneration == myGeneration { return .busy }
        inFlightGeneration = myGeneration
        defer { if inFlightGeneration == myGeneration { inFlightGeneration = nil } }

        var attempt = 0
        var lastError = ""
        while attempt < policy.maxAttempts {
            attempt += 1
            attemptsMade = Saturating.add(attemptsMade, 1)
            let page: EventPage
            do {
                page = try await transport.events(session: session, after: usesCursor ? sequencer.cursor?.sequence : nil, limit: pageLimit)
            } catch TransportError.retryable(let message) {
                lastError = message
                guard generation == myGeneration else { return .discardedStale }
                if attempt < policy.maxAttempts {
                    do { try await sleeper.sleep(milliseconds: policy.delay(afterAttempt: attempt, random: random)) } catch {
                        return .exhausted(attempts: attempt, lastError: "cancelled during backoff")
                    }
                    guard generation == myGeneration else { return .discardedStale }
                }
                continue
            } catch is CancellationError {
                // The caller's task was cancelled: not a server fault, and nothing was applied.
                return .exhausted(attempts: attempt, lastError: "cancelled")
            } catch TransportError.cursorExpired {
                guard generation == myGeneration else { return .discardedStale }
                sequencer.reset()
                return .resyncRequired
            } catch {
                guard generation == myGeneration else { return .discardedStale }
                return .fatal(String(describing: error))
            }

            // Suspension point above: a reset may have happened while the request was in flight.
            guard generation == myGeneration else { return .discardedStale }
            switch sequencer.ingest(page) {
            case let .applied(events, duplicates):
                return .applied(events, duplicatesDropped: duplicates)
            case let .rebased(from, to, retractAfter):
                return .rebased(fromEpoch: from, toEpoch: to, retractAfter: retractAfter)
            case let .gap(expected, received):
                // A hole is treated like a transient fault: refetch from the unchanged cursor, with backoff.
                lastError = "gap: expected \(expected), received \(received)"
                if attempt < policy.maxAttempts {
                    do { try await sleeper.sleep(milliseconds: policy.delay(afterAttempt: attempt, random: random)) } catch {
                        return .exhausted(attempts: attempt, lastError: "cancelled during backoff")
                    }
                    guard generation == myGeneration else { return .discardedStale }
                }
            case let .malformed(reason):
                return .fatal(reason)
            }
        }
        return .exhausted(attempts: attempt, lastError: lastError)
    }
}
