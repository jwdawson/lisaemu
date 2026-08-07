public final class Bus {
    /// The SETUP flip-flop. Starts `true` at power-on (translation off,
    /// I/O reachable via flat `$FCxxxx` physical addresses). The only way
    /// it changes on real hardware is the address-decoded `$E010`/`$E012`
    /// latch (`IODispatcher`, ANY access, data ignored -- see
    /// docs/hardware-notes.md "Setup Latch"), so this is `private(set)`;
    /// `_setSetupModeForTesting` is the internal escape hatch both that
    /// latch and test suites use.
    public private(set) var setupMode = true
    /// CPU-conformance testing only -- bypasses ALL Lisa routing; every
    /// address is RAM. `Bus.access` checks this first, before `setupMode`
    /// or anything else: the TomHarte/ProcessorTests vectors (`TomHarteTests`)
    /// construct a flat 16MB `Bus` and expect every one of those 16M
    /// addresses to behave as plain bounds-checked RAM, including the
    /// $FC0000-$FDFFFF I/O window, the $FE0000-$FE3FFF ROM window, and the
    /// 512 SLIM/SORG MMU port bytes -- none of which are part of what the
    /// 68000 conformance suite is testing. Left `false` (default) for every
    /// other caller, which gets the real M1a memory map below. `internal`,
    /// not `public`: this is a test-harness escape hatch, not API.
    internal var flatConformanceMode = false
    public var mmu = MMU()
    private var _domain = 0
    public var domain: Int {
        get { _domain }
        set {
            precondition((0...3).contains(newValue), "Bus.domain out of range")
            _domain = newValue
        }
    }

    /// The domain `MMU.translate` actually resolves a CPU access through --
    /// **domain 0 whenever the CPU is in supervisor mode, otherwise the
    /// latched `domain`.** This is the OQ1′ mechanism (M3 Task 4).
    ///
    /// The Lisa's 2-bit context (`ctbit`) latch names four domains, but they
    /// are NOT four fully-independent maps for supervisor code. Domain 0 is
    /// the OS/system domain (`initmmutil` LDASM:215 "establish domain 0, the
    /// OS domain"); domains 1-3 are per-user-process, LRU-assigned from the
    /// DCT (SYSGLOBAL:60/137 `domainRange`/`domvalue` "user's domain on sys
    /// call entry"; SCHED `Set_Address_Space`/`SelectDomain`). The context
    /// latch selects the domain ONLY for **user-mode** accesses; the OS,
    /// running in **supervisor** mode, always translates through domain 0.
    ///
    /// This is what lets the OS switch the latch to an as-yet-empty user
    /// domain and keep executing supervisor code across the switch --
    /// exactly what `do_an_mmu` (LDASM:364-425) and `SET_DOMAIN`
    /// (starasm1:232-258, "can only be called from the supervisor stack")
    /// require: both flip `ctbit` to the target domain with **SETUP OFF**,
    /// then keep fetching their own seg-84 / caller code and (for
    /// `do_an_mmu`) read the SMT, BEFORE any register is programmed there. A
    /// per-domain-independent supervisor map would fault on that first fetch
    /// -- and no Lisa would boot. Deterministic single-step confirms it:
    /// `do_an_mmu`'s domain-1 pivot fetches `$A84034` in the newly-latched,
    /// empty domain 1 with `setup=OFF`, having written nothing to domain 1
    /// (rom-trace-notes.md "Kernel push (M3 Task 4)").
    ///
    /// SLIM/SORG *register* programming is a separate mechanism and is NOT
    /// affected: `slimSorgPortAccess` keeps writing to the raw latched
    /// `domain`, so the loader still builds domain 1's registers (for later
    /// user-mode execution) while running in domain-0 supervisor code.
    private var translationDomain: Int {
        supervisorProvider() ? 0 : domain
    }
    public private(set) var lastFault: MMUFault?
    public private(set) var unmappedAccesses: [UInt32] = []
    public private(set) var unmappedDropped = 0
    /// Count of real (non-peek, non-double-fault) `busErrorHandler` pulses --
    /// i.e. how many times a translated CPU access actually raised a
    /// Musashi 68000 bus-error exception (M1b Task 6 diagnostic
    /// instrumentation, docs/rom-trace-notes.md "Bus-error frame spike").
    /// Incremented in the same branch that invokes `busErrorHandler`, right
    /// before the call -- NOT incremented for the double-bus-fault
    /// (`forceHaltHandler`) branch, since that path never reaches Musashi's
    /// bus-error exception at all. Used to answer whether the boot ROM ever
    /// takes a *recoverable* bus error before the current frontier.
    public private(set) var busErrorPulseCount = 0
    /// Count of SLIM/SORG MMU-port writes (`Bus.slimSorgPortAccess`,
    /// docs/hardware-notes.md "Register Port Addressing"). Incremented once
    /// per high-byte (i.e. per 16-bit register) write, not once per byte --
    /// see the doc comment on `slimSorgPortAccess`.
    public private(set) var mmuPortWrites = 0
    /// Diagnostic log of completed SLIM/SORG MMU-port *writes* (M1a Task 7,
    /// permitted instrumentation -- this is a debug trace, not device
    /// behavior). One entry is appended per completed 16-bit register write
    /// (logged on the low-byte lane, by which point the full 16-bit value the
    /// ROM's `MOVE.W` deposited is present), capturing which `domain` was
    /// latched, which 128KB `segment` block the port addressed
    /// (`addr >> 17`), whether it was `SORG` (`$8008`) vs SLIM (`$8000`), the
    /// complete 12-bit-masked register `value`, and the `cycles` stamp. Bounded
    /// to 8192 entries; `mmuPortLogDropped` counts overflow. Consumed by
    /// `lisadbg`'s `t`/`g` trace commands and `ROMBootTests`.
    public private(set) var mmuPortLog: [(domain: Int, segment: Int, isSorg: Bool, value: UInt16, cycles: UInt64)] = []
    public private(set) var mmuPortLogDropped = 0
    private static let mmuPortLogLimit = 8192
    /// Cycle stamp for `IOAccess.cycles`; `Machine.init` wires this to
    /// `Machine.cycles`. Defaults to a constant 0 for bare `Bus` use (e.g.
    /// these tests), matching `supervisorProvider`/`busErrorHandler`'s
    /// pattern of Machine-supplied closures.
    public var cycleProvider: () -> UInt64 = { 0 }
    /// Schedules `action` to run after `delay` elapsed cycles from now.
    /// `Machine.init` wires this to `Machine.schedule(at: cycles + delay)`.
    /// Defaults to a no-op for bare `Bus` use, matching
    /// `cycleProvider`/`busErrorHandler`'s pattern -- Task 4's `COPS`
    /// (owned by `IODispatcher`) is the first real caller, for CRDY-ack and
    /// input-byte-delivery timing (docs/hardware-notes.md §4).
    public var scheduleEvent: (UInt64, @escaping () -> Void) -> Void = { _, _ in }
    /// Reaches `Machine.vsyncPending` (the level-1 IRQ source shared with
    /// VIA1, docs/hardware-notes.md §5) from `VideoTiming`, which has no
    /// `Machine`/`Bus` reference of its own -- mirrors `scheduleEvent`'s
    /// injection pattern. `Machine.init` wires this to `{ [weak self] in
    /// self?.vsyncPending = $0 }`; defaults to a no-op for bare `Bus` use.
    public var vsyncInterruptHandler: (Bool) -> Void = { _ in }
    /// Reaches `Machine.floppyPending` -- the level-1 IRQ OR-term for the
    /// floppy completion line (docs/hardware-notes.md §5: Twiggy/Sony
    /// floppy interrupts are Level 1, not VIA2's level 2, even though the
    /// completion line itself lives on VIA2 port B -- see
    /// `FloppyController`'s type doc comment "Level-1 IRQ contribution").
    /// Mirrors `vsyncInterruptHandler`'s injection pattern exactly.
    /// `Machine.init` wires this to `{ [weak self] in self?.floppyPending =
    /// $0 }`; defaults to a no-op for bare `Bus` use.
    public var floppyInterruptHandler: (Bool) -> Void = { _ in }
    /// Reports the CPU's current supervisor/user mode to `mmu.translate`.
    /// Defaults to always-supervisor; `Machine.init` wires this to the live
    /// CPU state.
    public var supervisorProvider: () -> Bool = { true }
    /// Invoked (address, isWrite) whenever `mmu.translate` faults on a real
    /// access while translation is active (`setupMode == false`) and the
    /// access is not a `withPeek` peek. `Machine.init` wires this to
    /// `cpu.pulseBusError(address:isWrite:)`, which raises a genuine
    /// Musashi 68000 bus-error exception -- but only when the CPU is
    /// actually inside `m68k_execute` (see `M68K.insideCpuCallback`); calls
    /// arriving from peeks or direct test/tooling reads are no-ops there.
    /// Either way, `Bus` itself still records `lastFault` and returns
    /// 0xFF/drops the write below, exactly as before this handler existed.
    public var busErrorHandler: ((UInt32, Bool) -> Void)?
    /// Invoked (no arguments) when a translated CPU access faults while a
    /// *previous* fault's exception frame is still being pushed -- i.e. no
    /// successful translated access happened between the two faults. That
    /// shape means the fault occurred while Musashi was writing the
    /// bus-error exception's own stack frame (vector fetch + pushes), which
    /// on real 68000 hardware is a double bus fault: fatal, and the CPU
    /// halts rather than taking another exception. `Machine.init` wires
    /// this to `cpu.forceHalt()`.
    ///
    /// This exists because pulsing a *second* bus error into Musashi here
    /// would be unsafe, not just redundant: `m68ki_exception_bus_error`'s
    /// "already processing a bus/address error" branch
    /// (`RUN_MODE_BERR_AERR_RESET_WSF`) itself performs a live bus read
    /// (`m68k_read_memory_8(0x00ffff01)`) *before* it sets `CPU_STOPPED` --
    /// so if the supervisor stack is unmapped (a routine early-boot state
    /// before the OS has set up its stack segment), that read faults too,
    /// re-entering this same path with no base case. Detecting the
    /// consecutive-fault condition in Swift and halting directly (via the
    /// `lisa_cpu_force_halt` shim, not another pulse) avoids ever taking
    /// that recursive branch.
    public var forceHaltHandler: (() -> Void)?
    /// Set for the duration of `withPeek`'s body. `internal` get (not
    /// `private`) so `IODispatcher.swift` -- a different file in this
    /// module -- can consult it too: peek reads must not toggle latches,
    /// mutate MMU ports, or log to `ioTrace`/`unmappedAccesses`, exactly
    /// like they must not mutate `lastFault`/`faultPendingResolution`
    /// below. The setter stays `private` to this file, same as before.
    private(set) var peeking = false
    /// True from the moment a translated CPU access faults and pulses a
    /// bus error, until either a translated access succeeds (exception
    /// stacking completed -- the CPU is now cleanly executing the handler)
    /// or another fault arrives first (exception stacking itself faulted --
    /// a double bus fault). See `forceHaltHandler`.
    private var faultPendingResolution = false
    var ram: [UInt8]
    /// The 16KB boot ROM, `$FE0000-$FE3FFF` (docs/hardware-notes.md "ROM
    /// Range"). `loadROM` pads/truncates to exactly this size.
    private var rom = [UInt8](repeating: 0, count: 0x4000)
    /// Gates the `$0000-$3FFF` read mirror (see `access`): before any ROM
    /// is loaded there is nothing to mirror, so low addresses behave as
    /// plain flat RAM. This is a modeled convenience, not a cited hardware
    /// fact -- real silicon always has a ROM chip present -- but it lets
    /// every pre-Task-5 test (M68KTests/MachineTests/MonitorTests/etc.,
    /// which poke boot vectors straight into low RAM the way tests have
    /// since M0, and never call `loadROM`) keep working unchanged instead
    /// of every one of them needing a synthetic ROM image. Once `loadROM`
    /// is called (Task 6 onward, with the real Lisa ROM), the mirror is
    /// live for the rest of that Bus's lifetime.
    private var romLoaded = false
    private var io: IODispatcher!

    public init(ramSize: Int) {
        ram = [UInt8](repeating: 0, count: ramSize)
        io = IODispatcher(bus: self)
    }

    public func withPeek<T>(_ body: () -> T) -> T {
        let oldPeeking = peeking
        peeking = true
        defer { peeking = oldPeeking }
        return body()
    }

    /// Loads the 16KB boot ROM (`$FE0000-$FE3FFF`, and its `$0000-$3FFF`
    /// read mirror while `setupMode == true`). Pads with zero bytes if
    /// `bytes` is shorter than 16KB, truncates if longer -- Task 6 is
    /// expected to supply exactly 16KB from the real Lisa ROM image, but
    /// tests here use short hand-built byte arrays for convenience.
    public func loadROM(_ bytes: [UInt8]) {
        var newRom = [UInt8](repeating: 0, count: 0x4000)
        for i in 0..<min(bytes.count, 0x4000) {
            newRom[i] = bytes[i]
        }
        rom = newRom
        romLoaded = true
    }

    /// Sole path (besides the hardware latch itself) that mutates
    /// `setupMode`. `internal`, not `private`, for two reasons: (1)
    /// `IODispatcher.swift`'s `$E010`/`$E012` handlers -- the real
    /// "hardware path" per docs/hardware-notes.md's "Setup Latch" -- are a
    /// different file in this module and call this exact function; (2) test
    /// suites (`@testable import`) that predate the I/O latch and set up
    /// translation state directly need to flip the mode without walking a
    /// synthetic bus access through `IODispatcher`. Real hardware has no
    /// third way to change this bit.
    func _setSetupModeForTesting(_ value: Bool) {
        setupMode = value
    }

    /// True hardware warm reset of the setup/domain-context latches (M2
    /// Task 2): the reset line re-asserts the SETUP flip-flop -- real
    /// hardware's power-on default is SETUP on (see `setupMode`'s own doc
    /// comment, "Starts `true` at power-on"), and a reset re-establishes
    /// that same flat-addressing state (docs/hardware-notes.md "Setup
    /// Latch") -- and clears both domain-context latch bits, so `domain`
    /// returns to 0 (docs/hardware-notes.md "Domain Context Latches").
    /// Deliberately does NOT touch `mmu` (the SORG/SLIM segment registers
    /// are modeled as RAM-like, surviving reset -- with SETUP re-asserted
    /// the CPU's vector fetch and everything else in $0000-$3FFF goes
    /// through the flat ROM-mirror path regardless of what those registers
    /// still contain, so their survival is unobservable at reset time
    /// either way; see `Machine.reset()`'s doc comment for the same
    /// modeling note at the orchestration layer) or `ram`. `Machine.reset()`
    /// is the sole caller; VIA/COPS/VideoTiming reset are handled
    /// separately there.
    func resetSetupAndContextLatches() {
        setupMode = true
        io.resetContextLatches()
    }

    /// SLIM/SORG MMU port intercept, checked before every other setup-mode
    /// routing decision. Unlike everything else `Bus.access` hands off to
    /// `IODispatcher`, these ports are addressed per 128KB segment block
    /// across the *entire* 24-bit physical space -- `SLIM = $8000 +
    /// mmu_index * $20000`, `SORG` 8 bytes higher, `mmu_index = addr >> 17`
    /// (docs/hardware-notes.md "Register Port Addressing") -- not scoped to
    /// IOSpace, so it cannot live inside IODispatcher's `$FC0000-$FDFFFF`
    /// dispatch. Both registers are 16-bit hardware ports (`AND.W #$0FFF`),
    /// so this models them as two consecutive byte lanes (high byte at the
    /// base offset, low byte one above) read-modify-written against the
    /// already-12-bit-masked `SegmentRegister` storage; `mmuPortWrites`
    /// counts once per high-byte write (i.e. once per 16-bit register
    /// write), not once per byte, matching how real code always programs
    /// these with a single `MOVE.W`. Returns the accessed byte (the read
    /// value, or the written value echoed back) when `a`'s low 17 bits
    /// match a port, `nil` otherwise so the caller falls through to normal
    /// routing.
    private func slimSorgPortAccess(_ a: UInt32, isWrite: Bool, value: UInt8) -> UInt8? {
        let low = a & 0x1_FFFF
        let isSlim: Bool
        switch low {
        case 0x8000, 0x8001: isSlim = true
        case 0x8008, 0x8009: isSlim = false
        default: return nil
        }
        let isHighByte = (low == 0x8000 || low == 0x8008)
        let seg = Int(a >> 17)

        if isWrite {
            if !peeking {
                var reg = isSlim ? mmu.domains[domain][seg].slim : mmu.domains[domain][seg].sorg
                if isHighByte {
                    reg = (reg & 0x00FF) | (UInt16(value) << 8)
                } else {
                    reg = (reg & 0xFF00) | UInt16(value)
                }
                if isSlim { mmu.domains[domain][seg].slim = reg } else { mmu.domains[domain][seg].sorg = reg }
                if isHighByte {
                    mmuPortWrites += 1
                } else {
                    // Low-byte lane: the 16-bit register now holds the full
                    // value the ROM's MOVE.W deposited (high byte written
                    // first). Log the completed write for the Task 7 trace.
                    // Store the 12-bit-masked value actually latched.
                    let full = isSlim ? mmu.domains[domain][seg].slim : mmu.domains[domain][seg].sorg
                    if mmuPortLog.count < Self.mmuPortLogLimit {
                        mmuPortLog.append((domain: domain, segment: seg, isSorg: !isSlim, value: full, cycles: cycleProvider()))
                    } else {
                        mmuPortLogDropped += 1
                    }
                }
            }
            return value
        } else {
            let reg = isSlim ? mmu.domains[domain][seg].slim : mmu.domains[domain][seg].sorg
            return isHighByte ? UInt8(reg >> 8) : UInt8(reg & 0xFF)
        }
    }

    /// Routes one byte-wide bus access to its destination and returns the
    /// resulting byte (meaningful for reads; writes ignore it). This is the
    /// single place that implements the whole M1a memory map:
    ///
    /// 0. `flatConformanceMode`, checked first: bypasses everything below,
    ///    every address is bounds-checked RAM. See that property's doc
    ///    comment.
    ///
    /// While `setupMode == true` (flat physical addressing, no MMU):
    ///   1. SLIM/SORG ports (any segment block, see `slimSorgPortAccess`).
    ///   2. ROM window `$FE0000-$FE3FFF` (reads only -- writes ignored+logged).
    ///   3. Low ROM mirror `$0000-$3FFF`, once a ROM is loaded (`romLoaded`):
    ///      reads only; writes fall through to RAM. Both the write-falls-
    ///      through behavior and the `romLoaded` gate itself are modeled
    ///      assumptions, not cited hardware facts -- see the task-5 report.
    ///   4. `$FC0000-$FDFFFF` -> `IODispatcher`, offset = low 17 bits.
    ///   5. Otherwise: flat RAM.
    ///
    /// Once `setupMode == false` (translation active, Task 3/4 fault
    /// semantics preserved exactly):
    ///   - `.memory(p)`: RAM, UNLESS `p` itself falls in the ROM window. This
    ///     check is dead code today and intentionally so: `MMU.translate`'s
    ///     `.memory` formula is `((sorg << 9) + offsetInSegment) & 0x1F_FFFF`, with
    ///     the 12-bit page-add wrap applied before the offset is added (Task 1), so
    ///     the highest physical address `.memory` can ever produce is 0x1FFFFF
    ///     (~2MB) -- nowhere near `$FE0000` (~16.6MB). It is kept only because the
    ///     design note calls for it ("for simplicity detect ROM by final
    ///     physical address range") and it's a harmless, cheap guard.
    ///   - `.io(offset)`: `IODispatcher` -- the real IOSpace ($FC0000-
    ///     $FDFFFF) MMU access nibble `$8`, AND the ROM-discovered iospace
    ///     nibble `$9` (seg126 SLIM=`$901`, docs/rom-trace-notes.md OQ2),
    ///     which `MMU.translate` also routes to `.io` since it targets the
    ///     same IODispatcher.
    ///   - `.special(offset)`: prom/special space, MMU access nibble `$F`
    ///     (seg127 SLIM=`$F00`). This -- NOT `.io` -- is the real
    ///     translated-mode path to ROM bytes; the M1a ledger's hypothesis
    ///     that prommmu used nibble `$8` (routing through `.io`) was
    ///     refuted by the boot trace (rom-trace-notes.md OQ2). `specialAccess`
    ///     serves `$0000-$3FFF` of the offset (the 16KB ROM) directly from
    ///     `rom`, mirroring the setup-mode ROM window/low-mirror behavior
    ///     above; `$4000-$1FFFF` is unknown (hardware-notes.md §2 places the
    ///     SNUM region somewhere in this range) and is stubbed as a logged
    ///     0xFF read until a later M1b task traces what the ROM expects
    ///     there.
    ///   - `.fault`: unchanged bus-error path.
    private func access(_ address: UInt32, isWrite: Bool, value: UInt8) -> UInt8 {
        let a = address & 0xFF_FFFF

        if flatConformanceMode {
            return ramAccess(address, Int(a), isWrite: isWrite, value: value)
        }

        if setupMode {
            if let byte = slimSorgPortAccess(a, isWrite: isWrite, value: value) {
                return byte
            }
            if a >= 0xFE_0000 && a <= 0xFE_3FFF {
                if isWrite {
                    recordUnmapped(address)
                    return value
                }
                return rom[Int(a - 0xFE_0000)]
            }
            if a <= 0x3FFF && !isWrite && romLoaded {
                return rom[Int(a)]
            }
            if a >= 0xFC_0000 && a <= 0xFD_FFFF {
                let offset = a & 0x1_FFFF
                return ioAccess(offset, isWrite: isWrite, value: value)
            }
            // SETUP does not disturb live translation (docs/hardware-notes.md
            // §1 "Setup Latch"): while SETUP is on, SORG/SLIM *register* writes
            // are redirected (handled above by `slimSorgPortAccess`), but a
            // logical address that a PRESENT memory segment maps still
            // translates. The OS loader's `do_an_mmu` (LDASM:305-446) relies on
            // this -- it is entered at logical `$A84000` (seg-84 -> phys `$800`)
            // and toggles SETUP on *inside its own loop* while continuing to
            // fetch its code and read the SMT from that same seg-84 window
            // (M3 Task 2, rom-trace-notes.md "Checkpoint D"). So before falling
            // back to flat physical, try translation; use it only when it
            // resolves to a present memory segment. Unprogrammed segments
            // decode to `.fault` (default SLIM nibble 0 -> invalidSegment), so
            // every POST setup-mode access -- which runs before any segment is
            // programmed -- still falls through to flat exactly as before; only
            // code running from an already-mapped segment (the loader) changes.
            // Note: this branch honors `.memory` only; `.io`/`.special`/readOnly-write
            // cases fall through to flat RAM (benign for all traced paths; see M3 final review).
            if case .memory(let p) = mmu.translate(
                a, domain: translationDomain, isSupervisor: supervisorProvider(), isWrite: isWrite) {
                return ramAccess(address, Int(p), isWrite: isWrite, value: value)
            }
            return ramAccess(address, Int(a), isWrite: isWrite, value: value)
        }

        switch mmu.translate(a, domain: translationDomain, isSupervisor: supervisorProvider(), isWrite: isWrite) {
        case .memory(let p):
            if !peeking { faultPendingResolution = false }
            if p >= 0xFE_0000 && p <= 0xFE_3FFF {
                if isWrite {
                    recordUnmapped(address)
                    return value
                }
                return rom[Int(p - 0xFE_0000)]
            }
            return ramAccess(address, Int(p), isWrite: isWrite, value: value)
        case .io(let offset):
            // Real IOSpace (nibble $8) and the ROM's own iospace nibble $9
            // (seg126 SLIM=$901, docs/rom-trace-notes.md OQ2) both land
            // here -- `MMU.translate` routes both to `.io` identically.
            // Translated-mode ROM access is NOT this branch; see `.special`
            // below.
            if !peeking { faultPendingResolution = false }
            return ioAccess(offset, isWrite: isWrite, value: value)
        case .special(let offset):
            // prom/special space (nibble $F) -- the real translated-mode
            // path to ROM bytes, refuting the M1a ledger's $8/`.io`
            // hypothesis (rom-trace-notes.md OQ2). See `specialAccess`.
            if !peeking { faultPendingResolution = false }
            return specialAccess(address, offset, isWrite: isWrite, value: value)
        case .fault(let fault):
            if !peeking {
                lastFault = fault
                if faultPendingResolution {
                    // A fault arrived with no successful access since the
                    // previous one pulsed -- exception stacking for that
                    // prior fault never completed. Real double bus fault:
                    // halt, don't pulse again (see forceHaltHandler).
                    forceHaltHandler?()
                } else {
                    faultPendingResolution = true
                    busErrorPulseCount += 1
                    busErrorHandler?(address, isWrite)
                }
            }
            return 0xFF
        }
    }

    /// Dispatches to `IODispatcher`, respecting `peeking`: a peek must
    /// observe current state without toggling any latch, mutating any
    /// register, or logging to `ioTrace` (docs/hardware-notes.md-derived
    /// latches are address-decoded on ANY real access, but a peek is not a
    /// real bus access).
    private func ioAccess(_ offset: UInt32, isWrite: Bool, value: UInt8) -> UInt8 {
        if peeking {
            return io.currentValue(offset)
        }
        if isWrite {
            io.write(offset, value)
            return value
        }
        return io.read(offset)
    }

    /// Routes a `.special` MMU translation (nibble `$F`, prom/special
    /// space -- docs/rom-trace-notes.md OQ2) to its two known sub-ranges
    /// within the 128KB segment:
    ///
    ///   - `$0000-$3FFF`: the 16KB boot ROM, exactly like the setup-mode
    ///     `$FE0000-$FE3FFF` window / `$0000-$3FFF` mirror above. Reads
    ///     return ROM bytes; writes are dropped and logged via the same
    ///     `recordUnmapped` path those use (real hardware: ROM is read-only
    ///     silicon).
    ///   - `$4000-$1FFFF`: UNKNOWN. `hardware-notes.md §2` places the SNUM
    ///     (serial number) region somewhere in segment 127's upper range,
    ///     but no trace has reached it yet -- this task's scope is only
    ///     "run past the setup-drop boundary", not decode every offset a
    ///     later boot stage might touch. Stubbed as a logged 0xFF
    ///     read/no-op write (mirroring `IODispatcher`'s own unknown-I/O
    ///     stub) until a later M1b task traces what the ROM expects here.
    ///
    /// `originalAddress` is the untranslated logical CPU address, threaded
    /// through only so `recordUnmapped` logs what the CPU actually asked
    /// for -- consistent with the `.memory` ROM-window case above.
    private func specialAccess(_ originalAddress: UInt32, _ offset: UInt32, isWrite: Bool, value: UInt8) -> UInt8 {
        if offset <= 0x3FFF {
            if isWrite {
                recordUnmapped(originalAddress)
                return value
            }
            return rom[Int(offset)]
        }
        if !peeking {
            io.logUnknownSpecial(offset: offset, value: value, isWrite: isWrite)
        }
        return isWrite ? value : 0xFF
    }

    private func ramAccess(_ originalAddress: UInt32, _ index: Int, isWrite: Bool, value: UInt8) -> UInt8 {
        guard index >= 0, index < ram.count else {
            recordUnmapped(originalAddress)
            return 0xFF
        }
        if isWrite {
            ram[index] = value
            return value
        }
        return ram[index]
    }

    private func recordUnmapped(_ originalAddress: UInt32) {
        guard !peeking else { return }
        if unmappedAccesses.count < 1024 {
            unmappedAccesses.append(originalAddress & 0xFF_FFFF)
        } else {
            unmappedDropped += 1
        }
    }

    /// Clears the consecutive-fault tracking used by `forceHaltHandler`.
    /// Called by `M68K.run(cycles:)`/`step()` at the start of each CPU
    /// slice, belt-and-suspenders alongside `insideCpuCallback`, so stale
    /// state from a previous slice can never bleed into the next one.
    func resetFaultTracking() {
        faultPendingResolution = false
    }

    public func load(_ bytes: [UInt8], at address: UInt32) {
        for (offset, byte) in bytes.enumerated() {
            write8(address &+ UInt32(offset), byte)
        }
    }

    public func read8(_ address: UInt32) -> UInt8 {
        access(address, isWrite: false, value: 0)
    }

    public func write8(_ address: UInt32, _ value: UInt8) {
        _ = access(address, isWrite: true, value: value)
    }

    // MARK: - IODispatcher-backed diagnostics

    public var ioTrace: [IOAccess] { io.ioTrace }
    public var ioTraceDropped: Int { io.ioTraceDropped }
    public var videoPageLatch: UInt8 { io.videoPageLatch }
    /// VIA1 ($D901, stride 8) / VIA2 ($DD81, stride 2) -- the real 6522
    /// register files `IODispatcher` routes those IOSpace windows to (see
    /// `IODispatcher.viaRegisterIndex`). `Machine` reads these each
    /// slice/step to tick the timers and compute the CPU's IRQ level
    /// (docs/hardware-notes.md §5 "Interrupt Levels": VIA1 = level 1, VIA2
    /// = level 2).
    public var via1: VIA6522 { io.via1 }
    public var via2: VIA6522 { io.via2 }
    /// HLE COPS microcontroller (Task 4), owned by `IODispatcher` and wired
    /// to `via2`'s ports -- see `COPS`'s type doc comment. `Machine.reset()`
    /// calls `cops.reset()` (after clearing its own event queue) to
    /// (re-)deliver the power-on byte stream.
    public var cops: COPS { io.cops }
    /// Vsync timing source (Task 5), owned by `IODispatcher` and wired to
    /// `vsyncInterruptHandler` above -- see `VideoTiming`'s type doc
    /// comment. `Machine.reset()` calls `videoTiming.reset()` (after
    /// clearing its own event queue) to (re-)start the self-rescheduling
    /// vsync event, mirroring `cops.reset()`.
    public var videoTiming: VideoTiming { io.videoTiming }
    /// HLE floppy controller (Task 4), owned by `IODispatcher` and wired to
    /// `via2`'s port B (completion line) and `floppyInterruptHandler`
    /// above -- see `FloppyController`'s type doc comment.
    /// `Machine.reset()` calls `floppy.reset()` (after clearing its own
    /// event queue) to drop any in-flight command, mirroring
    /// `cops.reset()`/`videoTiming.reset()` -- the inserted disk, if any,
    /// survives (see `FloppyController.reset()`'s doc comment).
    public var floppy: FloppyController { io.floppy }
    public var statusByte: UInt8 {
        get { io.statusByte }
        set { io.statusByte = newValue }
    }

    public func read16(_ a: UInt32) -> UInt16 {
        UInt16(read8(a)) << 8 | UInt16(read8(a &+ 1))
    }
    public func read32(_ a: UInt32) -> UInt32 {
        UInt32(read16(a)) << 16 | UInt32(read16(a &+ 2))
    }
    public func write16(_ a: UInt32, _ v: UInt16) {
        write8(a, UInt8(v >> 8)); write8(a &+ 1, UInt8(v & 0xFF))
    }
    public func write32(_ a: UInt32, _ v: UInt32) {
        write16(a, UInt16(v >> 16)); write16(a &+ 2, UInt16(v & 0xFFFF))
    }
}
