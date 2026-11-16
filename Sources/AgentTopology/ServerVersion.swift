/// A server release, parsed once at the edge ("parse, don't validate").
///
/// Self-hosted customers install releases on their own schedule, so the client meets every version in the
/// field at once. Versions arrive as strings from servers we do not control: parsing never traps and
/// rejects anything that is not `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix.
public struct ServerVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `nil` for a release build. A prerelease sorts before the release with the same core version.
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        self.prerelease = (prerelease?.isEmpty ?? true) ? nil : prerelease
    }

    /// Accepts `2.3.1`, `v2.3.1`, `2.3` (patch 0), `2.3.1-beta.2`, `2.3.1-rc-1` and `2.3.1+build.7`
    /// (build metadata is dropped). Returns `nil` for anything else,
    /// including components that overflow `Int` (`Int(String)` returns `nil` rather than trapping).
    public init?(parsing raw: String) {
        var text = Substring(raw.trimmingWhitespace())
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        // SemVer build metadata (`+build.7`) never affects precedence: validate it, then drop it.
        if let plus = text.firstIndex(of: "+") {
            let metadata = text[text.index(after: plus)...]
            guard !metadata.isEmpty, metadata.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            text = text[..<plus]
        }
        var pre: String?
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            pre = String(suffix)
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        // Bounds are guaranteed by the `2...3` guard above; read defensively anyway.
        guard let major = numbers.first, numbers.count >= 2 else { return nil }
        let minor = numbers[1]
        let patch = numbers.count == 3 ? numbers[2] : 0
        self.init(major, minor, patch, prerelease: pre)
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (l?, r?): return l < r // Simplification: lexicographic, not full SemVer §11 precedence.
        }
    }

    /// `major.minor` only. The client treats patch releases as wire-compatible (see `SupportWindow`).
    var featureLine: (Int, Int) { (major, minor) }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s = s.dropFirst() }
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
