// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PearlBench",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "BenchCore", targets: ["BenchCore"]),
        .executable(name: "spike4_hud", targets: ["Spike4_HUD"]),
        .executable(name: "swift_router_bench", targets: ["SwiftRouterBenchmark"]),
        .executable(name: "baseline_v1", targets: ["BaselineV1"]),
        // .executable(name: "spike1_apple_fm", targets: ["Spike1_AppleFM"]),
        .executable(name: "m1_verification", targets: ["M1Verification"]),
        .executable(name: "router_eval", targets: ["RouterEvaluation"]),
        .executable(name: "action_bench", targets: ["ActionBenchmark"]),
        .executable(name: "voice_e2e", targets: ["VoiceE2E"]),
        .executable(name: "llm_path", targets: ["LLMPathBenchmark"]),
        .executable(name: "memory_bench", targets: ["MemoryBenchmark"]),
        .executable(name: "security_bench", targets: ["SecurityBenchmark"]),
        .executable(name: "mcp_bench", targets: ["MCPVerification"]),
        .executable(name: "conversation_verification", targets: ["ConversationVerification"])
    ],
    dependencies: [
        .package(name: "Pearl", path: "..")
    ],
    targets: [
        .target(
            name: "BenchCore",
            path: "Sources/BenchCore"
        ),
        .executableTarget(
            name: "Spike4_HUD",
            dependencies: ["BenchCore"],
            path: "Sources/Spike4_HUD"
        ),
        .executableTarget(
            name: "SwiftRouterBenchmark",
            dependencies: ["BenchCore"],
            path: "Sources/SwiftRouterBenchmark"
        ),
        .executableTarget(
            name: "BaselineV1",
            dependencies: ["BenchCore"],
            path: "Sources/BaselineV1"
        ),
        // .executableTarget(
        //     name: "Spike1_AppleFM",
        //     dependencies: ["BenchCore"],
        //     path: "Sources/Spike1_AppleFM"
        // ),
        .executableTarget(
            name: "M1Verification",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl")
            ],
            path: "Sources/M1Verification"
        ),
        .executableTarget(
            name: "RouterEvaluation",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl")
            ],
            path: "Sources/RouterEvaluation"
        ),
        .executableTarget(
            name: "ActionBenchmark",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl")
            ],
            path: "Sources/ActionBenchmark"
        ),
        .executableTarget(
            name: "VoiceE2E",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl"),
                .product(name: "PearlVoice", package: "Pearl")
            ],
            path: "Sources/VoiceE2E"
        ),
        .executableTarget(
            name: "LLMPathBenchmark",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl")
            ],
            path: "Sources/LLMPathBenchmark"
        ),
        .executableTarget(
            name: "MemoryBenchmark",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlMemory", package: "Pearl")
            ],
            path: "Sources/MemoryBenchmark"
        ),
        .executableTarget(
            name: "SecurityBenchmark",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl")
            ],
            path: "Sources/SecurityBenchmark"
        ),
        .executableTarget(
            name: "MCPVerification",
            dependencies: [
                "BenchCore",
                .product(name: "PearlMCP", package: "Pearl"),
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl")
            ],
            path: "Sources/MCPVerification"
        ),
        .executableTarget(
            name: "ConversationVerification",
            dependencies: [
                "BenchCore",
                .product(name: "PearlCore", package: "Pearl"),
                .product(name: "PearlTools", package: "Pearl")
            ],
            path: "Sources/ConversationVerification"
        )
    ]
)
