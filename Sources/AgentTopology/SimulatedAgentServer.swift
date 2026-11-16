import Foundation

/// An in-process stand-in for one deployment of the agent service, speaking the same illustrative wire
/// format as the adapters. It is the fixture for `TransportContract` and the backend of the demo app.
///
/// It models the operational events a client has to survive:
/// - `restart()`: the process restarts; history lives in the database, so the epoch is unchanged, but the
///   next requests fail with 503 while it comes back.
/// - `restoreBackup(keeping:)`: the database is restored from an older backup; a new epoch begins that
///   inherits the first `keeping` events and then diverges.
/// - `upgrade(to:features:)`: the customer installs a different release.
public actor SimulatedAgentServer: HTTPClient {
    public struct Profile: Sendable, Hashable {
        public var version: ServerVersion
        public var features: Set<Feature>
        public var topology: TopologyKind
        public var baseURL: URL
        public var pathPrefix: String
        public var tenantID: String

        public init(version: ServerVersion, features: Set<Feature>, topology: TopologyKind, baseURL: URL, pathPrefix: String = "", tenantID: String = "") {
            self.version = version
            self.features = features
            self.topology = topology
            self.baseURL = baseURL
            self.pathPrefix = pathPrefix
            self.tenantID = tenantID
        }
    }

    public private(set) var profile: Profile
    public private(set) var epoch: String
    public private(set) var previousEpoch: String?
    public private(set) var forkPoint: UInt64?
    /// Sequences are always `1...events.count`, so `events[seq - 1]` is the event with that sequence.
    public private(set) var events: [SessionEvent] = []
    public private(set) var requestCount = 0
    private var epochCounter = 1
    private var scriptIndex = 0
    private var pendingFailures: [Int] = []
    /// When `true` the server leaves `previous_epoch`/`fork_point` out of every page, like a deployment
    /// that predates lineage reporting. Clients must then retract everything on an epoch change, and the
    /// contract suite's lineage clause must fail.
    public private(set) var lineageOmitted = false

    public func setLineageOmitted(_ value: Bool) { lineageOmitted = value }

    /// Hard cap so a demo left running cannot grow without bound.
    public static let maxEvents = 10_000

    public init(profile: Profile) {
        self.profile = profile
        self.epoch = "ep-1"
    }

    // MARK: Operations

    public func append(_ count: Int) {
        let n = Saturating.clamp(count, to: 0...1_000)
        for _ in 0..<n where events.count < Self.maxEvents {
            let line = Self.script[scriptIndex % Self.script.count]
            scriptIndex = (scriptIndex + 1) % Self.script.count
            events.append(SessionEvent(sequence: UInt64(events.count + 1), kind: line.0, text: line.1))
        }
    }

    public func restart(unavailableFor requests: Int = 2) {
        failNext(Array(repeating: 503, count: Saturating.clamp(requests, to: 0...50)))
    }

    public func restoreBackup(keeping kept: Int, thenAppend divergent: Int = 2) {
        let keep = Saturating.clamp(kept, to: 0...events.count)
        previousEpoch = epoch
        forkPoint = UInt64(keep)
        epochCounter = Saturating.add(epochCounter, 1)
        epoch = "ep-\(epochCounter)"
        events.removeLast(events.count - keep)
        for i in 0..<Saturating.clamp(divergent, to: 0...100) where events.count < Self.maxEvents {
            events.append(SessionEvent(sequence: UInt64(events.count + 1), kind: .status,
                                       text: "Written after the restore (\(i + 1)): replaces history you may have seen"))
        }
    }

    public func upgrade(to version: ServerVersion, features: Set<Feature>) {
        profile.version = version
        profile.features = features
    }

    public func failNext(_ statuses: [Int]) {
        // Bounded in total, not just per call, so repeated scenarios cannot grow the queue without limit.
        pendingFailures.append(contentsOf: statuses.prefix(max(0, 100 - pendingFailures.count)))
    }

    // MARK: HTTP

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount = Saturating.add(requestCount, 1)
        guard request.url.host?.lowercased() == profile.baseURL.host?.lowercased() else {
            throw TransportError.retryable("could not connect to \(request.url.host ?? "?")")
        }
        if !pendingFailures.isEmpty { return HTTPResponse(status: pendingFailures.removeFirst()) }
        guard let auth = request.headers["Authorization"], auth.hasPrefix("Bearer "), auth.count > 7 else {
            return HTTPResponse(status: 401)
        }
        switch profile.topology {
        case .hosted:
            guard request.headers[HostedTransport.apiVersionHeader] != nil else { return HTTPResponse(status: 400) }
        case .selfHosted:
            guard request.headers[SelfHostedTransport.tenantHeader] == profile.tenantID else { return HTTPResponse(status: 403) }
        }
        let path = request.url.path
        guard path.hasPrefix(profile.pathPrefix) else { return HTTPResponse(status: 404) }
        let route = String(path.dropFirst(profile.pathPrefix.count))

        if route == "/v1/agent-server" {
            let body = Wire.Descriptor(version: profile.version.description,
                                       features: profile.features.map(\.rawValue).sorted(), epoch: epoch)
            return HTTPResponse(status: 200, body: try JSONEncoder().encode(body))
        }
        let parts = route.split(separator: "/")
        if parts.count == 4, parts[0] == "v1", parts[1] == "sessions", parts[3] == "events" {
            return try eventsResponse(query: URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        }
        return HTTPResponse(status: 404)
    }

    private func eventsResponse(query: [URLQueryItem]) throws -> HTTPResponse {
        func value(_ name: String) -> UInt64? { query.first(where: { $0.name == name })?.value.flatMap(UInt64.init) }
        let supportsCursor = profile.features.contains(.eventCursor)
        // A server without the cursor feature ignores `after` and `limit` and returns everything.
        let after = supportsCursor ? (value("after") ?? 0) : 0
        let limit = supportsCursor ? Int(clamping: value("limit") ?? 50) : Int.max
        let start = Int(clamping: min(after, UInt64(events.count))) // index of the first event with seq > after
        let slice = events[start...].prefix(max(0, limit))
        let page = Wire.Page(
            epoch: epoch, high_water: UInt64(events.count),
            previous_epoch: lineageOmitted ? nil : previousEpoch,
            fork_point: lineageOmitted ? nil : forkPoint,
            events: slice.map { Wire.Page.Event(seq: $0.sequence, kind: $0.kind.rawValue, text: $0.text) }
        )
        return HTTPResponse(status: 200, body: try JSONEncoder().encode(page))
    }

    static let script: [(SessionEvent.Kind, String)] = [
        (.user, "Summarise last night's failed builds and open a ticket for the worst one."),
        (.agent, "Reading the CI history for the last 24 hours."),
        (.toolUse, "ci.list_runs(branch: main, since: 24h)"),
        (.toolResult, "14 runs, 3 failed: two flaky UI tests, one linker error"),
        (.agent, "The linker error is new: an undefined symbol after the SwiftPM bump."),
        (.toolUse, "tickets.create(title: \"Linker error after package bump\")"),
        (.toolResult, "Created IOS-4812"),
        (.agent, "Opened IOS-4812 and linked the failing run."),
        (.status, "Session idle"),
    ]
}

/// Routes requests to simulated servers by host, like DNS would. An unknown host fails to connect.
public struct SimulatedNetwork: HTTPClient {
    let servers: [String: SimulatedAgentServer]

    public init(servers: [SimulatedAgentServer]) async {
        var map: [String: SimulatedAgentServer] = [:]
        for server in servers {
            if let host = await server.profile.baseURL.host?.lowercased() { map[host] = server }
        }
        self.servers = map
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let host = request.url.host?.lowercased(), let server = servers[host] else {
            throw TransportError.retryable("could not connect to \(request.url.host ?? "?")")
        }
        return try await server.send(request)
    }
}
