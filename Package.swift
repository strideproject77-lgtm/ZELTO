// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeltoCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ZeltoCore", targets: ["ZeltoCore"])],
    targets: [
        .target(name: "ZeltoCore"),
        .testTarget(name: "ZeltoCoreTests", dependencies: ["ZeltoCore"])
    ]
)
