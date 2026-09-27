// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceVoice", targets: ["VoiceVoice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceVoice",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoiceVoice",
            exclude: [
                "Resources/Info.plist",
                "Resources/VoiceVoice.entitlements",
                "Resources/AppIcon.icns",   // copied manually by build-app.sh
            ],
            resources: [
                // Куски SentencePiece GigaAM с оценками — разбиение подсказанных терминов.
                .copy("Resources/GigaAM"),
            ]
        ),
    ]
)
