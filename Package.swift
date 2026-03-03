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
    targets: [
        .executableTarget(
            name: "CodexAccountSwitcherApp",
            path: "Sources/CodexAccountSwitcherApp"
        )
    ]
)
