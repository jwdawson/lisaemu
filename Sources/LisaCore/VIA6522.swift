/// A real MOS 6522 VIA (Versatile Interface Adapter) core: 16 directly-
/// addressed registers, Timer 1 (free-run/one-shot), Timer 2 (one-shot),
/// and the IFR/IER interrupt-flag protocol -- everything the Rev H boot
/// ROM's VIA2 register self-test and both VIAs' driver-init sequences
/// exercise (docs/hardware-notes.md §3, docs/rom-trace-notes.md "Beyond the
/// M1a boundary" wait-target table).
///
/// This is deliberately a STANDALONE, address-agnostic register file: it
/// knows nothing about IOSpace offsets or VIA1-vs-VIA2 base addresses --
/// `IODispatcher` owns two instances and maps stride-8 (VIA1) / stride-2
/// (VIA2) IOSpace offsets onto the 0-15 register indices below (see
/// `IODispatcher.viaRegisterIndex`). Register semantics here match the
/// datasheet exactly regardless of which VIA an instance represents.
///
/// ## Register index map (0-15), per the task-3 brief
///
/// | Index | Name                | Read                          | Write                                             |
/// |-------|---------------------|--------------------------------|----------------------------------------------------|
/// | 0     | ORB/IRB             | DDR-mixed port B               | Output register B                                  |
/// | 1     | ORA/IRA             | DDR-mixed port A                | Output register A                                  |
/// | 2     | DDRB                | direction register B            | direction register B                               |
/// | 3     | DDRA                | direction register A            | direction register A                               |
/// | 4     | T1C-L               | T1 counter low; **clears IFR6** | T1 low-order LATCH only (no counter/IFR effect)    |
/// | 5     | T1C-H               | T1 counter high                 | reload counter from (written<<8 \| T1LL); **arms + clears IFR6** |
/// | 6     | T1L-L               | T1 low-order latch              | T1 low-order latch                                 |
/// | 7     | T1L-H               | T1 high-order latch             | T1 high-order latch; **clears IFR6** (brief: "cleared by T1CL read / T1LH write") |
/// | 8     | T2C-L               | T2 counter low; **clears IFR5** | T2 low-order LATCH only                            |
/// | 9     | T2C-H               | T2 counter high                 | reload counter from (written<<8 \| T2LL); **arms + clears IFR5** |
/// | 10    | SR                  | shift register (plain store)    | shift register (plain store)                       |
/// | 11    | ACR                 | plain store; bit6 = T1 free-run | plain store                                        |
/// | 12    | PCR                 | plain store (handshake unmodeled) | plain store                                      |
/// | 13    | IFR                 | stored flags \| synthesized bit7 (master) | writing a 1 to a bit CLEARS it (bits 0-6 only) |
/// | 14    | IER                 | stored mask \| 0x80 (always set) | bit7 of written value selects set(1)/clear(0) for the bits addressed by bits 0-6 |
/// | 15    | ORA (no handshake)  | same as index 1, no handshake side effects (we do not model CA1/CA2, so this is index 1's storage without any extra behavior) | same as index 1 |
///
/// ## Timer model / precision tradeoff
///
/// Both timers are 16-bit down-counters that decrement every VIA clock
/// (modeled 1:1 with CPU cycles -- the real Lisa's VIA clock is not
/// separately divided down from the CPU clock for this purpose, and no
/// trace evidence has surfaced requiring anything finer). `tick(cycles:)`
/// is a PURE counter-of-elapsed-cycles call: it is fed the number of CPU
/// cycles that elapsed since the previous tick (`Machine` calls it once per
/// executed CPU slice/step, not once per instruction), so an underflow that
/// happens partway through a slice is detected retroactively rather than at
/// the exact instruction boundary it would occur at on real hardware. This
/// is a deliberate simplification: modeling exact underflow-cycle interrupt
/// delivery would require scheduling a `Machine` event for every timer
/// reload, which the ROM's current requirements (a register read/write
/// presence test, and -- for `InterruptTests` -- a coarse "did the handler
/// run" check) do not need. `Machine.run(until:)` bounds each CPU burst to
/// a small quantum specifically so this per-slice tick still delivers
/// interrupts with bounded (not exact) latency -- see that file's doc
/// comment. If a later task's ROM timing loop turns out to need exact
/// underflow-cycle delivery, this is the seam to refine (schedule a
/// `Machine` event at the next underflow cycle instead of/in addition to
/// polling here).
///
/// One-shot vs free-run (ACR bit 6, T1 only -- T2 here is always one-shot,
/// matching the brief's scope): a reload (write to T1C-H/T2C-H) "arms" the
/// timer. On the underflow that follows, the interrupt flag is set; in
/// free-run mode the counter is reloaded from the latches and stays armed
/// forever (repeated interrupts). In one-shot mode the timer disarms itself
/// after firing once -- the counter keeps counting past zero and wrapping
/// (matching real hardware), but no further interrupt flags are set until
/// the next explicit reload re-arms it.
public final class VIA6522 {
    /// Sampled whenever a DDR-mixed port read (register 0/1/15) asks for
    /// the input-side bits (`DDR` bit == 0, i.e. that pin is configured as
    /// an input). Defaults to all-ones (idle/pulled-up bus), matching how
    /// an unconnected/not-yet-modeled peripheral typically reads on this
    /// hardware; callers (e.g. a later COPS/Task-4 HLE endpoint) override
    /// per-VIA/per-port as needed.
    public var portAInput: () -> UInt8 = { 0xFF }
    public var portBInput: () -> UInt8 = { 0xFF }

    // MARK: - Register storage

    private var orb: UInt8 = 0
    private var ora: UInt8 = 0
    private var ddrb: UInt8 = 0
    private var ddra: UInt8 = 0

    private var t1Counter: UInt16 = 0
    private var t1LatchLow: UInt8 = 0
    private var t1LatchHigh: UInt8 = 0
    private var t1Armed = false   // one-shot: true until it has fired once since the last reload

    private var t2Counter: UInt16 = 0
    private var t2LatchLow: UInt8 = 0
    private var t2Armed = false

    private var sr: UInt8 = 0
    private var acr: UInt8 = 0
    private var pcr: UInt8 = 0

    /// Stored interrupt flags, bits 0-6 only -- bit 7 (master/IRQ) is never
    /// stored, always synthesized on read from `ifr & ier & 0x7F`.
    private var ifr: UInt8 = 0
    /// Stored interrupt-enable mask, bits 0-6 only.
    private var ier: UInt8 = 0

    private static let t1FlagBit: UInt8 = 0x40
    private static let t2FlagBit: UInt8 = 0x20
    private static let acrT1FreeRunBit: UInt8 = 0x40

    public init() {}

    /// True whenever any enabled interrupt flag is set (`(ifr & ier & 0x7F)
    /// != 0`) -- the same condition IFR bit 7 synthesizes on read. `Machine`
    /// reads this after every slice/step to compute the CPU's IRQ level.
    public var irqAsserted: Bool {
        (ifr & ier & 0x7F) != 0
    }

    // MARK: - Register access (indices 0-15, see the type doc comment)

    /// A real, side-effecting read -- the path a genuine bus access takes.
    /// Reading T1C-L/T2C-L clears the corresponding IFR flag bit, matching
    /// real 6522 behavior; every other register is read with no side
    /// effect. Traps on an out-of-range index (an IODispatcher bug, not a
    /// reachable hardware condition -- `IODispatcher.viaRegisterIndex` only
    /// ever produces 0...15).
    public func read(_ index: Int) -> UInt8 {
        switch index {
        case 4:
            let value = UInt8(truncatingIfNeeded: t1Counter)
            ifr &= ~Self.t1FlagBit
            return value
        case 8:
            let value = UInt8(truncatingIfNeeded: t2Counter)
            ifr &= ~Self.t2FlagBit
            return value
        default:
            return peek(index)
        }
    }

    /// Side-effect-free read: the value a real `read(_:)` would currently
    /// return, WITHOUT clearing any IFR bit. This is the only path
    /// `IODispatcher.currentValue` (hence `Bus`'s peek discipline) may use --
    /// see the brief's "peek MUST NOT go through the normal read path"
    /// requirement, since register 4/8 reads are genuinely destructive on
    /// real hardware.
    public func peek(_ index: Int) -> UInt8 {
        switch index {
        case 0: return (orb & ddrb) | (portBInput() & ~ddrb)
        case 1, 15: return (ora & ddra) | (portAInput() & ~ddra)   // 15 = ORA-no-handshake, same storage as 1
        case 2: return ddrb
        case 3: return ddra
        case 4: return UInt8(truncatingIfNeeded: t1Counter)
        case 5: return UInt8(truncatingIfNeeded: t1Counter >> 8)
        case 6: return t1LatchLow
        case 7: return t1LatchHigh
        case 8: return UInt8(truncatingIfNeeded: t2Counter)
        case 9: return UInt8(truncatingIfNeeded: t2Counter >> 8)
        case 10: return sr
        case 11: return acr
        case 12: return pcr
        case 13: return ifr | ((ifr & ier & 0x7F) != 0 ? 0x80 : 0)
        case 14: return ier | 0x80
        default: return 0xFF
        }
    }

    public func write(_ index: Int, _ value: UInt8) {
        switch index {
        case 0: orb = value
        case 1: ora = value
        case 2: ddrb = value
        case 3: ddra = value
        case 4: t1LatchLow = value
        case 5:
            t1LatchHigh = value
            t1Counter = (UInt16(value) << 8) | UInt16(t1LatchLow)
            t1Armed = true
            ifr &= ~Self.t1FlagBit
        case 6: t1LatchLow = value
        case 7:
            t1LatchHigh = value
            ifr &= ~Self.t1FlagBit
        case 8: t2LatchLow = value
        case 9:
            t2Counter = (UInt16(value) << 8) | UInt16(t2LatchLow)
            t2Armed = true
            ifr &= ~Self.t2FlagBit
        case 10: sr = value
        case 11: acr = value
        case 12: pcr = value
        case 13: ifr &= ~(value & 0x7F)
        case 14:
            if value & 0x80 != 0 {
                ier |= value & 0x7F
            } else {
                ier &= ~(value & 0x7F)
            }
        case 15: ora = value
        default: break
        }
    }

    // MARK: - Timer advance

    /// Advances both timers by `cycles` elapsed CPU cycles, setting IFR
    /// flags on underflow per the one-shot/free-run rules above. See the
    /// type doc comment for the per-slice (not per-cycle) precision
    /// tradeoff this encodes.
    public func tick(cycles: Int) {
        guard cycles > 0 else { return }
        advance(&t1Counter, by: cycles, armed: &t1Armed,
                freeRun: (acr & Self.acrT1FreeRunBit) != 0,
                reloadValue: { (UInt16(self.t1LatchHigh) << 8) | UInt16(self.t1LatchLow) },
                flagBit: Self.t1FlagBit)
        advance(&t2Counter, by: cycles, armed: &t2Armed,
                freeRun: false,
                reloadValue: { 0xFFFF },   // unreachable while freeRun == false; see `advance`
                flagBit: Self.t2FlagBit)
    }

    /// Shared one-shot/free-run 16-bit down-counter advance for T1/T2.
    /// `armed` starts `false` (see the stored properties above) so a timer
    /// that has never been loaded cannot spuriously fire from its
    /// zero-initialized counter -- only a reload (write to T1C-H/T2C-H)
    /// arms it, matching real hardware where software always loads the
    /// timer before expecting an interrupt from it.
    private func advance(_ counter: inout UInt16, by cycles: Int, armed: inout Bool,
                          freeRun: Bool, reloadValue: () -> UInt16, flagBit: UInt8) {
        var remaining = cycles
        var value = Int(counter)

        // Each pass through the loop consumes exactly `value + 1` cycles to
        // reach the underflow instant (counter goes from 0 to $FFFF,
        // conceptually "landing" the counter at $FFFF with zero cycles yet
        // spent on the next decrement -- the same shape a freshly reloaded
        // counter is in, which is why every branch below ends by assigning
        // a fresh `value` and letting the loop re-test against it).
        while remaining > value {
            remaining -= value + 1
            if freeRun {
                ifr |= flagBit
                value = Int(reloadValue())
            } else if armed {
                // One-shot fires exactly once per reload, then disarms:
                // the counter keeps free-wrapping from $FFFF (matching real
                // hardware) but sets no further flags until re-armed by the
                // next T1C-H/T2C-H write.
                ifr |= flagBit
                armed = false
                value = 0xFFFF
            } else {
                value = 0xFFFF
            }
        }

        value -= remaining
        counter = UInt16(truncatingIfNeeded: value)
    }
}
