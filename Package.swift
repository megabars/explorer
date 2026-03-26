// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Explorer",
            path: "Sources/Explorer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
