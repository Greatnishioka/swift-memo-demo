// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "StarWindow",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "StarWindow"
        )
    ]
)
