import Foundation
import Testing
@testable import LisaCore

// Protocol-level, CPU-free tests for the FloppyController HLE device
// (M2 Task 4). No `Bus`/`Machine`/`M68K` involved -- these drive
// `FloppyController` directly through its injected scheduler/level-1
// closures and the same `read(_:)`/`write(_:_:)` window surface
// `IODispatcher` wires onto the `$FCC000-$FCC7FF` offset range, mirroring
// `COPSTests.swift`'s CPU-free shape exactly (same `FakeScheduler`
// pattern). Synthetic DC42 images are built with the same header-assembly
// approach `DC42ImageTests.swift`'s `makeDC42Container` uses.
//
// See `FloppyController.swift`'s type doc comment for the full protocol
// this models, including the two FLAGGED assumptions (completion-line
// polarity, DISKERR raw-byte inference) Task 5's ROM trace is expected to
// confirm or correct.

// MARK: - Fake scheduler (mirrors COPSTests.swift's FakeScheduler)

private final class FakeScheduler {
    private(set) var cycle: UInt64 = 0
    private var events: [(due: UInt64, action: () -> Void)] = []

    func schedule(_ delay: UInt64, _ action: @escaping () -> Void) {
        events.append((due: cycle + delay, action: action))
    }

    /// Advances the fake clock to `target` and fires every event now due,
    /// including events newly scheduled by an action that just fired (the
    /// commandDelayCycles -> completionDelayCycles two-hop chain), as long
    /// as their due cycle is also `<= target`.
    func advance(to target: UInt64) {
        cycle = target
        while let idx = events.firstIndex(where: { $0.due <= cycle }) {
            let action = events.remove(at: idx).action
            action()
        }
    }

    func advance(by delta: UInt64) { advance(to: cycle + delta) }

    /// Drops every not-yet-fired event without running it -- the test-level
    /// stand-in for `Machine.reset()`'s `queue.removeAll()`, which
    /// `FloppyController.reset()`'s doc comment documents callers MUST do
    /// first (mirroring `COPS.reset()`/`VideoTiming.reset()`'s identical
    /// ordering requirement).
    func clear() { events.removeAll() }
}

/// Callable observer for the level-1 IRQ OR-term (`Machine.floppyPending`
/// in the real system) -- mirrors COPSTests.swift's `InterruptObserver`.
private final class Level1Observer {
    private(set) var pending = false
    func set(_ value: Bool) { pending = value }
    func callAsFunction() -> Bool { pending }
}

private func makeController(log: @escaping (String) -> Void = { _ in })
    -> (floppy: FloppyController, scheduler: FakeScheduler, level1: Level1Observer) {
    let scheduler = FakeScheduler()
    let level1 = Level1Observer()
    let floppy = FloppyController(
        scheduleEvent: { delay, action in scheduler.schedule(delay, action) },
        setLevel1Pending: { pending in level1.set(pending) },
        log: log
    )
    return (floppy, scheduler, level1)
}

// MARK: - Synthetic DC42 image (800 single-sided blocks, distinguishable
// per-block content so a wrong zone-mapping/copy is caught, not masked by
// uniform filler)

private func makeSyntheticImage(blockCount: Int = 800) -> DC42Image {
    var dataPlane = [UInt8](repeating: 0, count: blockCount * 512)
    var tagPlane = [UInt8](repeating: 0, count: blockCount * 12)
    for block in 0..<blockCount {
        for i in 0..<512 {
            dataPlane[block * 512 + i] = UInt8(truncatingIfNeeded: block &* 7 &+ i)
        }
        for i in 0..<12 {
            tagPlane[block * 12 + i] = UInt8(truncatingIfNeeded: block &* 3 &+ i &+ 1)
        }
    }

    var container = Data()
    let name = "TEST"
    var pascalString = Data([UInt8(name.utf8.count)])
    pascalString.append(contentsOf: Array(name.utf8))
    container.append(pascalString)
    container.append(Data(repeating: 0, count: 64 - pascalString.count))
    var dataLen = UInt32(dataPlane.count).bigEndian
    container.append(Data(bytes: &dataLen, count: 4))
    var tagLen = UInt32(tagPlane.count).bigEndian
    container.append(Data(bytes: &tagLen, count: 4))
    container.append(Data(repeating: 0, count: 8))
    container.append(Data(repeating: 0, count: 4))
    container.append(Data(dataPlane))
    container.append(Data(tagPlane))
    return try! DC42Image(data: container)   // swiftlint:disable:this force_try -- hand-built, always valid
}

/// Forward CONVERT, implemented independently from the §9 zone table (NOT
/// derived from `FloppyController.blockNumber`, which is the "inverse"
/// under test): linear block -> (track, sector, side 0). Used both by the
/// full-range property test and to pick track/sector for the zone-boundary
/// round-trip test.
private func forwardConvert(block: Int) -> (track: Int, sector: Int, side: Int) {
    let zones: [(base: Int, secPerTrack: Int, firstTrack: Int, trackCount: Int)] = [
        (0, 12, 0, 16), (192, 11, 16, 16), (368, 10, 32, 16), (528, 9, 48, 16), (672, 8, 64, 16),
    ]
    for zone in zones {
        let count = zone.secPerTrack * zone.trackCount
        if block >= zone.base && block < zone.base + count {
            let rel = block - zone.base
            return (zone.firstTrack + rel / zone.secPerTrack, rel % zone.secPerTrack, 0)
        }
    }
    fatalError("block \(block) out of the 800-block single-sided range")
}

private func issueRead(_ floppy: FloppyController, _ scheduler: FakeScheduler,
                        track: Int, sector: Int, side: Int) {
    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.readdisk.rawValue)
    floppy.write(FloppyController.Cell.diskDriv, 0)
    floppy.write(FloppyController.Cell.diskHead, UInt8(side))
    floppy.write(FloppyController.Cell.diskSec, UInt8(sector))
    floppy.write(FloppyController.Cell.diskTrak, UInt8(track))
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)
    scheduler.advance(by: FloppyController.commandDelayCycles)
    scheduler.advance(by: FloppyController.completionDelayCycles)
}

// MARK: - Zone mapping (CONVERT) property test

@Test func zoneMappingInverseAgreesWithForwardConvertForAll800Blocks() {
    for block in 0..<800 {
        let (track, sector, side) = forwardConvert(block: block)
        #expect(FloppyController.blockNumber(track: track, sector: sector, side: side) == block,
                "block \(block) -> (track \(track), sector \(sector)) should round-trip through the inverse")
    }
}

@Test func zoneMappingRejectsOutOfRangeTrackAndSector() {
    #expect(FloppyController.blockNumber(track: 80, sector: 0, side: 0) == nil, "track 80 is past the last zone (64-79)")
    #expect(FloppyController.blockNumber(track: 0, sector: 12, side: 0) == nil, "track 0's zone has only 12 sectors (0-11)")
    #expect(FloppyController.blockNumber(track: -1, sector: 0, side: 0) == nil)
}

// MARK: - Full read round-trip, including every zone boundary

@Test func readCommandCopiesDataAndTagForZoneBoundaryBlocks() {
    let image = makeSyntheticImage()
    // Every documented zone boundary (hardware-notes.md §9's "Zone offset
    // table" bases) plus the very first and very last block.
    for block in [0, 191, 192, 367, 368, 527, 528, 671, 672, 799] {
        let (floppy, scheduler, level1) = makeController()
        floppy.insert(image)
        let (track, sector, side) = forwardConvert(block: block)

        issueRead(floppy, scheduler, track: track, sector: sector, side: side)

        let expectedData = image.data(block: block)
        let expectedTag = image.tag(block: block)
        for i in 0..<512 {
            #expect(floppy.read(FloppyController.Cell.diskData + i) == expectedData[i],
                    "block \(block) data byte \(i)")
        }
        for i in 0..<12 {
            #expect(floppy.read(FloppyController.Cell.diskHdr + i) == expectedTag[i],
                    "block \(block) tag byte \(i)")
        }
        #expect(floppy.read(FloppyController.Cell.diskErr) == 0, "block \(block): DISKERR=0 on success")
        #expect(floppy.read(FloppyController.Cell.diskCmd) == 0, "block \(block): DISKCMD cleared")
        #expect(floppy.read(FloppyController.Cell.diskStat) & 0xC0 == 0xC0,
                "block \(block): DISKSTAT done+int bits set")
        #expect(floppy.completionLineAsserted == true, "block \(block): completion line raised")
        #expect(level1() == true, "block \(block): level-1 IRQ contribution raised")
        #expect(floppy.blocksRead == 1)
        #expect(floppy.lastError == 0)
    }
}

@Test func completionLineAndDiskCmdAreNotYetSetBeforeEitherDelayElapses() {
    let (floppy, scheduler, level1) = makeController()
    floppy.insert(makeSyntheticImage())

    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.readdisk.rawValue)
    floppy.write(FloppyController.Cell.diskHead, 0)
    floppy.write(FloppyController.Cell.diskSec, 0)
    floppy.write(FloppyController.Cell.diskTrak, 0)
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)

    #expect(floppy.read(FloppyController.Cell.diskCmd) == FloppyController.GoByte.excmd.rawValue,
            "go-byte visible immediately -- the write itself always lands in the window")
    #expect(floppy.completionLineAsserted == false)

    scheduler.advance(by: FloppyController.commandDelayCycles)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == 0, "DISKCMD clears at the FIRST delay hop")
    #expect(floppy.completionLineAsserted == false, "but completion is a SECOND, separate delay hop")
    #expect(level1() == false)

    scheduler.advance(by: FloppyController.completionDelayCycles)
    #expect(floppy.completionLineAsserted == true)
    #expect(level1() == true)
}

// MARK: - Handshake / busy rejection

@Test func diskCmdWriteWhileBusyIsRejected() {
    var logged: [String] = []
    let (floppy, scheduler, _) = makeController(log: { logged.append($0) })
    floppy.insert(makeSyntheticImage())

    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.readdisk.rawValue)
    floppy.write(FloppyController.Cell.diskHead, 0)
    floppy.write(FloppyController.Cell.diskSec, 0)
    floppy.write(FloppyController.Cell.diskTrak, 0)
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == FloppyController.GoByte.excmd.rawValue)

    // A second go-byte write while the first is still in flight must be
    // rejected outright -- not stored, not scheduled.
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.nulcmd.rawValue)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == FloppyController.GoByte.excmd.rawValue,
            "rejected write must not clobber the in-flight command")
    #expect(logged.contains { $0.contains("busy") })

    scheduler.advance(by: FloppyController.commandDelayCycles)
    scheduler.advance(by: FloppyController.completionDelayCycles)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == 0, "the original excmd still completes normally")
    #expect(floppy.blocksRead == 1, "only ONE read happened -- the rejected nulcmd never ran")
}

// MARK: - Error paths

@Test func readWithNoDiskSetsReadErrorButStillCompletes() {
    let (floppy, scheduler, level1) = makeController()
    // No insert() -- no disk present.
    issueRead(floppy, scheduler, track: 0, sector: 0, side: 0)

    #expect(floppy.read(FloppyController.Cell.diskErr) == FloppyController.ErrorCode.read)
    #expect(floppy.lastError == FloppyController.ErrorCode.read)
    #expect(floppy.blocksRead == 0)
    // Errors are still delivered as a completion interrupt (SONYASM:136-157
    // "response := waitint" applies to excmd generally, not only success)
    // -- the driver reads DISKERR after being woken by the interrupt.
    #expect(floppy.completionLineAsserted == true)
    #expect(level1() == true)
}

@Test func readWithOutOfRangeTrackSetsReadError() {
    let (floppy, scheduler, _) = makeController()
    floppy.insert(makeSyntheticImage())
    issueRead(floppy, scheduler, track: 80, sector: 0, side: 0)   // no zone covers track 80
    #expect(floppy.read(FloppyController.Cell.diskErr) == FloppyController.ErrorCode.read)
}

@Test func unsupportedSubCommandSetsNotIssuedError() {
    let (floppy, scheduler, level1) = makeController()
    floppy.insert(makeSyntheticImage())

    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.format.rawValue)
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)
    scheduler.advance(by: FloppyController.commandDelayCycles)
    scheduler.advance(by: FloppyController.completionDelayCycles)

    #expect(floppy.read(FloppyController.Cell.diskErr) == FloppyController.ErrorCode.notIssued)
    #expect(level1() == true, "still completes -- the driver must be able to see the error")
}

@Test func writeSubCommandIsAcceptedAndDiscardedWithALoggedWarning() {
    var logged: [String] = []
    let (floppy, scheduler, _) = makeController(log: { logged.append($0) })
    floppy.insert(makeSyntheticImage())

    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.writedisk.rawValue)
    floppy.write(FloppyController.Cell.diskHead, 0)
    floppy.write(FloppyController.Cell.diskSec, 5)
    floppy.write(FloppyController.Cell.diskTrak, 2)
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)
    scheduler.advance(by: FloppyController.commandDelayCycles)
    scheduler.advance(by: FloppyController.completionDelayCycles)

    #expect(floppy.writeAttempts == 1)
    #expect(floppy.read(FloppyController.Cell.diskErr) == 0, "write is accepted (no error), just discarded")
    #expect(floppy.blocksRead == 0, "M2 is read-only -- no image mutation, and this isn't a read")
    #expect(logged.contains { $0.contains("writedisk") }, "logged warning per the task brief")
}

// MARK: - Media insertion / DISKIN / reset

@Test func insertAndEjectReflectInDiskIn() {
    let (floppy, _, _) = makeController()
    #expect(floppy.read(FloppyController.Cell.diskIn) == 0)
    #expect(floppy.isInserted == false)

    floppy.insert(makeSyntheticImage())
    #expect(floppy.read(FloppyController.Cell.diskIn) != 0)
    #expect(floppy.isInserted == true)

    floppy.eject()
    #expect(floppy.read(FloppyController.Cell.diskIn) == 0)
    #expect(floppy.isInserted == false)
}

@Test func resetDropsInFlightCommandButKeepsDiskInserted() {
    let (floppy, scheduler, level1) = makeController()
    floppy.insert(makeSyntheticImage())

    // Start a command but don't let it complete before resetting -- mirrors
    // "in-flight command dropped" from the task brief.
    floppy.write(FloppyController.Cell.diskParm, FloppyController.SubCommand.readdisk.rawValue)
    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.excmd.rawValue)

    // Per FloppyController.reset()'s doc comment, callers must clear the
    // event queue BEFORE calling reset() -- exactly like COPS/VideoTiming
    // (Machine.reset() does `queue.removeAll()` first); simulated here.
    scheduler.clear()
    floppy.reset()

    #expect(floppy.read(FloppyController.Cell.diskCmd) == 0, "in-flight command dropped")
    #expect(floppy.read(FloppyController.Cell.diskIn) != 0, "disk stays inserted across reset")
    #expect(floppy.isInserted == true)
    #expect(floppy.completionLineAsserted == false)
    #expect(level1() == false)
    #expect(floppy.blocksRead == 0, "the dropped command never ran")

    // A fresh command must work normally post-reset (not left "busy").
    issueRead(floppy, scheduler, track: 0, sector: 0, side: 0)
    #expect(floppy.read(FloppyController.Cell.diskErr) == 0, "read succeeds -- disk survived the reset")
    #expect(floppy.blocksRead == 1)
}

// MARK: - Simple go-bytes (state-flag effects + DISKCMD clear, no completion)

@Test func nulcmdSeekEnabstatClrmaskGoawayAllClearDiskCmdWithoutRaisingCompletion() {
    for goByte: UInt8 in [
        FloppyController.GoByte.nulcmd.rawValue,
        FloppyController.GoByte.seek.rawValue,
        FloppyController.GoByte.enabstat.rawValue,
        FloppyController.GoByte.clrmask.rawValue,
        FloppyController.GoByte.goaway.rawValue,
    ] {
        let (floppy, scheduler, level1) = makeController()
        floppy.write(FloppyController.Cell.diskCmd, goByte)
        scheduler.advance(by: FloppyController.commandDelayCycles)
        #expect(floppy.read(FloppyController.Cell.diskCmd) == 0, "go-byte $\(String(goByte, radix: 16)) clears DISKCMD")
        #expect(floppy.completionLineAsserted == false, "go-byte $\(String(goByte, radix: 16)) is non-interrupting")
        #expect(level1() == false)
    }
}

@Test func clristatClearsStatusIntDoneBitsAndDropsAnAssertedCompletionLine() {
    let (floppy, scheduler, level1) = makeController()
    floppy.insert(makeSyntheticImage())
    issueRead(floppy, scheduler, track: 0, sector: 0, side: 0)
    #expect(floppy.completionLineAsserted == true)
    #expect(level1() == true)
    #expect(floppy.read(FloppyController.Cell.diskStat) & 0xC0 == 0xC0)

    floppy.write(FloppyController.Cell.diskCmd, FloppyController.GoByte.clristat.rawValue)
    scheduler.advance(by: FloppyController.commandDelayCycles)

    #expect(floppy.read(FloppyController.Cell.diskStat) & 0xC0 == 0, "int+done bits cleared")
    #expect(floppy.completionLineAsserted == false, "clristat drops the interrupt line")
    #expect(level1() == false)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == 0)
}

@Test func unrecognizedGoByteStillClearsDiskCmdAsAHandshakeOnlyAck() {
    let (floppy, scheduler, level1) = makeController()
    floppy.write(FloppyController.Cell.diskCmd, 0xFF)   // not any documented go-byte
    scheduler.advance(by: FloppyController.commandDelayCycles)
    #expect(floppy.read(FloppyController.Cell.diskCmd) == 0)
    #expect(level1() == false)
}
