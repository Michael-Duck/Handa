// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Handa",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Handa", targets: ["Handa"]),
    ],
    targets: [
        // Plain Foundation logic: parsing, highlighting, MCP, reviews. Builds anywhere.
        .target(name: "HandaCore"),
        // The Mac app itself: windows, viewers, settings.
        .target(name: "HandaKit", dependencies: ["HandaCore"]),
        .executableTarget(name: "Handa", dependencies: ["HandaKit"]),
        .testTarget(name: "HandaCoreTests", dependencies: ["HandaCore"]),
        .testTarget(name: "HandaKitTests", dependencies: ["HandaKit"]),
    ]
)
