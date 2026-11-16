// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentTopology",
    // Only platforms that CI actually builds are declared. Linux builds the core module and runs the
    // tests too, but needs no declaration; the UI module compiles to nothing where SwiftUI is absent.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentTopology", targets: ["AgentTopology"]),
        .library(name: "AgentTopologyUI", targets: ["AgentTopologyUI"]),
    ],
    targets: [
        .target(name: "AgentTopology"),
        .target(name: "AgentTopologyUI", dependencies: ["AgentTopology"]),
        .testTarget(name: "AgentTopologyTests", dependencies: ["AgentTopology"]),
    ]
)
