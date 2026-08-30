// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "strafe",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "CStrafe",
            path: "Sources/CStrafe",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "strafe",
            dependencies: ["CStrafe"],
            path: "Sources/strafe"
        )
    ]
)
