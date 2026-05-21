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
    ],
    targets: [
        .executableTarget(
            name: "VoiceVoice",
            dependencies: [
                "WhisperKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/VoiceVoice",
            exclude: ["Resources/Info.plist", "Resources/VoiceVoice.entitlements"]
        ),
    ]
)
