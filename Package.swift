// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyWorkbench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProxyWorkbenchCore", targets: ["ProxyWorkbenchCore"]),
        .executable(name: "ProxyWorkbench", targets: ["ProxyWorkbench"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ProxyWorkbenchCore",
            path: "Sources/ProxyWorkbenchCore"
        ),
        .executableTarget(
            name: "ProxyWorkbench",
            dependencies: ["ProxyWorkbenchCore"],
            path: "Sources/ProxyWorkbench"
        ),
        .testTarget(
            name: "ProxyWorkbenchCoreTests",
            dependencies: ["ProxyWorkbenchCore"],
            path: "Tests/ProxyWorkbenchCoreTests"
        )
    ]
)
