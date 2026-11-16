/// Arithmetic that clamps instead of trapping. Every number that reaches these helpers can come from a
/// server, a managed-configuration payload or a retry counter, so none of them may crash the client.
enum Saturating {
    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }

    static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? .max : .min }
        return result
    }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { return (a < 0) == (b < 0) ? .max : .min }
        return result
    }

    /// Clamps `value` into `range`. Works for any `Comparable`, so callers never write ad-hoc min/max chains.
    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
