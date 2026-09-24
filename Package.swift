// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Eink", platforms: [.macOS(.v13)],
    products: [.executable(name: "eink", targets: ["eink"]), .executable(name: "EinkBar", targets: ["EinkBar"])],
    targets: [
        .target(name: "EinkCore"),
        .target(name: "EinkMac", dependencies: ["EinkCore"]),
        .executableTarget(name: "eink", dependencies: ["EinkCore", "EinkMac"]),
        .executableTarget(name: "EinkBar", dependencies: ["EinkCore", "EinkMac"]),
        .testTarget(name: "EinkCoreTests", dependencies: ["EinkCore", "EinkMac"])
    ])
