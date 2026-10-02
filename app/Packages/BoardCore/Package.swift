// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoardCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BoardCore", targets: ["BoardCore"])],
    targets: [
        .target(name: "BoardCore"),
        .testTarget(name: "BoardCoreTests", dependencies: ["BoardCore"])
    ]
)
