// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "snapspace",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "snapspace",
            path: "Sources/snapspace"
        )
    ]
)
