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
        // swift-testing is declared ONLY for AiTaskbarTestSupport, which is a
        // regular target — those do not get the toolchain's bundled Testing
        // (removing the dependency outright fails it with "missing required
        // module '_TestingInternals'"). The three testTargets deliberately do
        // NOT list it: they resolve Testing from the Swift 6 toolchain, and
        // linking the standalone package there emitted a deprecation on every
        // single @Test/@Suite — hundreds of warnings that buried the real ones.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "AiTaskbarApp",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AiTaskbarCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AiTaskbarProviders",
            dependencies: ["AiTaskbarCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AiTaskbarTesting",
            dependencies: ["AiTaskbarCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Assertion helpers for the test targets only. Kept OUT of
        // AiTaskbarTesting because that one is linked by the
        // AiTaskbarValidate executable, which must not pull in swift-testing.
        .target(
            name: "AiTaskbarTestSupport",
            dependencies: [
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AiTaskbarValidate",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders", "AiTaskbarTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AiTaskbarCoreTests",
            dependencies: [
                "AiTaskbarCore", "AiTaskbarTesting", "AiTaskbarTestSupport",
            ]
        ),
        .testTarget(
            name: "AiTaskbarProvidersTests",
            dependencies: [
                "AiTaskbarProviders", "AiTaskbarTesting", "AiTaskbarTestSupport",
            ]
        ),
        .testTarget(
            name: "AiTaskbarAppTests",
            dependencies: [
                "AiTaskbarApp",
                "AiTaskbarCore",
                "AiTaskbarProviders",
                "AiTaskbarTestSupport",
            ]
        ),
    ]
)
