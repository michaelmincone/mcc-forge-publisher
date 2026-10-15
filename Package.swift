// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCCForgePublisher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCCPublisherCore", targets: ["MCCPublisherCore"]),
        .executable(name: "MCCForgePublisher", targets: ["MCCPublisherApp"]),
        .executable(name: "mcc-publish", targets: ["MCCPublisherCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "MCCPublisherCore", dependencies: ["CZlib"]),
        .executableTarget(name: "MCCPublisherApp", dependencies: ["MCCPublisherCore"]),
        .executableTarget(name: "MCCPublisherCLI", dependencies: ["MCCPublisherCore"]),
        .testTarget(name: "MCCPublisherCoreTests", dependencies: ["MCCPublisherCore", "CZlib"]),
    ],
    swiftLanguageModes: [.v5]
)
