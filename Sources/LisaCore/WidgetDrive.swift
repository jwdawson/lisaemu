import Foundation

/// High-level emulation (HLE) of a Widget/ProFile parallel hard disk behind
/// **VIA1** (the "Hard Disk VIA"), implementing the OS ProFile driver's
/// byte-at-a-time handshake as the driver *actually* performs it
/// (SOURCE-PROFILEASM: `PROF_INIT`:1522, `DOSHAKE`, `WAIT_BUSY`/`WAIT_NOTBUSY`,
/// and the `DRIVER` state machine S1/S2/S3/S7; docs/hardware-notes.md §10.2-10.5).
/// Paired with `WidgetImage` (the persistent block store) exactly as
/// `FloppyController` is paired with `DC42Image`.
///
/// ## The wire protocol — RECONCILED against the live driver (M5 Task 3)
///
/// M5 Task 2 transcribed a *contract*; Task 3 drove `PROF_INIT` live for the
/// first time and found the transport model wrong. The corrected model, all
/// source-cited:
///
/// - **BSY is Port B bit 1, a LEVEL** the driver polls (`WAIT_BUSY`/
///   `WAIT_NOTBUSY`, PROFASM:1618-1651 `BTST #1,IRB`). Idle/ready ⇒ BSY = 1
///   (when CMD is deasserted, ORB bit 4 = 1); asserting CMD (bit 4 → 0) makes
///   the controller present a byte and drop BSY → 0. `PROF_INIT` waits BSY = 1
///   first, then per `DOSHAKE` asserts CMD + waits BSY = 0, reads the response,
///   replies, deasserts CMD + waits BSY = 1. The old HLE held bit 1 = 0 forever
///   ⇒ `WAIT_NOTBUSY` timed out (~16 s) ⇒ installer "unable to locate a usable
///   disk". (STRUCK: the old "BSY asserts *while* CMD held" model.)
/// - **Response codes come back on PORTA = VIA register 15** (offset $78, the
///   *no-handshake* ORA), read once per `DOSHAKE` (PROFASM:1663 `MOVE.B
///   PORTA(A3),D1`). The reply ($55 proceed / $AA-or-$69 negative) is written
///   back to PORTA.
/// - **Data / status stream through IRA = VIA register 1** (offset $8, the
///   *handshake* ORA), one byte per read, auto-advancing (PROFASM:538 `MOVE.B
///   (A2),D0` with A2 = `IRA(A4)`, and PROF_INIT:1600-1607). Command bytes go
///   *out* through ORA = register 1 (PROFASM:359 `MOVE.B (A1)+,ORA(A4)`).
/// - **`PROF_INIT`'s device-characteristics block** is NOT a normal 512+20
///   block: after the second handshake the driver reads 4 status bytes, skips
///   14, reads **DRIVETYPE at data byte 14**, skips 3, then reads a **3-byte
///   DISCSIZE at bytes 18-20** (PROFASM:1600-1613). We answer drivetype 0 +
///   discsize = blockCount (a 10 MB **T_Seagate**, single-block path, §10.8).
/// - **The `DRIVER` state machine** (real block I/O, distinct from `PROF_INIT`)
///   polls **IFR bit 1 (CA1)** for the same BSY edge (PROFASM:268 `BTST #1,IFR`)
///   and, for the data phase, *parks* until the level-1 interrupt (S200). So on
///   each CMD edge we also raise IFR bit 1 (`raiseInterrupt`), and we raise it
///   again when a command's data is ready. `PROF_INIT` ignores IFR (it polls
///   the Port B level), so this is harmless there.
///
/// ## Default = detached (every prior pin stays green)
///
/// With no image attached (the default), Port A reads as `0xFF` and Port B
/// reads as an idle pulled-up bus with **BSY = 1, DISCONNECT = 1** — CMD
/// strobes are ignored, so wiring this onto VIA1 changes nothing on the
/// no-widget boot path (the ROM never drives the handshake, §10.9).
public final class WidgetDrive {
    // MARK: - Wire constants (docs/hardware-notes.md §10.2, PROFASM equates)

    enum PortB {
        static let disconnect: UInt8 = 0x01   // bit 0: 1 = cable disconnected (input)
        static let bsy: UInt8 = 0x02          // bit 1: controller busy/ready (input)
        static let dir: UInt8 = 0x08          // bit 3: 1 = input-from-drive (output)
        static let cmd: UInt8 = 0x10          // bit 4: active-low command strobe (output)
    }

    /// Handshake response / reply codes (§10.3, PROFASM `DOSHAKE`/S-states).
    enum Code {
        static let replyProceed: UInt8 = 0x55       // driver "proceed" reply
        static let respIdleReady: UInt8 = 0x01      // first handshake: idle -> ready
        static let respReadAccepted: UInt8 = 0x02   // read command accepted
        static let respWriteAccepted: UInt8 = 0x03  // write command accepted
        static let respPostWrite: UInt8 = 0x06      // post-write status handshake
    }

    enum Command {
        static let read: UInt8 = 0x00
        static let write: UInt8 = 0x01
        static let deviceInfoBlock = 0xFFFFFF
    }

    /// Fatal-error mask AND'd against the 4-byte `ERRSTAT` longword (§10.5).
    static let fatalErrorMask: UInt32 = 0xC140C000

    // VIA1 register indices the driver drives (PROFASM:16-28).
    private static let regIRA = 1     // ORA/IRA with handshake (offset $8) — command out / data in
    private static let regPORTA = 15  // ORA/IRA no handshake (offset $78) — response in / reply out

    // MARK: - Injected dependencies (mirroring COPS/FloppyController)

    private let scheduleEvent: (UInt64, @escaping () -> Void) -> Void
    /// Raises VIA1 IFR bit 1 (the level-1 CA1/BSY interrupt, §10.2).
    private let raiseInterrupt: () -> Void
    private let clearInterrupt: () -> Void
    private let log: (String) -> Void

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

    /// Warm reset (Machine.reset): drop any in-flight handshake, keep the image.
    public func reset() {
        resetTransaction()
        clearInterrupt()
        completedCommands = 0
        lastStatus = [0, 0, 0, 0]
    }

    // MARK: - Protocol state

    /// Where we are in a single command transaction.
    private enum Phase {
        case idle           // no transaction; next CMD-assert opens one
        case firstHS        // presenting the ready code ($01)
        case awaitCommand   // consuming the 6-byte command block via ORA
        case acceptHS       // presenting the accept code ($02 read / $03 write)
        case readData       // streaming data/tag/status out via IRA
        case writeData      // consuming data/tag in via ORA
        case postWriteHS    // presenting the post-write code ($06)
        case postWriteStat  // streaming 4 status bytes out via IRA
    }

    private var phase: Phase = .idle
    private var dirIn = true
    private var cmdAsserted = false
    private var presented: UInt8 = 0xFF // byte currently on Port A (host reads this)

    private var responseCode: UInt8 = Code.respIdleReady
    private var commandAccum: [UInt8] = []
    private var outStream: [UInt8] = []
    private var outIdx = 0
    private var writeAccum: [UInt8] = []
    private var pendingBlock = 0

    private func resetTransaction() {
        phase = .idle
        dirIn = true
        cmdAsserted = false
        presented = 0xFF
        responseCode = Code.respIdleReady
        commandAccum = []
        outStream = []
        outIdx = 0
        writeAccum = []
    }

    // MARK: - Port B (CMD/DIR strobe + BSY/DISCONNECT status)

    /// Called by `IODispatcher` on every VIA1 Port B (ORB) write at the widget
    /// base ($FCD801 / $FCDC01) — the CMD strobe + DIR select (§10.2).
    public func portBWrite(_ value: UInt8) {
        guard image != nil else { return }
        dirIn = (value & PortB.dir) != 0
        let nowAsserted = (value & PortB.cmd) == 0   // active-low
        if nowAsserted && !cmdAsserted {
            cmdAssertEdge()
        } else if !nowAsserted && cmdAsserted {
            cmdDeassertEdge()
        }
        cmdAsserted = nowAsserted
    }

    /// VIA1 Port B input the driver reads for BSY/DISCONNECT (§10.2). Detached
    /// ⇒ fully pulled-up idle bus (0xFF, DISCONNECT + BSY both high); attached ⇒
    /// DISCONNECT clear (connected) and BSY reflecting the handshake level.
    public var portBInput: UInt8 {
        guard image != nil else { return 0xFF }
        var value: UInt8 = 0xFF
        value &= ~PortB.disconnect                 // connected: bit 0 = 0
        // BSY (bit 1) is a LEVEL: CMD asserted ⇒ controller busy/presenting ⇒
        // 0 (`WAIT_BUSY` proceeds); CMD deasserted ⇒ idle/ready ⇒ 1
        // (`WAIT_NOTBUSY` proceeds). PROFASM:1618-1651.
        if cmdAsserted { value &= ~PortB.bsy }
        return value
    }

    /// CMD asserted (bit 4 → 0): the controller presents its next response byte
    /// (during a handshake phase) and drops BSY → 0 so `WAIT_BUSY` proceeds; the
    /// `DRIVER` S-machine also sees the CA1/IFR edge.
    private func cmdAssertEdge() {
        switch phase {
        case .idle:
            phase = .firstHS
            responseCode = Code.respIdleReady
            presented = responseCode
        case .firstHS, .acceptHS, .postWriteHS:
            presented = responseCode
        case .readData, .postWriteStat:
            presented = outIdx < outStream.count ? outStream[outIdx] : 0xFF
        case .awaitCommand, .writeData:
            break
        }
        raiseInterrupt()   // CA1 edge for the DRIVER S-machine (PROFASM:268)
    }

    /// CMD deasserted (bit 4 → 1): BSY rises (level from `portBInput`) so
    /// `WAIT_NOTBUSY` proceeds; the CA1 edge also fires for the S-machine.
    private func cmdDeassertEdge() {
        raiseInterrupt()
    }

    // MARK: - Port A (register 1 = IRA/ORA handshake, register 15 = PORTA no-handshake)

    private var lastPortAWrite: UInt8 = 0xFF

    /// The byte the drive currently presents on Port A (§10.2). `0xFF` detached.
    public var portAInput: UInt8 { image != nil ? presented : 0xFF }

    /// Called by `IODispatcher` for every VIA1 Port A access, with the VIA
    /// register index (1 = IRA/ORA handshake, 15 = PORTA no-handshake).
    public func portAAccess(index: Int, value: UInt8, isWrite: Bool) {
        guard image != nil else { return }
        if isWrite {
            lastPortAWrite = value
            if index == Self.regPORTA {
                handleReply(value)          // $55 proceed / negative reply
            } else if index == Self.regIRA {
                handleOutgoingByte(value)   // command byte or write-data byte
            }
        } else if index == Self.regIRA {
            // Data-stream read: the byte was already presented; advance.
            advanceDataStream()
        }
        // index 15 read: response byte read, no advance.
    }

    /// A reply written to PORTA (register 15): $55 = proceed. Advances the
    /// handshake phase (`DOSHAKE`/RESPOND).
    private func handleReply(_ value: UInt8) {
        guard value == Code.replyProceed else {
            // Negative reply ($AA/$69) or unexpected — abandon the transaction.
            if value != Code.respIdleReady { resetTransaction() }
            return
        }
        switch phase {
        case .firstHS:
            phase = .awaitCommand
            commandAccum = []
        case .acceptHS:
            beginTransferAfterAccept()
        case .postWriteHS:
            phase = .postWriteStat
            outStream = lastStatus
            outIdx = 0
            presented = outStream.first ?? 0xFF
        default:
            break
        }
    }

    /// A byte written to ORA (register 1): a command byte (awaitCommand) or a
    /// write-data byte (writeData).
    private func handleOutgoingByte(_ value: UInt8) {
        switch phase {
        case .awaitCommand:
            commandAccum.append(value)
            if commandAccum.count == 6 { decodeCommand() }
        case .writeData:
            writeAccum.append(value)
            if writeAccum.count == WidgetImage.bytesPerBlock { commitWrite() }
        default:
            break
        }
    }

    private func advanceDataStream() {
        guard phase == .readData || phase == .postWriteStat else { return }
        outIdx += 1
        presented = outIdx < outStream.count ? outStream[outIdx] : 0xFF
        if outIdx >= outStream.count { finishRead() }
    }

    // MARK: - Command decode / block I/O

    private func decodeCommand() {
        let cmd = commandAccum[0]
        let block = (Int(commandAccum[1]) << 16) | (Int(commandAccum[2]) << 8) | Int(commandAccum[3])
        pendingBlock = block
        switch cmd {
        case Command.read:
            responseCode = Code.respReadAccepted
            phase = .acceptHS
        case Command.write:
            responseCode = Code.respWriteAccepted
            phase = .acceptHS
        default:
            // Out of the advertised single-block T_Seagate contract (§10.8):
            // Formatcmd ($02), multi-block ($26), diagnostics — reject with a
            // fatal ERRSTAT rather than mishandle as a read (review I2).
            log("WidgetDrive: unsupported command byte $\(String(cmd, radix: 16)) for block \(block) — rejected")
            responseCode = Code.respReadAccepted
            phase = .acceptHS
            rejectNext = true
        }
    }

    private var rejectNext = false

    /// After the accept handshake ($55 reply), set up the data phase.
    private func beginTransferAfterAccept() {
        if rejectNext {
            rejectNext = false
            lastStatus = fatalStatus()
            outStream = fatalStatus()
            outIdx = 0
            presented = outStream.first ?? 0xFF
            phase = .readData
            return
        }
        let cmd = commandAccum.first ?? 0
        if cmd == Command.write {
            phase = .writeData
            writeAccum = []
        } else {
            // Read (single-block) or device-info read.
            let (stream, status) = readStream(block: pendingBlock)
            lastStatus = status
            outStream = stream
            outIdx = 0
            presented = outStream.first ?? 0xFF
            phase = .readData
            // Data ready — the DRIVER S-machine parks on this interrupt (S200).
            scheduleEvent(Self.completionDelayCycles) { [weak self] in self?.raiseInterrupt() }
        }
    }

    /// The byte stream a read presents on IRA. For the device-info block
    /// ($FFFFFF) this is `PROF_INIT`'s status+characteristics layout
    /// (PROFASM:1596-1613); for a normal block it is 20 tag + 512 data + 4
    /// status (the driver reads the header then the data; status follows).
    private func readStream(block: Int) -> (stream: [UInt8], status: [UInt8]) {
        guard let image else { return (zeros(4) + zeros(WidgetImage.bytesPerBlock), fatalStatus()) }
        if block == Command.deviceInfoBlock {
            return (deviceInfoStream(), okStatus())
        }
        guard block >= 0, block < image.blockCount else {
            log("WidgetDrive: read of out-of-range block \(block) (blockCount \(image.blockCount))")
            let s = fatalStatus()
            return (zeros(WidgetImage.tagBytes) + zeros(WidgetImage.dataBytesPerBlock) + s, s)
        }
        let s = okStatus()
        // Tag first (RDHDR header, 20 bytes), then 512 data, then 4 status.
        return ([UInt8](image.tag(block: block)) + [UInt8](image.data(block: block)) + s, s)
    }

    private func commitWrite() {
        let data = Data(writeAccum.prefix(WidgetImage.dataBytesPerBlock))
        // The 20 tag bytes precede or follow the data in the driver's stream;
        // WidgetImage stores 512 data + 20 tag. Take the last 20 as tag.
        let tag = Data(writeAccum.suffix(WidgetImage.tagBytes))
        var status = okStatus()
        if let image, pendingBlock >= 0, pendingBlock < image.blockCount,
           pendingBlock != Command.deviceInfoBlock {
            do {
                try image.write(block: pendingBlock, data: data, tag: tag)
                try image.flush()
            } catch {
                log("WidgetDrive: write of block \(pendingBlock) failed: \(error)")
                status = fatalStatus()
            }
        } else {
            log("WidgetDrive: write of out-of-range block \(pendingBlock)")
            status = fatalStatus()
        }
        lastStatus = status
        responseCode = Code.respPostWrite
        phase = .postWriteHS
        scheduleEvent(Self.completionDelayCycles) { [weak self] in self?.raiseInterrupt() }
    }

    private func finishRead() {
        completedCommands += 1
        phase = .idle
        scheduleEvent(Self.completionDelayCycles) { [weak self] in self?.raiseInterrupt() }
    }

    // MARK: - Status / device-info helpers

    private func okStatus() -> [UInt8] { [0, 0, 0, 0] }
    private func fatalStatus() -> [UInt8] { [0x80, 0, 0, 0] }
    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    /// `PROF_INIT`'s device-characteristics stream (PROFASM:1596-1613), read via
    /// IRA right after the accept handshake: 4 status bytes, 14 skipped, then
    /// DRIVETYPE at byte 14, 3 skipped, then a 3-byte DISCSIZE at bytes 18-20.
    /// We report **drivetype 0** (⇒ hdinit resolves **T_Seagate**, single-block,
    /// PROFILE:283-301 / §10.8) and **discsize = blockCount**.
    private func deviceInfoStream() -> [UInt8] {
        var s = zeros(25)
        // s[0..3] = 4 OK status bytes (already zero)
        // s[4..17] = 14 skipped bytes (zero)
        s[18] = 0                                  // DRIVETYPE = 0 (Seagate)
        // s[19..21] = 3 skipped bytes (zero)
        let discsize = UInt32(image?.blockCount ?? WidgetImage.defaultBlockCount)
        s[22] = UInt8((discsize >> 16) & 0xFF)     // DISCSIZE MSB
        s[23] = UInt8((discsize >> 8) & 0xFF)      // DISCSIZE mid
        s[24] = UInt8(discsize & 0xFF)             // DISCSIZE LSB
        return s
    }
}
