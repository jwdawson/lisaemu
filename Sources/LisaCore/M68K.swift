import Foundation
import CMusashi

/// Swift wrapper around the vendored Musashi 68000 core.
///
/// Musashi is a singleton C core (global statics, not reentrant), so only one
/// `M68K` instance may be in use at a time; `init` installs its `bus` into
/// `M68K.currentBus`, which the `@convention(c)` trampolines below read from.
public final class M68K {
    public enum Register {
        case d0, d1, d2, d3, d4, d5, d6, d7
        case a0, a1, a2, a3, a4, a5, a6, a7
        case pc, sr, usp, isp

        var musashi: m68k_register_t {
            switch self {
            case .d0: return M68K_REG_D0
            case .d1: return M68K_REG_D1
            case .d2: return M68K_REG_D2
            case .d3: return M68K_REG_D3
            case .d4: return M68K_REG_D4
            case .d5: return M68K_REG_D5
            case .d6: return M68K_REG_D6
            case .d7: return M68K_REG_D7
            case .a0: return M68K_REG_A0
            case .a1: return M68K_REG_A1
            case .a2: return M68K_REG_A2
            case .a3: return M68K_REG_A3
            case .a4: return M68K_REG_A4
            case .a5: return M68K_REG_A5
            case .a6: return M68K_REG_A6
            case .a7: return M68K_REG_A7
            case .pc: return M68K_REG_PC
            case .sr: return M68K_REG_SR
            case .usp: return M68K_REG_USP
            case .isp: return M68K_REG_ISP
            }
        }
    }

    /// The bus backing the currently-installed `M68K` instance. Musashi's C
    /// core has no per-instance context pointer available to our read/write
    /// trampolines, so this static is how they find their way back to Swift.
    static var currentBus: Bus?

    public let bus: Bus
    private let ownerThread = Thread.current

    /// True only while a call into Musashi's `m68k_execute` is live on the
    /// current C stack -- set immediately before, cleared immediately after,
    /// in both `run(cycles:)` and `step()`. `pulseBusError(address:isWrite:)`
    /// refuses to call into Musashi unless this is true; see that method's
    /// doc comment for why calling outside of `m68k_execute` would be unsafe.
    /// Deliberately *not* set around `m68k_pulse_reset()` in `reset()`
    /// below: its SSP/PC vector reads happen before any `m68k_execute` call
    /// establishes the bus-error `setjmp` context, so a fault during reset
    /// must stay a silent 0xFF read (via `pulseBusError`'s guard), never a
    /// pulse -- there is no live jmp_buf to longjmp into yet.
    private var insideCpuCallback = false

    public init(bus: Bus) {
        self.bus = bus
        M68K.currentBus = bus

        var cbus = lisa_bus_t()
        cbus.read8 = { _, address in
            UInt32(M68K.currentBus!.read8(address))
        }
        cbus.read16 = { _, address in
            UInt32(M68K.currentBus!.read16(address))
        }
        cbus.read32 = { _, address in
            M68K.currentBus!.read32(address)
        }
        cbus.write8 = { _, address, value in
            M68K.currentBus!.write8(address, UInt8(truncatingIfNeeded: value))
        }
        cbus.write16 = { _, address, value in
            M68K.currentBus!.write16(address, UInt16(truncatingIfNeeded: value))
        }
        cbus.write32 = { _, address, value in
            M68K.currentBus!.write32(address, value)
        }
        lisa_bus_install(cbus)

        m68k_init()
        m68k_set_cpu_type(UInt32(M68K_CPU_TYPE_68000))
    }

    /// Pulses reset: loads SSP from vector 0 and PC from vector 4.
    public func reset() {
        m68k_pulse_reset()
        // Musashi bills the RESET exception's cycle cost (40 cycles for the
        // 68000) against the *next* m68k_execute() call rather than paying it
        // here: internally it sets a pending "RESET_CYCLES" counter that the
        // first m68k_execute() call subtracts from its budget before running
        // any instructions, returning early if the budget is smaller than
        // that count. Left alone, a caller's first `run(cycles:)`/`step()`
        // after reset could see its entire cycle budget consumed by this
        // bookkeeping without executing a single instruction. Calling
        // m68k_execute(0) here flushes that pending counter immediately (0
        // cycles requested still triggers the subtraction and early return)
        // so subsequent run(cycles:)/step() calls get their full budget.
        m68k_execute(0)
    }

    private func assertOwner() {
        assert(Thread.current === ownerThread, "M68K used off its creation thread — Musashi is a process-global singleton")
    }

    /// Runs the core for at least `cycles` cycles, returning the number of
    /// cycles actually executed.
    @discardableResult
    public func run(cycles: Int) -> Int {
        assertOwner()
        insideCpuCallback = true
        bus.resetFaultTracking()
        defer { insideCpuCallback = false }
        return Int(m68k_execute(Int32(cycles)))
    }

    /// Executes a single instruction, returning the number of cycles it took.
    @discardableResult
    public func step() -> Int {
        assertOwner()
        insideCpuCallback = true
        bus.resetFaultTracking()
        defer { insideCpuCallback = false }
        return Int(m68k_execute(1))
    }

    /// Raises a genuine Musashi 68000 bus-error exception for an MMU
    /// translation fault. Wired as `Bus.busErrorHandler` by `Machine.init`,
    /// so `Bus.access` calls this on every real (non-peek) translation
    /// failure while `setupMode == false`.
    ///
    /// `address`/`isWrite` are load-bearing: `m68ki_exception_bus_error()`
    /// now pushes the real 68000 group-0 (7-word) frame via
    /// `m68ki_stack_frame_buserr()` (m68kcpu.h:1681, patched in at
    /// m68kcpu.h:1956's `m68ki_exception_bus_error` -- see the LisaEmu-fix
    /// comment there and `Scripts/vendor-musashi.sh`'s third patch block),
    /// which reads `m68ki_aerr_address`/`m68ki_aerr_write_mode`/
    /// `m68ki_aerr_fc`. Those are private-header C globals, not exposed by
    /// the public `m68k.h` Swift sees, so this method stashes them first via
    /// the `lisa_set_bus_error_fault` shim (shim.h/shim.c) -- mirroring how
    /// Musashi's own `m68ki_check_address_error` macro sets the same three
    /// globals before every *address*-error group-0 exception. The function
    /// code passed is a documented approximation (always DATA space, since
    /// `M68K_EMULATE_FC` is off in our vendored config and `Bus` does not
    /// distinguish instruction-fetch vs. data access at the fault site --
    /// see the shim doc comment for why this matches Musashi's own FC-off
    /// fallback); `isSupervisor` still selects the correct supervisor/user
    /// FC bit.
    ///
    /// ## The longjmp mechanism (read m68kcpu.c/.h before touching this)
    ///
    /// `m68k_pulse_bus_error()` -> `m68ki_exception_bus_error()`
    /// (m68kcpu.h:1956) pushes the exception stack frame, redirects PC to
    /// the bus-error vector (vector 2, address `VBR + 8`), and then performs
    /// a synchronous C `longjmp(m68ki_bus_error_jmp_buf, 1)`
    /// (m68kcpu.h:1988) -- it does **not** return to its caller. The
    /// matching `setjmp` lives at the top of `m68k_execute`, inside the
    /// *same* C call (`m68ki_check_bus_error_trap()`, m68kcpu.c:982,
    /// discarding the setjmp return value and falling into the main
    /// instruction loop either way). So the longjmp unwinds every frame
    /// between here and that setjmp point -- this function, the
    /// `busErrorHandler` closure, `Bus.access`/`read8`/`write8`, and the
    /// `@convention(c)` `cbus.read8`/`write8` trampolines installed in
    /// `init` above, down through shim.c's `m68k_read_memory_8` /
    /// `m68k_write_memory_8` and Musashi's inline memory-access macros --
    /// but it lands back inside the *same* `m68k_execute()` C call that our
    /// `run(cycles:)`/`step()` invoked, which then continues its do-while
    /// loop from the new PC and returns to Swift normally once its cycle
    /// budget is exhausted. Callers of `run`/`step` see nothing unusual.
    ///
    /// None of the unwound frames may run cleanup code after being skipped
    /// this way: the trampolines in `init` are single-expression closures
    /// with no `defer` and no local allocations, `Bus.access`/`read8`/
    /// `write8` have no `defer` either, so there is nothing for the longjmp
    /// to skip past unsafely (a leaked ARC retain on `M68K.currentBus!`'s
    /// temporary would be the worst case, harmless for a process-lifetime
    /// singleton). This mirrors the pre-existing address-error longjmp path
    /// (`m68ki_aerr_trap`, guarded by the local BSD sigsetjmp cycle-check
    /// patch documented in m68kcpu.h) that this codebase already relies on
    /// and has validated against the TomHarte suite -- bus error and
    /// address error are two different jmp_buf families reusing the same
    /// "longjmp back into the top of m68k_execute" mechanism.
    ///
    /// Because the target `jmp_buf` is only valid while `m68k_execute` is
    /// live on the stack, calling `m68k_pulse_bus_error()` from outside a
    /// CPU-driven memory access (e.g. `Monitor` peeks, or a test calling
    /// `bus.read8` directly) would longjmp into a stack frame that no
    /// longer exists -- undefined behavior, not a clean no-op. `Bus` only
    /// invokes `busErrorHandler` for non-peek faults, but that alone is not
    /// enough (direct/tooling reads outside CPU execution are also
    /// non-peek), so this method additionally guards on
    /// `insideCpuCallback`, which is only true while `run`/`step` has an
    /// `m68k_execute` call live. Faulting still records `Bus.lastFault` and
    /// returns 0xFF/drops the write regardless -- that bookkeeping lives in
    /// `Bus.access` and happens whether or not this method actually
    /// pulses Musashi.
    public func pulseBusError(address: UInt32, isWrite: Bool) {
        guard insideCpuCallback else { return }
        lisa_set_bus_error_fault(address, isWrite ? 1 : 0, isSupervisor ? 1 : 0)
        m68k_pulse_bus_error()
    }

    /// Forces Musashi's core into the fatal HALT stop level (`STOP_LEVEL_HALT`),
    /// the same terminal state a real double bus fault produces. Wired as
    /// `Bus.forceHaltHandler` by `Machine.init`; see that property's doc
    /// comment for why `Bus` detects a double-fault shape itself and halts
    /// directly rather than pulsing a second bus error into Musashi.
    /// `Machine.run(until:)`/`step()` already surface `isHalted` as
    /// `Machine.halted`, so no further wiring is needed here.
    ///
    /// Guarded on `insideCpuCallback` for the same reason as
    /// `pulseBusError(address:isWrite:)` above: `Bus.forceHaltHandler` is
    /// invoked for any consecutive-fault shape on a non-peek access, which
    /// includes direct/tooling reads made outside `run`/`step` (e.g. two
    /// back-to-back faulting `bus.read8` calls from a test or the
    /// `Monitor`). Calling into Musashi's C core with no CPU access live
    /// would touch process-global state with no corresponding
    /// `m68k_execute` on the stack, which is unsafe for the same reasons
    /// pulsing a bus error outside `m68k_execute` is.
    public func forceHalt() {
        guard insideCpuCallback else { return }
        lisa_cpu_force_halt()
    }

    /// Bit values of Musashi's internal `stopped` field (`m68ki_cpu.stopped`,
    /// read via the `lisa_cpu_stopped()` shim accessor). Mirrored here
    /// because the public m68k.h does not expose `STOP_LEVEL_STOP` /
    /// `STOP_LEVEL_HALT` -- see Sources/CMusashi/m68kcpu.h.
    private enum StopLevel {
        static let stop: UInt32 = 1
        static let halt: UInt32 = 2
    }

    /// True while the core is idling in a STOP-instruction low-power wait.
    /// This resumes automatically on interrupt; it is not a fatal
    /// condition (the Lisa's scheduler idles this way between ticks).
    public var isStopped: Bool {
        (lisa_cpu_stopped() & StopLevel.stop) != 0
    }

    /// True once the core has taken a double bus fault (an address/bus
    /// error while already processing a bus/address-error/reset
    /// exception). This is fatal -- the core will not resume without a
    /// reset, unlike `isStopped`.
    public var isHalted: Bool {
        (lisa_cpu_stopped() & StopLevel.halt) != 0
    }

    /// True while the core is executing in supervisor mode (the SR's S bit
    /// set). Read via the `lisa_cpu_supervisor()` shim accessor, which
    /// returns Musashi's internal `m68ki_cpu.s_flag` -- stored pre-shifted,
    /// so we compare against zero rather than a specific bit pattern.
    public var isSupervisor: Bool {
        lisa_cpu_supervisor() != 0
    }

    /// Sets the CPU's interrupt priority level (the IPL0-IPL2 pins), 0-7 --
    /// a thin wrapper over Musashi's `m68k_set_irq`. `Machine` calls this
    /// after every executed slice/step with `max(VIA1-derived level 1,
    /// VIA2-derived level 2)` (docs/hardware-notes.md §5).
    ///
    /// No `insideCpuCallback` guard is needed here (unlike
    /// `pulseBusError`/`forceHalt`): `m68k_set_irq` just stores the level
    /// into a process-global variable; it does not itself touch CPU state
    /// or perform a longjmp, so it is safe to call at any time, including
    /// between `run`/`step` calls (which is exactly when `Machine` calls
    /// it). IMPORTANT precision note, confirmed by reading `m68k_execute`
    /// (m68kcpu.c:958-974) rather than assumed: `m68ki_check_interrupts()`
    /// runs exactly ONCE, at the very top of `m68k_execute`, before its
    /// per-instruction do-while loop -- NOT at every instruction boundary
    /// within a single call. So a pending interrupt only becomes visible at
    /// the START of the NEXT `run(cycles:)`/`step()` call, never mid-burst.
    /// `M68K.step()` (always exactly one instruction per call) therefore
    /// recognizes an interrupt with exact, one-instruction latency; a
    /// multi-instruction `run(cycles:)` burst does not check again until it
    /// returns and a new call begins -- which is precisely why
    /// `Machine.run(until:)` bounds its bursts to `irqPollQuantum` cycles
    /// (see that property's doc comment) rather than relying on any
    /// mid-burst recognition that does not exist.
    ///
    /// Autovectored delivery ($64/$68/... per level, docs/hardware-notes.md
    /// §5) is Musashi's out-of-the-box behavior here with zero extra
    /// wiring, confirmed by reading the vendored core rather than assumed:
    /// `m68ki_exception_interrupt` (m68kcpu.h:2130) resolves the vector via
    /// `vector = m68ki_int_ack(int_level)`, and with `M68K_EMULATE_INT_ACK`
    /// left `M68K_OPT_OFF` in the vendored `m68kconf.h`, that macro expands
    /// to the literal constant `M68K_INT_ACK_AUTOVECTOR` (m68kcpu.h:483) --
    /// no int-ack callback is even compiled in, let alone consulted, so
    /// every interrupt this core takes is unconditionally autovectored.
    /// (`m68k_set_int_ack_callback`/`default_int_ack_callback` in
    /// m68kcpu.c also default to autovector, but that path is dead code
    /// here since the option is off.) No shim changes were needed.
    public func setIRQ(level: Int) {
        assertOwner()
        m68k_set_irq(UInt32(level))
    }

    public subscript(_ reg: Register) -> UInt32 {
        get {
            assertOwner()
            return m68k_get_reg(nil, reg.musashi)
        }
        set {
            assertOwner()
            m68k_set_reg(reg.musashi, newValue)
        }
    }

    /// Disassembles the instruction at `address`, returning its text and
    /// length in bytes.
    public func disassemble(at address: UInt32) -> (text: String, length: Int) {
        assertOwner()
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer { ptr in
            m68k_disassemble(ptr.baseAddress, address, UInt32(M68K_CPU_TYPE_68000))
        }
        return (String(cString: buffer), Int(length))
    }
}
