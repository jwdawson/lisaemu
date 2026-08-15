public final class Machine {
    public let bus: Bus
    public let cpu: M68K
    public private(set) var cycles: UInt64 = 0
    /// True once the core has taken a fatal double-bus-fault HALT (see
    /// `M68K.isHalted`). A STOP instruction (low-power wait that resumes on
    /// interrupt) is *not* halted and does not set this flag. Cleared by
    /// `reset()`.
    public private(set) var halted = false

    /// Soft-power state (M6 Task 1). `.on` normally; `.off` once the OS's own
    /// shutdown sequence issues a COPS power-off command (`$20`/`$21`/`$23` --
    /// hardware-notes.md §7), which `COPS` routes here via
    /// `Bus.powerOffHandler` (wired in `init` below). A powered-off machine
    /// executes NO further instructions: `run(until:)` and `step()` both
    /// short-circuit, exactly like a real Lisa whose COPS cut the CPU's power.
    ///
    /// Deliberately DISTINCT from `halted` (which is a fatal double-bus-fault
    /// HALT): powering off is the clean, OS-requested stop -- `halted` stays
    /// `false` across it. Cleared back to `.on` by `reset()` (a fresh boot).
    public enum PowerState { case on, off }
    public private(set) var powerState: PowerState = .on
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

    /// The 6522 VIAs are clocked at phi2 = CPU clock / 4 on a Pepsi-board Lisa
    /// (the machine this emulator models -- Rev H boot ROM, boot ROM id >=
    /// $80). Master oscillator 20.371 MHz -> CPU = /4 = 5.093 MHz; VIA phi2 =
    /// /16 = 1.273 MHz = CPU/4. The OS itself pins this ratio: it loads VIA1
    /// T1 with $637B = 25467 (LIBHW-DRIVERS:587-588) SPECIFICALLY so 25467
    /// VIA-clocks == 20 ms, and its Timer1 handler adds 20 to the millisecond
    /// clock `TimerTicks` per T1 IRQ (LIBHW-DRIVERS:974/987). At CPU/4 that is
    /// 25467*4 = ~101,872 CPU cycles = ~20.37 ms per IRQ (correct within the
    /// existing 5.0-vs-5.093 MHz approximation `VideoTiming.cyclesPerVsync`
    /// already carries). The comment at DRIVERS:574-576 confirms the divisor:
    /// pre-Pepsi loads $27CA = 10186 (= CPU/10, the classic 6800 E-clock),
    /// Pepsi needs the "larger number ... since the clock is running faster"
    /// -- 25467/10186 = 2.5 = 10/4, i.e. Pepsi phi2 went from CPU/10 to CPU/4.
    ///
    /// Ticking the VIAs at CPU/1 (the pre-fix model) made T1 fire every
    /// ~5.09 ms instead of 20 ms, so `TimerTicks` advanced ~3.93x too fast and
    /// the keyboard auto-repeat's 400 ms `RepeatInitial` delay
    /// (LIBHW-DRIVERS:543) elapsed after only ~102 ms of real key-hold --
    /// inside a normal human keypress -- emitting a spurious auto-repeat that
    /// duplicated the typed key. See docs/hardware-notes.md "VIA phi2 clock".
    static let viaClockDivisor = 4

    /// Carries the sub-divisor remainder of CPU cycles not yet delivered to
    /// the VIAs, so `viaClockDivisor` loses no cycles across slice boundaries
    /// (a `run(until:)`/`step()` slice is rarely a multiple of 4). Reset with
    /// the rest of `Machine` state in `reset()`.
    private var viaPhi2Remainder = 0

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
        bus.powerOffHandler = { [weak self] in self?.powerState = .off }
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
        viaPhi2Remainder = 0
        halted = false
        powerState = .on   // a warm reset / fresh boot powers the machine back on
        queue.removeAll()
        // COPS.reset() / VideoTiming.reset() schedule their own recurring
        // events -- must happen AFTER queue.removeAll() above, or that
        // clear would wipe the very event each just scheduled. See
        // `COPS.reset()`'s doc comment.
        bus.cops.reset()
        bus.videoTiming.reset()
        bus.floppy.reset()
        bus.widget.reset()
        bus.scc.reset()   // M7 Task 2: SCC register state back to power-on
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
    /// reloads are $CA27/$7B63 = 10186/25467 VIA-clocks; at the CPU/4 phi2
    /// divisor these are ~40-102K CPU cycles -- the `viaClockDivisor` fix
    /// multiplied the effective CPU-cycle periods by 4 vs the old ~10-31K,
    /// so the 1024-cycle invariant now holds with EVEN MORE margin), so an
    /// interrupt becomes visible within at most two bursts of latency; this
    /// is a
    /// deliberate coarse-grained precision tradeoff, not cycle-exact
    /// delivery -- see `VIA6522`'s doc comment for the matching tradeoff on
    /// the timer side. `step()` does not need this: it always executes
    /// exactly one instruction per call, so its IRQ recognition is already
    /// exact to the instruction boundary.
    private static let irqPollQuantum: UInt64 = 1024

    public func run(until targetCycle: UInt64) {
        while cycles < targetCycle && powerState == .on {
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
            // A power-off command decoded during that event drain (COPS's
            // ack fires `onPowerOff` -> `powerState = .off`) stops the run
            // promptly, without executing another burst -- the clean,
            // OS-requested stop (see `powerState`'s doc comment). Distinct
            // from the `halted` return just below (fatal double fault).
            if powerState == .off { return }
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

    /// Why `run(untilPC:maxCycles:)` stopped.
    public enum StopReason: String, Equatable, CustomStringConvertible {
        /// The target PC was observed at an instruction boundary.
        case reachedPC
        /// `maxCycles` were spent without ever seeing the target PC.
        case budgetExhausted
        /// Fatal double fault (`halted`) before the target was reached.
        case halted
        /// A clean OS-requested power-off (`powerState == .off`).
        case poweredOff

        public var description: String { rawValue }
    }

    /// Runs until the PC reaches `targetPC` at an instruction boundary, at
    /// most `maxCycles` cycles pass, or the machine halts / powers off --
    /// the breakpoint primitive `lisadbg`'s `gu` is built on (M8 tooling,
    /// added for the MacWorks Plus P0 probe: the guest's splash loop burns
    /// a `$40000`-iteration delay, so `t` cannot practically be walked to
    /// the interesting call and `g` can only stop on a cycle count).
    ///
    /// **Breakpoint semantics:** stops *before* executing the instruction
    /// at `targetPC`, and always executes at least one instruction first --
    /// so `gu <the PC you are sitting on>` means "run until you come back
    /// here", not "return immediately".
    ///
    /// **Why single-step and not `run(until:)`:** that path hands Musashi
    /// slices of up to `irqPollQuantum` cycles, so a PC only visible
    /// mid-slice is invisible to it. Vendored Musashi's
    /// `M68K_INSTRUCTION_HOOK` is `M68K_OPT_OFF`, and turning it on would
    /// be a `Scripts/vendor-musashi.sh` patch billing every caller
    /// (TomHarte's 807k cases included) for a debugger-only feature. So the
    /// debugger pays instead. This is a **diagnostic** entry point, not an
    /// emulation path -- nothing in `LisaShell`/`LisaApp` calls it.
    ///
    /// **Precision note:** stepping ticks the VIAs once per instruction
    /// rather than once per <=1024-cycle slice, so IRQ recognition here is
    /// *finer* than `run(until:)`'s (see `irqPollQuantum`). Identical
    /// semantics, marginally different timing -- worth remembering if a
    /// timing-sensitive repro is being chased through `gu` rather than `g`.
    @discardableResult
    public func run(untilPC targetPC: UInt32, maxCycles: UInt64) -> StopReason {
        let deadline = cycles &+ maxCycles
        var executedAny = false
        while cycles < deadline {
            if halted { return .halted }
            if powerState != .on { return .poweredOff }
            if executedAny && cpu[.pc] == targetPC { return .reachedPC }
            step()
            executedAny = true
        }
        // The budget can run out on the very step that lands on the target;
        // report that as a hit rather than a miss.
        if halted { return .halted }
        if powerState != .on { return .poweredOff }
        if executedAny && cpu[.pc] == targetPC { return .reachedPC }
        return .budgetExhausted
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
        // Divide CPU cycles down to VIA phi2 = CPU/4 (see `viaClockDivisor`),
        // carrying the remainder so no cycles are lost across slices.
        viaPhi2Remainder += executed
        let viaCycles = viaPhi2Remainder / Machine.viaClockDivisor
        viaPhi2Remainder %= Machine.viaClockDivisor
        if viaCycles > 0 {
            bus.via1.tick(cycles: viaCycles)
            bus.via2.tick(cycles: viaCycles)
        }
        let level1 = (bus.via1.irqAsserted || vsyncPending || floppyPending) ? 1 : 0
        let level2 = bus.via2.irqAsserted ? 2 : 0
        // M7 Task 4: the SCC serial controller is CPU Level 6 (docs/hardware-
        // notes.md §5, §11.4). Its only asserted source in the printer model
        // is the channel-B Tx-empty interrupt that drives the OS's XMIT ISR --
        // without it the printer driver sends one byte and waits forever.
        let level6 = bus.scc.irqAsserted ? 6 : 0
        cpu.setIRQ(level: max(level1, level2, level6))
    }

    /// Executes a single CPU instruction, advancing `cycles` by the amount
    /// executed and draining any events now due, in (cycle, seq) order.
    /// Returns 0 immediately -- without touching the CPU -- once `halted`.
    @discardableResult
    public func step() -> Int {
        // Powered off (M6 Task 1) is a no-op just like `halted`, but distinct
        // from it (`halted` stays false) -- see `powerState`'s doc comment.
        guard !halted, powerState == .on else { return 0 }
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

    // MARK: - Scripted-input gestures (M7 Task 4)

    /// The double-click **gesture**, timed so the running OS reliably reads it
    /// as one: two mouse-button down/up pairs with both button-downs inside
    /// ~400k CPU cycles. Two independently scripted clicks put the downs
    /// ~600k+ cycles apart — marginal against the OS's double-click threshold
    /// and observably flaky (M7 Task 4). The **single** implementation of the
    /// timing; steering the cursor to the target first is the caller's job
    /// (`lisadbg`'s `dclick` and `ROMPrinterTests` each steer with their own
    /// harness idiom, then call this).
    ///
    /// `0x06` is the COPS mouse-button keycode (same code `lisadbg`'s single
    /// `click` posts).
    public func postDoubleClick() {
        for _ in 0..<2 {
            bus.cops.postKey(code: 0x06, down: true);  run(until: cycles + 100_000)
            bus.cops.postKey(code: 0x06, down: false); run(until: cycles + 100_000)
        }
    }
}
