/// Register-level emulation of the Lisa's Zilog **Z8530 SCC** (dual-channel
/// serial communications controller) -- the built-in RS-232 A/B ports at
/// `RSBASE = $FCD201`. This replaces the generic `0xFF` unmapped-I/O stub the
/// `$FCD2xx` window answered through M6 with a real register file that honors
/// the OS RS-232 driver's two-step pointer protocol and moves channel-B
/// (printer) bytes to a `PrinterPort` sink. The contract is
/// docs/hardware-notes.md §11 (M7 Task 1); every constant below cites it.
///
/// ## Address decode (§11.1)
///
/// The four registers sit at **odd** byte addresses, stride 2, with higher
/// address bits **undecoded** (so `$FCD241` is a channel-B-control mirror the
/// ROM POST probes -- §11.5). Within the `$FCD2xx` window only bits 1 and 2 of
/// the address matter: **bit 1 selects channel** (0 = B, 1 = A), **bit 2
/// selects data** (0 = control, 1 = data). `IODispatcher` routes the whole
/// `$D200-$D2FF` offset window here so the POST mirror and every alias ACK
/// exactly as the old stub did (no bus error) -- see §11.5 "Why 0xFF passes".
///
/// ## Two-step pointer protocol (§11.2)
///
/// A control-port access is register-pointer-then-value: the first write to a
/// control port is decoded as **WR0** (its low 3 bits are the register select;
/// a "point high" command in bits 3-5 adds 8, so `WR_SCC` reaching registers
/// 9/10/11/12/13/14/15 works by writing the raw register number, e.g. `$09`),
/// the second write deposits the value into the selected register, and the
/// pointer then resets to 0. A control **read** returns `RR[pointer]` and also
/// resets the pointer; a bare read (pointer 0) returns **RR0** -- how `RSOUT`
/// samples status (§11.2, §11.4).
///
/// ## Transmit + "ready" (§11.4)
///
/// The driver's notion of "connected and ready to accept a byte" is **RR0
/// bit 2 (Tx buffer empty) set** and -- under hardware handshake -- **RR0 bit 5
/// (CTS/"DSR'") read 0** (channel-B `xmtzrr0 = $20`, the `(~RR0 & $20)==$20`
/// test at §11.4 step 3). A host sink is infinitely fast, so RR0 bit 2 is
/// pinned 1 and bit 5 pinned 0: transmit always proceeds. A channel-B **data**
/// write forwards the byte to `channelB.printerPort` in order; Tx-buffer-empty
/// stays ready.
///
/// ## Level-6 Tx-empty interrupt (M7 Task 4 — REQUIRED for printing)
///
/// The OS RS-232 driver sends only the **first** byte polled; every byte after
/// that is driven by the **Level-6 Tx-empty interrupt** (`XMIT` ISR, §11.4
/// step 5). So the SCC asserts `/INT` (→ CPU Level 6, via `irqAsserted` OR'd
/// into `Machine.tickVIAsAndUpdateIRQ`) whenever a channel's Tx-empty latch is
/// set AND Tx interrupts are enabled (WR1 bit 1) AND MIE is set (WR9 bit 3).
/// The latch (`txInterruptPending`) sets on *every* data write and is cleared
/// by the ISR's `WR0=$29`; the ISR re-arms it by writing the next byte and
/// `RESTORE`-ing `WR1=$17`. Task 2's earlier "not wired to the CPU IRQ" note
/// was **wrong in reasoning, harmless in effect at boot**: its rationale ("the
/// driver drains its buffer synchronously and never waits on a Level-6
/// interrupt") is refuted by rsASM:96-152 (only byte 1 is polled; bytes 2..N
/// ride the `XMIT` ISR) -- it was boot-harmless only because channel B is never
/// armed at boot. Without this wiring a live print emits exactly one byte and
/// stalls (observed). Ext/status and Rx interrupts are not modeled.
///
/// ## Unknown accesses (bounded, inert)
///
/// Writes to / reads of registers outside the modeled subset are absorbed and
/// counted in a bounded log (cap + drop counter, the `Bus.unmappedAccesses`
/// idiom) -- never fatal.
public final class SCC8530 {
    public let channelA: SCCChannel
    public let channelB: SCCChannel

    /// The optional **PFG** board plugged into this chip's socket.
    /// `nil` (the default) = not installed, which is a stock Lisa: both seams
    /// stay unwired, so WR7 writes keep falling into the unknown-access log
    /// and `RR0` bit 3 stays clear. Attach with `bus.scc.pfg = PFG()`
    /// (`lisadbg --pfg`). See `PFG` for what is and is not modeled.
    public var pfg: PFG? {
        didSet { wirePFG() }
    }

    public init() {
        channelA = SCCChannel(id: .a)
        channelB = SCCChannel(id: .b)
    }

    /// Connects/disconnects the PFG's two seams. Weak `self` capture: the
    /// channels are owned by this chip and hold these closures, so a strong
    /// capture would retain the chip through its own channel.
    private func wirePFG() {
        guard pfg != nil else {
            channelA.onSyncCharacterWrite = nil
            channelB.dcdInput = nil
            return
        }
        channelA.onSyncCharacterWrite = { [weak self] value in
            self?.pfg?.writeCommand(value)
        }
        channelB.dcdInput = { [weak self] in
            self?.pfg?.dcdAsserted ?? false
        }
    }

    /// True while either channel asserts the Z8530 `/INT` line -- the Lisa's
    /// **Level 6** CPU interrupt (docs/hardware-notes.md §5). `Machine` ORs
    /// this into the CPU IRQ level so the OS RS-232 driver's Level-6 `XMIT`
    /// ISR runs and drives the printer byte stream (M7 Task 4, §11.4 step 5).
    public var irqAsserted: Bool { channelA.irqAsserted || channelB.irqAsserted }

    /// Decodes an IODispatcher offset in the `$D200-$D2FF` window to the
    /// channel it addresses (address bit 1) and whether it is the data
    /// register (address bit 2). Higher bits are undecoded (§11.1).
    private func decode(_ address: UInt32) -> (channel: SCCChannel, isData: Bool) {
        let channel = (address & 0x02) != 0 ? channelA : channelB
        let isData = (address & 0x04) != 0
        return (channel, isData)
    }

    /// A real (non-peek) read: control reads return `RR[pointer]` and reset the
    /// pointer; data reads return the (absent) Rx byte.
    func read(address: UInt32) -> UInt8 {
        let (channel, isData) = decode(address)
        return isData ? channel.readData() : channel.readControl()
    }

    /// Side-effect-free twin of `read` for the peek path (`Bus.withPeek` ->
    /// `IODispatcher.currentValue`): never resets the pointer or mutates state.
    func peek(address: UInt32) -> UInt8 {
        let (channel, isData) = decode(address)
        return isData ? channel.peekData() : channel.peekControl()
    }

    func write(address: UInt32, _ value: UInt8) {
        let (channel, isData) = decode(address)
        if isData {
            channel.writeData(value)
        } else {
            channel.writeControl(value)
        }
    }

    /// Warm reset (`Machine.reset()`): both channels return to their power-on
    /// register state. The attached `printerPort`, like `FloppyController`'s
    /// media or `WidgetDrive`'s image, survives -- a reset line does not
    /// unplug the printer.
    public func reset() {
        channelA.reset()
        channelB.reset()
        // A board in the socket is reset alongside the chip, but stays
        // plugged in -- same shape as `COPS.reset()` under `Machine.reset()`.
        pfg?.reset()
    }
}

/// One Z8530 channel (A or B) -- its write-register file, the two-step pointer,
/// the synthesized RR0/RR1 read registers, the transmit path, and the bounded
/// unknown-access log. See `SCC8530`'s doc comment for the full contract.
public final class SCCChannel {
    public enum ID { case a, b }
    public let id: ID

    /// The channel-B transmitter's byte sink (§11.4). `nil` = detached (bytes
    /// absorbed and dropped). Attach via `bus.scc.channelB.printerPort`.
    public var printerPort: PrinterPort?

    /// Fired when this channel's **WR7** (SDLC sync character) is written.
    /// `nil` = nothing is listening, and WR7 keeps its existing behavior of
    /// falling into `logUnknown` untouched.
    ///
    /// This is the PFG's command port: that board plugs into the SCC socket
    /// and snoops WR7, a register the Lisa's own RS-232 driver never programs
    /// (`modeledWriteRegisters` deliberately omits WR6/WR7). Wired to channel
    /// A only, by `SCC8530.pfg` -- see `PFG` for the protocol.
    var onSyncCharacterWrite: ((UInt8) -> Void)?

    /// Supplies **RR0 bit 3 (DCD)** when something is driving that modem-
    /// control input. `nil` = the line is idle and `rr0()` reports bit 3
    /// clear, exactly as it did before any of this existed. Wired to channel
    /// B only, by `SCC8530.pfg`.
    var dcdInput: (() -> Bool)?

    // MARK: - Register file + pointer (§11.2)

    /// Write-register file WR0-WR15. WR0 command bytes are transient (decoded,
    /// not stored); WR1-WR15 persist. Exposed read-only for tests.
    public private(set) var wr = [UInt8](repeating: 0, count: 16)
    /// The register the next control-port access targets. Reset to 0 after each
    /// access (§11.2). A bare read/first-write therefore hits WR0/RR0.
    public private(set) var pointer: Int = 0

    /// The Z8530 **Tx-buffer-empty interrupt latch**. Set on **every** data
    /// write -- the host sink is infinitely fast, so the Tx buffer goes
    /// full→empty instantly (§11.4). Cleared by the driver's `WR0 = $29`
    /// (reset Tx int pending) ack (§11.4 step 5) and by a channel reset.
    ///
    /// M7 Task 4: this is the *latch* (buffer state), deliberately independent
    /// of whether interrupts are enabled -- the CPU /INT assertion is the
    /// separate, gated `irqAsserted` below. Setting it unconditionally is what
    /// lets the XMIT ISR's per-byte re-arm work: the ISR sends the next byte
    /// while WR1 Tx-int is momentarily disabled (latch sets, /INT stays low),
    /// then `RESTORE` re-enables WR1=$17 and the still-set latch re-asserts
    /// /INT for the following byte (see `irqAsserted`).
    public private(set) var txInterruptPending = false

    /// Count of bytes forwarded to `printerPort` (or absorbed while detached) --
    /// a diagnostic, like the counters on the other HLE devices.
    public private(set) var transmittedCount = 0

    // MARK: - Bounded unknown-access log (Bus.unmappedAccesses idiom)

    public struct UnknownAccess: Equatable {
        public let register: Int
        public let value: UInt8
        public let isWrite: Bool
    }
    public private(set) var unknownAccesses: [UnknownAccess] = []
    public private(set) var unknownDropped = 0
    private static let unknownLogCap = 256

    // Registers the driver programs and we accept (store or act on) -- §11.3.
    // WR6/WR7 (sync chars) are never touched by the built-in RS-232 driver, so
    // they are the "outside the modeled subset" bucket the unknown log catches.
    private static let modeledWriteRegisters: Set<Int> = [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15]
    // Read registers the driver samples: RR0 status, RR1 errors (§11.4), and
    // RR2 the modified interrupt vector the Level-6 RSINT handler dispatches on
    // (§11.4 step 5, source-mover.text.unix.txt:828-833).
    private static let modeledReadRegisters: Set<Int> = [0, 1, 2]

    public init(id: ID) {
        self.id = id
    }

    // MARK: - Control port

    /// WR0 command field (bits 3-5) decode (§11.2, §11.4 step 5, §11.5).
    private enum WR0Command: UInt8 {
        case null = 0
        case pointHigh = 1          // adds 8 to the register select
        case resetExtStatus = 2     // reset ext/status latch (dinit step 10 `$10`)
        case sendAbort = 3
        case enableIntNextRx = 4
        case resetTxIntPending = 5  // the `WR0 = $29` Tx-int ack (§11.4 step 5)
        case errorReset = 6
        case resetIUS = 7           // the `WR0 = $38` reset-highest-IUS (§11.4 step 5)
    }

    func writeControl(_ value: UInt8) {
        if pointer == 0 {
            decodeWR0(value)
        } else {
            writeRegister(pointer, value)
            pointer = 0
        }
    }

    /// A first control write (pointer == 0) is WR0: bits 0-2 select the next
    /// register, bits 3-5 are a command (point-high adds 8; other commands act
    /// immediately). The command byte itself is not stored.
    private func decodeWR0(_ value: UInt8) {
        let registerSelect = Int(value & 0x07)
        let command = WR0Command(rawValue: (value >> 3) & 0x07) ?? .null
        if command == .pointHigh {
            pointer = registerSelect + 8
            return
        }
        pointer = registerSelect
        switch command {
        case .resetTxIntPending: txInterruptPending = false
        case .resetExtStatus, .errorReset, .resetIUS, .enableIntNextRx, .sendAbort, .null:
            break   // no modeled internal state to clear beyond the above
        case .pointHigh:
            break   // handled above
        }
    }

    /// Second control write: deposit `value` into WR`register`. WR9 reset codes
    /// (bits 7-6) soft-reset the channel (§11.3 step 2 `$4A`, §11.5 POST `$C0`).
    private func writeRegister(_ register: Int, _ value: UInt8) {
        // WR7 with a listener attached is the PFG's command port (see
        // `onSyncCharacterWrite`). Still not stored -- WR7 is not otherwise
        // modeled -- and with no listener this falls through to the unchanged
        // `logUnknown` path below, so a detached machine behaves exactly as
        // it did before.
        if register == 7, let sink = onSyncCharacterWrite {
            sink(value)
            return
        }
        guard Self.modeledWriteRegisters.contains(register) else {
            logUnknown(register: register, value: value, isWrite: true)
            return
        }
        wr[register] = value
        if register == 9, value & 0xC0 != 0 {
            // Any of channel-B reset ($40), channel-A reset ($80), or force
            // hardware reset ($C0): return this channel to power-on register
            // state. Cross-channel scope is immaterial here -- the OS resets
            // each channel through its own port, and at POST time channel A is
            // not yet programmed (§11.5).
            softReset()
            // M7 Task 4: a channel reset applies the reset AND the mode bits
            // programmed in the SAME WR9 write -- the driver's dinit relies on
            // WR9=$4A (ch-B reset + MIE bit3 + NV bit1) leaving MIE set, since
            // it never re-writes WR9 afterward (source-rs232.text:545). Keep
            // the low 6 bits (MIE/NV/status-hi/DLC); only the reset command
            // bits 7-6 are transient. Without this, `softReset`'s blanket clear
            // would drop MIE and the Level-6 Tx-empty interrupt would never
            // assert, stalling the printer after a single byte.
            //
            // MODEL NOTE: WR9 (hence MIE) is a **chip-wide** register on a real
            // Z8530, but we store it per-channel (like the $C0 cross-channel
            // reset scope, Task 2 concern 3). Harmless here: only channel B ever
            // arms interrupts on the print path, so per-channel MIE is
            // indistinguishable from chip-wide for every state this model reaches.
            wr[9] = value & 0x3F
        }
    }

    /// Whether this channel is currently asserting the Z8530 `/INT` line to the
    /// CPU (the Lisa's **Level 6** -- docs/hardware-notes.md §5, §11.4 step 5).
    ///
    /// Modeled for the **Tx-buffer-empty** interrupt ONLY: it is the sole SCC
    /// interrupt source the transmit-only printer path uses (the rsASM `XMIT`
    /// ISR). Asserted while the Tx-empty latch is set (`txInterruptPending`),
    /// Tx interrupts are enabled (**WR1 bit 1**), and the master interrupt
    /// enable is set (**WR9 bit 3, MIE**). Ext/status (CTS/DCD/Break) and Rx
    /// interrupts are never asserted -- nothing in the printer model changes a
    /// modem line or feeds the receiver, so there is no source to raise them.
    public var irqAsserted: Bool {
        txInterruptPending && (wr[1] & 0x02) != 0 && (wr[9] & 0x08) != 0
    }

    func readControl() -> UInt8 {
        let register = pointer
        pointer = 0
        return readRegister(register)
    }

    func peekControl() -> UInt8 {
        readRegister(pointer)   // no pointer reset, no logging side effects
    }

    private func readRegister(_ register: Int) -> UInt8 {
        switch register {
        case 0: return rr0()
        case 1: return rr1()
        case 2: return rr2()
        default:
            logUnknown(register: register, value: 0, isWrite: false)
            return 0
        }
    }

    /// RR0 status (§11.4). Bit 2 (Tx buffer empty) is pinned **1** -- the host
    /// sink is infinitely fast, so the buffer is always empty/ready. Bit 5
    /// (CTS/"DSR'") is pinned **0** so the channel-B hardware-handshake gate
    /// `(~RR0 & $20)==$20` passes (§11.4 step 3) -- i.e. the modem-control input
    /// reads "asserted/ready". Bit 0 (Rx char available) is 0 (no Rx). No other
    /// bit gates the transmit path.
    private func rr0() -> UInt8 {
        // bit2 = Tx buffer empty; bit5 = 0 (CTS asserted); rest 0.
        // Bit 3 is DCD: 0 (idle) unless something is driving that input --
        // the PFG is the only such device, and only while attached, so a
        // machine without one returns the same literal $04 as always.
        var status: UInt8 = 0x04
        if dcdInput?() == true { status |= 0x08 }
        return status
    }

    /// RR1 input-error status (§11.4). No framing/overrun/parity errors ever --
    /// the driver's `$70` mask reads clean.
    private func rr1() -> UInt8 {
        return 0x00
    }

    /// RR2 -- the interrupt-vector register, and the register the OS's Level-6
    /// RSINT handler dispatches on. RSINT selects RR2 on **channel B**, reads
    /// it, masks **`$0E`** (bits 3-1), and decodes: bit 3 = which channel
    /// (0 = B, 1 = A), bits 2-1 = interrupt type (0 = Tx buffer empty, 1 =
    /// ext/status, 2 = Rx available, 3 = special Rx). It calls the matching
    /// driver with that as `INTPAR`; `INTPAR == 0` enters `XMIT`
    /// (source-mover.text.unix.txt:824-848, source-rsASM.TEXT.unix.txt:96-133).
    ///
    /// On channel A, RR2 reads the base vector (`WR2`) **unmodified**; on
    /// channel B it reads `WR2` **modified** by the highest-priority pending
    /// interrupt's status (V3-V1 in bits 3-1, status-**low** since the driver's
    /// dinit leaves `WR9` bit 4 clear). Our only asserted interrupt source is
    /// the **channel-B Tx-buffer-empty** interrupt (status code V3V2V1 = 000 --
    /// the only reachable state, since Level 6 only ever asserts for it), so
    /// channel B's modified vector forces bits 3-1 to `000`; RSINT then decodes
    /// "port B, output interrupt" and enters `XMIT`.
    ///
    /// **Modeled explicitly** rather than served by the unknown-register
    /// fallback (which returned 0 -- coincidentally the same `$0E`-masked value,
    /// but undocumented, log-spamming on every interrupt, and silently fragile
    /// to any fallback change). Ext/status and Rx status codes are not modeled
    /// because those interrupts are never asserted (see `irqAsserted`).
    private func rr2() -> UInt8 {
        guard id == .b else { return wr[2] }
        // Status-low, channel-B Tx-buffer-empty (V3V2V1 = 000): clear bits 3-1
        // of the base vector; the other vector bits pass through.
        return wr[2] & ~UInt8(0x0E)
    }

    // MARK: - Data port (§11.4)

    /// Channel-B data-register write: forward the byte to the printer sink in
    /// order (§11.4 step 4). Tx-buffer-empty stays set (host sink infinitely
    /// fast); if Tx interrupts are enabled (WR1 bit 1) latch Tx-int-pending for
    /// the driver's `WR0 = $29` ack (§11.4 step 5).
    func writeData(_ byte: UInt8) {
        printerPort?.transmit(byte)
        transmittedCount += 1
        // The byte transmits instantly (infinitely-fast host sink), so the Tx
        // buffer goes full→empty and the Tx-empty latch sets UNCONDITIONALLY.
        // Whether that latch actually asserts /INT is gated separately in
        // `irqAsserted` (WR1 bit1 + WR9 MIE) -- see `txInterruptPending`'s doc.
        txInterruptPending = true
    }

    /// Data-register read = the Rx byte. Nothing feeds the receiver in the
    /// transmit-only printer model, so this reads 0.
    func readData() -> UInt8 { 0 }
    func peekData() -> UInt8 { 0 }

    // MARK: - Reset

    /// Power-on / WR9-reset register state: clear the WR file, pointer, and
    /// pending latch. The `printerPort` sink is retained (see `SCC8530.reset`).
    func softReset() {
        for i in wr.indices { wr[i] = 0 }
        pointer = 0
        txInterruptPending = false
    }

    /// Full warm reset (`Machine.reset()` path): register state plus the
    /// diagnostic counters/log. Keeps the attached `printerPort`.
    func reset() {
        softReset()
        transmittedCount = 0
        unknownAccesses.removeAll(keepingCapacity: true)
        unknownDropped = 0
    }

    private func logUnknown(register: Int, value: UInt8, isWrite: Bool) {
        if unknownAccesses.count < Self.unknownLogCap {
            unknownAccesses.append(UnknownAccess(register: register, value: value, isWrite: isWrite))
        } else {
            unknownDropped += 1
        }
    }
}
