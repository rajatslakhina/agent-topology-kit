import XCTest
@testable import AgentTopology

final class SequencerTests: XCTestCase {
    func testFreshPageAppliesFromOne() {
        var s = EventSequencer()
        XCTAssertEqual(s.ingest(page([1, 2, 3])), .applied(newEvents: [ev(1), ev(2), ev(3)], duplicatesDropped: 0))
        XCTAssertEqual(s.cursor, EventCursor(epoch: "ep-1", sequence: 3))
    }

    func testOverlappingPageDropsDuplicatesExactlyOnce() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 3))
        XCTAssertEqual(s.ingest(page([2, 3, 4, 5])), .applied(newEvents: [ev(4), ev(5)], duplicatesDropped: 2))
        XCTAssertEqual(s.ingest(page([1, 2, 3, 4, 5])), .applied(newEvents: [], duplicatesDropped: 5))
        XCTAssertEqual(s.cursor?.sequence, 5)
    }

    func testGapIsRejectedWholeAndCursorDoesNotMove() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 3))
        XCTAssertEqual(s.ingest(page([5, 6])), .gap(expected: 4, received: 5))
        XCTAssertEqual(s.ingest(page([4, 6])), .gap(expected: 5, received: 6))
        XCTAssertEqual(s.cursor?.sequence, 3)
    }

    func testFreshClientRejectsHistoryThatDoesNotStartAtOne() {
        var s = EventSequencer()
        XCTAssertEqual(s.ingest(page([2, 3])), .gap(expected: 1, received: 2))
        XCTAssertNil(s.cursor)
    }

    func testContractBreakingPagesAreMalformed() {
        var s = EventSequencer()
        guard case .malformed = s.ingest(page([1, 3, 2])) else { return XCTFail("non-monotonic") }
        guard case .malformed = s.ingest(page([1, 1])) else { return XCTFail("repeated") }
        guard case .malformed = s.ingest(page([0, 1])) else { return XCTFail("zero") }
        guard case .malformed = s.ingest(page(high: 2, [1, 2, 3])) else { return XCTFail("above high-water") }
        XCTAssertNil(s.cursor)
    }

    func testHistoryShrinkingInsideOneEpochIsMalformedNotSilentlyAccepted() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 9))
        guard case .malformed = s.ingest(page(high: 4, [])) else { return XCTFail("expected malformed") }
        XCTAssertEqual(s.cursor?.sequence, 9)
    }

    func testRebaseKeepsEventsUpToTheForkPointWhenLineageNamesOurEpoch() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 8))
        XCTAssertEqual(s.ingest(page("ep-2", high: 7, prev: "ep-1", fork: 5, [1, 2, 3, 4, 5, 6, 7])),
                       .rebased(fromEpoch: "ep-1", toEpoch: "ep-2", retractAfter: 5))
        XCTAssertEqual(s.cursor, EventCursor(epoch: "ep-2", sequence: 5))
        // The refetch continues at 6 in the new epoch.
        XCTAssertEqual(s.ingest(page("ep-2", high: 7, prev: "ep-1", fork: 5, [6, 7])),
                       .applied(newEvents: [ev(6), ev(7)], duplicatesDropped: 0))
    }

    func testRebaseNeverRetractsLessThanTheClientHasNotSeen() {
        // Fork point beyond what the client saw: nothing the client saw is retracted, but the cursor stays at what it saw.
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 3))
        XCTAssertEqual(s.ingest(page("ep-2", high: 9, prev: "ep-1", fork: 6, [])),
                       .rebased(fromEpoch: "ep-1", toEpoch: "ep-2", retractAfter: 3))
    }

    func testInconsistentForkPointAboveHighWaterDoesNotWedgeTheCursor() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 8))
        XCTAssertEqual(s.ingest(page("ep-2", high: 3, prev: "ep-1", fork: 6, [])),
                       .rebased(fromEpoch: "ep-1", toEpoch: "ep-2", retractAfter: 3))
        XCTAssertEqual(s.ingest(page("ep-2", high: 3, prev: "ep-1", fork: 6, [])),
                       .applied(newEvents: [], duplicatesDropped: 0), "the next page must not be malformed")
    }

    func testUnknownOrChainedLineageRetractsEverything() {
        var a = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 8))
        XCTAssertEqual(a.ingest(page("ep-3", high: 9, prev: "ep-2", fork: 7, [])),
                       .rebased(fromEpoch: "ep-1", toEpoch: "ep-3", retractAfter: 0))
        var b = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: 8))
        XCTAssertEqual(b.ingest(page("ep-2", high: 9, [])),
                       .rebased(fromEpoch: "ep-1", toEpoch: "ep-2", retractAfter: 0))
    }

    func testCursorAtMaximumSequenceDoesNotTrap() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: .max))
        XCTAssertEqual(s.ingest(page(high: .max, [.max])), .applied(newEvents: [], duplicatesDropped: 1))
    }

    func testEmptyFirstPageStillPinsTheEpoch() {
        var s = EventSequencer()
        XCTAssertEqual(s.ingest(page(high: 0, [])), .applied(newEvents: [], duplicatesDropped: 0))
        XCTAssertEqual(s.cursor, EventCursor(epoch: "ep-1", sequence: 0))
        guard case .rebased = s.ingest(page("ep-2", [1])) else { return XCTFail("epoch change after an empty page must rebase") }
    }
}

/// The property the README leans on: whatever pages arrive (duplicates, overlaps, retries), the applied
/// stream within an epoch is exactly 1, 2, 3, … with no repeats. Checked against the real sequencer,
/// and a deliberately broken one to show the check can fail.
final class SequencerPropertyTests: XCTestCase {
    /// Replays random overlapping pages of a 40-event history and returns every applied sequence.
    static func appliedStream(seed: UInt64, ingest: (inout EventSequencer, EventPage) -> IngestOutcome) -> [UInt64] {
        var rng = SplitMix(seed: seed)
        var s = EventSequencer()
        var out: [UInt64] = []
        var rounds = 0
        while (s.cursor?.sequence ?? 0) < 40 && rounds < 500 {
            rounds += 1
            let cur = s.cursor?.sequence ?? 0
            let back = UInt64(rng.next() % 4)               // re-deliver up to 3 already-seen events
            let start = cur >= back ? cur - back + 1 : 1
            let length = UInt64(rng.next() % 6) + 1
            let end = min(40, start + length - 1)
            guard start <= end else { continue }
            if case let .applied(events, _) = ingest(&s, page(high: 40, Array(start...end))) {
                out += events.map(\.sequence)
            }
        }
        return out
    }

    static func isExactlyOnceInOrder(_ seqs: [UInt64]) -> Bool {
        seqs == Array(1...40)
    }

    func testRealSequencerYieldsEachEventExactlyOnceInOrder() {
        for seed in 1...50 as ClosedRange<UInt64> {
            XCTAssertTrue(Self.isExactlyOnceInOrder(Self.appliedStream(seed: seed) { $0.ingest($1) }), "seed \(seed)")
        }
    }

    func testTheCheckFailsForASequencerThatDoesNotDropDuplicates() {
        // Broken: applies every event in the page regardless of the cursor.
        let broken: (inout EventSequencer, EventPage) -> IngestOutcome = { s, p in
            _ = s.ingest(p)
            return .applied(newEvents: p.events, duplicatesDropped: 0)
        }
        let failures = (1...50 as ClosedRange<UInt64>).filter { !Self.isExactlyOnceInOrder(Self.appliedStream(seed: $0, ingest: broken)) }
        XCTAssertFalse(failures.isEmpty, "the property check must reject a sequencer that re-applies duplicates")
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
