import XCTest
@testable import AgentTopology

final class NegotiationTests: XCTestCase {
    let n = CapabilityNegotiator.standard

    func server(_ v: ServerVersion, _ features: Set<Feature>) -> ServerDescriptor {
        ServerDescriptor(version: v, advertised: features, epoch: "ep-1", topology: .selfHosted)
    }

    func testCurrentHostedServerGetsEverything() {
        let plan = n.negotiate(server(ServerVersion(2, 3, 4), Set(Feature.allCases)))
        XCTAssertEqual(plan.compatibility, .compatible)
        XCTAssertEqual(plan.counts.available, Feature.allCases.count)
    }

    func testVersionAloneDoesNotUnlockAFeatureTheServerDoesNotAdvertise() {
        // A self-hosted 2.3 build without the hosted-only memory feature.
        let plan = n.negotiate(server(ServerVersion(2, 3, 0), Set(Feature.allCases).subtracting([.memoryStores])))
        XCTAssertEqual(plan.state(of: .memoryStores), .unavailable("not enabled on this server"))
        XCTAssertEqual(plan.state(of: .multiAgent), .available)
    }

    func testAdvertisementAloneDoesNotUnlockAFeatureBelowItsMinimumVersion() {
        let plan = n.negotiate(server(ServerVersion(2, 0, 0), Set(Feature.allCases)))
        XCTAssertEqual(plan.state(of: .multiAgent), .unavailable("needs server ≥ 2.3.0"))
        XCTAssertEqual(plan.state(of: .toolConfirmation), .available)
    }

    func testMissingFeatureWithFallbackDegradesInsteadOfDisappearing() {
        let plan = n.negotiate(server(ServerVersion(1, 8, 0), [.sessionEvents]))
        XCTAssertEqual(plan.state(of: .eventCursor),
                       .degraded("Full-history polling; duplicates dropped client-side (needs server ≥ 1.9.0; not enabled on this server)"))
        XCTAssertTrue(plan.state(of: .eventCursor).isUsable)
        XCTAssertFalse(plan.state(of: .memoryStores).isUsable)
    }

    func testServerBelowTheSupportWindowIsUnsupportedAndEveryFeatureIsOff() {
        let plan = n.negotiate(server(ServerVersion(1, 5, 9), Set(Feature.allCases)))
        guard case .unsupported = plan.compatibility else { return XCTFail("expected unsupported") }
        XCTAssertEqual(plan.counts.available, 0)
        XCTAssertEqual(plan.counts.degraded, 0)
        XCTAssertEqual(plan.states.count, Feature.allCases.count)
    }

    func testNewerLineHoldsBackOnlySkewSensitiveFeatures() {
        let plan = n.negotiate(server(ServerVersion(2, 4, 0), Set(Feature.allCases)))
        XCTAssertEqual(plan.compatibility, .newerThanTested)
        XCTAssertFalse(plan.state(of: .memoryStores).isUsable)
        XCTAssertFalse(plan.state(of: .multiAgent).isUsable)
        XCTAssertEqual(plan.state(of: .toolConfirmation), .available)
    }

    func testPatchReleaseInsideTheTestedLineIsNotNewerThanTested() {
        let plan = n.negotiate(server(ServerVersion(2, 3, 99), Set(Feature.allCases)))
        XCTAssertEqual(plan.compatibility, .compatible)
        XCTAssertEqual(plan.state(of: .multiAgent), .available)
    }

    func testDuplicateRequirementCannotLoosenTheFirstRule() {
        let neg = CapabilityNegotiator(
            window: n.window,
            requirements: [FeatureRequirement(.multiAgent, since: ServerVersion(2, 3, 0)),
                           FeatureRequirement(.multiAgent, since: ServerVersion(1, 0, 0))]
        )
        XCTAssertEqual(neg.requirements.count, 1)
        XCTAssertFalse(neg.negotiate(server(ServerVersion(2, 0, 0), [.multiAgent])).state(of: .multiAgent).isUsable)
    }

    func testUnnegotiatedFeatureReadsAsUnavailable() {
        let plan = CapabilityPlan(compatibility: .compatible, states: [:])
        XCTAssertEqual(plan.state(of: .fileOutputs), .unavailable("not negotiated"))
    }
}
