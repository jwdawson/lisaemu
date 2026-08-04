public final class Bus {
    /// The SETUP flip-flop. Starts `true` at power-on (translation off,
    /// I/O reachable via flat `$FCxxxx` physical addresses). The only way
    /// it changes on real hardware is the address-decoded `$E010`/`$E012`
    /// latch (`IODispatcher`, ANY access, data ignored -- see
    /// docs/hardware-notes.md "Setup Latch"), so this is `private(set)`;
    /// `_setSetupModeForTesting` is the internal escape hatch both that
    /// latch and test suites use.
    public private(set) var setupMode = true
    public var mmu = MMU()
    private var _domain = 0
    public var domain: Int {
        get { _domain }
        set {
            precondition((0...3).contains(newValue), "Bus.domain out of range")
            _domain = newValue
        }
    }
    public private(set) var lastFault: MMUFault?
    public private(set) var unmappedAccesses: [UInt32] = []
    public private(set) var unmappedDropped = 0
    /// Count of SLIM/SORG MMU-port writes (`Bus.slimSorgPortAccess`,
    /// docs/hardware-notes.md "Register Port Addressing"). Incremented once
    /// per high-byte (i.e. per 16-bit register) write, not once per byte --
    /// see the doc comment on `slimSorgPortAccess`.
    public private(set) var mmuPortWrites = 0
    /// Cycle stamp for `IOAccess.cycles`; `Machine.init` wires this to
    /// `Machine.cycles`. Defaults to a constant 0 for bare `Bus` use (e.g.
    /// these tests), matching `supervisorProvider`/`busErrorHandler`'s
    /// pattern of Machine-supplied closures.
    public var cycleProvider: () -> UInt64 = { 0 }
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
                if isHighByte { mmuPortWrites += 1 }
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
    ///   - `.memory(p)`: RAM, UNLESS `p` itself falls in the ROM window
    ///     (design note: "for simplicity detect ROM by final physical
    ///     address range" -- currently unreachable given SORG's 12-bit/2MB
    ///     ceiling, but kept for forward compatibility; see task-5 report).
    ///   - `.io(offset)`: `IODispatcher`.
    ///   - `.fault`: unchanged bus-error path.
    private func access(_ address: UInt32, isWrite: Bool, value: UInt8) -> UInt8 {
        let a = address & 0xFF_FFFF

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
            return ramAccess(address, Int(a), isWrite: isWrite, value: value)
        }

        switch mmu.translate(a, domain: domain, isSupervisor: supervisorProvider(), isWrite: isWrite) {
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
            if !peeking { faultPendingResolution = false }
            return ioAccess(offset, isWrite: isWrite, value: value)
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
