import Foundation

/// High-level emulation (HLE) of a Widget/ProFile parallel hard disk behind
/// **VIA1** (the "Hard Disk VIA"), implementing the OS ProFile driver's
/// byte-at-a-time handshake (docs/hardware-notes.md §10.2-10.5). Paired with
/// `WidgetImage` (the persistent block store) exactly as `FloppyController`
/// is paired with `DC42Image`.
///
/// ## What is modeled, and the UNOBSERVED caveat (M5 Task 2 / Task 1 Q1)
///
/// The wire protocol is a byte-at-a-time handshake over VIA1 Port A (the
/// 8-bit bidirectional data bus, §10.2) gated by Port B control bits
/// (CMD/DIR) with Port B status bits (BSY/DISCONNECT) read back. This type
/// transcribes that contract: it presents/consumes one byte per CMD strobe,
/// returns the documented response codes ($01 idle->ready, $02 read-accepted,
/// $03 write-accepted, $06 post-write, §10.3), expects the $55 "proceed"
/// reply, transfers 512 data + 20 tag bytes per block (§10.7), and reports a
/// 4-byte `ERRSTAT` whose fatal-error mask is `$C140C000` (§10.5). On command
/// completion it raises VIA1's level-1 interrupt (IFR bit 1, the CB-latched
/// BSY event, §10.2).
///
/// **The live register choreography is UNOBSERVED.** `PROF_INIT`/`PROFASM`
/// have never executed on our machine (§10.9; the boot ROM never touches
/// `$FCD801`), so the exact per-byte DIR-flip / CMD-edge timing the OS driver
/// drives is not yet trace-confirmed. This model encodes the contract's
/// *observable results* -- correct block data, status, and completion IRQ --
/// keyed on the CMD strobe as the transfer clock, in the same spirit as
/// `FloppyController`'s HLE (which does not bit-replay the 6504 microcode).
/// Task 3 exercises PROF_INIT live and will reconcile OBSERVED vs this
/// contract (see docs/rom-trace-notes.md "Checkpoint H"). Until then the
/// preamble/DIR sequencing here is the source-derived best transcription.
///
/// ## Handshake clock
///
/// CMD (Port B bit 4) is active-low and acts as the transfer clock. A
/// falling edge (driver asserts CMD) performs one byte transfer -- present
/// the drive's next outgoing byte (DIR=in, §10.2 bit 3 set) or consume the
/// byte the driver staged on Port A (DIR=out) -- and asserts BSY (Port B bit
/// 1). The rising edge (driver deasserts CMD) drops BSY. The driver reads
/// Port A while BSY is held.
///
/// ## Default = detached (every prior pin stays green)
///
/// With no image attached (the default), `portAInput`/`portBInput` read as an
/// idle pulled-up bus (`0xFF`, DISCONNECT asserted) and CMD strobes are
/// ignored, so wiring this onto VIA1 changes nothing on the no-widget boot
/// path -- checkpoint E/G and the menu FNV anchors are unmoved by
/// construction (the ROM never drives the handshake, §10.9).
public final class WidgetDrive {
    // MARK: - Wire constants (docs/hardware-notes.md §10.2-10.5)

    /// Port B control/status bits (§10.2).
    enum PortB {
        static let disconnect: UInt8 = 0x01   // bit 0: 1 = cable disconnected
        static let bsy: UInt8 = 0x02          // bit 1: controller busy
        static let dir: UInt8 = 0x08          // bit 3: 1 = input-from-drive
        static let cmd: UInt8 = 0x10          // bit 4: active-low command strobe
        static let parity: UInt8 = 0x20       // bit 5: parity control
        static let reset: UInt8 = 0x80        // bit 7: PROFILE-RESET
    }

    /// Handshake reply / response codes (§10.3).
    enum Code {
        static let replyProceed: UInt8 = 0x55       // standard "proceed" reply
        static let respIdleReady: UInt8 = 0x01      // EXPECT_HS idle -> ready
        static let respReadAccepted: UInt8 = 0x02   // read command accepted
        static let respWriteAccepted: UInt8 = 0x03  // write command accepted
        static let respPostWrite: UInt8 = 0x06      // post-write status
    }

    /// Command block bytes (§10.4): 0 = read, 1 = write; device-info read is
    /// command 0 with block `$FFFFFF`.
    enum Command {
        static let read: UInt8 = 0x00
        static let write: UInt8 = 0x01
        static let deviceInfoBlock = 0xFFFFFF
    }

    /// Fatal-error mask AND'd against the 4-byte `ERRSTAT` longword: non-zero
    /// ⇒ hard error (§10.5).
    static let fatalErrorMask: UInt32 = 0xC140C000

    // MARK: - Injected dependencies (mirroring COPS/FloppyController so the
    // protocol tests drive this CPU-free)

    private let scheduleEvent: (UInt64, @escaping () -> Void) -> Void
    /// Raises VIA1 IFR bit 1 (the level-1 BSY/completion interrupt, §10.2).
    private let raiseInterrupt: () -> Void
    /// Clears VIA1 IFR bit 1.
    private let clearInterrupt: () -> Void
    private let log: (String) -> Void

    /// Cycles from a completed command until the completion interrupt raises
    /// -- "plausible", not cycle-exact, matching COPS/Floppy precedent.
    static let completionDelayCycles: UInt64 = 3000

    public init(scheduleEvent: @escaping (UInt64, @escaping () -> Void) -> Void,
                raiseInterrupt: @escaping () -> Void,
                clearInterrupt: @escaping () -> Void,
                log: @escaping (String) -> Void = { _ in }) {
        self.scheduleEvent = scheduleEvent
        self.raiseInterrupt = raiseInterrupt
        self.clearInterrupt = clearInterrupt
        self.log = log
    }

    // MARK: - Media

    private var image: WidgetImage?
    public var isAttached: Bool { image != nil }
    public private(set) var completedCommands = 0
    public private(set) var lastStatus: [UInt8] = [0, 0, 0, 0]

    public func attach(_ image: WidgetImage) {
        self.image = image
        resetTransaction()
    }

    public func detach() {
        image = nil
        resetTransaction()
    }

    /// Warm reset (Machine.reset): drop any in-flight handshake but keep the
    /// attached image -- real hardware's RESTART line does not unmount the
    /// disk (mirrors `FloppyController.reset()`).
    public func reset() {
        resetTransaction()
        clearInterrupt()
        completedCommands = 0
        lastStatus = [0, 0, 0, 0]
    }

    // MARK: - Handshake program

    /// One step of the transaction program the driver walks (§10.3-10.4).
    private enum Step {
        case present(UInt8)     // present one fixed byte (DIR=in read)
        case presentStream      // present bytes from `outStream` (DIR=in reads)
        case expectReply        // consume one $55 "proceed" reply (DIR=out)
        case receiveCommand     // consume the 6-byte command block (DIR=out) -> decode
        case receiveWrite       // consume 512 data + 20 tag (DIR=out) -> commit
        case finish             // raise the completion interrupt
    }

    private var program: [Step] = []
    private var pc = 0
    private var streamIndex = 0
    private var commandAccum: [UInt8] = []
    private var writeAccum: [UInt8] = []
    private var outStream: [UInt8] = []
    private var presented: UInt8 = 0xFF
    private var pendingBlock = 0

    // MARK: - Port B (CMD/DIR) strobe + status

    private var cmdAsserted = false
    private var busy = false

    /// Called by `IODispatcher` on every VIA1 Port B (ORB) write -- the CMD
    /// strobe / DIR select the OS driver bit-bangs (§10.2). Edge-triggered on
    /// CMD (bit 4, active-low).
    public func portBWrite(_ value: UInt8) {
        guard image != nil else { return }   // detached: ignore the bus
        if value & PortB.reset != 0 {         // PROFILE-RESET (§10.2 bit 7)
            // **Task-3 reconciliation point (review M2).** §10.2 bit 7 is
            // PROFILE-RESET, and we treat any ORB write with it set as "abort
            // the in-flight transaction". But PROF_INIT's *init* sequence does
            // `ORI #$A0,ORB` (bits 7+5 together, PROFASM:1532-1533) to set
            // those pins to OUTPUT at startup -- which is configuration, not
            // necessarily a mid-transfer reset. This is harmless at init (no
            // transaction is in flight yet, so resetTransaction() is a no-op),
            // but once PROF_INIT runs live (Task 3) confirm the driver never
            // sets bit 7 during a transfer for a non-reset reason; if it does,
            // refine this edge (e.g. gate on a bit7 rising edge, or require
            // bit5 clear) rather than aborting. UNOBSERVED today (§10.9).
            resetTransaction()
            return
        }
        let nowAsserted = (value & PortB.cmd) == 0     // active-low
        let dirFromDrive = (value & PortB.dir) != 0
        if nowAsserted && !cmdAsserted {
            // Falling edge: perform one byte transfer + assert BSY.
            busy = true
            clockByte(dirFromDrive: dirFromDrive)
        } else if !nowAsserted && cmdAsserted {
            // Rising edge: drop BSY.
            busy = false
        }
        cmdAsserted = nowAsserted
    }

    /// VIA1 Port B input the driver reads for BSY/DISCONNECT (§10.2). Idle
    /// bits are pulled up (1) so the ROM floppy path's own `$FCD901` PB6 idle
    /// read is unaffected; only bit 0 (DISCONNECT) and bit 1 (BSY) are driven.
    public var portBInput: UInt8 {
        // Detached: a fully pulled-up idle bus (0xFF, DISCONNECT asserted) --
        // drive NO bits, so wiring this onto VIA1 moves nothing on the
        // no-widget boot path.
        guard image != nil else { return 0xFF }
        var value: UInt8 = 0xFF
        value &= ~PortB.disconnect               // connected: bit 0 = 0
        if busy { value |= PortB.bsy } else { value &= ~PortB.bsy }
        return value
    }

    // MARK: - Port A (data bus)

    private var lastPortAWrite: UInt8 = 0xFF

    /// Called by `IODispatcher` when the driver writes a byte to VIA1 Port A
    /// (ORA) -- the byte staged for the next DIR=out handshake (§10.2).
    public func portAWrite(_ value: UInt8) {
        lastPortAWrite = value
    }

    /// VIA1 Port A input the driver reads -- the byte the drive is currently
    /// presenting (response code / read data / tag / status), `0xFF` when
    /// detached or nothing is presented.
    public var portAInput: UInt8 {
        image != nil ? presented : 0xFF
    }

    // MARK: - Transaction engine

    private func resetTransaction() {
        program = []
        pc = 0
        streamIndex = 0
        commandAccum = []
        writeAccum = []
        outStream = []
        presented = 0xFF
        cmdAsserted = false
        busy = false
    }

    private func startTransaction() {
        // §10.3: idle -> ready ($01), driver replies $55, then sends the
        // 6-byte command block.
        program = [.present(Code.respIdleReady), .expectReply, .receiveCommand]
        pc = 0
        streamIndex = 0
        commandAccum = []
        writeAccum = []
        outStream = []
    }

    private func advance() {
        pc += 1
        streamIndex = 0
        runFinishIfReached()
    }

    private func runFinishIfReached() {
        while pc < program.count, case .finish = program[pc] {
            completedCommands += 1
            scheduleEvent(Self.completionDelayCycles) { [weak self] in
                self?.raiseInterrupt()
            }
            pc += 1
        }
    }

    /// One byte handshake (a CMD falling edge), gated by DIR.
    private func clockByte(dirFromDrive: Bool) {
        if pc >= program.count {
            // Idle: the driver is starting a new transaction with its first
            // ready read (DIR=in). Ignore a stray DIR=out strobe while idle.
            guard dirFromDrive else { return }
            startTransaction()
        }
        guard pc < program.count else { return }

        switch program[pc] {
        case .present(let byte):
            guard dirFromDrive else { return }
            presented = byte
            advance()
        case .presentStream:
            guard dirFromDrive else { return }
            presented = streamIndex < outStream.count ? outStream[streamIndex] : 0xFF
            streamIndex += 1
            if streamIndex >= outStream.count { advance() }
        case .expectReply:
            guard !dirFromDrive else { return }
            // The driver's $55 "proceed" reply (§10.3); accepted and dropped.
            advance()
        case .receiveCommand:
            guard !dirFromDrive else { return }
            commandAccum.append(lastPortAWrite)
            if commandAccum.count == 6 { decodeCommand() }
        case .receiveWrite:
            guard !dirFromDrive else { return }
            writeAccum.append(lastPortAWrite)
            if writeAccum.count == WidgetImage.bytesPerBlock {
                commitWrite()
                advance()
            }
        case .finish:
            break   // handled by runFinishIfReached
        }
    }

    // MARK: - Command decode / block I/O

    private func decodeCommand() {
        let cmd = commandAccum[0]
        let block = (Int(commandAccum[1]) << 16) | (Int(commandAccum[2]) << 8) | Int(commandAccum[3])
        pendingBlock = block

        switch cmd {
        case Command.read:
            // Read (cmd 0) -- includes the device-info read (block $FFFFFF).
            let (data, tag, status) = readPayload(block: block)
            lastStatus = status
            outStream = data + tag + status
            program.append(contentsOf: [.present(Code.respReadAccepted), .expectReply, .presentStream, .finish])
        case Command.write:
            // §10.3: accept write ($03), driver replies $55, streams the
            // block, drive posts status ($06 + reply + 4 ERRSTAT bytes).
            program.append(contentsOf: [.present(Code.respWriteAccepted), .expectReply, .receiveWrite])
            // Status steps are spliced after the write commits (commitWrite).
        default:
            // **Unsupported single-block command byte — REJECTED, not silently
            // read** (M5 Task 2 review I2). We advertise a 10 MB **T_Seagate**
            // (§10.8 / `deviceInfoData`), so the OS ProFile driver only ever
            // issues read (`$00`) / write (`$01`): `DRIVETYPE < 2` takes the
            // single-block path (PROFASM:250 `CMPI.B #2,DRIVETYPE / BLT`).
            // Anything else — `Formatcmd` (`$02`, §10.4), a multi-block prefix
            // (`$26`, §10.6), a Widget diagnostic — is out of the advertised
            // contract, so it is logged and answered with a fatal `ERRSTAT`
            // (§10.5) rather than mishandled as a read. (Multi-block / Widget
            // diagnostics would require advertising `T_Widget` and building the
            // §10.6 path — a documented Task 3+ enhancement, not this task.)
            log("WidgetDrive: unsupported command byte $\(String(cmd, radix: 16)) for block \(block) -- rejected (single-block T_Seagate advertises only read/write)")
            lastStatus = fatalStatus()
            outStream = fatalStatus()
            program.append(contentsOf: [.presentStream, .finish])
        }
        advance()   // move off .receiveCommand into the spliced steps
    }

    /// Builds the (data, tag, status) a read command returns (§10.4-10.5,
    /// §10.7). Out-of-range blocks stream a zero block with a fatal ERRSTAT.
    private func readPayload(block: Int) -> (data: [UInt8], tag: [UInt8], status: [UInt8]) {
        guard let image else {
            return (zeros(WidgetImage.dataBytesPerBlock), zeros(WidgetImage.tagBytes), fatalStatus())
        }
        if block == Command.deviceInfoBlock {
            return (deviceInfoData(), zeros(WidgetImage.tagBytes), okStatus())
        }
        guard block >= 0, block < image.blockCount else {
            log("WidgetDrive: read of out-of-range block \(block) (blockCount \(image.blockCount))")
            return (zeros(WidgetImage.dataBytesPerBlock), zeros(WidgetImage.tagBytes), fatalStatus())
        }
        return ([UInt8](image.data(block: block)), [UInt8](image.tag(block: block)), okStatus())
    }

    private func commitWrite() {
        let data = Data(writeAccum.prefix(WidgetImage.dataBytesPerBlock))
        let tag = Data(writeAccum.suffix(WidgetImage.tagBytes))
        var status = okStatus()
        if let image, pendingBlock >= 0, pendingBlock < image.blockCount,
           pendingBlock != Command.deviceInfoBlock {
            do {
                try image.write(block: pendingBlock, data: data, tag: tag)
                try image.flush()   // §10.10: flush per completed block write
            } catch {
                log("WidgetDrive: write of block \(pendingBlock) failed: \(error)")
                status = fatalStatus()
            }
        } else {
            log("WidgetDrive: write of out-of-range block \(pendingBlock)")
            status = fatalStatus()
        }
        lastStatus = status
        outStream = status
        // Post-write status sequence (§10.3): $06, reply, 4 ERRSTAT bytes.
        program.append(contentsOf: [.present(Code.respPostWrite), .expectReply, .presentStream, .finish])
    }

    // MARK: - Status / helpers

    private func okStatus() -> [UInt8] { [0, 0, 0, 0] }

    /// A 4-byte ERRSTAT whose longword hits the fatal mask `$C140C000`
    /// (§10.5): byte 0 = `$80` ⇒ `$80 & $C1 != 0`.
    private func fatalStatus() -> [UInt8] { [0x80, 0, 0, 0] }

    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    /// Best-effort device-info payload for a block `$FFFFFF` read (§10.4,
    /// §10.8): PROF_INIT reads it for `discsize` + raw `drivetype`. The exact
    /// byte offsets are UNOBSERVED (the 6504/Widget firmware is not in the OS
    /// source tree, §10.8 "Could Not Find"), so this places `discsize` (=
    /// blockCount, big-endian) at offset 0 as a documented placeholder pending
    /// Task 3's live trace.
    ///
    /// **We advertise a 10 MB T_Seagate, NOT a T_Widget (M5 Task 2 review I2).**
    /// hdinit's type decision (PROFILE:283-301): with our `discsize = 19456`
    /// (in `(9728, 30000]`), a raw `drivetype == 0` resolves to **T_Seagate**
    /// with `num_bloks := discsize - strt_blok` (full 10 MB capacity) — whereas
    /// a raw `drivetype ≠ 0` would resolve to **T_Widget**, which makes the OS
    /// driver issue **multi-block** commands (`$26`, §10.6; PROFASM:250
    /// `CMPI.B #2,DRIVETYPE / BLT` sends multi-block iff `DRIVETYPE ≥ 2`) that
    /// this HLE does not implement. T_Seagate (`DRIVETYPE = 1 < 2`) stays on the
    /// **single-block** read/write path this HLE *does* implement, at full 10 MB
    /// capacity — the coherent choice (a 10 MB single-block *T_Profile* is
    /// incoherent: PROFILE:283-284 forces `num_bloks := 9720`). The whole block
    /// is therefore left zero except `discsize`: a raw `drivetype` byte of 0 at
    /// whatever offset PROF_INIT actually reads keeps us on T_Seagate
    /// regardless of the (unobserved) exact layout. Advertising T_Widget +
    /// building the §10.6 multi-block path is a documented Task 3+ enhancement.
    private func deviceInfoData() -> [UInt8] {
        var data = zeros(WidgetImage.dataBytesPerBlock)
        let discsize = UInt32(image?.blockCount ?? WidgetImage.defaultBlockCount)
        data[0] = UInt8((discsize >> 24) & 0xFF)
        data[1] = UInt8((discsize >> 16) & 0xFF)
        data[2] = UInt8((discsize >> 8) & 0xFF)
        data[3] = UInt8(discsize & 0xFF)
        // (raw drivetype byte left 0 -> OS resolves T_Seagate, single-block)
        return data
    }
}
