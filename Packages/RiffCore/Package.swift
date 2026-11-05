// swift-tools-version:5.9
// Platform-neutral core for Riff Pocket. Builds and tests on Windows, Linux, macOS and iOS.
import PackageDescription

let package = Package(
    name: "RiffCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RiffCore", targets: ["RiffCore"]),
    ],
    targets: [
        .target(name: "RiffCore"),
        .testTarget(name: "RiffCoreTests", dependencies: ["RiffCore"]),
    ]
)
