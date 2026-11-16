import Foundation

/// Where a tenant's agent service runs.
public enum TopologyKind: String, Sendable, Hashable, CaseIterable {
    /// Anthropic operates the service.
    case hosted
    /// The customer runs the service inside its own perimeter, on its own release schedule.
    case selfHosted = "self-hosted"
}

/// A validated tenant configuration. The only way to get one is `ManagedConfigParser.parse`, so every
/// value in here has already passed the residency and URL rules below.
public struct TenantConfiguration: Sendable, Hashable {
    public let tenantID: String
    public let topology: TopologyKind
    /// The single origin session traffic goes to.
    public let baseURL: URL
    /// Path prefix in front of the API routes (self-hosted deployments often sit behind a gateway path).
    public let pathPrefix: String
    /// Exact, lower-cased host names this tenant's traffic may reach. Enforced by `ResidencyEnforcingClient`.
    public let allowedHosts: Set<String>
    /// Plain HTTP is accepted only for loopback hosts, and only when the payload opts in (local development).
    public let allowsLoopbackHTTP: Bool
    public let region: String?

    /// The hosted service's origin. A self-hosted tenant may never list this host: the device must not send
    /// that tenant's session content anywhere except the tenant's own server.
    public static let hostedBaseURL = URL(string: "https://api.anthropic.com")! // Literal, well-formed URL: cannot fail.
    public static var hostedHost: String { hostedBaseURL.host ?? "api.anthropic.com" }
}

/// Why a managed-configuration payload was rejected. The app shows this instead of connecting.
public enum ConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(key: String)
    case wrongType(key: String)
    case invalidTenantID(String)
    case unknownTopology(String)
    case invalidURL(String)
    case insecureScheme(String)
    case credentialsInURL
    case baseHostNotAllowed(host: String)
    case hostedEndpointInSelfHostedAllowlist
    case emptyAllowlist
    case invalidHost(String)
    case invalidPathPrefix(String)

    public var description: String {
        switch self {
        case .missing(let k): return "missing key '\(k)'"
        case .wrongType(let k): return "key '\(k)' has the wrong type"
        case .invalidTenantID(let t): return "invalid tenant id '\(t)'"
        case .unknownTopology(let t): return "unknown topology '\(t)'"
        case .invalidURL(let u): return "invalid base URL '\(u)'"
        case .insecureScheme(let u): return "base URL must use https: '\(u)'"
        case .credentialsInURL: return "base URL must not embed credentials"
        case .baseHostNotAllowed(let h): return "base host '\(h)' is not in the residency allowlist"
        case .hostedEndpointInSelfHostedAllowlist: return "a self-hosted tenant may not allow the hosted API host"
        case .emptyAllowlist: return "the residency allowlist is empty"
        case .invalidHost(let h): return "invalid allowlist host '\(h)'"
        case .invalidPathPrefix(let p): return "invalid path prefix '\(p)'"
        }
    }
}

/// Parses the managed app configuration an MDM pushes (`com.apple.configuration.managed`).
///
/// Keys: `tenantID` (String), `topology` ("hosted" | "self-hosted"), `baseURL` (String, self-hosted only),
/// `allowedHosts` ([String]), `pathPrefix` (String, optional), `region` (String, optional),
/// `allowLoopbackHTTP` (Bool, optional). Read the payload with
/// `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")` and pass it in.
public enum ManagedConfigParser {
    public static func parse(_ payload: [String: any Sendable]) -> Result<TenantConfiguration, ConfigurationError> {
        do { return .success(try parseThrowing(payload)) } catch let error as ConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.wrongType(key: "?")) // Unreachable: parseThrowing only throws ConfigurationError.
        }
    }

    static let tenantIDCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    static let hostCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
    static let pathPrefixCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")

    private static func parseThrowing(_ p: [String: any Sendable]) throws -> TenantConfiguration {
        let tenantRaw = try string(p, "tenantID").trimmingWhitespace()
        guard (1...64).contains(tenantRaw.count), tenantRaw.allSatisfy({ tenantIDCharacters.contains($0) }) else {
            throw ConfigurationError.invalidTenantID(tenantRaw)
        }
        let topologyRaw = try string(p, "topology").trimmingWhitespace().lowercased()
        guard let topology = TopologyKind(rawValue: topologyRaw) else { throw ConfigurationError.unknownTopology(topologyRaw) }
        let allowLoopback = try optionalBool(p, "allowLoopbackHTTP") ?? false

        let baseURL: URL
        switch topology {
        case .hosted:
            baseURL = TenantConfiguration.hostedBaseURL
        case .selfHosted:
            baseURL = try validatedBaseURL(try string(p, "baseURL"), allowLoopbackHTTP: allowLoopback)
        }
        let baseHost = (baseURL.host ?? "").lowercased()

        var hosts: Set<String>
        if let list = p["allowedHosts"] {
            guard let array = list as? [String] else { throw ConfigurationError.wrongType(key: "allowedHosts") }
            hosts = []
            for raw in array {
                let host = raw.trimmingWhitespace().lowercased()
                guard !host.isEmpty, host.count <= 253, host.allSatisfy({ hostCharacters.contains($0) }),
                      !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
                    throw ConfigurationError.invalidHost(raw)
                }
                hosts.insert(host)
            }
        } else if topology == .hosted {
            hosts = [baseHost] // Hosted tenants may omit the list; the only origin is the hosted API.
        } else {
            throw ConfigurationError.missing(key: "allowedHosts")
        }
        guard !hosts.isEmpty else { throw ConfigurationError.emptyAllowlist }
        guard hosts.contains(baseHost) else { throw ConfigurationError.baseHostNotAllowed(host: baseHost) }
        if topology == .selfHosted, hosts.contains(TenantConfiguration.hostedHost) {
            throw ConfigurationError.hostedEndpointInSelfHostedAllowlist
        }
        // A hosted tenant has exactly one origin; extra entries would only widen what the guard lets out.
        if topology == .hosted, let extra = hosts.subtracting([baseHost]).sorted().first {
            throw ConfigurationError.invalidHost(extra)
        }

        let prefix = try optionalString(p, "pathPrefix")?.trimmingWhitespace() ?? ""
        if !prefix.isEmpty {
            guard prefix.count <= 128, prefix.allSatisfy({ pathPrefixCharacters.contains($0) }),
                  prefix.hasPrefix("/"), !prefix.hasSuffix("/"), !prefix.contains(".."),
                  !prefix.contains("?"), !prefix.contains("#"), !prefix.contains("//"), !prefix.contains("%") else {
                throw ConfigurationError.invalidPathPrefix(prefix)
            }
        }
        let region = try optionalString(p, "region")?.trimmingWhitespace()
        return TenantConfiguration(
            tenantID: tenantRaw, topology: topology, baseURL: baseURL,
            pathPrefix: topology == .hosted ? "" : prefix,
            allowedHosts: hosts, allowsLoopbackHTTP: allowLoopback,
            region: (region?.isEmpty ?? true) ? nil : region
        )
    }

    static func isLoopback(_ host: String) -> Bool {
        // IPv6 loopback is deliberately absent: allowlist entries are host names / IPv4 only.
        host == "localhost" || host == "127.0.0.1"
    }

    private static func validatedBaseURL(_ raw: String, allowLoopbackHTTP: Bool) throws -> URL {
        let text = raw.trimmingWhitespace()
        guard let comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty else {
            throw ConfigurationError.invalidURL(text)
        }
        guard comps.user == nil, comps.password == nil else { throw ConfigurationError.credentialsInURL }
        guard comps.query == nil, comps.fragment == nil, comps.path.isEmpty || comps.path == "/" else {
            throw ConfigurationError.invalidURL(text) // Paths belong in `pathPrefix`, where they are validated.
        }
        switch scheme {
        case "https": break
        case "http" where allowLoopbackHTTP && isLoopback(host): break
        default: throw ConfigurationError.insecureScheme(text)
        }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = comps.port
        guard let url = clean.url else { throw ConfigurationError.invalidURL(text) }
        return url
    }

    private static func string(_ p: [String: any Sendable], _ key: String) throws -> String {
        guard let value = p[key] else { throw ConfigurationError.missing(key: key) }
        guard let s = value as? String else { throw ConfigurationError.wrongType(key: key) }
        return s
    }

    private static func optionalString(_ p: [String: any Sendable], _ key: String) throws -> String? {
        guard let value = p[key] else { return nil }
        guard let s = value as? String else { throw ConfigurationError.wrongType(key: key) }
        return s
    }

    private static func optionalBool(_ p: [String: any Sendable], _ key: String) throws -> Bool? {
        guard let value = p[key] else { return nil }
        guard let b = value as? Bool else { throw ConfigurationError.wrongType(key: key) }
        return b
    }
}
