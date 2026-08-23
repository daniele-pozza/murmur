// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MurmurYouTube",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Whisper large-v3-turbo on CoreML/ANE, multilingual with automatic per-utterance
        // language detection — the whole reason we're not on Apple's single-locale engine.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MurmurYouTube",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MurmurYouTube",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
