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
        // Whether a HALTED status has already been force-published for the
        // CURRENT halt (see `haltedStatusPublish(...)`, below, and this
        // function's "guard running, !machine.halted" branch) -- reset
        // whenever the machine is not halted (including a fresh `.reset`)
        // so the next halt gets its own forced publish.
        var haltedPublished = false

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
                case .shutdown:
                    shutdownGate.signal()
                    return
                }
            }

            guard running, !machine.halted else {
                // Avoid a hot spin while paused/halted; mailbox is still
                // drained every iteration so commands stay responsive.
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
                // happened to cross the independent 0.25s `lastStatusPublish`
                // gate (empirically ~7% of transitions, per the review). Use
                // `haltedStatusPublish` (pure decision function, see below)
                // to force exactly one publish per halt, regardless of the
                // 0.25s gate, from right here -- both immediately after the
                // transition (next loop iteration after `run(until:)`
                // discovers it) and, defensively, from this branch on any
                // subsequent iteration if that first attempt were ever
                // somehow missed.
                if EmulationController.haltedStatusPublish(machineHalted: machine.halted,
                                                             alreadyPublished: haltedPublished) {
                    haltedPublished = true
                    lastStatusPublish = ProcessInfo.processInfo.systemUptime
                    shared.onStatus?(EmuStatus(cycles: machine.cycles,
                                                halted: true,
                                                throttled: shared.mailbox.throttledSnapshot,
                                                emulatedSeconds: Double(machine.cycles) / Governor.cyclesPerSecond))
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
            if now - lastStatusPublish >= 0.25 {
                lastStatusPublish = now
                shared.onStatus?(EmuStatus(cycles: machine.cycles,
                                            halted: machine.halted,
                                            throttled: shared.mailbox.throttledSnapshot,
                                            emulatedSeconds: Double(machine.cycles) / Governor.cyclesPerSecond))
            }
        }
    }

    /// Pure decision function for the HALTED force-publish, above --
    /// extracted so the transition logic is unit-testable without a real
    /// `Machine`/ROM/thread (see `EmulationControllerHaltedPublishTests`).
    /// Answers "should THIS iteration force-publish a HALTED status": true
    /// exactly once per halt (`machineHalted && !alreadyPublished`), never
    /// while not halted, and never a second time for the same halt once
    /// `alreadyPublished` is true.
    static func haltedStatusPublish(machineHalted: Bool, alreadyPublished: Bool) -> Bool {
        machineHalted && !alreadyPublished
    }
}

