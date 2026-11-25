// swift-tools-version:5.9
// The Wyoming protocol code, kept free of UIKit so `swift test` can run it.
import PackageDescription

let package = Package(
    name: "VACACore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "VACACore", targets: ["VACACore"]),
    ],
    targets: [
        .target(name: "VACACore"),
        .testTarget(name: "VACACoreTests", dependencies: ["VACACore"]),
    ]
)
