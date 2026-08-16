import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LisaCore
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

    /// M7 Task 4: the Machine-menu "Printer Connected (Serial B)" indicator,
    /// **default connected**. The emulator always attaches the printer pipeline
    /// to Serial B (see `EmulationController`), so this is primarily a status
    /// indicator; when the user unchecks it, the app suppresses the print panel
    /// (treating the printer as unplugged) rather than reaching into the
    /// emulation thread to detach the port. A real ImageWriter print still
    /// requires the OS-side Preferences → Connect Devices config (§11.6); this
    /// toggle is the app's own "should I surface print jobs" switch.
    var printerConnected: Bool = true

    private var controller: EmulationController?

    /// Long-lived, reused across `apply(_:)` calls (perf-fix round, "CGImage
    /// pipeline reuse") -- sized/recreated only once the first frame's
    /// dimensions are known (or if they ever change). The OLD `apply(_:)`
    /// path rebuilt a fresh `Data(scratch) as CFData` (a full 720x364 copy)
    /// plus a new `CGDataProvider` every single vsync, forever, on top of
    /// the `CGImage` that's unavoidably fresh every call (SwiftUI needs a
    /// new image identity to redraw). This context's backing buffer is
    /// written into directly (`makeCGImage`), and `context.makeImage()`
    /// hands the result to a `CGImage` copy-on-write -- no copy at that
    /// call itself, only lazily, the next time this buffer is written to
    /// (see `makeCGImage`'s in-body comment on re-fetching `ctx.data`) --
    /// eliminating the per-frame `Data` copy + provider churn while still
    /// producing a correctly-identitied fresh `CGImage` each call. Also
    /// subsumes the old separate `rowBuffer`/`pixelScratch`
    /// pair: rows are expanded straight into this context's buffer, so
    /// there is no intermediate array to promote/reuse at all.
    private var pixelContext: CGContext?

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
        // M7 Task 4: a closed print job fires on the emulation thread (see
        // `EmulationController.onPrintJob`); hop to main, then present it in the
        // standard macOS print panel. `[PrinterPage]` is Sendable, so the hop
        // is clean; `presentPrintJob` respects the `printerConnected` toggle.
        controller.onPrintJob = { [weak self] pages in
            DispatchQueue.main.async {
                self?.presentPrintJob(pages)
            }
        }
    }

    /// Presents a closed print job (`[PrinterPage]`) in the standard macOS
    /// print panel — unless the "Printer Connected (Serial B)" indicator is
    /// off, in which case the job is dropped (the app is acting as an unplugged
    /// printer). Main-actor: `NSPrintOperation` is main-thread only, and
    /// `wire(_:)` already hopped here.
    private func presentPrintJob(_ pages: [PrinterPage]) {
        guard printerConnected else { return }
        PrintPresenter.present(pages)
    }

    private func apply(_ frame: Frame) {
        image = AppModel.makeCGImage(frame: frame, context: &pixelContext)
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

    /// LEXICAL filter for an insertable floppy image, matching File > Insert
    /// Disk…'s `NSOpenPanel` filter (`LisaApp.swift`'s
    /// `presentInsertDiskPanel`). Extracted as a `nonisolated static` pure
    /// function (no `AppModel` instance state) so `LisaAppTests` can
    /// exercise it directly without a real drag session -- same shape as
    /// `InputCapture.isReservedMenuShortcut`.
    ///
    /// **M9: `.image`/`.img` joined `.dc42`.** `.image` is the classic Disk
    /// Copy 4.2 extension -- Mac-era disks are routinely distributed as
    /// `Something.image` while being byte-for-byte DC42 containers (verified
    /// against a System 6.0.7 Tools image: 84-byte header, 819200-byte data
    /// plane, 19200 bytes of real tags). No parser work was needed for
    /// those; only this filter stood in the way.
    ///
    /// Still purely lexical, and `.image` therefore OVERLAPS `isWidgetFile`.
    /// That is deliberate and harmless for the two `NSOpenPanel`s, where the
    /// menu item the user chose states the intent. Drag-and-drop has no such
    /// signal, so it uses `isDroppableFloppyImage` instead.
    nonisolated static func isFloppyImageFile(_ url: URL) -> Bool {
        ["dc42", "image", "img"].contains(url.pathExtension.lowercased())
    }

    /// The drag-and-drop gate (`ScreenView.swift`'s `.onDrop`): the lexical
    /// filter above, then -- for the ambiguous `.image`/`.img` extensions a
    /// Widget hard-disk image can equally carry -- a cheap CONTENT probe, so
    /// dropping a Widget is silently ignored rather than bounced off
    /// `insertFloppy`'s error alert. `DC42Image.looksLikeDC42` reads 84
    /// bytes, not the file.
    ///
    /// `.dc42` deliberately skips the probe: the extension is unambiguous,
    /// and skipping keeps the documented "purely lexical, no filesystem
    /// check" behaviour intact for the format that has always worked (see
    /// `DiskInsertLogicTests.isPurelyLexicalNoFilesystemCheck`) -- a
    /// nonexistent or malformed `.dc42` still reaches
    /// `EmulationController.insertFloppy`'s try/catch and its dismissible
    /// alert, which is where bad images are meant to be reported.
    nonisolated static func isDroppableFloppyImage(_ url: URL) -> Bool {
        guard isFloppyImageFile(url) else { return false }
        if url.pathExtension.lowercased() == "dc42" { return true }
        return DC42Image.looksLikeDC42(url: url)
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

    /// Supports `--print-test`: a debug-only launch argument that, shortly
    /// after launch, feeds a synthetic ImageWriter page through the SAME
    /// `PrintPresenter` path a real print job uses — so the standard macOS
    /// print panel can be brought up (and screenshotted / "Save as PDF"
    /// sanity-checked) without driving a full multi-minute OS boot + print in
    /// the GUI. The page is rendered entirely from our own `SyntheticDotFont`
    /// via `ImageWriterInterpreter` (no Apple content). Inert unless the
    /// argument is present. Mirrors `runAutoScreenshotIfRequested`'s shape.
    func runPrintTestIfRequested() {
        let args = CommandLine.arguments
        // `--print-test-pdf <path>`: headless variant — writes the exact PDF
        // the panel would render (via `PrintDocument.makePDFData`) and quits.
        // Usable without a window server (unlike the interactive panel), so it
        // produces a viewable render artifact in CI / an agent context.
        if let flag = args.firstIndex(of: "--print-test-pdf"), args.count > flag + 1 {
            let path = args[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let pages = [AppModel.syntheticPrintTestPage()]
                if let data = PrintDocument.makePDFData(pages: pages) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard args.contains("--print-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.presentPrintJob([AppModel.syntheticPrintTestPage()])
        }
    }

    /// A synthetic ImageWriter page (our own `SyntheticDotFont` — no Apple
    /// content) for the `--print-test`/`--print-test-pdf` proofs.
    private static func syntheticPrintTestPage() -> PrinterPage {
        let interpreter = ImageWriterInterpreter()
        var page: PrinterPage?
        interpreter.onPage = { page = $0 }
        interpreter.feed(Array("LISAEMU M7 PRINT PANEL TEST".utf8))
        interpreter.flush()
        return page ?? PrinterPage(width: 8, height: 8, bits: [UInt8](repeating: 0, count: 8),
                                    dpi: PrinterPage.DPI(h: 160, v: 144))
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
            // A screenshot is a one-off, user-triggered request (not the
            // 60Hz hot path `apply(_:)` is), so a fresh `CGContext` here
            // -- rather than a reused instance property -- is fine: there's
            // no sustained-churn concern to optimize away.
            var context: CGContext?
            let png = AppModel.encodePNG(frame: frame, context: &context)
            DispatchQueue.main.async {
                completion(png)
            }
        }
    }

    // MARK: - Frame -> CGImage / PNG (CoreGraphics stays in LisaApp only;
    // the 1bpp -> 8bpp bit math itself is `LisaShell.expand1bppRow`)

    /// Expands `frame.bits` (packed 1bpp, MSB-first, set bit = black --
    /// see `expand1bppRow`'s doc comment) into an 8bpp DeviceGray
    /// `CGImage`. `nonisolated`, deliberately: `AppModel` itself is
    /// `@MainActor`, and
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
    ///
    /// `context` is caller-owned reusable storage (`pixelContext` for the
    /// hot `apply(_:)` path; a fresh local for the cold screenshot path) --
    /// created on first use and recreated only if `frame`'s dimensions ever
    /// change. Perf-fix round ("CGImage pipeline reuse" + "per-scanline
    /// array elimination"): the OLD implementation allocated a fresh
    /// `[UInt8]` `rowBuffer` AND `replaceSubrange`'d it into `scratch` AND
    /// sliced a fresh `Array(frame.bits[...])` per row, THEN wrapped the
    /// whole `scratch` buffer in a fresh `Data`/`CGDataProvider` -- every
    /// single vsync, forever. This version expands each row directly out
    /// of `frame.bits` (no per-row slice) into `context`'s own backing
    /// buffer (no intermediate row buffer, no final whole-frame copy), and
    /// hands back `context.makeImage()` -- which still allocates a new
    /// `CGImage` per call (unavoidable: SwiftUI needs a new image identity
    /// to redraw), but nothing else.
    nonisolated static func makeCGImage(frame: Frame, context: inout CGContext?) -> CGImage? {
        let width = frame.width
        let height = frame.height
        if context == nil || context?.width != width || context?.height != height {
            // `bytesPerRow: width` (1 byte/pixel, 8bpp DeviceGray, no
            // padding) is only safe to hand to `expand1bppRow` as a flat
            // `width * height` buffer below because CGContext honors it
            // exactly for widths that are already a multiple of the pixel
            // format's natural alignment -- true for every real Lisa frame
            // (720 = 90 x 8 bytes). A non-16-byte-aligned width would let
            // Quartz silently pad each row wider than `width`, which would
            // desync `outputOffset: y * width` below from the context's
            // actual per-row stride and skew the image.
            context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let ctx = context, let base = ctx.data else { return nil }
        // Re-fetch `ctx.data` on every call (not cached alongside `context`
        // itself): `ctx.makeImage()` below hands the CURRENT buffer's
        // contents to the returned `CGImage` copy-on-write -- the backing
        // store isn't copied at `makeImage()` time, only lazily, on this
        // context's NEXT write after that. Quartz may satisfy that lazy
        // copy by allocating a fresh buffer and repointing `ctx.data`
        // rather than mutating in place, so a pointer captured on an
        // earlier call could silently go stale. Re-deriving `buffer` from
        // `ctx.data` fresh each call means we always write through
        // whatever pointer is actually live, and is also exactly why the
        // previously-returned `CGImage` can never tear: it already owns
        // (or will copy-on-write into) its own snapshot before this
        // function's next row-write touches anything.
        let buffer = UnsafeMutableBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: width * height
        )
        let bytesPerRow = (width + 7) / 8
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            let rowEnd = min(rowStart + bytesPerRow, frame.bits.count)
            guard rowEnd > rowStart else { break }
            expand1bppRow(frame.bits, rowByteOffset: rowStart, into: buffer, outputOffset: y * width, width: width)
        }
        return ctx.makeImage()
    }

    /// `nonisolated` for the same reason as `makeCGImage`, above -- also
    /// called from `requestScreenshotPNG`'s closure on the emulation
    /// thread.
    nonisolated static func encodePNG(frame: Frame, context: inout CGContext?) -> Data? {
        guard let image = makeCGImage(frame: frame, context: &context) else { return nil }
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
