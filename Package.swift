// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Blaze",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProxyWorkbenchCore", targets: ["ProxyWorkbenchCore"]),
        .executable(name: "blaze", targets: ["blaze"]),
        .executable(name: "BlazeTunnelExtension", targets: ["BlazeTunnelExtension"])
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
        .executableTarget(
            name: "BlazeTunnelExtension",
            path: "Sources/BlazeTunnelExtension",
            linkerSettings: [
                .linkedFramework("CFNetwork"),
                .linkedFramework("NetworkExtension")
            ]
        ),
        .testTarget(
            name: "ProxyWorkbenchCoreTests",
            dependencies: ["ProxyWorkbenchCore"],
            path: "Tests/ProxyWorkbenchCoreTests"
        )
    ]
)
