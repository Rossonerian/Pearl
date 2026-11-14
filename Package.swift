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
        .library(name: "PearlVoice", targets: ["PearlVoice"]),
        .library(name: "PearlMemory", targets: ["PearlMemory"]),
        .library(name: "PearlMCP", targets: ["PearlMCP"])
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
        .target(
            name: "PearlMemory",
            dependencies: ["PearlCore"],
            path: "Sources/PearlMemory",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PearlMCP",
            dependencies: ["PearlCore", "PearlTools"],
            path: "Sources/PearlMCP"
        ),
        .executableTarget(
            name: "PearlApp",
            dependencies: ["PearlCore", "PearlTools", "PearlVoice", "PearlMemory"],
            path: "App",
            exclude: ["Pearl.entitlements"]
        ),
        .executableTarget(
            name: "PearlCLI",
            dependencies: ["PearlCore", "PearlTools", "PearlVoice", "PearlMemory", "PearlMCP"],
            path: "Sources/pearl-cli"
        ),
        .testTarget(
            name: "PearlMemoryTests",
            dependencies: ["PearlMemory", "PearlCore"],
            path: "Tests/PearlMemoryTests"
        )
    ]
)
