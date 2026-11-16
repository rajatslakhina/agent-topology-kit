import XCTest
@testable import AgentTopology

final class ServerVersionTests: XCTestCase {
    func testParsesReleaseAndPrefixedAndTwoComponentForms() {
        XCTAssertEqual(ServerVersion(parsing: "2.3.1"), ServerVersion(2, 3, 1))
        XCTAssertEqual(ServerVersion(parsing: " v2.3.1 "), ServerVersion(2, 3, 1))
        XCTAssertEqual(ServerVersion(parsing: "2.3"), ServerVersion(2, 3, 0))
        XCTAssertEqual(ServerVersion(parsing: "2.3.0-beta.2")?.prerelease, "beta.2")
    }

    func testAcceptsHyphenatedPrereleaseAndDropsBuildMetadata() {
        // A self-hosted build string must not take a tenant offline just because it is valid SemVer we did not expect.
        XCTAssertEqual(ServerVersion(parsing: "2.4.0-rc-1")?.prerelease, "rc-1")
        XCTAssertEqual(ServerVersion(parsing: "2.4.0+sha.abc123"), ServerVersion(2, 4, 0))
        XCTAssertEqual(ServerVersion(parsing: "2.4.0-rc.1+build-7"), ServerVersion(2, 4, 0, prerelease: "rc.1"))
        XCTAssertNil(ServerVersion(parsing: "2.4.0+"))
        XCTAssertNil(ServerVersion(parsing: "2.4.0+a b"))
    }

    func testRejectsMalformedAndOverflowingVersionsWithoutTrapping() {
        for bad in ["", "2", "1..2", "a.b.c", "1.2.3.4", "-1.0.0", "1.2.3-", "1.2.3-be ta",
                    "99999999999999999999999.0.0", "١.٢.٣", "1.2.x"] {
            XCTAssertNil(ServerVersion(parsing: bad), bad)
        }
    }

    func testOrderingTreatsPrereleaseAsOlderThanRelease() {
        XCTAssertLessThan(ServerVersion(parsing: "2.3.0-beta.1")!, ServerVersion(2, 3, 0)) // Literal parses: asserted above.
        XCTAssertLessThan(ServerVersion(2, 2, 9), ServerVersion(2, 3, 0))
        XCTAssertFalse(ServerVersion(2, 3, 0) < ServerVersion(2, 3, 0))
        XCTAssertLessThan(ServerVersion(1, 10, 0), ServerVersion(2, 0, 0))
        XCTAssertLessThan(ServerVersion(1, 9, 0), ServerVersion(1, 10, 0)) // numeric, not lexicographic
    }

    func testNegativeComponentsClampToZero() {
        XCTAssertEqual(ServerVersion(-1, -2, -3), ServerVersion(0, 0, 0))
    }
}

final class ManagedConfigParserTests: XCTestCase {
    func selfHosted(_ overrides: [String: any Sendable] = [:], removing: [String] = []) -> [String: any Sendable] {
        var p: [String: any Sendable] = [
            "tenantID": "acme", "topology": "self-hosted", "baseURL": "https://agents.acme.example",
            "allowedHosts": ["agents.acme.example"], "pathPrefix": "/cma", "region": "eu-west",
        ]
        for (k, v) in overrides { p[k] = v }
        for k in removing { p.removeValue(forKey: k) }
        return p
    }

    func testHostedDefaultsToTheHostedOriginAndAllowlist() throws {
        let c = try ManagedConfigParser.parse(["tenantID": "globex", "topology": "hosted"]).get()
        XCTAssertEqual(c.topology, .hosted)
        XCTAssertEqual(c.baseURL, TenantConfiguration.hostedBaseURL)
        XCTAssertEqual(c.allowedHosts, ["api.anthropic.com"])
        XCTAssertEqual(c.pathPrefix, "")
    }

    func testSelfHostedValidPayload() throws {
        let c = try ManagedConfigParser.parse(selfHosted(["baseURL": "https://Agents.ACME.example/"])).get()
        XCTAssertEqual(c.baseURL.host, "agents.acme.example")
        XCTAssertEqual(c.pathPrefix, "/cma")
        XCTAssertEqual(c.region, "eu-west")
    }

    func testRejections() {
        let cases: [([String: any Sendable], ConfigurationError)] = [
            (selfHosted(removing: ["tenantID"]), .missing(key: "tenantID")),
            (selfHosted(["tenantID": 42]), .wrongType(key: "tenantID")),
            (selfHosted(["tenantID": "acme corp"]), .invalidTenantID("acme corp")),
            (selfHosted(["topology": "edge"]), .unknownTopology("edge")),
            (selfHosted(["baseURL": "http://agents.acme.example"]), .insecureScheme("http://agents.acme.example")),
            (selfHosted(["baseURL": "https://u:p@agents.acme.example"]), .credentialsInURL),
            (selfHosted(["baseURL": "https://agents.acme.example/cma"]), .invalidURL("https://agents.acme.example/cma")),
            (selfHosted(["allowedHosts": ["other.acme.example"]]), .baseHostNotAllowed(host: "agents.acme.example")),
            (selfHosted(["allowedHosts": ["agents.acme.example", "api.anthropic.com"]]), .hostedEndpointInSelfHostedAllowlist),
            (selfHosted(["allowedHosts": [String]()]), .emptyAllowlist),
            (selfHosted(["allowedHosts": "agents.acme.example"]), .wrongType(key: "allowedHosts")),
            (selfHosted(["allowedHosts": ["agents.acme.example", "*.acme.example"]]), .invalidHost("*.acme.example")),
            (selfHosted(removing: ["allowedHosts"]), .missing(key: "allowedHosts")),
            (selfHosted(["pathPrefix": "/cma/../admin"]), .invalidPathPrefix("/cma/../admin")),
            (selfHosted(["pathPrefix": "cma"]), .invalidPathPrefix("cma")),
            (selfHosted(["pathPrefix": "/agent gateway"]), .invalidPathPrefix("/agent gateway")),
            (["tenantID": "g", "topology": "hosted", "allowedHosts": ["evil.example"]], .baseHostNotAllowed(host: "api.anthropic.com")),
            (["tenantID": "g", "topology": "hosted", "allowedHosts": ["api.anthropic.com", "evil.example"]], .invalidHost("evil.example")),
        ]
        for (payload, expected) in cases {
            XCTAssertEqual(ManagedConfigParser.parse(payload), .failure(expected), "\(expected)")
        }
    }

    func testLoopbackHTTPOnlyWithOptIn() throws {
        let local = selfHosted(["baseURL": "http://localhost:8080", "allowedHosts": ["localhost"]])
        XCTAssertEqual(ManagedConfigParser.parse(local), .failure(.insecureScheme("http://localhost:8080")))
        var optedIn = local
        optedIn["allowLoopbackHTTP"] = true
        let c = try ManagedConfigParser.parse(optedIn).get()
        XCTAssertEqual(c.baseURL.port, 8080)
        // Opting in does not open HTTP to non-loopback hosts.
        var remote = selfHosted(["baseURL": "http://agents.acme.example"])
        remote["allowLoopbackHTTP"] = true
        XCTAssertEqual(ManagedConfigParser.parse(remote), .failure(.insecureScheme("http://agents.acme.example")))
    }
}
