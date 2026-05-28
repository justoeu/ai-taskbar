// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ai-taskbar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
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
            resources: [.process("Resources")]
        ),
        .target(
            name: "AiTaskbarCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .target(
            name: "AiTaskbarProviders",
            dependencies: ["AiTaskbarCore"]
        ),
        .target(
            name: "AiTaskbarTesting",
            dependencies: ["AiTaskbarCore"]
        ),
        .executableTarget(
            name: "AiTaskbarValidate",
            dependencies: ["AiTaskbarCore", "AiTaskbarProviders", "AiTaskbarTesting"]
        ),
        .testTarget(
            name: "AiTaskbarCoreTests",
            dependencies: ["AiTaskbarCore", "AiTaskbarTesting"]
        ),
        .testTarget(
            name: "AiTaskbarProvidersTests",
            dependencies: ["AiTaskbarProviders", "AiTaskbarTesting"]
        ),
        .testTarget(
            name: "AiTaskbarAppTests",
            dependencies: ["AiTaskbarApp"]
        ),
    ]
)
