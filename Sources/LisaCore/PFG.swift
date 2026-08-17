/// The **PFG (Programmable Frequency Generator)** — the third-party add-on
/// MacWorks Plus II 2.5 requires, modeled as an optional, detachable device.
///
/// ## What the real thing is
///
/// A small board that **plugs into the Lisa's Z8530 SCC socket** (position 9D
/// on the I/O board), with two flying leads to an LS132 at 6A. Its job is
/// real-time adjustment of the floppy controller's bit-cell timing under
/// software control, so a Lisa can read Macintosh diskettes written with
/// **3 bytes of bit-slip `$FF`** where the Lisa's own controller expects 5.
/// MacWorks Plus II *requires* it and will not boot without one.
///
/// ## What we model, and what we deliberately do not
///
/// **Only the handshake.** The real device's entire purpose — retiming the
/// floppy bit clock — is meaningless here: `FloppyController` is a high-level
/// emulation that serves whole 512-byte blocks and never synthesizes a GCR
/// bit stream, so there is no frequency to generate and nothing for a timing
/// command to change. Timing commands are therefore accepted and logged, and
/// have no effect. This is a presence/identity responder, not a frequency
/// generator; do not read more into it than that.
///
/// ## The wire protocol (captured live, M10)
///
/// The PFG sits in the SCC's socket, so it can watch the SCC's own bus. It is
/// commanded by writes to **channel A `WR7`** — the SDLC sync-character
/// register, which the Lisa's own RS-232 driver never programs (see
/// `SCCChannel.modeledWriteRegisters`, where WR6/WR7 are explicitly the
/// "outside the modeled subset" bucket) — and it answers on **channel B
/// `RR0` bit 3, DCD**.
///
/// Captured from MacWorks Plus II 2.5.0's own probe (`lisadbg`, `iot` slice
/// across `$022FCE`), cross-checked against the guest code at `$023D7C`
/// (the writer) and `$023E78` (the sampler), and byte-identical in 2.5.3:
///
/// ```text
/// setup   ch-A: read (reset pointer), WR9 <- $0D, WR7 <- $50, WR9 <- $09
///         ch-B: read RR0, WR15 read, WR15 <- $00
///
/// then 8 iterations, addr stepping $10, $12, $14 ... $1E:
///         ch-A: WR7 <- $00
///         ch-A: WR7 <- addr        (selects a bit pair)
///         ch-B: read RR0           -> bit, from DCD
///         ch-A: WR7 <- $08         (strobe/second phase)
///         ch-B: read RR0           -> bit, from DCD
/// ```
///
/// The guest shifts those 16 bits MSB-first into `D1` (`lsl.l #1,D1`, then
/// `ori.b #1,D1` when DCD reads high) and requires the result's **low nibble
/// to be `$A`** (`andi.w #$f` / `subi.w #$a` at `$023E9C`, and again at the
/// boot gate `$423A96`). With no PFG attached the Lisa's DCD line is idle,
/// every bit shifts in as zero, the nibble reads `0`, and MacWorks Plus II
/// prints `PFG NOT RESPONDING - CHECK INSTALLATION` and later spins forever
/// at `$423AA2`.
///
/// ## Bit numbering
///
/// Iteration `k` (`addr == $10 + 2k`, `k` in `0...7`) supplies bits
/// `15 - 2k` (first sample, after the address write) and `14 - 2k` (second
/// sample, after the `$08` strobe). So the required low nibble `$A` = `1010`
/// is delivered by iterations 6 and 7 — the last four samples.
///
/// ## Honest limits
///
/// Only the **low nibble** is evidenced. The upper 12 bits of the identity
/// word are unconstrained by anything observed so far, so `identity` below is
/// the minimal assumption (`$000A`) rather than a known value, and is a
/// `var` precisely so it can be corrected the moment a guest is seen caring
/// about a higher bit. No public documentation of this device's protocol
/// exists — the MacWorks Plus II manual covers installation only — so the
/// guest's own code is the entire specification. See
/// docs/hardware-notes.md §13 and docs/macworks-plus-notes.md.
public final class PFG {
    /// The 16-bit identity word the probe shifts out of us, MSB first.
    ///
    /// **Only the low nibble is evidenced** (`$A`, required by the guest's
    /// `andi.w #$f` / `subi.w #$a` check). The upper 12 bits have never been
    /// observed being tested, so this is the minimal choice that satisfies
    /// what we can actually cite. If a guest is ever caught branching on a
    /// higher bit, correct it here and record the evidence.
    public var identity: UInt16 = 0x000A

    /// Command byte that opens a probe exchange (`moveq #$50,D0` at
    /// `$023E84`). Its meaning beyond "start" is unknown; we accept it and
    /// reset the exchange state, which is all the observed sequence needs.
    public static let openCommand: UInt8 = 0x50
    /// Second-phase strobe within an iteration (`moveq #8,D0` at `$023EAA`).
    public static let strobeCommand: UInt8 = 0x08
    /// Address selects: `$10, $12, ... $1E`, one per iteration.
    public static let firstAddress: UInt8 = 0x10
    public static let lastAddress: UInt8 = 0x1E

    // MARK: - PRAM EEPROM (function 2 -- hardware-notes.md §13)

    /// The board's **256 bytes of non-volatile PRAM**, where MacWorks Plus II
    /// keeps its startup configuration. A factory-fresh serial EEPROM reads
    /// all-ones, which is also what a newly fitted board would present, so
    /// that is the initial state -- the guest is expected to initialize it
    /// itself rather than us pre-seeding anything.
    ///
    /// In memory only. A real board's EEPROM survives power-off; making that
    /// faithful means a write-through file (the `WidgetImage` shape) and is
    /// deliberately not done here, so no test or scripted boot silently
    /// accumulates state. Public so a file-backed option can be layered on.
    public var eeprom = [UInt8](repeating: 0xFF, count: 256)

    /// Microwire line state, decoded from `WR7`: CS = bit 2, SK = bit 3,
    /// DI = bit 1 (DO is reported back on DCD). See §13 for the capture this
    /// is derived from.
    private static let csBit: UInt8 = 0x04
    private static let skBit: UInt8 = 0x08
    private static let diBit: UInt8 = 0x02
    /// Bit 4 selects the *identity* function on this shared command port;
    /// clear means the access is aimed at the EEPROM.
    private static let identityBit: UInt8 = 0x10

    private var chipSelected = false
    private var clockHigh = false
    /// Frame bits shifted in since the start bit, MSB first: 2 opcode bits
    /// then 8 address bits, then (for WRITE) 8 data bits.
    private var frame: [Int] = []
    private var sawStartBit = false
    /// Bits still to shift out on DO for a READ, MSB first.
    private var readShift: UInt8 = 0
    private var readBitsRemaining = 0
    private var dataOut = false
    /// Set by EWEN, cleared by EWDS -- a real 93Cxx ignores WRITE/ERASE
    /// until write-enabled.
    private var writeEnabled = false

    /// Which bit pair the last address write selected (`k` in `0...7`), or
    /// `nil` before any address has been written.
    private var selectedPair: Int?
    /// `false` = first sample of the pair (after the address write), `true` =
    /// second (after the `$08` strobe).
    private var strobePhase = false

    /// Bounded log of command bytes received on `WR7`, in order — the house
    /// diagnostic idiom (`COPS.powerCommandLog`, `WidgetDrive.log`,
    /// `Bus.unmappedAccesses`): append while under the cap, else drop and
    /// count. Diagnostic only; nothing reads it to change behavior.
    public private(set) var commandLog: [UInt8] = []
    public private(set) var commandLogDropped = 0
    private static let commandLogCap = 512

    public init() {}

    /// Power-on/reset state. The identity word is a property of the board and
    /// survives, exactly as the real hardware's would.
    public func reset() {
        selectedPair = nil
        strobePhase = false
        commandLog.removeAll()
        commandLogDropped = 0
        releaseChipSelect()
        writeEnabled = false
        // The EEPROM is NON-VOLATILE: its contents survive a reset, exactly
        // as the real board's would. Only the serial-interface state is
        // cleared.
    }

    /// A write to channel A `WR7` — the PFG's command port. Wired by
    /// `SCC8530` only while a PFG is attached.
    public func writeCommand(_ value: UInt8) {
        if commandLog.count < Self.commandLogCap {
            commandLog.append(value)
        } else {
            commandLogDropped += 1
        }

        // Bit 4 set selects the identity function; otherwise the byte drives
        // the EEPROM's Microwire lines. `$00` and `$08` belong to the
        // identity sequence (both have CS clear), so they are handled there.
        if value & Self.identityBit != 0 {
            selectedPair = Int((value & 0x0E) >> 1)
            strobePhase = false
            releaseChipSelect()
            return
        }
        if value == Self.openCommand {
            selectedPair = nil
            strobePhase = false
            releaseChipSelect()
            return
        }
        if value & Self.csBit == 0 {
            // Identity strobe ($08) or idle ($00). An unsequenced strobe is a
            // no-op rather than an error -- we have no evidence for what real
            // hardware does with one, and inventing an error would be a fact
            // we cannot cite.
            if value == Self.strobeCommand { strobePhase = true }
            releaseChipSelect()
            return
        }

        clockMicrowire(value)
    }

    /// Deasserting CS ends any in-flight Microwire frame, exactly as on a
    /// real 93Cxx.
    private func releaseChipSelect() {
        chipSelected = false
        clockHigh = false
        frame.removeAll(keepingCapacity: true)
        sawStartBit = false
        readBitsRemaining = 0
        dataOut = false
    }

    /// One `WR7` write with CS asserted: decode the Microwire transaction.
    /// Bits shift on the RISING edge of SK, MSB first (93Cxx convention).
    private func clockMicrowire(_ value: UInt8) {
        if !chipSelected {
            chipSelected = true
            frame.removeAll(keepingCapacity: true)
            sawStartBit = false
            readBitsRemaining = 0
            dataOut = false
        }

        let sk = value & Self.skBit != 0
        defer { clockHigh = sk }
        guard sk, !clockHigh else { return }   // rising edge only

        // A READ in progress shifts its next bit out and consumes the edge;
        // DI is don't-care for the rest of the frame.
        if readBitsRemaining > 0 {
            dataOut = (readShift & 0x80) != 0
            readShift <<= 1
            readBitsRemaining -= 1
            return
        }

        let di = value & Self.diBit != 0 ? 1 : 0
        guard sawStartBit else {
            // Leading zeros are dummy clocks; the frame begins at the first 1.
            if di == 1 { sawStartBit = true }
            return
        }

        frame.append(di)
        // 2 opcode bits + 8 address bits (256 x 8 organization).
        guard frame.count >= 10 else { return }
        let opcode = (frame[0] << 1) | frame[1]
        let address = frame[2..<10].reduce(0) { ($0 << 1) | $1 }

        switch opcode {
        case 0b10:   // READ
            readShift = eeprom[address]
            readBitsRemaining = 8
            dataOut = false   // 93Cxx emits a leading dummy 0 before the data
            frame.removeAll(keepingCapacity: true)
            sawStartBit = false
        case 0b01:   // WRITE -- 8 data bits follow
            guard frame.count >= 18 else { return }
            if writeEnabled {
                eeprom[address] = UInt8(frame[10..<18].reduce(0) { ($0 << 1) | $1 })
            }
            frame.removeAll(keepingCapacity: true)
            sawStartBit = false
        case 0b11:   // ERASE
            if writeEnabled { eeprom[address] = 0xFF }
            frame.removeAll(keepingCapacity: true)
            sawStartBit = false
        default:     // 0b00 -- the top address bits select the sub-command
            switch address >> 6 {
            case 0b00: writeEnabled = false                              // EWDS
            case 0b11: writeEnabled = true                               // EWEN
            case 0b01: if writeEnabled { eeprom = .init(repeating: 0x00, count: 256) }  // WRAL
            default:   if writeEnabled { eeprom = .init(repeating: 0xFF, count: 256) }  // ERAL
            }
            frame.removeAll(keepingCapacity: true)
            sawStartBit = false
        }
    }

    /// The DCD level this board is currently driving, sampled by channel B's
    /// `RR0` bit 3. Wired by `SCC8530` only while a PFG is attached.
    public var dcdAsserted: Bool {
        // An EEPROM frame owns the line while CS is asserted (function 2);
        // otherwise the identity responder does (see `selectedPair`).
        if chipSelected { return dataOut }
        guard let pair = selectedPair else { return false }
        let bit = 15 - (2 * pair) - (strobePhase ? 1 : 0)
        guard bit >= 0 else { return false }
        return (identity >> UInt16(bit)) & 1 == 1
    }
}
