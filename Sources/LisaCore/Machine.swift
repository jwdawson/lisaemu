public final class Machine {
    public let bus: Bus
    public let cpu: M68K
    public private(set) var cycles: UInt64 = 0
    /// True once the core has taken a fatal double-bus-fault HALT (see
    /// `M68K.isHalted`). A STOP instruction (low-power wait that resumes on
    /// interrupt) is *not* halted and does not set this flag. Cleared by
    /// `reset()`.
    public private(set) var halted = false
    /// Level-1 IRQ source alongside VIA1 (docs/hardware-notes.md §5:
    /// "Level 1: VIA1 ... Sources: VIA1 timer, vertical retrace, parallel
    /// port, Twiggy"). Defaults `false`; driven for real by `VideoTiming`
    /// (Task 5) via `Bus.vsyncInterruptHandler`, wired below. Exposed as a
    /// plain settable `var` -- unlike VIA1/VIA2's interrupt flags, there is
    /// no dedicated hardware register modeled here for the vsync source
    /// itself (that lives in `VideoTiming`), so this stands in for it in
    /// the IRQ-level computation below.
    public var vsyncPending = false
    /// Level-1 IRQ source alongside VIA1 and `vsyncPending` (docs/hardware-
    /// notes.md §5: Twiggy/Sony floppy interrupts are Level 1). Driven by
    /// `FloppyController`'s completion line via `Bus.floppyInterruptHandler`
    /// -- see `FloppyController`'s type doc comment "Level-1 IRQ
    /// contribution" for why this can't just fold into VIA2's own IFR/IER
    /// (VIA2 is wired to CPU level 2). Cleared by `Machine.reset()`
    /// (`FloppyController.reset()` calls the handler with `false`).
    public var floppyPending = false

    /// M1c shell hook (docs/superpowers/plans/2026-08-05-m1c-app-shell.md
    /// Task 1): called on the emulation thread at every `VideoTiming` vsync
    /// tick, regardless of whether the vsync interrupt is currently armed
    /// (contrast `vsyncPending`, which only reflects the IRQ-relevant
    /// subset). `LisaShell.FramePublisher` hooks this to snapshot
    /// `bus.framebufferSnapshot()` at the real ~60Hz cadence. Not used
    /// anywhere in LisaCore itself; `nil` by default so tests that don't
    /// care about frame cadence pay nothing. Forwarded from
    /// `bus.videoTiming.onVsyncTick` (assigned once in `init`, below);
    /// `reset()` does not need to reassign it since `Bus`/`VideoTiming` are
    /// not recreated by `reset()`, only re-initialized in place.
    public var onVsync: (() -> Void)?

    private struct Event {
        let cycle: UInt64
        let seq: UInt64
        let action: (Machine) -> Void
    }
    private var queue: [Event] = []   // kept sorted by (cycle, seq)
    private var nextSeq: UInt64 = 0

    public init(ramSize: Int = 0x20_0000) {
        bus = Bus(ramSize: ramSize)
        cpu = M68K(bus: bus)
        bus.supervisorProvider = { [weak cpu] in cpu?.isSupervisor ?? true }
        bus.busErrorHandler = { [weak cpu] address, isWrite in
            cpu?.pulseBusError(address: address, isWrite: isWrite)
        }
        bus.forceHaltHandler = { [weak cpu] in cpu?.forceHalt() }
        bus.cycleProvider = { [weak self] in self?.cycles ?? 0 }
        bus.scheduleEvent = { [weak self] delay, action in
            guard let self else { return }
            self.schedule(at: self.cycles &+ delay) { _ in action() }
        }
        bus.vsyncInterruptHandler = { [weak self] pending in self?.vsyncPending = pending }
        bus.floppyInterruptHandler = { [weak self] pending in self?.floppyPending = pending }
        bus.videoTiming.onVsyncTick = { [weak self] in self?.onVsync?() }
    }

    /// A true hardware warm reset (M2 Task 2), matching what the Lisa's
    /// reset line does to every device on the bus:
    ///
    /// - `Bus.resetSetupAndContextLatches()`: re-asserts the SETUP
    ///   flip-flop and clears both domain-context latch bits (`domain`
    ///   back to 0) — see that method's doc comment.
    /// - Both VIAs (`VIA6522.reset()`): DDRs/ORs/ACR/PCR/IER/IFR cleared,
    ///   timers disarmed — see that method's doc comment for the
    ///   datasheet basis and the one documented simplification.
    /// - `cpu.reset()`: CPU reset, deliberately AFTER the two resets above
    ///   — `m68k_pulse_reset()` immediately fetches the SSP/PC vectors
    ///   from the bus, and that fetch must see the FRESH setup/domain
    ///   state (flat addressing, domain 0), not whatever was dirty right
    ///   before reset, exactly like real hardware where the bus-level
    ///   reset conditions settle before the CPU's own vector fetch.
    /// - Cycle counter, halt flag, and event queue cleared.
    /// - COPS and VideoTiming re-initialized (re-triggering their
    ///   recurring/power-on events) — unchanged from before this task.
    /// - `FloppyController.reset()` (M2 Task 4): drops any in-flight
    ///   command and clears the shared-RAM window, but an inserted disk
    ///   survives — see that method's doc comment.
    ///
    /// `mmu` (the SORG/SLIM segment registers) is deliberately left
    /// untouched — modeled as RAM-like, surviving reset. This is a
    /// modeling choice, not a hardware citation either way: with SETUP
    /// re-asserted, the CPU always fetches vectors (and everything else in
    /// $0000-$3FFF) through the flat ROM-mirror path regardless of what
    /// those registers still contain, so stale MMU content is unobservable
    /// at reset time — see `Bus.resetSetupAndContextLatches()`'s doc
    /// comment. `ram` is also untouched (real hardware: RAM survives a
    /// warm reset too).
    ///
    /// M1c interplay: `EmulationController.reset()` (LisaShell) now posts
    /// a mailbox command that calls this method on the live emulation-
    /// thread `Machine`, instead of tearing down and recreating it — so
    /// any Bus-attached device state a later task adds (e.g. Task 4's
    /// inserted floppy image) survives a controller reset by construction,
    /// exactly like real hardware's RESTART button doesn't eject media.
    public func reset() {
        bus.resetSetupAndContextLatches()
        bus.via1.reset()
        bus.via2.reset()
        cpu.reset()
        cycles = 0
        halted = false
        queue.removeAll()
        // COPS.reset() / VideoTiming.reset() schedule their own recurring
        // events -- must happen AFTER queue.removeAll() above, or that
        // clear would wipe the very event each just scheduled. See
        // `COPS.reset()`'s doc comment.
        bus.cops.reset()
        bus.videoTiming.reset()
        bus.floppy.reset()
    }

    public func schedule(at cycle: UInt64, _ action: @escaping (Machine) -> Void) {
        let e = Event(cycle: cycle, seq: nextSeq, action: action)
        nextSeq += 1
        let i = queue.firstIndex { ($0.cycle, $0.seq) > (e.cycle, e.seq) } ?? queue.count
        queue.insert(e, at: i)
    }

    /// Computes how many cycles to request from the CPU core for the next
    /// slice of `run(until:)`, clamped to `Int32.max` so the trapping
    /// `Int32(cycles)` conversion inside `M68K.run(cycles:)` never overflows
    /// even when `stop - cycles` is far larger than `Int32` can hold.
    /// Pure and side-effect free so it can be unit-tested directly without
    /// running a multi-billion-cycle CPU loop.
    static func boundedSlice(from cycles: UInt64, to stop: UInt64) -> Int {
        let remaining = stop - cycles
        let bounded = min(remaining, UInt64(Int32.max))
        return max(1, Int(bounded))
    }

    /// Caps every `run(until:)` CPU burst to at most this many cycles, even
    /// when no `Event` is queued sooner. VIA timer ticking and IRQ-level
    /// computation only happen BETWEEN bursts (see `tickVIAsAndUpdateIRQ`),
    /// so without this cap a `run(until:)` call spanning a long, event-free
    /// stretch (the common case: the ROM's boot loop has no `Machine`
    /// events scheduled against it) would execute the entire span in one
    /// `cpu.run(cycles:)` call and never let a VIA-generated interrupt
    /// become visible to Musashi until the call returned -- i.e. never,
    /// for a single `run(until: 20_000_000)` style call. `1024` is smaller
    /// than any VIA1/VIA2 timer period this codebase or the ROM has been
    /// observed to use (docs/hardware-notes.md §3's Pre-/Post-Pepsi T1
    /// reloads are $CA27/$7B63, i.e. ~10-31K cycles), so an interrupt
    /// becomes visible within at most two bursts of latency; this is a
    /// deliberate coarse-grained precision tradeoff, not cycle-exact
    /// delivery -- see `VIA6522`'s doc comment for the matching tradeoff on
    /// the timer side. `step()` does not need this: it always executes
    /// exactly one instruction per call, so its IRQ recognition is already
    /// exact to the instruction boundary.
    private static let irqPollQuantum: UInt64 = 1024

    public func run(until targetCycle: UInt64) {
        while cycles < targetCycle {
            let eventStop = queue.first?.cycle ?? targetCycle
            let stop = min(targetCycle, eventStop, cycles + Machine.irqPollQuantum)
            let slice = Machine.boundedSlice(from: cycles, to: stop)
            let executed = cpu.run(cycles: slice)
            cycles &+= UInt64(executed)
            tickVIAsAndUpdateIRQ(executed)
            while let first = queue.first, first.cycle <= cycles {
                queue.removeFirst()
                first.action(self)
            }
            if cpu.isHalted {
                halted = true
                return
            }
            if executed == 0 {
                // Defensive only: Musashi's m68k_execute returns the full
                // requested slice even when STOPPED or double-fault HALTed
                // (once the post-reset RESET_CYCLES flush has happened), so
                // this should be unreachable in practice. Kept as a guard
                // against a runaway loop if that assumption ever changes.
                halted = true
                return
            }
        }
    }

    /// Advances both VIAs by the cycles just executed and recomputes the
    /// CPU's IRQ level (docs/hardware-notes.md §5 "Interrupt Levels": VIA1
    /// = level 1 -- OR'd with `vsyncPending`, the not-yet-modeled vsync
    /// source sharing that level -- VIA2 = level 2; higher level wins when
    /// both are asserted, matching the 68000's single IPL0-2 input).
    /// Called once per executed slice/step by both `run(until:)` and
    /// `step()`, which is also the granularity at which VIA timers are
    /// ticked -- see `VIA6522`'s doc comment for that precision tradeoff.
    private func tickVIAsAndUpdateIRQ(_ executed: Int) {
        guard executed > 0 else { return }
        bus.via1.tick(cycles: executed)
        bus.via2.tick(cycles: executed)
        let level1 = (bus.via1.irqAsserted || vsyncPending || floppyPending) ? 1 : 0
        let level2 = bus.via2.irqAsserted ? 2 : 0
        cpu.setIRQ(level: max(level1, level2))
    }

    /// Executes a single CPU instruction, advancing `cycles` by the amount
    /// executed and draining any events now due, in (cycle, seq) order.
    /// Returns 0 immediately -- without touching the CPU -- once `halted`.
    @discardableResult
    public func step() -> Int {
        guard !halted else { return 0 }
        let executed = cpu.step()
        cycles &+= UInt64(executed)
        tickVIAsAndUpdateIRQ(executed)
        while let first = queue.first, first.cycle <= cycles {
            queue.removeFirst()
            first.action(self)
        }
        if cpu.isHalted {
            halted = true
        } else if executed == 0 {
            // Defensive only; see the comment in run(until:).
            halted = true
        }
        return executed
    }
}
