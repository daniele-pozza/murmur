// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MurmurYouTube",
    platforms: [.macOS(.v26)],
    targets: [
        // transcribe.cpp's native library (ggml/Metal), consumed as the prebuilt
        // xcframework the project publishes per release — no standalone SwiftPM
        // mirror exists yet (bindings/swift/README.md), so we point straight at
        // the GitHub release asset instead of vendoring a CMake build.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.1/TranscribeCpp.xcframework.zip",
            checksum: "d24e6c0aaff1e628a626f792f74bb7155287a49a5c5bb1179deb73b35f0410f5"
        ),
        // The idiomatic Swift wrapper (bindings/swift/Sources/TranscribeCpp), vendored
        // verbatim under Sources/TranscribeCpp/ for the same reason: no published
        // package to depend on yet. MIT-licensed, see Sources/TranscribeCpp/LICENSE.
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "Sources/TranscribeCpp",
            exclude: ["LICENSE"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "MurmurYouTube",
            dependencies: ["TranscribeCpp"],
            path: "Sources/MurmurYouTube",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
