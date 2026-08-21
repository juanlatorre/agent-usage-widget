// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsageCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentUsageCore", targets: ["AgentUsageCore"])
    ],
    targets: [
        .target(name: "AgentUsageCore"),
        .testTarget(name: "AgentUsageCoreTests", dependencies: ["AgentUsageCore"])
    ]
)
