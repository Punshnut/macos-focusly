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
            path: "Sources",
            resources: [
                .process("Focusly_centered.png"),
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
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
