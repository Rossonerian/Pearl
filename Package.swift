// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pearl",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Pearl", targets: ["PearlApp"]),
        .executable(name: "pearl-cli", targets: ["PearlCLI"]),
        .library(name: "PearlCore", targets: ["PearlCore"]),
        .library(name: "PearlTools", targets: ["PearlTools"])
    ],
    targets: [
        .target(
            name: "PearlCore",
            path: "Sources/PearlCore"
        ),
        .target(
            name: "PearlTools",
            dependencies: ["PearlCore"],
            path: "Sources/PearlTools"
        ),
        .executableTarget(
            name: "PearlApp",
            dependencies: ["PearlCore", "PearlTools"],
            path: "App"
        ),
        .executableTarget(
            name: "PearlCLI",
            dependencies: ["PearlCore", "PearlTools"],
            path: "Sources/pearl-cli"
        )
    ]
)
