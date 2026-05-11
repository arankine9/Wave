// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Beck", targets: ["Beck"]),
        .library(name: "BeckCore", targets: ["BeckCore"]),
    ],
    targets: [
        .executableTarget(
            name: "Beck",
            dependencies: ["BeckCore"],
            path: "Sources/Beck"
        ),
        .target(
            name: "BeckCore",
            path: "Sources/BeckCore"
        ),
        .testTarget(
            name: "BeckCoreTests",
            dependencies: ["BeckCore"],
            path: "Tests/BeckCoreTests"
        ),
    ]
)
