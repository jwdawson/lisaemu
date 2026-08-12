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

    /// M2 Task 7: set from `EmulationController.onDiskError` when
    /// `insertFloppy(url:)` fails to load the image (bad path, malformed
    /// DC42 container). Unlike `startupError`, this is DISMISSIBLE --
    /// `ScreenView`'s alert clears it via `dismissDiskError()` -- because a
    /// bad disk pick is recoverable (unlike a missing ROM, which leaves the
    /// app with nothing to run). See `EmulationController.onDiskError`'s
    /// doc comment for why this is a callback rather than an `EmuStatus`
    /// field.
    private(set) var diskError: String?

    /// Optimistic local mirror of "should the emulation thread be
    /// running" -- `EmulationController` has no synchronous getter for
    /// this (mailbox-only), so `start()`/`pause()` set it immediately for
    /// responsive menu-item labels/checkmarks rather than round-tripping
    /// through a status publish.
    private(set) var running = false

    /// `UserDefaults` key backing `showActualSize`'s persistence, below.
    private static let showActualSizeDefaultsKey = "showActualSize"

    /// View menu "Actual Size (1:1)" toggle backing store -- `ScreenView`
    /// reads this to pick its displayed size. Defaults to aspect-corrected
    /// (`false`), matching the plan's "Default view applies aspect
    /// correction" Global Constraint, and PERSISTS across launches (M1c
    /// Task 5 polish: "aspect-toggle persistence (@AppStorage)") via
    /// `UserDefaults.standard`.
    ///
    /// Not the `@AppStorage` property wrapper itself: that wrapper is a
    /// `DynamicProperty` designed to be read inside a SwiftUI `View.body`
    /// (its automatic invalidation only fires there), and `AppModel` is a
    /// plain `@Observable` class, not a `View` -- composing a second
    /// property wrapper with `@Observable`'s own macro-synthesized storage
    /// on the same stored property isn't supported. This reads/writes the
    /// exact same `UserDefaults.standard` store `@AppStorage` would, with
    /// `@Observable` (already driving every other property here) providing
    /// the reactivity instead. Set directly in `init()` (below) from the
    /// persisted value -- assigning there, before the rest of `init()`
    /// runs, does not re-trigger `didSet` (Swift suppresses property
    /// observers for a class's own first assignment to its stored
    /// property, during its own initializer), so startup never redundantly
    /// re-writes the value it just read.
    var showActualSize: Bool {
        didSet {
            guard oldValue != showActualSize else { return }
            UserDefaults.standard.set(showActualSize, forKey: Self.showActualSizeDefaultsKey)
        }
    }

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

    /// Latest-frame coalescing slot for `wire(_:)`'s `onFrame` callback
    /// (whole-branch-review Important finding: "unthrottled mode can flood
    /// the main thread with CGImage rebuilds"). `nonisolated let`, not a
    /// plain `@MainActor`-isolated stored property: `onFrame` fires ON THE
    /// EMULATION THREAD (see `EmulationController`'s "Threading" doc
    /// comment), so `wire(_:)`'s closure needs to touch this BEFORE hopping
    /// to main -- `FrameCoalescer` is its own lock-protected, `@unchecked
    /// Sendable` type specifically so that cross-thread touch is safe
    /// without requiring the whole of `AppModel` to lose its `@MainActor`
    /// isolation. See `FrameCoalescer`'s own doc comment for the
    /// offer/take protocol.
    private nonisolated let frameCoalescer = FrameCoalescer()

    init() {
        showActualSize = UserDefaults.standard.object(forKey: Self.showActualSizeDefaultsKey) as? Bool ?? false
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
        // CODE-REVIEW FIX (whole-branch-review Important finding:
        // "unthrottled mode can flood the main thread with CGImage
        // rebuilds"): unthrottled mode runs continuous back-to-back vsync
        // slices with no sleep between them (`EmulationController`'s
        // "Pacing" doc comment), so `onFrame` can fire far faster than the
        // main thread can drain `DispatchQueue.main.async` blocks -- the
        // OLD code scheduled one such block, each doing a full 1bpp ->
        // 8bpp `CGImage` rebuild (`apply(_:)`/`makeCGImage`), PER FRAME,
        // unconditionally. Under sustained flooding that queue only grows,
        // starving every other main-queue work item (menu actions, window
        // events) behind an ever-lengthening backlog of stale-by-the-time-
        // they-run image rebuilds. `frameCoalescer.offer(frame)` always
        // records the LATEST frame but returns `true` (schedule a main-
        // queue apply) only when none is already scheduled; the scheduled
        // block itself calls `take()` to consume whatever the latest frame
        // turned out to be BY THE TIME IT RUNS, dropping every
        // intermediate one -- so there is at most one pending `apply` at
        // any moment, no matter how fast frames arrive. Throttled mode
        // publishes at a much lower, already-paced rate, so this never
        // actually coalesces there in practice -- see `FrameCoalescer`'s
        // doc comment for why the offer/take protocol is harmless (a no-op
        // beyond one extra lock/unlock pair) when frames aren't flooding.
        controller.framePublisher.onFrame = { [weak self] frame in
            guard let self, self.frameCoalescer.offer(frame) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let frame = self.frameCoalescer.take() else { return }
                self.apply(frame)
            }
        }
        controller.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.status = status
            }
        }
        controller.onDiskError = { [weak self] message in
            DispatchQueue.main.async {
                self?.diskError = message
            }
        }
    }

    private func apply(_ frame: Frame) {
        image = AppModel.makeCGImage(frame: frame, scratch: &pixelScratch)
    }

    // MARK: - Floppy (M2 Task 7): File > Insert Disk…/Eject, drag-and-drop

    /// File > Insert Disk… (`LisaApp.swift`'s `NSOpenPanel`) and the
    /// drag-and-drop handler (`ScreenView.swift`'s `.onDrop`) both funnel
    /// through here -- a thin passthrough to `EmulationController
    /// .insertFloppy(url:)`, matching `post(_:)`'s existing "controller is
    /// private, everything else reaches it through `AppModel`" boundary.
    func insertFloppy(url: URL) {
        controller?.insertFloppy(url: url)
    }

    /// File > Eject.
    func ejectFloppy() {
        controller?.ejectFloppy()
    }

    // MARK: - Widget hard disk (M5 Task 2): File > Attach/Detach Widget Disk…

    /// File > Attach Widget Disk… -- passthrough to `EmulationController
    /// .attachWidget(url:)`. Unlike the floppy, a Widget image persists writes
    /// to its file (write-back, §10.10); a missing path is created as a blank
    /// on demand.
    func attachWidget(url: URL) {
        controller?.attachWidget(url: url)
    }

    /// File > Detach Widget Disk…
    func detachWidget() {
        controller?.detachWidget()
    }

    /// Pure predicate behind the Widget open/drop filter -- a `.widget`
    /// (or `.image`) file. Mirrors `isDC42File`.
    nonisolated static func isWidgetFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "widget" || ext == "image"
    }

    /// Dismisses `diskError`'s alert (`ScreenView.swift`) -- see that
    /// property's doc comment for why it's dismissible, unlike
    /// `startupError`.
    func dismissDiskError() {
        diskError = nil
    }

    /// Pure predicate behind the drag-and-drop filter (`ScreenView.swift`'s
    /// `.onDrop`): only a `.dc42` file is accepted as an insertable floppy
    /// image, matching File > Insert Disk…'s `NSOpenPanel` filter
    /// (`LisaApp.swift`'s `presentInsertDiskPanel`). Extracted as a
    /// `nonisolated static` pure function (no `AppModel` instance state) so
    /// `LisaAppTests` can exercise it directly without a real drag session
    /// -- same shape as `InputCapture.isReservedMenuShortcut`.
    nonisolated static func isDC42File(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dc42"
    }

    /// Supports `--insert-disk <path>`: a debug-only launch argument,
    /// alongside `--auto-screenshot`, that inserts a floppy image at launch
    /// without needing a human to drive `NSOpenPanel` or drag-and-drop --
    /// the manual verification checkpoint's "boot with a disk already in
    /// the drive" scenario. Called from `LisaEmuApp.swift`'s `.onAppear`,
    /// same as `runAutoScreenshotIfRequested()`. Inert (no-op) unless the
    /// argument is present.
    func insertDiskIfRequested() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--insert-disk"), args.count > flagIndex + 1 else { return }
        insertFloppy(url: URL(fileURLWithPath: args[flagIndex + 1]))
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

    /// Machine > Power (M6 Task 1, ⌘⌥P): presses the Lisa's soft-power button.
    /// The OS sees the COPS `$FB` reset-dispatch byte, runs its own clean
    /// shutdown, and issues a COPS power-off command -- the emulated machine
    /// then stops (`poweredOff` flips true via the next status publish).
    /// Closes M1c/M2's consciously-deferred "power on/off via COPS" Power-menu
    /// item (spec §4). A thin passthrough, matching every other menu action's
    /// "controller is private; reach it through AppModel" boundary.
    func pressPowerButton() {
        controller?.pressPowerButton()
    }

    /// Whether the emulated Lisa has cleanly powered itself off (M6 Task 1) --
    /// derived from the latest `EmuStatus`, so it updates reactively as the
    /// shutdown completes. Distinct from `status?.halted` (a fatal fault).
    var poweredOff: Bool { status?.poweredOff ?? false }

    /// Explicit clean-shutdown hook (M1c Task 5 polish: "clean shutdown --
    /// emulation thread joined on window close"). Releasing `controller`
    /// here drops the last strong reference to `EmulationController`,
    /// running its `deinit` -- which posts `.shutdown` to the emulation
    /// thread's mailbox and BLOCKS (`shutdownGate.wait()`) until that
    /// thread actually acknowledges and returns from its run loop, i.e. a
    /// real join, not just "stop asking it to run." Called from
    /// `AppDelegate.applicationWillTerminate` (`LisaApp.swift`) --
    /// deliberately NOT left to happen implicitly via ARC releasing the
    /// `App`'s `@State` when the process exits: macOS's actual quit path
    /// (`NSApplication.terminate` ending the run loop) does not reliably
    /// guarantee Swift deinits run before the process itself exits, so
    /// this makes the join an explicit, verifiable step instead of an
    /// accident of teardown ordering.
    func shutdown() {
        controller = nil
    }

    // MARK: - Input (M1c Task 4)

    /// Passthrough seam for `InputCapture`: `controller` is intentionally
    /// `private` (nothing outside `AppModel` should reach into
    /// `EmulationController` directly -- see its own `debugSync` doc
    /// comment for the same boundary-enforcement rationale), so
    /// `InputCapture` posts through here rather than being handed the
    /// controller itself.
    func post(_ event: InputEvent) {
        controller?.post(event)
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

/// Lock-guarded latest-frame slot backing `AppModel.wire(_:)`'s coalescing
/// fix (whole-branch-review Important finding: "unthrottled mode can flood
/// the main thread with CGImage rebuilds"). Two operations, matching the
/// producer (emulation thread, every vsync) / consumer (main queue, once
/// per scheduled apply) split:
///
/// - `offer(_:)`: called by the PRODUCER. Always stores `frame` as the
///   latest pending one (overwriting whatever was there -- a not-yet-
///   applied older frame is by definition stale once a newer one exists).
///   Returns `true` exactly when no apply is currently scheduled (i.e. the
///   caller should schedule one); once `true` has been returned, every
///   subsequent `offer` returns `false` until the next `take()`, so at
///   most one scheduled apply is ever outstanding no matter how many
///   frames arrive in between.
/// - `take()`: called by the CONSUMER (the scheduled main-queue block).
///   Returns whatever the latest offered frame was and clears the slot +
///   the "scheduled" flag, re-arming `offer` to return `true` again for
///   the next frame.
///
/// `final class ... @unchecked Sendable`: an `NSLock` guards every access
/// to the two `var`s below, which is exactly the shape `@unchecked
/// Sendable` exists for -- the compiler cannot verify a hand-rolled lock's
/// correctness itself, but the invariant (never touch `pending`/
/// `scheduled` without holding `lock`) is upheld by every method in this
/// type, the only place either property is touched.
final class FrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Frame?
    private var scheduled = false

    /// Records `frame` as the latest pending frame; returns whether the
    /// caller should schedule a consuming apply (see this type's doc
    /// comment for the full offer/take protocol).
    func offer(_ frame: Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = frame
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Consumes and returns the latest pending frame (`nil` if somehow
    /// called with nothing pending), clearing both `pending` and
    /// `scheduled` so the next `offer(_:)` call schedules again.
    func take() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        let frame = pending
        pending = nil
        return frame
    }
}
