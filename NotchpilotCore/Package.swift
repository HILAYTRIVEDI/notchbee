// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchpilotCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "NotchpilotCore", targets: ["NotchpilotCore"])],
    targets: [
        .target(name: "NotchpilotCore"),
        .testTarget(name: "NotchpilotCoreTests", dependencies: ["NotchpilotCore"])
    ]
)
