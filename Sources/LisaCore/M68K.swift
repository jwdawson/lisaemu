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
        return Int(m68k_execute(Int32(cycles)))
    }

    /// Executes a single instruction, returning the number of cycles it took.
    @discardableResult
    public func step() -> Int {
        assertOwner()
        return Int(m68k_execute(1))
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
