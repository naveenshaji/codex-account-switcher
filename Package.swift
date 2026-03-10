// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexAccountSwitcherApp", targets: ["CodexAccountSwitcherApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1")
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountSwitcherApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodexAccountSwitcherApp"
        )
    ]
)
