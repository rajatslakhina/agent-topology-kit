import Foundation

// MARK: - HTTP seam

public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]

    public init(method: String = "GET", url: URL, headers: [String: String] = [:]) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// The only way bytes leave the device. Production wraps `URLSession`; tests and the demo use
/// `SimulatedNetwork`. `ResidencyEnforcingClient` decorates whichever one is used.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Supplies a short-lived bearer token. The device never holds an organization API key: the customer's
/// backend (or its identity provider, for self-hosted) mints a token scoped to this user and tenant.
public protocol CredentialProvider: Sendable {
    func bearerToken() async throws -> String
}

public struct StaticCredentials: CredentialProvider {
    let token: String
    public init(token: String) { self.token = token }
    public func bearerToken() async throws -> String { token }
}

// MARK: - Domain types

public enum TransportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Transient: timeouts, 408, 429, 5xx, a server mid-restart. Safe to retry with backoff.
    case retryable(String)
    /// Will not succeed on retry: auth, bad request, unknown route.
    case fatal(String)
    /// The server pruned history past the client's cursor (HTTP 410). The client must resync from zero.
    case cursorExpired
    /// The body did not decode into the contract's shape.
    case malformed(String)
    /// The residency guard refused to send the request.
    case residency(String)

    public var description: String {
        switch self {
        case .retryable(let m): return "retryable: \(m)"
        case .fatal(let m): return "fatal: \(m)"
        case .cursorExpired: return "cursor expired"
        case .malformed(let m): return "malformed: \(m)"
        case .residency(let m): return "residency: \(m)"
        }
    }
}

public struct SessionEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case user, agent, toolUse = "tool_use", toolResult = "tool_result", status, other
    }

    public let sequence: UInt64
    public let kind: Kind
    public let text: String
    public var id: UInt64 { sequence }

    public init(sequence: UInt64, kind: Kind, text: String) {
        self.sequence = sequence
        self.kind = kind
        self.text = text
    }
}

/// One page of a session's event history plus the lineage the client needs to resume safely.
public struct EventPage: Sendable, Hashable {
    public let epoch: String
    /// The highest sequence the server holds in this epoch.
    public let highWater: UInt64
    /// For a history that replaced an older one: the epoch it replaced and the last sequence it inherited
    /// unchanged. Both `nil` for an original history. The client retracts everything after `forkPoint`.
    public let previousEpoch: String?
    public let forkPoint: UInt64?
    public let events: [SessionEvent]

    public init(epoch: String, highWater: UInt64, previousEpoch: String? = nil, forkPoint: UInt64? = nil, events: [SessionEvent]) {
        self.epoch = epoch
        self.highWater = highWater
        self.previousEpoch = previousEpoch
        self.forkPoint = forkPoint
        self.events = events
    }
}

/// The port every screen and every sync loop depends on. Two adapters implement it, and both must pass
/// `TransportContract`; nothing above this line knows which topology it is talking to.
public protocol ManagedAgentsTransport: Sendable {
    var topology: TopologyKind { get }
    func describe() async throws -> ServerDescriptor
    /// Events with `sequence > after` (all events when `after` is `nil`), oldest first, at most `limit`.
    func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage
}

// MARK: - Shared wire handling

/// The wire shape both adapters speak. The routes and JSON here are an illustrative stand-in for the
/// real Managed Agents API: the point of the adapter layer is that changing them touches only this file.
enum Wire {
    struct Descriptor: Codable {
        let version: String
        let features: [String]
        let epoch: String
    }

    struct Page: Codable {
        struct Event: Codable {
            let seq: UInt64
            let kind: String
            let text: String
        }
        let epoch: String
        let high_water: UInt64
        let previous_epoch: String?
        let fork_point: UInt64?
        let events: [Event]
    }

    static let pageLimitRange = 1...500
    static let sessionIDCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Session ids go into a URL path: anything but a short token is refused before a request is built.
    static func validSessionID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { sessionIDCharacters.contains($0) }
    }

    /// Status mapping is part of the contract: both adapters must classify errors identically, or the
    /// retry loop behaves differently per topology.
    static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200...299: return
        case 410: throw TransportError.cursorExpired
        case 408, 429, 500...599: throw TransportError.retryable("HTTP \(response.status)")
        default: throw TransportError.fatal("HTTP \(response.status)")
        }
    }

    static func decodeDescriptor(_ data: Data, topology: TopologyKind) throws -> ServerDescriptor {
        let wire: Descriptor
        do { wire = try JSONDecoder().decode(Descriptor.self, from: data) } catch {
            throw TransportError.malformed("descriptor did not decode")
        }
        guard let version = ServerVersion(parsing: wire.version) else {
            throw TransportError.malformed("unparseable server version '\(wire.version)'")
        }
        guard !wire.epoch.isEmpty else { throw TransportError.malformed("empty epoch") }
        return ServerDescriptor(
            version: version,
            advertised: Set(wire.features.compactMap(Feature.init(rawValue:))),
            epoch: wire.epoch, topology: topology
        )
    }

    static func decodePage(_ data: Data) throws -> EventPage {
        let wire: Page
        do { wire = try JSONDecoder().decode(Page.self, from: data) } catch {
            throw TransportError.malformed("event page did not decode")
        }
        guard !wire.epoch.isEmpty else { throw TransportError.malformed("empty epoch") }
        return EventPage(
            epoch: wire.epoch, highWater: wire.high_water,
            previousEpoch: wire.previous_epoch, forkPoint: wire.fork_point,
            events: wire.events.map {
                SessionEvent(sequence: $0.seq, kind: SessionEvent.Kind(rawValue: $0.kind) ?? .other, text: $0.text)
            }
        )
    }

    static func url(base: URL, prefix: String, path: String, query: String? = nil) throws -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        text += prefix + path
        if let query { text += "?" + query }
        guard let url = URL(string: text) else { throw TransportError.fatal("could not build URL") }
        return url
    }
}

// MARK: - Adapters

/// Adapter for the hosted topology. The origin and the `anthropic-version` header follow the hosted API; the
/// bearer token (minted by the customer's backend), routes and bodies are this package's illustrative
/// assumptions (see `Wire`), not real endpoints or auth on that host.
public struct HostedTransport: ManagedAgentsTransport {
    public static let apiVersionHeader = "anthropic-version"
    public static let apiVersion = "2023-06-01"

    let client: any HTTPClient
    let credentials: any CredentialProvider
    let baseURL: URL
    public var topology: TopologyKind { .hosted }

    public init(client: any HTTPClient, credentials: any CredentialProvider, baseURL: URL = TenantConfiguration.hostedBaseURL) {
        self.client = client
        self.credentials = credentials
        self.baseURL = baseURL
    }

    private func headers() async throws -> [String: String] {
        ["Authorization": "Bearer " + (try await credentials.bearerToken()), Self.apiVersionHeader: Self.apiVersion]
    }

    public func describe() async throws -> ServerDescriptor {
        let request = HTTPRequest(url: try Wire.url(base: baseURL, prefix: "", path: "/v1/agent-server"), headers: try await headers())
        let response = try await client.send(request)
        try Wire.check(response)
        return try Wire.decodeDescriptor(response.body, topology: .hosted)
    }

    public func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
        guard Wire.validSessionID(session) else { throw TransportError.fatal("invalid session id") }
        let lim = Saturating.clamp(limit, to: Wire.pageLimitRange)
        let query = "limit=\(lim)" + (after.map { "&after=\($0)" } ?? "")
        let url = try Wire.url(base: baseURL, prefix: "", path: "/v1/sessions/\(session)/events", query: query)
        let response = try await client.send(HTTPRequest(url: url, headers: try await headers()))
        try Wire.check(response)
        return try Wire.decodePage(response.body)
    }
}

/// Adapter for a customer-operated deployment: tenant base URL, optional gateway path prefix, and the
/// tenant header the customer's gateway routes on.
public struct SelfHostedTransport: ManagedAgentsTransport {
    public static let tenantHeader = "X-Tenant-ID"

    let client: any HTTPClient
    let credentials: any CredentialProvider
    let baseURL: URL
    let pathPrefix: String
    let tenantID: String
    public var topology: TopologyKind { .selfHosted }

    public init(client: any HTTPClient, credentials: any CredentialProvider, baseURL: URL, pathPrefix: String, tenantID: String) {
        self.client = client
        self.credentials = credentials
        self.baseURL = baseURL
        self.pathPrefix = pathPrefix
        self.tenantID = tenantID
    }

    private func headers() async throws -> [String: String] {
        ["Authorization": "Bearer " + (try await credentials.bearerToken()), Self.tenantHeader: tenantID]
    }

    public func describe() async throws -> ServerDescriptor {
        let url = try Wire.url(base: baseURL, prefix: pathPrefix, path: "/v1/agent-server")
        let response = try await client.send(HTTPRequest(url: url, headers: try await headers()))
        try Wire.check(response)
        return try Wire.decodeDescriptor(response.body, topology: .selfHosted)
    }

    public func events(session: String, after: UInt64?, limit: Int) async throws -> EventPage {
        guard Wire.validSessionID(session) else { throw TransportError.fatal("invalid session id") }
        let lim = Saturating.clamp(limit, to: Wire.pageLimitRange)
        let query = "limit=\(lim)" + (after.map { "&after=\($0)" } ?? "")
        let url = try Wire.url(base: baseURL, prefix: pathPrefix, path: "/v1/sessions/\(session)/events", query: query)
        let response = try await client.send(HTTPRequest(url: url, headers: try await headers()))
        try Wire.check(response)
        return try Wire.decodePage(response.body)
    }
}

/// The composition root for transports: the one place that looks at `topology`.
public enum TransportFactory {
    public static func make(for config: TenantConfiguration, network: any HTTPClient,
                            credentials: any CredentialProvider, audit: ResidencyAudit) -> any ManagedAgentsTransport {
        let guarded = ResidencyEnforcingClient(inner: network, configuration: config, audit: audit)
        switch config.topology {
        case .hosted:
            return HostedTransport(client: guarded, credentials: credentials, baseURL: config.baseURL)
        case .selfHosted:
            return SelfHostedTransport(client: guarded, credentials: credentials, baseURL: config.baseURL,
                                       pathPrefix: config.pathPrefix, tenantID: config.tenantID)
        }
    }
}
