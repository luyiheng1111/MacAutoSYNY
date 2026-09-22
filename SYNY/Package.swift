// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SYNY",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SYNY",
            path: "Sources/SYNY"
        )
    ]
)
