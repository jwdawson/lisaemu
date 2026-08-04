// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LisaEmu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LisaCore", targets: ["LisaCore"]),
    ],
    targets: [
        .target(
            name: "LisaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LisaCoreTests",
            dependencies: ["LisaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
