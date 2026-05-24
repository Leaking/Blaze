// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Blaze",
    platforms: [
        .macOS(.v14),
        // iOS support is library-only: the `blaze` host app and
        // `BlazeTunnelExtension` System Extension are mac-only and won't
        // compile for iOS, but iOS consumers (the Xcode-driven iPad target,
        // see project.yml) only pull in the ProxyWorkbenchCore library
        // product so those executables are never built for iOS.
        .iOS(.v15)
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
        ),
        .testTarget(
            name: "BlazeTunnelExtensionTests",
            dependencies: ["BlazeTunnelExtension"],
            path: "Tests/BlazeTunnelExtensionTests"
        )
    ]
)
