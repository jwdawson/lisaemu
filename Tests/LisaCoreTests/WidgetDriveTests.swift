import Foundation
import Testing
@testable import LisaCore

// MARK: - WidgetDrive: the ProFile/Widget parallel-port HLE
//
// Drives the byte-at-a-time handshake exactly as the OS ProFile driver
// performs it (docs/hardware-notes.md §10.2-10.5). These tests act as the
// executable spec of that contract: they simulate the driver clocking bytes
// through the VIA1 Port A/Port B surface (`portBWrite`/`portAWrite`/
// `portAInput`/`portBInput`) and assert the response codes, reply bytes,
// block data, status bytes, and completion interrupt.
//
// Synthetic blank images in temp dirs -- NO env gating.

private func scratchWidget(blockCount: Int = 32) throws -> (WidgetImage, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wdrv-\(UUID().uuidString).widget")
    let image = try WidgetImage(createBlankAt: url, blockCount: blockCount)
    return (image, url)
}

private final class InterruptBox { var raised = false }

/// A test harness that drives a `WidgetDrive` the way the OS driver does,
/// pulsing CMD over Port B and moving one byte per handshake, with an
/// interrupt-capturing box for the completion line.
private final class Harness {
    let drive: WidgetDrive
    let image: WidgetImage?
    let raiseBox = InterruptBox()
    var completionRaised: Bool { raiseBox.raised }

    init(image: WidgetImage?) {
        let box = raiseBox
        self.drive = WidgetDrive(
            scheduleEvent: { _, action in action() },   // fire completion synchronously
            raiseInterrupt: { box.raised = true },
            clearInterrupt: { box.raised = false }
        )
        self.image = image
        if let image { drive.attach(image) }
    }

    private static let cmdFalseDirIn: UInt8 = 0x18
    private static let cmdTrueDirIn: UInt8 = 0x08
    private static let cmdFalseDirOut: UInt8 = 0x10
    private static let cmdTrueDirOut: UInt8 = 0x00

    func readByte() -> UInt8 {
        drive.portBWrite(Self.cmdFalseDirIn)
        drive.portBWrite(Self.cmdTrueDirIn)
        let b = drive.portAInput
        drive.portBWrite(Self.cmdFalseDirIn)
        return b
    }
    func writeByte(_ b: UInt8) {
        drive.portAWrite(b)
        drive.portBWrite(Self.cmdFalseDirOut)
        drive.portBWrite(Self.cmdTrueDirOut)
        drive.portBWrite(Self.cmdFalseDirOut)
    }
    func readBytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in readByte() } }

    /// Sends the 6-byte command block (cmd, 3-byte block#, retry, sparing).
    func sendCommandBlock(cmd: UInt8, block: Int, retry: UInt8 = 0x0A, sparing: UInt8 = 3) {
        writeByte(cmd)
        writeByte(UInt8((block >> 16) & 0xFF))
        writeByte(UInt8((block >> 8) & 0xFF))
        writeByte(UInt8(block & 0xFF))
        writeByte(retry)
        writeByte(sparing)
    }
}

// MARK: - Attach / disconnect status

@Test func detachedDriveReportsDisconnectAndAttachedDoesNot() throws {
    let (image, url) = try scratchWidget()
    defer { try? FileManager.default.removeItem(at: url) }

    let h = Harness(image: nil)
    // Detached: DISCONNECT (Port B bit 0) asserted (reads 1).
    #expect(h.drive.portBInput & 0x01 == 0x01)
    #expect(!h.drive.isAttached)

    h.drive.attach(image)
    #expect(h.drive.isAttached)
    // Attached: DISCONNECT clear (bit 0 == 0); other idle bits still pulled up.
    #expect(h.drive.portBInput & 0x01 == 0x00)
}

// MARK: - Read block round-trip through the handshake

@Test func readCommandRoundTripsBlockDataTagAndStatus() throws {
    let (image, url) = try scratchWidget(blockCount: 16)
    defer { try? FileManager.default.removeItem(at: url) }

    // Seed a known block directly in the image.
    let data = Data((0..<512).map { UInt8(($0 * 7) & 0xFF) })
    let tag = Data((0..<20).map { UInt8(0xC0 &+ UInt8($0)) })
    try image.write(block: 6, data: data, tag: tag)

    let h = Harness(image: image)

    // §10.3 ready handshake: drive presents $01 (idle->ready), driver replies $55.
    #expect(h.readByte() == 0x01)
    h.writeByte(0x55)
    // §10.4 6-byte read command block for block 6.
    h.sendCommandBlock(cmd: 0x00, block: 6)
    // §10.3 drive accepts the read command: $02, driver replies $55.
    #expect(h.readByte() == 0x02)
    h.writeByte(0x55)
    // Drive streams 512 data + 20 tag.
    let gotData = h.readBytes(512)
    let gotTag = h.readBytes(20)
    #expect(Data(gotData) == data)
    #expect(Data(gotTag) == tag)
    // Then 4 status bytes; a clean read is all-zero (no fatal bits, §10.5).
    let status = h.readBytes(4)
    #expect(status == [0, 0, 0, 0])
    // Completion interrupt raised (VIA1 level-1, §10.2 BSY interrupt).
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
    #expect(h.readByte() == 0x01)
    h.writeByte(0x55)
    h.sendCommandBlock(cmd: 0x01, block: 10)     // §10.4 cmd 1 = write
    // Drive accepts the write command: $03, driver replies $55.
    #expect(h.readByte() == 0x03)
    h.writeByte(0x55)
    // Driver streams 512 data + 20 tag to the drive.
    for b in data { h.writeByte(b) }
    for b in tag { h.writeByte(b) }
    // Drive posts write status: $06 then reply, then 4 status bytes.
    #expect(h.readByte() == 0x06)
    h.writeByte(0x55)
    let status = h.readBytes(4)
    #expect(status == [0, 0, 0, 0])
    #expect(h.completionRaised)

    // Persisted to the live image...
    #expect(image.data(block: 10) == data)
    #expect(image.tag(block: 10) == tag)
    // ...and across a reopen (write-back, §10.10).
    try image.flush()
    let reopened = try WidgetImage(contentsOf: url)
    #expect(reopened.data(block: 10) == data)
    #expect(reopened.tag(block: 10) == tag)
}

// MARK: - Error / status paths the OS driver checks (§10.5)

@Test func readOfOutOfRangeBlockReturnsFatalStatus() throws {
    let (image, url) = try scratchWidget(blockCount: 8)
    defer { try? FileManager.default.removeItem(at: url) }

    let h = Harness(image: image)
    #expect(h.readByte() == 0x01)
    h.writeByte(0x55)
    h.sendCommandBlock(cmd: 0x00, block: 999)    // out of range (only 8 blocks)
    #expect(h.readByte() == 0x02)
    h.writeByte(0x55)
    // Out-of-range read still streams a (zero) block, but the 4 status bytes
    // carry a fatal bit: (status_longword & $C140C000) != 0 (§10.5).
    _ = h.readBytes(512 + 20)
    let status = h.readBytes(4)
    let longword = (UInt32(status[0]) << 24) | (UInt32(status[1]) << 16)
        | (UInt32(status[2]) << 8) | UInt32(status[3])
    #expect(longword & 0xC140C000 != 0, "expected a fatal errstat bit for an out-of-range block")
}

// MARK: - BSY sequencing (§10.2/§10.3)

@Test func bsyAssertsDuringHandshakeAndClearsBetween() throws {
    let (image, url) = try scratchWidget()
    defer { try? FileManager.default.removeItem(at: url) }
    let h = Harness(image: image)

    // Idle before any strobe: BSY (bit 1) clear.
    #expect(h.drive.portBInput & 0x02 == 0x00)

    // Assert CMD (falling edge) -> drive presents ready byte + asserts BSY.
    h.drive.portBWrite(0x18)   // cmd false, dir in
    h.drive.portBWrite(0x08)   // cmd asserted, dir in
    #expect(h.drive.portBInput & 0x02 == 0x02, "BSY should assert while CMD is held")
    // Deassert CMD -> BSY clears.
    h.drive.portBWrite(0x18)
    #expect(h.drive.portBInput & 0x02 == 0x00, "BSY should clear when CMD deasserts")
}

// MARK: - reset() drops an in-flight handshake, keeps the attached image

@Test func resetDropsInflightHandshakeButKeepsImage() throws {
    let (image, url) = try scratchWidget()
    defer { try? FileManager.default.removeItem(at: url) }
    let h = Harness(image: image)

    #expect(h.readByte() == 0x01)   // start a transaction
    h.writeByte(0x55)
    h.writeByte(0x00)               // partial command block
    h.drive.reset()

    // Image survives a warm reset (real hardware doesn't unmount media).
    #expect(h.drive.isAttached)
    // A fresh transaction starts clean: the very next read is the ready byte.
    #expect(h.readByte() == 0x01)
}
