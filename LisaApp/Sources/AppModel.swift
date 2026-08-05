import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LisaShell
import Observation
import UniformTypeIdentifiers

/// Owns the `EmulationController` and republishes its cross-thread output
/// (frames, status) as `@Observable` state on the main thread, for
/// `ScreenView`/`LisaApp.swift`'s `.commands` to read and drive.
///
/// Threading: `EmulationController.framePublisher.onFrame`/`.onStatus` are
/// invoked ON THE EMULATION THREAD (see that type's "Threading" doc
/// comment) -- this class is the one place that hops back to main via
/// `DispatchQueue.main.async`, exactly once per callback, so every other
/// type in `LisaApp` can assume main-thread/`@Observable` semantics for
/// free.
@MainActor
@Observable
final class AppModel {
    /// Current framebuffer, expanded to a `CGImage` ready for `Image
    /// (decorative:)`. `nil` until the first vsync frame arrives.
    private(set) var image: CGImage?

    /// Most recent `EmuStatus` (cycles/halted/throttled/emulatedSeconds),
    /// `nil` until the emulation thread's first ~4Hz publish.
    private(set) var status: EmuStatus?

    /// Set (and never cleared) if `EmulationController` failed to start --
    /// typically a missing/invalid ROM directory. `ScreenView` surfaces
    /// this as an alert; the app stays open with an empty screen rather
    /// than crashing or silently doing nothing.
    private(set) var startupError: String?

    /// Optimistic local mirror of "should the emulation thread be
    /// running" -- `EmulationController` has no synchronous getter for
    /// this (mailbox-only), so `start()`/`pause()` set it immediately for
    /// responsive menu-item labels/checkmarks rather than round-tripping
    /// through a status publish.
    private(set) var running = false

    /// View menu "Actual Size (1:1)" toggle backing store -- `ScreenView`
    /// reads this to pick its displayed size. Defaults to aspect-corrected
    /// (`false`), matching the plan's "Default view applies aspect
    /// correction" Global Constraint.
    var showActualSize = false

    var throttled: Bool = true {
        didSet {
            guard oldValue != throttled else { return }
            controller?.throttled = throttled
        }
    }

    private var controller: EmulationController?

    /// Reused across `apply(_:)` calls to avoid a fresh allocation every
    /// vsync -- sized once the first frame's dimensions are known.
    private var pixelScratch: [UInt8] = []

    init() {
        let romDirectory = AppModel.resolveROMDirectory()
        do {
            let controller = try EmulationController(romDirectory: romDirectory)
            self.controller = controller
            controller.throttled = throttled
            wire(controller)
            controller.start()
            running = true
        } catch {
            startupError =
                "Could not load the Lisa ROM from \(romDirectory.path).\n\n" +
                "Set LISAEMU_ROM_DIR to a directory containing the ROM images, " +
                "or place them at ~/Development/LisaROMs.\n\nUnderlying error: \(error)"
        }
    }

    /// `LISAEMU_ROM_DIR` if set (and non-empty), else `~/Development/
    /// LisaROMs` -- the same fallback convention `LisaShellTests`/
    /// `LisaCoreTests` use for their env-gated ROM tests (see
    /// `Tests/LisaCoreTests/ROMImageTests.swift`).
    static func resolveROMDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment["LISAEMU_ROM_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/LisaROMs")
    }

    private func wire(_ controller: EmulationController) {
        controller.framePublisher.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                self?.apply(frame)
            }
        }
        controller.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.status = status
            }
        }
    }

    private func apply(_ frame: Frame) {
        image = AppModel.makeCGImage(frame: frame, scratch: &pixelScratch)
    }

    // MARK: - Machine menu actions

    func toggleRunning() {
        if running {
            controller?.pause()
            running = false
        } else {
            controller?.start()
            running = true
        }
    }

    func reset() {
        controller?.reset()
        running = true
        controller?.start()
    }

    // MARK: - Screenshot

    /// Fetches the current raw frame from the emulation thread and
    /// PNG-encodes it (app-side, per the plan's Task 1 interfaces: the
    /// controller returns only the raw 1bpp snapshot). `completion` is
    /// called on the main thread with the encoded PNG data, or `nil` on
    /// failure.
    ///
    /// `completion` is `@Sendable`: it's captured by the `@Sendable`
    /// closure this method hands to `EmulationController.requestScreenshot`
    /// (which fires on the emulation thread, per that method's doc
    /// comment) -- `Data?` is itself `Sendable`, so this only requires the
    /// caller's closure not capture non-Sendable state, which none of
    /// `LisaApp`'s call sites do (see `LisaApp.swift`'s
    /// `presentSaveScreenshotPanel` and `runAutoScreenshotIfRequested`,
    /// below).
    func requestScreenshotPNG(_ completion: @escaping @Sendable (Data?) -> Void) {
        guard let controller else {
            completion(nil)
            return
        }
        controller.requestScreenshot { frame in
            var scratch: [UInt8] = []
            let png = AppModel.encodePNG(frame: frame, scratch: &scratch)
            DispatchQueue.main.async {
                completion(png)
            }
        }
    }

    // MARK: - Frame -> CGImage / PNG (CoreGraphics stays in LisaApp only;
    // the 1bpp -> 8bpp bit math itself is `LisaShell.expand1bppRow`)

    /// Expands `frame.bits` (packed 1bpp, MSB-first, set bit = black --
    /// see `expand1bppRow`'s doc comment) into an 8bpp DeviceGray
    /// `CGImage`. `scratch` is caller-owned reusable storage for the
    /// expanded pixel buffer, sized/resized here as needed.
    /// `nonisolated`, deliberately: `AppModel` itself is `@MainActor`, and
    /// static members of a global-actor-isolated type inherit that
    /// isolation by default -- but this function's caller
    /// (`requestScreenshotPNG`'s closure, below) is invoked by
    /// `EmulationController.requestScreenshot`'s completion handler ON THE
    /// EMULATION THREAD (see that type's "Threading" doc comment), not
    /// main. Without `nonisolated` here, the Swift runtime's actor
    /// isolation check traps (`SIGTRAP`/`dispatch_assert_queue_fail`) the
    /// instant this is reached from a thread that isn't the main actor's
    /// executor -- confirmed via a crash report
    /// (`~/Library/Logs/DiagnosticReports/LisaApp-*.ips`) during the Task
    /// 3 manual verification checkpoint. Safe to mark `nonisolated`: this
    /// is a pure function of its parameters (no access to any `AppModel`
    /// instance/actor-isolated state), matching `expand1bppRow`'s own
    /// pure-function shape one layer down.
    nonisolated static func makeCGImage(frame: Frame, scratch: inout [UInt8]) -> CGImage? {
        let width = frame.width
        let height = frame.height
        let bytesPerRow = (width + 7) / 8
        let pixelCount = width * height
        if scratch.count != pixelCount {
            scratch = [UInt8](repeating: 0, count: pixelCount)
        }
        var rowBuffer = [UInt8](repeating: 0, count: width)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            let rowEnd = min(rowStart + bytesPerRow, frame.bits.count)
            guard rowEnd > rowStart else { break }
            let packedRow = Array(frame.bits[rowStart..<rowEnd])
            expand1bppRow(packedRow, into: &rowBuffer)
            scratch.replaceSubrange(y * width..<(y + 1) * width, with: rowBuffer)
        }
        guard let provider = CGDataProvider(data: Data(scratch) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// `nonisolated` for the same reason as `makeCGImage`, above -- also
    /// called from `requestScreenshotPNG`'s closure on the emulation
    /// thread.
    nonisolated static func encodePNG(frame: Frame, scratch: inout [UInt8]) -> Data? {
        guard let image = makeCGImage(frame: frame, scratch: &scratch) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Debug-only automated checkpoint

    /// Supports `--auto-screenshot <path>`: a debug-only launch argument
    /// that saves a screenshot to `path` after a fixed delay (long enough
    /// for throttled-mode POST to reach the boot menu) and quits, so the
    /// M1c Task 3 manual verification checkpoint ("app launches, POST runs
    /// live, Save Screenshot works") can be driven from a script instead
    /// of a human clicking through `NSSavePanel`. Not wired to any release
    /// configuration gate -- it's inert unless the argument is present, so
    /// leaving it compiled in is harmless; documented here and in
    /// task-3-report.md rather than hidden behind `#if DEBUG` so it stays
    /// usable in Release builds run manually for the same purpose.
    static let autoScreenshotDelay: TimeInterval = 20

    func runAutoScreenshotIfRequested() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--auto-screenshot"),
              args.count > flagIndex + 1 else { return }
        let path = args[flagIndex + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.autoScreenshotDelay) { [weak self] in
            self?.requestScreenshotPNG { data in
                if let data {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                // `requestScreenshotPNG`'s completion is `@Sendable` (it's
                // ultimately invoked from the emulation thread's mailbox
                // handler before hopping to main -- see that method's doc
                // comment), so the compiler can't assume this closure body
                // runs on the main actor even though, by construction, it
                // always does (via `requestScreenshotPNG`'s own internal
                // `DispatchQueue.main.async`). Hop explicitly before
                // touching `NSApp`, a MainActor-isolated API.
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
