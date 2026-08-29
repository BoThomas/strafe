// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "snapspace",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "CSnapSpace",
            path: "Sources/CSnapSpace",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "snapspace",
            dependencies: ["CSnapSpace"],
            path: "Sources/snapspace"
        )
    ]
)
