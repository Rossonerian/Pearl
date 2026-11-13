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
        .library(name: "PearlTools", targets: ["PearlTools"]),
        .library(name: "PearlVoice", targets: ["PearlVoice"])
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
        .target(
            name: "PearlVoice",
            dependencies: ["PearlCore"],
            path: "Sources/PearlVoice"
        ),
        .executableTarget(
            name: "PearlApp",
            dependencies: ["PearlCore", "PearlTools", "PearlVoice"],
            path: "App"
        ),
        .executableTarget(
            name: "PearlCLI",
            dependencies: ["PearlCore", "PearlTools", "PearlVoice"],
            path: "Sources/pearl-cli"
        )
    ]
)
