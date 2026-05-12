// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Beck", targets: ["Beck"]),
        .executable(name: "beck-record", targets: ["BeckRecord"]),
        .library(name: "BeckCore", targets: ["BeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
    ],
    targets: [
        .executableTarget(
            name: "Beck",
            dependencies: ["BeckCore"],
            path: "Sources/Beck"
        ),
        .executableTarget(
            name: "BeckRecord",
            dependencies: ["BeckCore"],
            path: "Sources/BeckRecord"
        ),
        .target(
            name: "BeckCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/BeckCore"
        ),
        .testTarget(
            name: "BeckCoreTests",
            dependencies: ["BeckCore"],
            path: "Tests/BeckCoreTests"
        ),
    ]
)
