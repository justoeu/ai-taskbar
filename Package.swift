// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ai-taskbar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    // Swift 6 tools (so testTargets can `import Testing`), but the source
    // targets keep Swift 5 language mode to avoid the strict-concurrency
    // diagnostics we don't have the bandwidth to chase right now.
    // Bump per-target to .v6 when we're ready to enforce Sendable.
    products: [
        .executable(name: "ai-taskbar", targets: ["AiTaskbarApp"]),
        .executable(name: "ai-taskbar-validate", targets: ["AiTaskbarValidate"]),
        .library(name: "AiTaskbarCore", targets: ["AiTaskbarCore"]),
        .library(name: "AiTaskbarProviders", targets: ["AiTaskbarProviders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        // swift-testing is bundled with Swift 6 toolchains, but Command Line
        // Tools doesn't auto-link it for testTargets the way Xcode does.
        // Pull it in explicitly so `import Testing` resolves.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "AiTaskbarApp",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AiTaskbarCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AiTaskbarProviders",
            dependencies: ["AiTaskbarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AiTaskbarTesting",
            dependencies: ["AiTaskbarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AiTaskbarValidate",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders", "AiTaskbarTesting"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AiTaskbarCoreTests",
            dependencies: [
                "AiTaskbarCore", "AiTaskbarTesting",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AiTaskbarProvidersTests",
            dependencies: [
                "AiTaskbarProviders", "AiTaskbarTesting",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "AiTaskbarAppTests",
            dependencies: [
                "AiTaskbarApp",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
