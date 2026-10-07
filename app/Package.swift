// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hushdeck",
    // User-facing strings live in Sources/Hushdeck/Resources/Localizable.xcstrings.
    // English is the source language; see README "Localisation" to add another.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hushdeck", targets: ["Hushdeck"]),
        .library(name: "HeadsetControlKit", targets: ["HeadsetControlKit"]),
    ],
    targets: [
        // Talks to the HeadsetControl CLI as a subprocess. Never links libheadsetcontrol (GPL-3.0).
        .target(
            name: "HeadsetControlKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Hushdeck",
            dependencies: ["HeadsetControlKit", "OmniKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HeadsetControlKitTests",
            dependencies: ["HeadsetControlKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // App-level pure logic (battery alerts) and String Catalog checks.
        .testTarget(
            name: "HushdeckTests",
            dependencies: ["Hushdeck", "OmniKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Native USB HID backend for the Arctis Nova Pro Omni GameHub. See Sources/OmniKit/README.md.
        .target(
            name: "OmniKit",
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OmniKitTests",
            dependencies: ["OmniKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
