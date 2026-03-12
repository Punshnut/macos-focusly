// swift-tools-version: 6.2.1

import PackageDescription

let package = Package(
    name: "Focusly",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "focusly",
            targets: ["Focusly"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Focusly",
            path: "Focusly",
            exclude: [
                "Resources/Media/Focusly_Logo.png",
                "Resources/Focusly.icon"
            ],
            resources: [
                .process("Resources/Localization")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "FocuslyTests",
            dependencies: ["Focusly"],
            path: "Tests/FocuslyTests"
        )
    ]
)
