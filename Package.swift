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
        .library(name: "PearlCore", targets: ["PearlCore"])
    ],
    targets: [
        .target(
            name: "PearlCore",
            path: "Sources/PearlCore"
        ),
        .executableTarget(
            name: "PearlApp",
            dependencies: ["PearlCore"],
            path: "App"
        ),
        .executableTarget(
            name: "PearlCLI",
            dependencies: ["PearlCore"],
            path: "Sources/pearl-cli"
        )
    ]
)
