// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LisaEmu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LisaCore", targets: ["LisaCore"]),
        .executable(name: "lisadbg", targets: ["lisadbg"]),
    ],
    targets: [
        .target(
            name: "CMusashi",
            exclude: [
                "MUSASHI_COMMIT.txt",
                "m68k_in.c",
                "m68kfpu.c",
                "softfloat/README.txt",
                "softfloat/softfloat-macros",
                "softfloat/softfloat-specialize",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "LisaCore",
            dependencies: ["CMusashi"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LisaCoreTests",
            dependencies: ["LisaCore"],
            resources: [.copy("TomHarteKnownFailures.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lisadbg",
            dependencies: ["LisaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
