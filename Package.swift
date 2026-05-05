// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Blaze",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProxyWorkbenchCore", targets: ["ProxyWorkbenchCore"]),
        .executable(name: "blaze", targets: ["blaze"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ProxyWorkbenchCore",
            path: "Sources/ProxyWorkbenchCore"
        ),
        .executableTarget(
            name: "blaze",
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
