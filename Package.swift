// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wave",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wave", targets: ["Wave"]),
        .executable(name: "wave-record", targets: ["WaveRecord"]),
        .library(name: "WaveCore", targets: ["WaveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
    ],
    targets: [
        .executableTarget(
            name: "Wave",
            dependencies: ["WaveCore"],
            path: "Sources/Wave"
        ),
        .executableTarget(
            name: "WaveRecord",
            dependencies: ["WaveCore"],
            path: "Sources/WaveRecord"
        ),
        .target(
            name: "WaveCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/WaveCore"
        ),
        .testTarget(
            name: "WaveCoreTests",
            dependencies: ["WaveCore"],
            path: "Tests/WaveCoreTests"
        ),
    ]
)
