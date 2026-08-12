import Foundation
import LisaCore

/// Lisa-side input event, forwarded 1:1 onto the existing `COPS.postKey`/
/// `postMouse` seams (docs/superpowers/plans/2026-08-05-m1c-app-shell.md
/// Task 1 "Interfaces"). Deliberately Lisa-keycap-shaped, not
/// host-keycap-shaped -- translating host (macOS) key codes into these is
/// Task 2's `KeyMap`, which lives in the app layer, not here.
public enum InputEvent {
    case keyDown(UInt8)
    case keyUp(UInt8)
    case mouseDelta(dx: Int8, dy: Int8)
    case mouseButton(down: Bool)
}

/// Published ~4Hz on the emulation thread (see `EmulationController`'s
/// "Threading" doc comment for the cross-thread contract -- same as
/// `FramePublisher.onFrame`, the app hops threads itself inside the
/// closure).
public struct EmuStatus: Sendable {
    public let cycles: UInt64
    public let halted: Bool
    public let throttled: Bool
    public let emulatedSeconds: Double
    /// Whether a floppy image is currently attached (`FloppyController
    /// .isInserted`), sampled fresh at every publish -- an instantaneous
    /// snapshot, not a diffed/edge-triggered flag like `diskActivity`.
    public let diskInserted: Bool
    /// M2 Task 7: "the floppy processed a command within the last status
    /// interval" -- computed by diffing `FloppyController.commandsProcessed`
    /// against its value at the previous publish (see
    /// `EmulationController.runEmulationThread`'s `lastCommandsProcessed`).
    /// Deliberately simple: any go-byte the controller finished handling
    /// since the last publish counts as "activity," whether it was a real
    /// disk read or a housekeeping command (`seek`/`clristat`/...) -- this
    /// is a UI liveness indicator (`ScreenView`'s status-strip flash), not a
    /// precise "disk read in progress" signal.
    public let diskActivity: Bool
    /// M6 Task 1 (soft power): whether the machine has been cleanly powered
    /// off by its own OS shutdown (COPS power-off command -> `Machine
    /// .powerState == .off`), sampled fresh at every publish. Distinct from
    /// `halted` (a fatal double-fault): a powered-off Lisa stopped on purpose.
    /// The app surfaces this as a "powered off" UI state.
    public let poweredOff: Bool
}

/// Commands crossing from any external thread into the emulation thread's
/// mailbox (see `Mailbox`, below). Internal: the public surface is
/// `EmulationController`'s methods, which just enqueue these.
private enum Command {
    case start
    case pause
    case reset
    case setThrottled(Bool)
    case input(InputEvent)
    case screenshot(@Sendable (Frame) -> Void)
    case debug((Machine) -> Void)
    case insertFloppy(URL)
    case ejectFloppy
    case attachWidget(URL)
    case detachWidget
    case powerButton
    case shutdown
}

/// Locked command queue crossing from any thread into the emulation
/// thread's loop, drained between run slices (see `EmulationController`'s
/// "Threading" doc comment). Backed by a plain `NSLock` + array: the task
/// brief named two shapes ("NSCondition or os_unfair_lock + array"); this
/// is functionally the same shape as the latter (a lock + array) using the
/// portable, non-`@unchecked` `NSLock` rather than the lower-level
/// `os_unfair_lock` C API. `NSCondition`'s wait/signal semantics buy
/// nothing here because the mailbox is drained by POLLING once per loop
/// iteration -- never a blocking wait for a command to arrive.
private final class Mailbox {
    private let lock = NSLock()
    private var commands: [Command] = []
    private var _throttled = false

    func post(_ command: Command) {
        lock.lock()
        commands.append(command)
        if case .setThrottled(let value) = command { _throttled = value }
        lock.unlock()
    }

    /// `throttled`'s cached last-set value, readable synchronously from any
    /// thread without waiting for the emulation loop to drain the
    /// corresponding `.setThrottled` command -- satisfies the brief's
    /// "`var throttled: Bool` (mailbox-set)": the SETTER goes through the
    /// mailbox like any other cross-thread command (so the emulation loop
    /// applies it, and `EmuStatus.throttled` reflects it, between slices),
    /// while the GETTER can answer immediately from this lock-protected
    /// cache rather than round-tripping through the loop.
    var throttledSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _throttled
    }

    /// Drains and returns every command queued since the last drain, in
    /// FIFO order. Called once per emulation-loop iteration.
    func drain() -> [Command] {
        lock.lock()
        defer { lock.unlock() }
        let drained = commands
        commands.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Cross-thread shared state: everything the emulation thread's loop reads
/// or writes that isn't purely local to that thread's own call stack.
///
/// A separate object from `EmulationController` itself, on purpose: the
/// `Thread`'s closure is built and started from inside
/// `EmulationController.init`, BEFORE `self` is fully initialized, and
/// Swift forbids capturing `self` (even weakly) in an escaping closure
/// before all stored properties are set ("definite initialization").
/// Routing everything the thread needs through this fully-constructed-first
/// object sidesteps that entirely.
private final class Shared {
    let romDirectory: URL
    let framePublisher: FramePublisher
    let mailbox = Mailbox()

    private let lock = NSLock()
    private var _onStatus: (@Sendable (EmuStatus) -> Void)?
    var onStatus: (@Sendable (EmuStatus) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStatus }
        set { lock.lock(); defer { lock.unlock() }; _onStatus = newValue }
    }

    /// M2 Task 7's chosen error surface for `insertFloppy(url:)` load
    /// failures -- see `EmulationController.onDiskError`'s doc comment for
    /// why a dedicated callback was chosen over adding an error field to
    /// `EmuStatus`. Same lock-protected get/set shape as `onStatus`, above,
    /// for the identical cross-thread-reassignment reason.
    private var _onDiskError: (@Sendable (String) -> Void)?
    var onDiskError: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onDiskError }
        set { lock.lock(); defer { lock.unlock() }; _onDiskError = newValue }
    }

    /// Set only from the emulation thread's startup failure path (before
    /// `startupGate.signal()`), read only from `EmulationController.init`
    /// after `startupGate.wait()` returns -- the semaphore itself is the
    /// happens-before edge, so this doesn't need its own lock.
    var startupError: Error?

    init(romDirectory: URL, framePublisher: FramePublisher) {
        self.romDirectory = romDirectory
        self.framePublisher = framePublisher
    }
}

/// Owns a dedicated emulation thread that creates and exclusively drives a
/// `Machine`, per `docs/superpowers/plans/2026-08-05-m1c-app-shell.md`'s
/// threading rule: "the `Machine` is created ON the emulation thread and
/// never touched from any other thread." `M68K`'s own `assertOwner()`
/// (`Sources/LisaCore/M68K.swift`) is the enforcement backstop -- it
/// records its creation thread and traps in debug builds if ever called
/// from another one, which is exactly why `Machine(...)` is constructed
/// inside the thread's own entry point (`runEmulationThread`/`makeMachine`
/// below) rather than in `init` on the caller's thread.
///
/// ## Threading
///
/// All cross-thread traffic goes through either:
/// - the `Mailbox` (commands: start/pause/reset/throttle/input/screenshot),
///   drained once per loop iteration between run slices, or
/// - immutable published snapshots: `FramePublisher.onFrame` (called once
///   per vsync) and `onStatus` (called ~4Hz) -- both invoked ON THE
///   EMULATION THREAD; the app is responsible for hopping to its own
///   thread inside those closures, this type never does it for them.
///
/// ## Pacing
///
/// Throttled mode paces `Machine.run(until:)` calls using `Governor`
/// (above), anchored to a nominal start time recomputed whenever
/// start/reset/throttle-toggle re-enters the throttled branch. Unthrottled
/// mode runs continuous one-vsync-sized slices (`VideoTiming.cyclesPerVsync`
/// cycles) back-to-back with no sleep, still draining the mailbox between
/// slices so input/pause/etc. stay responsive.
///
/// ## reset() semantics
///
/// `reset()` posts a mailbox command that calls `machine.reset()` -- a true
/// hardware warm reset (see `LisaCore.Machine.reset()`'s doc comment) -- on
/// the live emulation-thread `Machine`, rather than tearing down and
/// recreating it. M1c's interim behavior (recreate `Machine` from scratch)
/// is gone: warm reset is simpler (no ROM re-read, no re-wiring `onVsync`/
/// the bus closures), faster, and -- the load-bearing reason -- means any
/// Bus-attached device state a later task adds (e.g. Task 4's inserted
/// floppy image) survives a controller reset BY CONSTRUCTION, since the
/// `Machine`/`Bus` object identity never changes. Real hardware's RESTART
/// button doesn't eject media either.
public final class EmulationController {
    public let framePublisher = FramePublisher()

    public var onStatus: (@Sendable (EmuStatus) -> Void)? {
        get { shared.onStatus }
        set { shared.onStatus = newValue }
    }

    /// Fires ON THE EMULATION THREAD (same contract as `onStatus`/`onFrame`
    /// -- the app hops threads itself) exactly when `insertFloppy(url:)`'s
    /// `DC42Image.load(url:)` throws, with a human-readable description.
    /// Never fires for a successful insert.
    ///
    /// **Documented choice**: a dedicated callback, not an `EmuStatus`
    /// field. `EmuStatus` is a periodic ~4Hz SNAPSHOT (its whole shape is
    /// "what does the machine look like right now") -- a load failure is a
    /// discrete EVENT that happens once, synchronously with the
    /// `insertFloppy` call that caused it. Modeling it as a status field
    /// would need its own sticky/clear lifecycle (when does the field go
    /// back to `nil`? on the next successful insert? after N publishes?)
    /// that has no natural answer, whereas a callback delivers the failure
    /// exactly once, right when it happens, mirroring `onStatus`'s own
    /// "fire and let the app decide what to do" shape. `AppModel` (LisaApp)
    /// surfaces this as a dismissible alert, same pattern as `startupError`
    /// but non-fatal.
    public var onDiskError: (@Sendable (String) -> Void)? {
        get { shared.onDiskError }
        set { shared.onDiskError = newValue }
    }

    /// Mailbox-set (see `Mailbox.throttledSnapshot`'s doc comment): the
    /// setter posts `.setThrottled` for the emulation loop to apply between
    /// slices; the getter answers from a lock-protected cache, not a
    /// mailbox round-trip. Defaults to `false` (unthrottled) -- `LisaApp`
    /// (Task 5) is where "throttle default ON" becomes the shipped default;
    /// this layer stays neutral.
    public var throttled: Bool {
        get { shared.mailbox.throttledSnapshot }
        set { shared.mailbox.post(.setThrottled(newValue)) }
    }

    private let shared: Shared
    private let startupGate = DispatchSemaphore(value: 0)
    private let shutdownGate = DispatchSemaphore(value: 0)

    /// Lisa keycap for the mouse button, per hardware-notes.md §8 "Mouse":
    /// "keycap `$06` in the KEYBOARD stream (down = `$86`, up = `$06`) --
    /// NOT part of the delta packet." This is an ordinary keycap event
    /// (`COPS.postKey`), the same channel as every other key -- there is no
    /// separate "modifier state" or delta-packet-field mechanism for the
    /// mouse button (Task 1's `placeholderMouseButtonKeycap = 0x7F` --
    /// Command/Apple -- was a pre-research stand-in per that constant's
    /// former doc comment; M1c Task 4 corrects it to the researched `$06`
    /// in lockstep with hardware-notes.md, matching the both-docs rule
    /// `COPS.placeholderKeyboardID` established for the keyboard-ID byte).
    static let mouseButtonKeycap: UInt8 = 0x06

    public init(romDirectory: URL) throws {
        let framePublisher = self.framePublisher
        let shared = Shared(romDirectory: romDirectory, framePublisher: framePublisher)
        self.shared = shared

        let startupGate = self.startupGate
        let shutdownGate = self.shutdownGate
        let thread = Thread {
            EmulationController.runEmulationThread(shared: shared, startupGate: startupGate,
                                                     shutdownGate: shutdownGate)
        }
        thread.name = "LisaEmu.EmulationController"
        thread.stackSize = 4 << 20
        thread.start()

        startupGate.wait()
        if let error = shared.startupError {
            throw error
        }
    }

    deinit {
        shared.mailbox.post(.shutdown)
        shutdownGate.wait()
    }

    public func start() { shared.mailbox.post(.start) }
    public func pause() { shared.mailbox.post(.pause) }
    public func reset() { shared.mailbox.post(.reset) }
    public func post(_ event: InputEvent) { shared.mailbox.post(.input(event)) }

    /// Posts a mailbox command that loads `url` as a `DC42Image` ON THE
    /// EMULATION THREAD and attaches it via `Machine.bus.floppy.insert(_:)`
    /// -- mirrors `Task 5`'s `bootedWithDisk()` test helper, but reachable
    /// from any thread through the mailbox rather than requiring direct
    /// `Machine` access. A load failure (bad path, malformed/truncated
    /// DC42 container -- see `DC42Image.Error`) is caught on the emulation
    /// thread and reported via `onDiskError`, never thrown across the
    /// mailbox boundary and never left to crash the emulation thread.
    /// Asynchronous, like every other mailbox command: the insert is not
    /// guaranteed complete by the time this call returns (see `debugSync`'s
    /// doc comment for the test-only seam that CAN block for that).
    public func insertFloppy(url: URL) { shared.mailbox.post(.insertFloppy(url)) }

    /// Posts a mailbox command that calls `Machine.bus.floppy.eject()` on
    /// the emulation thread. A no-op if nothing is currently inserted.
    ///
    /// **NOT symmetric with `insertFloppy(url:)`, deliberately (M6 Task 4
    /// decision).** `insertFloppy` raises the OS-visible media-change
    /// attention (`insertWhileRunning`); this calls bare `eject()`, which
    /// raises nothing. That is correct, not a bug: see
    /// `FloppyController.eject()`'s doc comment "User-forced eject" (and
    /// docs/hardware-notes.md §9) -- a real Lisa's Sony drive has no
    /// independent "diskette physically removed" interrupt at all, only the
    /// OS's OWN commanded eject (`unclamp`, a 68000-driven solenoid), so
    /// this menu command already models a scenario with no real-hardware
    /// interrupt to raise even in principle. The OS discovers the stale
    /// presence on its own next disk access (a failed read/write already
    /// raises a normal completion interrupt with a read/write DISKERR --
    /// see `FloppyController.performRead`/`performWrite`'s `image == nil`
    /// paths), exactly as it would on real hardware.
    public func ejectFloppy() { shared.mailbox.post(.ejectFloppy) }

    /// Posts a mailbox command that attaches a Widget hard-disk image at `url`
    /// ON THE EMULATION THREAD via `Machine.bus.widget.attach(_:)` -- the
    /// hard-disk counterpart of `insertFloppy(url:)` (M5 Task 2). If the file
    /// does not exist, an all-zero blank Widget-10 image is CREATED there on
    /// demand (docs/hardware-notes.md §10.10 creation policy); an existing
    /// file is opened and validated. Unlike the floppy's read-only session
    /// overlay, Widget writes PERSIST to this file (write-back, §10.10). An
    /// open/create failure is caught on the emulation thread and reported via
    /// `onDiskError` (the same surface `insertFloppy` uses), never thrown
    /// across the mailbox boundary. Asynchronous, like every mailbox command.
    public func attachWidget(url: URL) { shared.mailbox.post(.attachWidget(url)) }

    /// Symmetric with `attachWidget(url:)`: posts a command that calls
    /// `Machine.bus.widget.detach()` on the emulation thread. A no-op if no
    /// Widget is currently attached.
    public func detachWidget() { shared.mailbox.post(.detachWidget) }

    /// Presses the Lisa's soft-power button (M6 Task 1): posts a mailbox
    /// command that calls `Machine.bus.cops.pressPowerButton()` on the
    /// emulation thread. The OS sees the COPS `$FB` reset-dispatch byte and
    /// runs its own shutdown, which ends by issuing a COPS power-off command
    /// -> `Machine.powerState == .off`; the run loop then stops executing and
    /// publishes a `poweredOff` status. Asynchronous, like every mailbox
    /// command -- the shutdown takes real emulated time to run.
    public func pressPowerButton() { shared.mailbox.post(.powerButton) }

    /// Returns the raw 1bpp framebuffer snapshot + dimensions via `Frame`
    /// (PNG-encoding stays app-side, per the plan's Task 1 interfaces).
    /// `completion` fires ON THE EMULATION THREAD, same as `onFrame`/
    /// `onStatus` -- the app hops threads itself. The returned `Frame`'s
    /// `sequence` is `framePublisher.currentSequence` (the most recently
    /// published vsync frame's number, or 0 if none yet), not a fabricated
    /// `0` -- see that property's doc comment for why a hardcoded `0` would
    /// wrongly collide with `Frame`'s own "no frame published yet" sentinel.
    ///
    /// `@Sendable`: see `FramePublisher.onFrame`'s doc comment for why --
    /// same cross-thread-callback trap, hit here first during Task 3's
    /// manual verification checkpoint via `AppModel.requestScreenshotPNG`.
    public func requestScreenshot(_ completion: @escaping @Sendable (Frame) -> Void) {
        shared.mailbox.post(.screenshot(completion))
    }

    /// Test-only observability seam
    /// (docs/superpowers/plans/2026-08-05-m1c-app-shell.md Task 1, "input
    /// events reach COPS" test discussion in task-1-report.md):
    /// synchronously fetches a value computed from the LIVE `Machine`,
    /// blocking the caller until the emulation thread has drained the
    /// mailbox up to and including this request and run `body`.
    ///
    /// Deliberately `internal`, not `public`: defeats the entire point of
    /// the async mailbox/thread-ownership design if called from the app's
    /// UI thread (it blocks the CALLER, not the emulation thread, but a
    /// production caller has no legitimate reason to reach into `Machine`
    /// directly anyway -- that's exactly the boundary this type exists to
    /// enforce). `@testable import LisaShell` is how `LisaShellTests`
    /// reaches this.
    func debugSync<T>(_ body: @escaping (Machine) -> T) -> T {
        var result: T!
        let sem = DispatchSemaphore(value: 0)
        shared.mailbox.post(.debug { machine in
            result = body(machine)
            sem.signal()
        })
        sem.wait()
        return result
    }

    // MARK: - Emulation thread

    private static func makeMachine(romBytes: [UInt8], shared: Shared) -> Machine {
        let machine = Machine(ramSize: 0x20_0000)   // 2 MB, hardware max -- matches ROMBootTests.
        machine.bus.loadROM(romBytes)
        machine.reset()
        // [weak machine]: `onVsync` is a property ON `machine` itself, so a
        // strong capture here would be a genuine retain cycle.
        machine.onVsync = { [weak machine] in
            guard let machine else { return }
            shared.framePublisher.publish(bits: machine.bus.framebufferSnapshot(),
                                           width: Bus.framebufferWidth,
                                           height: Bus.framebufferHeight)
        }
        return machine
    }

    private static func apply(_ event: InputEvent, to machine: Machine) {
        switch event {
        case .keyDown(let code):
            machine.bus.cops.postKey(code: code, down: true)
        case .keyUp(let code):
            machine.bus.cops.postKey(code: code, down: false)
        case .mouseDelta(let dx, let dy):
            machine.bus.cops.postMouse(dx: dx, dy: dy)
        case .mouseButton(let down):
            machine.bus.cops.postKey(code: mouseButtonKeycap, down: down)
        }
    }

    /// Runs entirely on the dedicated emulation thread; never touches
    /// `EmulationController` (`self`) -- see `Shared`'s doc comment for why.
    private static func runEmulationThread(shared: Shared, startupGate: DispatchSemaphore,
                                            shutdownGate: DispatchSemaphore) {
        let romBytes: [UInt8]
        let machine: Machine
        do {
            romBytes = try ROMImage.load(directory: shared.romDirectory)
            machine = makeMachine(romBytes: romBytes, shared: shared)
        } catch {
            shared.startupError = error
            startupGate.signal()
            shutdownGate.signal()
            return
        }
        startupGate.signal()

        var running = false
        // `nil` means "recompute on next throttled slice" -- forces a fresh
        // anchor whenever we (re-)enter throttled running (start/reset/
        // throttle-toggle), so pacing always resumes relative to "now",
        // never replays a stale wall-clock anchor from before a pause.
        var throttleAnchor: TimeInterval?
        var lastStatusPublish = ProcessInfo.processInfo.systemUptime
        // Whether a HALTED status has been force-published at least ONCE for
        // the CURRENT halt (see `haltedStatusPublish(...)`, below, and this
        // function's "guard running, !machine.halted" branch) -- reset
        // whenever the machine is not halted (including a fresh `.reset`) so
        // the next halt gets its own immediate forced publish. Does NOT
        // suppress every publish thereafter (M3 Task 3, M1c parked debt):
        // once true, `haltedStatusPublish` still answers `true` again every
        // `statusPublishInterval`, so a halted machine's status (throttled
        // flag, cycle count) keeps refreshing instead of going stale forever
        // after the one transition publish.
        var haltedPublished = false
        // `FloppyController.commandsProcessed` as of the last published
        // `EmuStatus` -- diffed against the live value at each publish site
        // to compute `EmuStatus.diskActivity` (see that property's doc
        // comment). Reset to 0 alongside the floppy controller's own
        // counter whenever `.reset` fires, so a warm reset doesn't report
        // stale "activity" from before it.
        var lastCommandsProcessed = 0
        func currentStatus(halted: Bool) -> EmuStatus {
            let commandsProcessed = machine.bus.floppy.commandsProcessed
            let activity = commandsProcessed != lastCommandsProcessed
            lastCommandsProcessed = commandsProcessed
            return EmuStatus(cycles: machine.cycles,
                              halted: halted,
                              throttled: shared.mailbox.throttledSnapshot,
                              emulatedSeconds: Double(machine.cycles) / Governor.cyclesPerSecond,
                              diskInserted: machine.bus.floppy.isInserted,
                              diskActivity: activity,
                              poweredOff: machine.powerState == .off)
        }

        while true {
            for command in shared.mailbox.drain() {
                switch command {
                case .start:
                    running = true
                    throttleAnchor = nil
                case .pause:
                    running = false
                case .reset:
                    // Warm reset (M2 Task 2): same Machine/Bus identity,
                    // not a recreate -- see this type's "reset() semantics"
                    // doc comment above.
                    machine.reset()
                    running = false
                    throttleAnchor = nil
                    haltedPublished = false
                    lastCommandsProcessed = 0
                case .setThrottled:
                    throttleAnchor = nil
                case .input(let event):
                    apply(event, to: machine)
                case .screenshot(let completion):
                    completion(Frame(bits: machine.bus.framebufferSnapshot(),
                                      width: Bus.framebufferWidth,
                                      height: Bus.framebufferHeight,
                                      sequence: shared.framePublisher.currentSequence))
                case .debug(let body):
                    body(machine)
                case .insertFloppy(let url):
                    do {
                        let image = try DC42Image.load(url: url)
                        // Mailbox insert happens WHILE the OS is running, so use
                        // the media-change path: it raises the floppy attention
                        // interrupt (bot_in) the OS's DISK_INT needs to mount the
                        // new volume (M5 Task 3 round 2). Bare insert() is only
                        // for the power-on/pre-boot path (tests, lisadbg --disk).
                        machine.bus.floppy.insertWhileRunning(image)
                    } catch {
                        shared.onDiskError?("Could not load disk image at \(url.path): \(error)")
                    }
                case .ejectFloppy:
                    // Deliberately the bare eject, not an OS-attention path --
                    // see `ejectFloppy()`'s doc comment (M6 Task 4 decision):
                    // real hardware has no "physically removed" interrupt to
                    // raise here at all.
                    machine.bus.floppy.eject()
                case .attachWidget(let url):
                    do {
                        let image: WidgetImage
                        if FileManager.default.fileExists(atPath: url.path) {
                            image = try WidgetImage(contentsOf: url)
                        } else {
                            // Blank-on-demand (§10.10): a fresh Widget is blank.
                            image = try WidgetImage(createBlankAt: url)
                        }
                        machine.bus.widget.attach(image)
                    } catch {
                        shared.onDiskError?("Could not open/create Widget image at \(url.path): \(error)")
                    }
                case .detachWidget:
                    machine.bus.widget.detach()
                case .powerButton:
                    machine.bus.cops.pressPowerButton()
                case .shutdown:
                    shutdownGate.signal()
                    return
                }
            }

            guard running, !machine.halted, machine.powerState == .on else {
                // Avoid a hot spin while paused/halted/powered-off; mailbox is
                // still drained every iteration so commands stay responsive.
                // M6 Task 1: a cleanly powered-off machine (COPS power-off ->
                // `powerState == .off`) is a terminal-until-reset stop, just
                // like `halted` -- it reuses the exact same force-publish path
                // below so the app reliably learns the transition (the status
                // it publishes carries `poweredOff`, sampled in
                // `currentStatus`). `stopped` OR's the two so either reason
                // triggers the transition + periodic republish.
                //
                // HALTED force-publish (whole-branch-review Important
                // finding: "HALTED status almost never published"): without
                // this, the ~4Hz publish below only ever runs from the
                // `running`/still-executing branch. The instant
                // `machine.halted` flips true (discovered by `Machine.run
                // (until:)` INSIDE the slice below, on some earlier
                // iteration), THIS branch is taken on every subsequent
                // iteration instead, and the publish below is unreachable
                // forever after -- so the one iteration where `run(until:)`
                // just discovered the halt was the ONLY chance to publish
                // it, and that iteration only actually published if it also
                // happened to cross the independent `statusPublishInterval`
                // `lastStatusPublish` gate (empirically ~7% of transitions,
                // per the review).
                //
                // M3 Task 3 (M1c parked debt -- "halted-status staleness"):
                // the original fix stopped at forcing exactly ONE publish
                // per halt, transition-only -- which fixed the "almost never
                // published" bug but left a narrower staleness: once halted,
                // NOTHING published again for the rest of the run, so a
                // throttle toggle or (hypothetically) any other post-halt
                // status change would never reach the app. The halted branch
                // now gets its OWN interval check, mirroring the running
                // branch's `now - lastStatusPublish >= statusPublishInterval`
                // gate below: `haltedStatusPublish` (pure decision function,
                // see below) forces exactly one IMMEDIATE publish at the
                // transition (`!alreadyPublished`), then republishes again
                // every `statusPublishInterval` for as long as the halt
                // continues, same cadence as ordinary running-mode status.
                let now = ProcessInfo.processInfo.systemUptime
                let stopped = machine.halted || machine.powerState == .off
                if EmulationController.haltedStatusPublish(machineHalted: stopped,
                                                             alreadyPublished: haltedPublished,
                                                             secondsSinceLastPublish: now - lastStatusPublish) {
                    haltedPublished = true
                    lastStatusPublish = now
                    shared.onStatus?(currentStatus(halted: machine.halted))
                }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            if shared.mailbox.throttledSnapshot {
                let now = ProcessInfo.processInfo.systemUptime
                let anchor = throttleAnchor ?? {
                    let a = now - Double(machine.cycles) / Governor.cyclesPerSecond
                    throttleAnchor = a
                    return a
                }()
                let (target, newAnchor) = Governor.clampedTargetCycles(anchor: anchor, now: now,
                                                                        cyclesDone: machine.cycles)
                throttleAnchor = newAnchor
                let sliceStart = now
                machine.run(until: target)
                let sliceDuration = ProcessInfo.processInfo.systemUptime - sliceStart
                let sleep = Governor.sleepInterval(sliceDuration: sliceDuration)
                if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
            } else {
                throttleAnchor = nil
                machine.run(until: machine.cycles + VideoTiming.cyclesPerVsync)
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStatusPublish >= EmulationController.statusPublishInterval {
                lastStatusPublish = now
                shared.onStatus?(currentStatus(halted: machine.halted))
            }
        }
    }

    /// Minimum interval, in seconds, between `onStatus` publishes -- the
    /// ~4Hz cadence the type's doc comment ("## Threading") promises.
    /// Shared by both the ordinary running-mode gate (`runEmulationThread`'s
    /// final `if now - lastStatusPublish >= ...` check) and the halted-mode
    /// periodic republish (`haltedStatusPublish`, below) -- factored out
    /// (M3 Task 3) so the two gates can't drift apart, and so tests can
    /// reference the real production cadence instead of hardcoding `0.25`
    /// a second time.
    static let statusPublishInterval: TimeInterval = 0.25

    /// Pure decision function for the HALTED-branch publish, above --
    /// extracted so the logic is unit-testable without a real `Machine`/
    /// ROM/thread (see `HaltedStatusPublishTests`). Answers "should THIS
    /// iteration publish a HALTED status":
    /// - `false` whenever `!machineHalted` (the running branch owns
    ///   publishing then, via its own `statusPublishInterval` gate).
    /// - `true` on the FIRST call for a given halt (`!alreadyPublished`),
    ///   unconditionally and immediately -- this is what fixes the original
    ///   "HALTED status almost never published" bug: the transition is never
    ///   missed regardless of `secondsSinceLastPublish`.
    /// - Thereafter (M3 Task 3, the halted-status-staleness parked debt):
    ///   `true` again once `secondsSinceLastPublish >= statusPublishInterval`
    ///   -- so a status keeps flowing periodically for as long as the halt
    ///   lasts, at the same cadence as ordinary running-mode status, instead
    ///   of publishing exactly once and then never again.
    static func haltedStatusPublish(machineHalted: Bool, alreadyPublished: Bool,
                                     secondsSinceLastPublish: TimeInterval) -> Bool {
        guard machineHalted else { return false }
        guard alreadyPublished else { return true }
        return secondsSinceLastPublish >= statusPublishInterval
    }
}

