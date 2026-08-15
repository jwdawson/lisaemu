// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LisaEmu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LisaCore", targets: ["LisaCore"]),
        .library(name: "LisaShell", targets: ["LisaShell"]),
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
            // LisaShell for the M7 printer pipeline (ImageWriterInterpreter +
            // PrintJobSpooler + PrinterPipeline) behind `--printer-dir`; still
            // Foundation-only, so the debugger stays framework-light apart from
            // its existing ImageIO/CoreGraphics PNG use.
            dependencies: ["LisaCore", "LisaShell"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Foundation-only shell layer (M1c): owns the emulation thread and
        // mailbox. Deliberately depends on LisaCore ONLY -- no AppKit/
        // SwiftUI/CoreGraphics -- so it stays fully unit-testable headless;
        // see docs/superpowers/plans/2026-08-05-m1c-app-shell.md "Global
        // Constraints".
        .target(
            name: "LisaShell",
            dependencies: ["LisaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LisaShellTests",
            dependencies: ["LisaShell"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
