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
/// stays ready. If the driver uses the Tx-empty interrupt path
/// (`WR0=$29 / WR1=0 / WR0=$38`, §11.4 step 5) the reset/ack commands are
/// honored (they clear the internal Tx-int-pending latch) -- but the SCC is
/// **not** wired to the CPU IRQ. That is deliberate and sufficient: the polled
/// fast path never blocks because RR0 bit 2 is always set, so the driver drains
/// its buffer synchronously and never waits on a Level-6 interrupt. Per the
/// brief, IRQ plumbing is touched only if the printing path *requires* it; it
/// does not. (See the report for the full argument.)
///
/// ## Unknown accesses (bounded, inert)
///
/// Writes to / reads of registers outside the modeled subset are absorbed and
/// counted in a bounded log (cap + drop counter, the `Bus.unmappedAccesses`
/// idiom) -- never fatal.
public final class SCC8530 {
    public let channelA: SCCChannel
    public let channelB: SCCChannel

    public init() {
        channelA = SCCChannel(id: .a)
        channelB = SCCChannel(id: .b)
    }

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

    // MARK: - Register file + pointer (§11.2)

    /// Write-register file WR0-WR15. WR0 command bytes are transient (decoded,
    /// not stored); WR1-WR15 persist. Exposed read-only for tests.
    public private(set) var wr = [UInt8](repeating: 0, count: 16)
    /// The register the next control-port access targets. Reset to 0 after each
    /// access (§11.2). A bare read/first-write therefore hits WR0/RR0.
    public private(set) var pointer: Int = 0

    /// Internal Tx-empty interrupt-pending latch. Set when a byte is
    /// transmitted with Tx interrupts enabled (WR1 bit 1); cleared by the
    /// driver's `WR0 = $29` (reset Tx int pending) ack (§11.4 step 5). Modeled
    /// for ack fidelity only -- NOT wired to the CPU IRQ (see type doc).
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
    // Read registers the driver samples (§11.4): RR0 status, RR1 errors.
    private static let modeledReadRegisters: Set<Int> = [0, 1]

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
        }
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
        return 0x04   // bit2 = Tx buffer empty; bit5 = 0 (CTS asserted); rest 0
    }

    /// RR1 input-error status (§11.4). No framing/overrun/parity errors ever --
    /// the driver's `$70` mask reads clean.
    private func rr1() -> UInt8 {
        return 0x00
    }

    // MARK: - Data port (§11.4)

    /// Channel-B data-register write: forward the byte to the printer sink in
    /// order (§11.4 step 4). Tx-buffer-empty stays set (host sink infinitely
    /// fast); if Tx interrupts are enabled (WR1 bit 1) latch Tx-int-pending for
    /// the driver's `WR0 = $29` ack (§11.4 step 5).
    func writeData(_ byte: UInt8) {
        printerPort?.transmit(byte)
        transmittedCount += 1
        if wr[1] & 0x02 != 0 {
            txInterruptPending = true
        }
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
