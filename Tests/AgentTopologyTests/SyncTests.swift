import XCTest
@testable import AgentTopology

final class RetryPolicyTests: XCTestCase {
    func testCeilingDoublesAndCaps() {
        let p = RetryPolicy(baseMilliseconds: 100, capMilliseconds: 1_000, maxAttempts: 10)
        XCTAssertEqual((1...6).map { p.ceiling(afterAttempt: $0) }, [100, 200, 400, 800, 1_000, 1_000])
    }

    func testDegenerateInputsNeverTrap() {
        let p = RetryPolicy(baseMilliseconds: Int.max / 2 + 1, capMilliseconds: Int.max, maxAttempts: Int.max)
        XCTAssertEqual(p.maxAttempts, 20)
        XCTAssertEqual(p.ceiling(afterAttempt: Int.max), Int.max)
        XCTAssertEqual(p.ceiling(afterAttempt: 0), 0)
        XCTAssertEqual(p.ceiling(afterAttempt: -3), 0)
        let q = RetryPolicy(baseMilliseconds: -5, capMilliseconds: -10, maxAttempts: -1)
        XCTAssertEqual(q.baseMilliseconds, 1)
        XCTAssertEqual(q.capMilliseconds, 1)
        XCTAssertEqual(q.maxAttempts, 1)
    }

    func testJitterIsClampedEvenForAHostileRandomSource() {
        let p = RetryPolicy(baseMilliseconds: 100, capMilliseconds: 1_000)
        XCTAssertEqual(p.delay(afterAttempt: 2, random: HostileRandom()), 200)
        XCTAssertEqual(p.delay(afterAttempt: 0, random: HostileRandom()), 0)
        for _ in 0..<200 { XCTAssertTrue((0...400).contains(p.delay(afterAttempt: 3, random: SystemRandom()))) }
    }
}

final class SessionEventSyncTests: XCTestCase {
    let policy = RetryPolicy(baseMilliseconds: 100, capMilliseconds: 1_000, maxAttempts: 4)

    func testRetriesTransientFailuresWithBackoffThenApplies() async {
        let t = ScriptedTransport([.failure(.retryable("HTTP 503")), .failure(.retryable("HTTP 503")), .success(page([1, 2]))])
        let sleeper = RecordingSleeper()
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: sleeper, random: MaxRandom())
        let outcome = await sync.pump()
        XCTAssertEqual(outcome, .applied([ev(1), ev(2)], duplicatesDropped: 0))
        XCTAssertEqual(sleeper.sleeps, [100, 200])
        let attempts = await sync.attemptsMade
        XCTAssertEqual(attempts, 3)
    }

    func testExhaustsAfterMaxAttemptsWithoutSleepingAfterTheLast() async {
        let t = ScriptedTransport(Array(repeating: .failure(.retryable("HTTP 503")), count: 10))
        let sleeper = RecordingSleeper()
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: sleeper, random: MaxRandom())
        let outcome = await sync.pump()
        XCTAssertEqual(outcome, .exhausted(attempts: 4, lastError: "HTTP 503"))
        XCTAssertEqual(sleeper.sleeps, [100, 200, 400])
        let cursor = await sync.cursor
        XCTAssertNil(cursor)
    }

    func testResumesFromTheCursorAfterAFailure() async {
        let t = ScriptedTransport([.success(page([1, 2, 3])), .failure(.retryable("HTTP 503")), .success(page([4]))])
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        _ = await sync.pump()
        _ = await sync.pump()
        let calls = await t.calls
        XCTAssertEqual(calls, [nil, 3, 3])
    }

    func testDegradedModeAlwaysAsksForFullHistoryAndDropsDuplicates() async {
        let t = ScriptedTransport([.success(page([1, 2])), .success(page([1, 2, 3]))])
        let sync = SessionEventSync(transport: t, session: "s", usesCursor: false, policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        _ = await sync.pump()
        let second = await sync.pump()
        XCTAssertEqual(second, .applied([ev(3)], duplicatesDropped: 2))
        let calls = await t.calls
        XCTAssertEqual(calls, [nil, nil])
    }

    func testGapIsRefetchedFromTheUnchangedCursor() async {
        let t = ScriptedTransport([.success(page([1])), .success(page([3])), .success(page([2, 3]))])
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        _ = await sync.pump()
        let outcome = await sync.pump()
        XCTAssertEqual(outcome, .applied([ev(2), ev(3)], duplicatesDropped: 0))
        let calls = await t.calls
        XCTAssertEqual(calls, [nil, 1, 1])
    }

    func testCursorExpiredResetsAndAsksForResync() async {
        let t = ScriptedTransport([.success(page([1, 2])), .failure(.cursorExpired), .success(page([1, 2, 3]))])
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        _ = await sync.pump()
        let expired = await sync.pump()
        XCTAssertEqual(expired, .resyncRequired)
        let cursor = await sync.cursor
        XCTAssertNil(cursor)
        let refetched = await sync.pump()
        XCTAssertEqual(refetched, .applied([ev(1), ev(2), ev(3)], duplicatesDropped: 0))
    }

    func testFatalErrorsAreNotRetried() async {
        let t = ScriptedTransport([.failure(.fatal("HTTP 403")), .success(page([1]))])
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        let outcome = await sync.pump()
        XCTAssertEqual(outcome, .fatal("fatal: HTTP 403"))
        let calls = await t.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// Reentrancy: a reset that lands while a fetch is suspended must win. The stale page is discarded.
    func testResetDuringAnInFlightFetchDiscardsTheStalePage() async {
        let t = GatedTransport(result: page([1, 2, 3]))
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        async let first = sync.pump()
        await t.waitUntilEntered(1)
        await sync.reset()
        await t.releaseAll()
        let outcome = await first
        XCTAssertEqual(outcome, .discardedStale)
        let cursor = await sync.cursor
        XCTAssertNil(cursor, "a page fetched before reset must not move the cursor after it")
    }

    /// Reentrancy: two concurrent pumps must not fetch twice for the same generation.
    func testConcurrentPumpIsBusyNotDoubleFetched() async {
        let t = GatedTransport(result: page([1]))
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        async let first = sync.pump()
        await t.waitUntilEntered(1)
        // Run the second pump concurrently and wait (bounded) until it has either finished or reached the
        // transport. A correct implementation finishes with `.busy`; a broken one enters the transport a
        // second time. Either way the gate is then opened, so the test fails instead of deadlocking.
        let done = Flag()
        let second = Task { () -> SyncOutcome in
            let r = await sync.pump()
            await done.set()
            return r
        }
        for _ in 0..<100_000 {
            if await done.isSet { break }
            if await t.enteredCount >= 2 { break }
            await Task.yield()
        }
        await t.releaseAll()
        let a = await first
        let b = await second.value
        XCTAssertEqual(a, .applied([ev(1)], duplicatesDropped: 0))
        XCTAssertEqual(b, .busy)
        let entered = await t.enteredCount
        XCTAssertEqual(entered, 1, "the transport must be called once")
    }

    /// After a reset, a new pump may start even though the stale one is still suspended.
    func testNewGenerationCanPumpWhileTheStaleOneIsSuspended() async {
        let t = GatedTransport(result: page([1]))
        let sync = SessionEventSync(transport: t, session: "s", policy: policy, sleeper: RecordingSleeper(), random: MaxRandom())
        async let stale = sync.pump()
        await t.waitUntilEntered(1)
        await sync.reset()
        async let fresh = sync.pump()
        await t.waitUntilEntered(2)
        await t.releaseAll()
        let (a, b) = await (stale, fresh)
        XCTAssertEqual(a, .discardedStale)
        XCTAssertEqual(b, .applied([ev(1)], duplicatesDropped: 0))
    }
}
