/// Client features that depend on what a particular server can do. Raw values are the strings servers
/// advertise; strings the client does not know are ignored (forward compatibility).
public enum Feature: String, Sendable, Hashable, CaseIterable, Comparable {
    case sessionEvents = "session_events"
    case eventCursor = "event_cursor"
    case toolConfirmation = "tool_confirmation"
    case memoryStores = "memory_stores"
    case fileOutputs = "file_outputs"
    case multiAgent = "multi_agent"

    public static func < (l: Feature, r: Feature) -> Bool {
        (allCases.firstIndex(of: l) ?? 0) < (allCases.firstIndex(of: r) ?? 0)
    }

    public var title: String {
        switch self {
        case .sessionEvents: return "Session events"
        case .eventCursor: return "Resumable event cursor"
        case .toolConfirmation: return "Tool confirmation"
        case .memoryStores: return "Memory stores"
        case .fileOutputs: return "File outputs"
        case .multiAgent: return "Multi-agent sessions"
        }
    }
}

/// What a server says about itself, after decoding. Produced by a transport adapter.
public struct ServerDescriptor: Sendable, Hashable {
    public let version: ServerVersion
    /// Features this deployment has switched on. A self-hosted build can be newer than a hosted-only
    /// feature and still not have it, which is why negotiation requires the advertisement, not just a version.
    public let advertised: Set<Feature>
    /// Lineage of the server's event history. Unchanged across process restarts; changes when the
    /// history is replaced (restore from backup, rollback of the database).
    public let epoch: String
    public let topology: TopologyKind

    public init(version: ServerVersion, advertised: Set<Feature>, epoch: String, topology: TopologyKind) {
        self.version = version
        self.advertised = advertised
        self.epoch = epoch
        self.topology = topology
    }
}

/// The server versions this client build was written against.
public struct SupportWindow: Sendable, Hashable {
    /// Below this, the client refuses to drive the server at all.
    public let minimumSupported: ServerVersion
    /// The newest `major.minor` line this build was tested against. Patch releases inside the line are
    /// treated as compatible; a newer line is `newerThanTested` and holds back skew-sensitive features.
    public let newestTestedLine: ServerVersion

    public init(minimumSupported: ServerVersion, newestTestedLine: ServerVersion) {
        self.minimumSupported = minimumSupported
        self.newestTestedLine = max(minimumSupported, newestTestedLine)
    }
}

/// The client's rule for one feature.
public struct FeatureRequirement: Sendable, Hashable {
    public let feature: Feature
    public let minimumVersion: ServerVersion
    /// What the screen does instead when the feature is missing. `nil` means the feature is simply hidden.
    public let degradedMode: String?
    /// Features whose wire shape has changed between lines: held back on servers newer than tested.
    public let skewSensitive: Bool

    public init(_ feature: Feature, since minimumVersion: ServerVersion, degradedMode: String? = nil, skewSensitive: Bool = false) {
        self.feature = feature
        self.minimumVersion = minimumVersion
        self.degradedMode = degradedMode
        self.skewSensitive = skewSensitive
    }
}

public enum FeatureState: Sendable, Hashable {
    case available
    case degraded(String)
    case unavailable(String)

    public var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

public enum Compatibility: Sendable, Hashable {
    case compatible
    case newerThanTested
    case unsupported(String)
}

/// The outcome of negotiation: one state per feature. Screens read this; they never branch on tenant
/// or topology, so a hosted and a self-hosted tenant with the same plan render the same UI.
public struct CapabilityPlan: Sendable, Hashable {
    public let compatibility: Compatibility
    public let states: [Feature: FeatureState]

    public func state(of feature: Feature) -> FeatureState {
        states[feature] ?? .unavailable("not negotiated")
    }

    public var counts: (available: Int, degraded: Int, unavailable: Int) {
        var a = 0, d = 0, u = 0
        for state in states.values {
            switch state {
            case .available: a += 1
            case .degraded: d += 1
            case .unavailable: u += 1
            }
        }
        return (a, d, u)
    }
}

public struct CapabilityNegotiator: Sendable {
    public let window: SupportWindow
    public let requirements: [FeatureRequirement]

    public init(window: SupportWindow, requirements: [FeatureRequirement]) {
        self.window = window
        // One rule per feature: the first one wins, so a duplicated entry cannot silently loosen a rule.
        var seen = Set<Feature>()
        self.requirements = requirements.filter { seen.insert($0.feature).inserted }
    }

    /// The rules the demo app and the tests use.
    public static let standard = CapabilityNegotiator(
        window: SupportWindow(minimumSupported: ServerVersion(1, 6, 0), newestTestedLine: ServerVersion(2, 3, 0)),
        requirements: [
            FeatureRequirement(.sessionEvents, since: ServerVersion(1, 0, 0)),
            FeatureRequirement(.eventCursor, since: ServerVersion(1, 9, 0),
                               degradedMode: "Full-history polling; duplicates dropped client-side"),
            FeatureRequirement(.toolConfirmation, since: ServerVersion(2, 0, 0),
                               degradedMode: "Approvals open the tenant's web console"),
            FeatureRequirement(.memoryStores, since: ServerVersion(2, 1, 0), skewSensitive: true),
            FeatureRequirement(.fileOutputs, since: ServerVersion(2, 2, 0),
                               degradedMode: "Files listed; download disabled"),
            FeatureRequirement(.multiAgent, since: ServerVersion(2, 3, 0), skewSensitive: true),
        ]
    )

    public func negotiate(_ server: ServerDescriptor) -> CapabilityPlan {
        if server.version < window.minimumSupported {
            let reason = "server \(server.version) is older than the minimum supported \(window.minimumSupported)"
            return CapabilityPlan(
                compatibility: .unsupported(reason),
                states: Dictionary(uniqueKeysWithValues: requirements.map { ($0.feature, FeatureState.unavailable(reason)) })
            )
        }
        let newer = server.version.featureLine > window.newestTestedLine.featureLine
        var states: [Feature: FeatureState] = [:]
        for req in requirements {
            var missing: [String] = []
            if server.version < req.minimumVersion { missing.append("needs server ≥ \(req.minimumVersion)") }
            // Both conditions are required: version alone is wrong for self-hosted builds without hosted-only
            // features; advertisement alone is wrong for servers that advertise a flag before the client's
            // minimum wire shape for it existed.
            if !server.advertised.contains(req.feature) { missing.append("not enabled on this server") }

            if missing.isEmpty {
                if newer && req.skewSensitive {
                    states[req.feature] = .unavailable("held back: server \(server.version) is newer than the tested \(window.newestTestedLine.major).\(window.newestTestedLine.minor) line")
                } else {
                    states[req.feature] = .available
                }
            } else if let degraded = req.degradedMode {
                states[req.feature] = .degraded(degraded + " (" + missing.joined(separator: "; ") + ")")
            } else {
                states[req.feature] = .unavailable(missing.joined(separator: "; "))
            }
        }
        return CapabilityPlan(compatibility: newer ? .newerThanTested : .compatible, states: states)
    }
}
