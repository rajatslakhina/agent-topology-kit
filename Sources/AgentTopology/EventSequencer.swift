/// Where the client is in a session's history: a sequence number *within a lineage*. A sequence number
/// on its own is meaningless once a server restores an older backup and starts reusing numbers.
public struct EventCursor: Sendable, Hashable {
    public let epoch: String
    public let sequence: UInt64
}

public enum IngestOutcome: Sendable, Hashable {
    /// New events, in order, plus how many already-seen events the page repeated.
    case applied(newEvents: [SessionEvent], duplicatesDropped: Int)
    /// The page skipped ahead. Nothing was applied and the cursor did not move; refetch from the cursor.
    case gap(expected: UInt64, received: UInt64)
    /// The server's history was replaced. The caller retracts every shown event after `retractAfter`
    /// and refetches; the cursor is already moved to (`toEpoch`, `retractAfter`).
    case rebased(fromEpoch: String, toEpoch: String, retractAfter: UInt64)
    /// The page broke the contract (non-monotonic, sequence 0, history shrank inside one epoch).
    case malformed(String)
}

/// The ordering core of resumption, as a pure value type so every rule is unit-testable without I/O.
///
/// Guarantees, for everything it reports as applied:
/// 1. **Exactly once** within an epoch: sequences ≤ cursor are dropped as duplicates.
/// 2. **In order, no holes**: a page that does not continue at `cursor + 1` is rejected whole.
/// 3. **Lineage-safe**: a page from a different epoch never applies on top of the old cursor. If the
///    server names our epoch as its predecessor, events up to its fork point survive; if it does not
///    (two restores while we were offline, or a server that omits lineage), nothing survives.
public struct EventSequencer: Sendable, Hashable {
    public private(set) var cursor: EventCursor?

    public init(cursor: EventCursor? = nil) {
        self.cursor = cursor
    }

    public mutating func reset() {
        cursor = nil
    }

    public mutating func ingest(_ page: EventPage) -> IngestOutcome {
        // Contract checks first: a page must be strictly increasing and never contain sequence 0.
        var previous: UInt64 = 0
        for event in page.events {
            guard event.sequence > previous else {
                return .malformed(event.sequence == 0 ? "sequence 0 is reserved" : "events are not strictly increasing at \(event.sequence)")
            }
            previous = event.sequence
        }
        if let last = page.events.last, last.sequence > page.highWater {
            return .malformed("event \(last.sequence) is above the page's high-water mark \(page.highWater)")
        }

        guard let current = cursor else {
            return apply(page, after: 0, epoch: page.epoch)
        }

        if current.epoch != page.epoch {
            let inherited: UInt64
            if page.previousEpoch == current.epoch, let fork = page.forkPoint {
                // Also bounded by the new history's high-water mark: an inconsistent fork point must not
                // park the cursor above the server's history (every later page would be malformed).
                inherited = min(current.sequence, fork, page.highWater)
            } else {
                inherited = 0 // Unknown lineage: assume total divergence. Showing a stale event is worse than refetching.
            }
            cursor = EventCursor(epoch: page.epoch, sequence: inherited)
            return .rebased(fromEpoch: current.epoch, toEpoch: page.epoch, retractAfter: inherited)
        }

        if page.highWater < current.sequence {
            return .malformed("high-water \(page.highWater) is below the client cursor \(current.sequence) in epoch \(page.epoch); history shrank without a new epoch")
        }
        return apply(page, after: current.sequence, epoch: current.epoch)
    }

    private mutating func apply(_ page: EventPage, after position: UInt64, epoch: String) -> IngestOutcome {
        let fresh = page.events.filter { $0.sequence > position }
        let duplicates = page.events.count - fresh.count
        var expected = Saturating.add(position, 1)
        for event in fresh {
            guard event.sequence == expected else {
                return .gap(expected: expected, received: event.sequence)
            }
            expected = Saturating.add(expected, 1)
        }
        if let last = fresh.last {
            cursor = EventCursor(epoch: epoch, sequence: last.sequence)
        } else if cursor == nil {
            cursor = EventCursor(epoch: epoch, sequence: position)
        }
        return .applied(newEvents: fresh, duplicatesDropped: duplicates)
    }
}
