// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "wyoming-apple-speech",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "WyomingProtocol", targets: ["WyomingProtocol"]),
        .library(name: "AppleSpeech", targets: ["AppleSpeech"]),
        .executable(name: "wyoming-apple-speech", targets: ["WyomingAppleSpeech"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", "2.98.0"..<"3.0.0"),
        .package(
            url: "https://github.com/livekit/livekit-wakeword.git",
            revision: "60b5d755ee0835bd184cbb1f05063944a9bed121"
        ),
    ],
    targets: [
        .target(
            name: "WyomingProtocol",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .target(
            name: "AppleSpeech",
            dependencies: ["WyomingProtocol"]
        ),
        .target(
            name: "WakeWord",
            dependencies: [
                .product(name: "LiveKitWakeWord", package: "livekit-wakeword"),
            ],
            resources: [
                .copy("Resources/okay_nabu.onnx"),
                .copy("Resources/hey_jarvis.onnx"),
            ]
        ),
        .executableTarget(
            name: "WyomingAppleSpeech",
            dependencies: [
                "AppleSpeech",
                "WakeWord",
                "WyomingProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "WyomingProtocolTests",
            dependencies: [
                "WyomingProtocol",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "AppleSpeechTests",
            dependencies: ["AppleSpeech", "WyomingProtocol"]
        ),
        .testTarget(
            name: "WakeWordTests",
            dependencies: ["WakeWord"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "WyomingAppleSpeechTests",
            dependencies: [
                "AppleSpeech",
                "WyomingProtocol",
                "WyomingAppleSpeech",
            ]
        ),
    ]
)
