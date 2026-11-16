import XCTest
@testable import AgentTopology

final class SaturatingTests: XCTestCase {
    func testAdditionSaturatesAtBothEnds() {
        XCTAssertEqual(Saturating.add(UInt64.max, 1), .max)
        XCTAssertEqual(Saturating.add(UInt64.max - 1, 1), .max)
        XCTAssertEqual(Saturating.add(UInt64(2), 3), 5)
        XCTAssertEqual(Saturating.add(Int.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int.min, -1), .min)
        XCTAssertEqual(Saturating.add(-2, 5), 3)
    }

    func testMultiplicationSaturatesWithTheRightSign() {
        XCTAssertEqual(Saturating.multiply(Int.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
    }

    func testClamp() {
        XCTAssertEqual(Saturating.clamp(0, to: 1...500), 1)
        XCTAssertEqual(Saturating.clamp(Int.max, to: 1...500), 500)
        XCTAssertEqual(Saturating.clamp(42, to: 1...500), 42)
    }

    /// A sequence at the top of the range followed by the "next" one must not wrap to 0 and be accepted.
    func testSequencerDoesNotWrapPastTheMaximumSequence() {
        var s = EventSequencer(cursor: EventCursor(epoch: "ep-1", sequence: .max - 1))
        XCTAssertEqual(s.ingest(page(high: .max, [.max])), .applied(newEvents: [ev(.max)], duplicatesDropped: 0))
        XCTAssertEqual(s.cursor?.sequence, .max)
    }
}
