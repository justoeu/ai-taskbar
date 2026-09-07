// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ai-taskbar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    // Swift 6 tools + Swift 6 language mode on all targets (see per-target
    // swiftSettings). All test code uses the toolchain's bundled Testing;
    // do not mix it with a standalone swift-testing package.
    products: [
        .executable(name: "ai-taskbar", targets: ["AiTaskbarApp"]),
        .executable(name: "ai-taskbar-validate", targets: ["AiTaskbarValidate"]),
        .library(name: "AiTaskbarCore", targets: ["AiTaskbarCore"]),
        .library(name: "AiTaskbarProviders", targets: ["AiTaskbarProviders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
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
        .executableTarget(
            name: "AiTaskbarValidate",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders", "AiTaskbarTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AiTaskbarCoreTests",
            dependencies: [
                "AiTaskbarCore", "AiTaskbarTesting",
            ]
        ),
        .testTarget(
            name: "AiTaskbarProvidersTests",
            dependencies: [
                "AiTaskbarProviders", "AiTaskbarTesting",
            ]
        ),
        .testTarget(
            name: "AiTaskbarAppTests",
            dependencies: [
                "AiTaskbarApp",
                "AiTaskbarCore",
                "AiTaskbarProviders",
            ]
        ),
    ]
)
