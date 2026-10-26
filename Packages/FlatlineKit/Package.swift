// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlatlineKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FlatlineKit", targets: ["FlatlineKit"]),
    ],
    targets: [
        .target(
            name: "FlatlineKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "FlatlineKitTests", dependencies: ["FlatlineKit"]),
    ]
)
