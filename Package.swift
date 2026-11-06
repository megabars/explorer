// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Explorer",
            path: "Sources/Explorer",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ExplorerTests",
            dependencies: ["Explorer"],
            path: "Tests/ExplorerTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
