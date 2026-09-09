// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceVoice", targets: ["VoiceVoice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // Already in the graph transitively (WhisperKit/FluidAudio); declared directly
        // so we can `import Tokenizers` for the RUPunct WordPiece tokenizer.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.0.0"),
        // LLM-постредактор («Глубокая чистка»): Qwen3 через MLX (Metal, Apple Silicon).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        // Прямо — ради `import MLX` (Memory.cacheLimit / clearCache): диапазон тот же,
        // что требует mlx-swift-lm, иначе резолв разъедется.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
    ],
    targets: [
        .executableTarget(
            name: "VoiceVoice",
            dependencies: [
                "WhisperKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/VoiceVoice",
            exclude: [
                "Resources/Info.plist",
                "Resources/VoiceVoice.entitlements",
                "Resources/AppIcon.icns",   // copied manually by build-app.sh
            ],
            resources: [
                // RUPunct punctuation model + tokenizer (bundled, loaded via Bundle.module).
                .copy("Resources/RUPunct"),
            ]
        ),
    ]
)
