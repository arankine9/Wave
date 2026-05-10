// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voxflow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voxflow", targets: ["Voxflow"]),
        .library(name: "VoxflowCore", targets: ["VoxflowCore"]),
    ],
    targets: [
        .executableTarget(
            name: "Voxflow",
            dependencies: ["VoxflowCore"],
            path: "Sources/Voxflow"
        ),
        .target(
            name: "VoxflowCore",
            path: "Sources/VoxflowCore"
        ),
        .testTarget(
            name: "VoxflowCoreTests",
            dependencies: ["VoxflowCore"],
            path: "Tests/VoxflowCoreTests"
        ),
    ]
)
