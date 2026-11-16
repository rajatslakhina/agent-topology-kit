import Foundation

/// A bounded record of refused requests, for the app's diagnostics screen and support bundles.
public actor ResidencyAudit {
    public struct Entry: Sendable, Hashable {
        public let tenantID: String
        public let host: String
        public let reason: String
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    /// Counts every refusal, including ones evicted from `entries`.
    public private(set) var totalRefused: Int = 0

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    func record(_ entry: Entry) {
        totalRefused = Saturating.add(totalRefused, 1)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}

/// Decorates the network so a request can only reach the tenant's own hosts.
///
/// The check is an exact, lower-cased host match against the allowlist from managed configuration. No
/// suffix or wildcard matching: `evil-agents.acme.example` must not pass just because it ends in the
/// allowed name. HTTP is refused unless the host is loopback and the payload opted in. A refused request is
/// never handed to the inner client, so no byte of session content leaves the device.
///
/// Limitations: the match is on host, not host and port (an allowlisted host on another port passes);
/// and the guard sees the request it is given. A production `URLSession` client must also refuse
/// redirects to other hosts (`urlSession(_:task:willPerformHTTPRedirection:...)`) or the guard is bypassed.
public struct ResidencyEnforcingClient: HTTPClient {
    let inner: any HTTPClient
    let tenantID: String
    let allowedHosts: Set<String>
    let allowsLoopbackHTTP: Bool
    let audit: ResidencyAudit

    public init(inner: any HTTPClient, configuration: TenantConfiguration, audit: ResidencyAudit) {
        self.inner = inner
        self.tenantID = configuration.tenantID
        self.allowedHosts = configuration.allowedHosts
        self.allowsLoopbackHTTP = configuration.allowsLoopbackHTTP
        self.audit = audit
    }

    /// `nil` when the request may be sent; otherwise the reason it may not.
    func refusal(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "request has no host" }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "https": break
        case "http" where allowsLoopbackHTTP && ManagedConfigParser.isLoopback(host): break
        default: return "scheme '\(scheme)' not allowed"
        }
        guard allowedHosts.contains(host) else { return "host '\(host)' is outside tenant \(tenantID)'s residency allowlist" }
        return nil
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let reason = refusal(for: request.url) {
            await audit.record(.init(tenantID: tenantID, host: request.url.host ?? "?", reason: reason))
            throw TransportError.residency(reason)
        }
        return try await inner.send(request)
    }
}
