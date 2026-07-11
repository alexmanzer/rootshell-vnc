// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RootShellVNC",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RootShellVNC", targets: ["RootShellVNC"]),
        .library(name: "RFBProtocol", targets: ["RFBProtocol"]),
        .library(name: "RFBTransport", targets: ["RFBTransport"]),
        .library(name: "RFBRendering", targets: ["RFBRendering"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
    ],
    targets: [
        // MARK: - RFBProtocol (pure types, parsing, state machine — Foundation only)
        .target(
            name: "RFBProtocol",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("z")]
        ),

        // MARK: - RFBTransport (network I/O, crypto, auth)
        .target(
            name: "RFBTransport",
            dependencies: [
                "RFBProtocol",
                .product(name: "BigInt", package: "BigInt"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - RFBRendering (VideoToolbox HEVC decode, framebuffer, display)
        .target(
            name: "RFBRendering",
            dependencies: ["RFBProtocol", "RFBRenderingC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Adaptive DCT is a bit-level codec with an integer IDCT per
                // tile. At -Onone a single Retina reference frame can take
                // several seconds, allowing standard-mode updates to backlog
                // even on a fast LAN. Keep the rendering package optimized in
                // app Debug builds while the UI/transport remain debuggable.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "RFBRenderingC",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3"], .when(configuration: .debug)),
            ]
        ),

        // MARK: - RootShellVNC (public API facade, SwiftUI views, input handling)
        .target(
            name: "RootShellVNC",
            dependencies: ["RFBProtocol", "RFBTransport", "RFBRendering"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(
            name: "RFBProtocolTests",
            dependencies: ["RFBProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RFBTransportTests",
            dependencies: ["RFBTransport", "RFBProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RootShellVNCTests",
            dependencies: ["RootShellVNC", "RFBProtocol", "RFBTransport", "RFBRendering"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
