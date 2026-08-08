import Foundation
import Testing
@testable import LisaCore

// MARK: - WidgetDrive: the ProFile/Widget parallel-port HLE
//
// Drives the byte-at-a-time handshake exactly as the OS ProFile driver performs
// it (SOURCE-PROFILEASM PROF_INIT/DOSHAKE/WAIT_BUSY/WAIT_NOTBUSY and the DRIVER
// S-machine; docs/hardware-notes.md §10.2-10.5). These tests are the executable
// spec of the transport RECONCILED against the live driver in M5 Task 3:
//
//   - Response codes are read from PORTA (VIA register 15, no-handshake).
//   - The $55 "proceed" reply is written back to PORTA.
//   - Command bytes go OUT through ORA (register 1); data/status come IN through
//     IRA (register 1), auto-advancing one byte per read.
//   - BSY is Port B bit 1, a LEVEL: idle/ready = 1 (CMD deasserted), dropping to
//     0 when CMD is asserted.
//
// Synthetic blank images in temp dirs -- NO env gating.

private func scratchWidget(blockCount: Int = 32) throws -> (WidgetImage, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wdrv-\(UUID().uuidString).widget")
    let image = try WidgetImage(createBlankAt: url, blockCount: blockCount)
    return (image, url)
}

private final class InterruptBox { var raised = false }

/// Drives a `WidgetDrive` the way the OS driver does: CMD/DIR over Port B, the
/// handshake response over PORTA (reg 15), command/data over ORA/IRA (reg 1).
private final class Harness {
    let drive: WidgetDrive
    let raiseBox = InterruptBox()
    var completionRaised: Bool { raiseBox.raised }

    init(image: WidgetImage?) {
        let box = raiseBox
        self.drive = WidgetDrive(
            scheduleEvent: { _, action in action() },   // fire completion synchronously
            raiseInterrupt: { box.raised = true },
            clearInterrupt: { box.raised = false }
        )
        if let image { drive.attach(image) }
    }

    // ORB bit patterns (bit 3 = DIR 1=in, bit 4 = CMD active-low).
    private static let cmdTrueDirIn: UInt8 = 0x08    // cmd asserted, dir in
    private static let cmdFalseDirOut: UInt8 = 0x10  // cmd deasserted, dir out

    /// One `DOSHAKE`: assert CMD (dir in), read the response off PORTA, reply
    /// $55, deassert CMD. Returns the controller's response code.
    @discardableResult
    func handshake() -> UInt8 {
        drive.portBWrite(Self.cmdTrueDirIn)          // CMD assert -> present response, BSY=0
        #expect(drive.portBInput & 0x02 == 0x00, "BSY should be 0 while CMD asserted")
        let resp = drive.portAInput                  // read response (PORTA reg 15)
        drive.portAAccess(index: 15, value: resp, isWrite: false)
        drive.portAAccess(index: 15, value: 0x55, isWrite: true)   // reply $55
        drive.portBWrite(Self.cmdFalseDirOut)        // CMD deassert -> BSY=1
        #expect(drive.portBInput & 0x02 == 0x02, "BSY should be 1 after CMD deasserts")
        return resp
    }

    /// Write a byte OUT to ORA (register 1) — command byte or write-data byte.
    func sendByte(_ b: UInt8) { drive.portAAccess(index: 1, value: b, isWrite: true) }

    /// Read a byte IN from IRA (register 1) — data/tag/status, auto-advancing.
    func readByte() -> UInt8 {
        let b = drive.portAInput
        drive.portAAccess(index: 1, value: b, isWrite: false)
        return b
    }
    func readBytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in readByte() } }

    func sendCommandBlock(cmd: UInt8, block: Int, retry: UInt8 = 0x0A, sparing: UInt8 = 3) {
        sendByte(cmd)
        sendByte(UInt8((block >> 16) & 0xFF))
        sendByte(UInt8((block >> 8) & 0xFF))
        sendByte(UInt8(block & 0xFF))
        sendByte(retry)
        sendByte(sparing)
    }
}

// MARK: - Attach / disconnect + idle BSY status

@Test func detachedReportsDisconnectAndBSYHigh() throws {
    let (image, url) = try scratchWidget()
    defer { try? FileManager.default.removeItem(at: url) }

    let h = Harness(image: nil)
    #expect(h.drive.portBInput & 0x01 == 0x01, "detached: DISCONNECT asserted")
    #expect(!h.drive.isAttached)

    h.drive.attach(image)
    #expect(h.drive.isAttached)
    #expect(h.drive.portBInput & 0x01 == 0x00, "attached: DISCONNECT clear")
    #expect(h.drive.portBInput & 0x02 == 0x02, "attached + idle: BSY = 1 (ready)")
}

// MARK: - Read block round-trip (tag 20 + data 512 + status 4)

@Test func readCommandRoundTripsTagDataAndStatus() throws {
    let (image, url) = try scratchWidget(blockCount: 16)
    defer { try? FileManager.default.removeItem(at: url) }

    let data = Data((0..<512).map { UInt8(($0 * 7) & 0xFF) })
    let tag = Data((0..<20).map { UInt8(0xC0 &+ UInt8($0)) })
    try image.write(block: 6, data: data, tag: tag)

    let h = Harness(image: image)
    #expect(h.handshake() == 0x01)                 // first handshake: idle -> ready
    h.sendCommandBlock(cmd: 0x00, block: 6)        // 6-byte read command
    #expect(h.handshake() == 0x02)                 // read accepted
    // Driver read order: 4 status (S6) FIRST, then 20 tag (RDHDR), then 512 data.
    let status = h.readBytes(4)
    let gotTag = h.readBytes(20)
    let gotData = h.readBytes(512)
    #expect(status == [0, 0, 0, 0])
    #expect(Data(gotTag) == tag)
    #expect(Data(gotData) == data)
    #expect(h.completionRaised)
    #expect(h.drive.completedCommands == 1)
}

// MARK: - Write persists to the backing image + across a reopen

@Test func writeCommandPersistsBlockToImageAndReopen() throws {
    let (image, url) = try scratchWidget(blockCount: 16)
    defer { try? FileManager.default.removeItem(at: url) }

    let data = Data((0..<512).map { UInt8((0xFF - ($0 & 0xFF)) & 0xFF) })
    let tag = Data((0..<20).map { _ in UInt8(0x3C) })

    let h = Harness(image: image)
    #expect(h.handshake() == 0x01)
    h.sendCommandBlock(cmd: 0x01, block: 10)       // cmd 1 = write
    #expect(h.handshake() == 0x03)                 // write accepted
    for b in tag { h.sendByte(b) }                 // 20 header (WRHDR) first
    for b in data { h.sendByte(b) }                // then 512 data (WRDATA)
    #expect(h.handshake() == 0x06)                 // post-write status handshake
    let status = h.readBytes(4)
    #expect(status == [0, 0, 0, 0])

    #expect(image.data(block: 10) == data)
    #expect(image.tag(block: 10) == tag)
    try image.flush()
    let reopened = try WidgetImage(contentsOf: url)
    #expect(reopened.data(block: 10) == data)
    #expect(reopened.tag(block: 10) == tag)
}

// MARK: - Out-of-range read -> fatal status (§10.5)

@Test func readOfOutOfRangeBlockReturnsFatalStatus() throws {
    let (image, url) = try scratchWidget(blockCount: 8)
    defer { try? FileManager.default.removeItem(at: url) }

    let h = Harness(image: image)
    #expect(h.handshake() == 0x01)
    h.sendCommandBlock(cmd: 0x00, block: 999)
    #expect(h.handshake() == 0x02)
    let status = h.readBytes(4)     // status FIRST (S6)
    _ = h.readBytes(20 + 512)
    let longword = (UInt32(status[0]) << 24) | (UInt32(status[1]) << 16)
        | (UInt32(status[2]) << 8) | UInt32(status[3])
    #expect(longword & 0xC140C000 != 0, "out-of-range block must carry a fatal errstat bit")
}

// MARK: - Unsupported command bytes are REJECTED, not silently read (review I2)

@Test func unsupportedCommandByteReturnsFatalStatusNotRead() throws {
    let (image, url) = try scratchWidget(blockCount: 8)
    defer { try? FileManager.default.removeItem(at: url) }
    let h = Harness(image: image)

    #expect(h.handshake() == 0x01)
    // $02 = Formatcmd (a driver op, NOT a wire read/write, §10.4) -- the
    // canonical "neither 0 nor 1" byte. We advertise single-block T_Seagate, so
    // this is out of contract and must be rejected, not treated as a read.
    h.sendCommandBlock(cmd: 0x02, block: 3)
    // The accept handshake still returns (read-accepted code), but the data
    // phase is a 4-byte fatal ERRSTAT (§10.5) instead of block data -- and the
    // command still completes (interrupt raised).
    #expect(h.handshake() == 0x02)
    let status = h.readBytes(4)
    let longword = (UInt32(status[0]) << 24) | (UInt32(status[1]) << 16)
        | (UInt32(status[2]) << 8) | UInt32(status[3])
    #expect(longword & 0xC140C000 != 0,
            "an unsupported command byte must return a fatal ERRSTAT, not read data")
    #expect(h.completionRaised)
}

// MARK: - Device-info read: PROF_INIT's characteristics layout (T_Seagate)

@Test func deviceInfoReadAdvertisesSeagateDrivetypeAndDiscsize() throws {
    // discsize in (9728, 30000] -> the 10 MB Widget/Seagate range (§10.8).
    let (image, url) = try scratchWidget(blockCount: 19456)
    defer { try? FileManager.default.removeItem(at: url) }
    let h = Harness(image: image)

    #expect(h.handshake() == 0x01)
    h.sendCommandBlock(cmd: 0x00, block: 0xFFFFFF)   // device-info read (§10.4)
    #expect(h.handshake() == 0x02)
    // PROF_INIT layout (PROFASM:1596-1613): 4 status, 14 skip, DRIVETYPE@14,
    // 3 skip, 3-byte DISCSIZE @18-20.
    let s = h.readBytes(25)
    #expect(Array(s[0..<4]) == [0, 0, 0, 0], "4 OK status bytes")
    #expect(s[18] == 0, "DRIVETYPE = 0 -> hdinit resolves T_Seagate (single-block)")
    let discsize = (UInt32(s[22]) << 16) | (UInt32(s[23]) << 8) | UInt32(s[24])
    #expect(discsize == 19456, "DISCSIZE (3-byte) = blockCount")
}

// MARK: - reset() drops an in-flight handshake, keeps the attached image

@Test func resetDropsInflightHandshakeButKeepsImage() throws {
    let (image, url) = try scratchWidget()
    defer { try? FileManager.default.removeItem(at: url) }
    let h = Harness(image: image)

    #expect(h.handshake() == 0x01)   // open a transaction
    h.sendByte(0x00)                 // partial command block
    h.drive.reset()

    #expect(h.drive.isAttached)      // image survives warm reset
    #expect(h.handshake() == 0x01)   // a fresh transaction starts clean
}
