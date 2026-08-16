import Foundation
import Testing
@testable import LisaApp

/// Pure-logic coverage for M2 Task 7's disk-insert filter --
/// `AppModel.isFloppyImageFile(_:)`, the predicate shared by drag-and-drop
/// (`ScreenView.swift`'s `.onDrop`) and documented alongside File > Insert
/// Disk…'s `NSOpenPanel` filter (`LisaApp.swift`'s `presentInsertDiskPanel`,
/// which filters via `UTType(filenameExtension:)` instead -- this predicate
/// is the drag-and-drop-side equivalent, extracted so it's testable without
/// a real drag session or `NSItemProvider`). Same shape as
/// `InputCaptureLogicTests`: a `nonisolated static` pure function, no
/// `AppModel` instance/`NSView`/AppKit side effects needed to exercise it.
@Suite
struct DiskInsertLogicTests {
    @Test func acceptsLowercaseDC42Extension() {
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/OS31_Install_1.dc42")))
    }

    @Test func acceptsUppercaseOrMixedCaseExtension() {
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/Disk.DC42")))
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/Disk.Dc42")))
    }

    @Test func rejectsOtherExtensions() {
        #expect(!AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/rom.bin")))
    }

    @Test func rejectsNoExtension() {
        #expect(!AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/OS31_Install_1")))
    }

    @Test func isPurelyLexicalNoFilesystemCheck() {
        // pathExtension is purely lexical (no filesystem stat), so a
        // nonexistent/bogus path named "*.dc42" still reads as accepted
        // here -- documented, not a bug: the real gate against a
        // bogus/nonexistent path is `EmulationController.insertFloppy`'s
        // `DC42Image.load(url:)` try/catch -> `onDiskError`, not this
        // lexical pre-filter (see that method's doc comment, "never a
        // crash").
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/does-not-exist.dc42")))
    }

    // MARK: - M9: Disk Copy 4.2 images shipped as `.image` / `.img`

    /// `.image` is the classic Disk Copy 4.2 extension: Mac-era disks are
    /// routinely distributed as `Something.image` while being byte-for-byte
    /// DC42 containers. The parser always handled them; only this filter
    /// did not.
    @Test func acceptsImageAndImgExtensions() {
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/6.0.7 System Tools.image")))
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/Disk.IMAGE")))
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/Disk.img")))
        #expect(AppModel.isFloppyImageFile(URL(fileURLWithPath: "/tmp/Disk.IMG")))
    }

    /// The drop gate probes CONTENT for the ambiguous extensions, because
    /// `.image` is also what this project's Widget hard-disk images use.
    /// `.dc42` skips the probe and stays purely lexical.
    @Test func dropGateProbesContentOnlyForAmbiguousExtensions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropgate-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real DC42 container named `.image` -- accepted.
        var container = Data([4]); container.append(contentsOf: Array("TEST".utf8))
        container.append(Data(repeating: 0, count: 64 - container.count))
        var dl = UInt32(4 * 512).bigEndian; container.append(Data(bytes: &dl, count: 4))
        var tl = UInt32(0).bigEndian; container.append(Data(bytes: &tl, count: 4))
        container.append(Data(repeating: 0, count: 12))
        container.append(Data(repeating: 0, count: 4 * 512))
        let good = dir.appendingPathComponent("Disk.image")
        try container.write(to: good)
        #expect(AppModel.isDroppableFloppyImage(good))

        // A Widget-shaped file named `.image` -- rejected by the probe, so a
        // dropped hard-disk image is ignored instead of erroring.
        let widgetish = dir.appendingPathComponent("HD.image")
        try Data(repeating: 0, count: 532 * 64).write(to: widgetish)
        #expect(!AppModel.isDroppableFloppyImage(widgetish))

        // `.dc42` never probes: a nonexistent path still passes the gate and
        // is left for insertFloppy's error alert to report.
        #expect(AppModel.isDroppableFloppyImage(dir.appendingPathComponent("nope.dc42")))
        #expect(!AppModel.isDroppableFloppyImage(dir.appendingPathComponent("notes.txt")))
    }

    // MARK: - M5 Task 2: Widget hard-disk image filter

    @Test func widgetFilterAcceptsWidgetAndImageExtensions() {
        #expect(AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/HD.widget")))
        #expect(AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/HD.WIDGET")))
        #expect(AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/HD.image")))
    }

    @Test func widgetFilterRejectsFloppyAndOtherExtensions() {
        #expect(!AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/OS31_Install_1.dc42")))
        #expect(!AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!AppModel.isWidgetFile(URL(fileURLWithPath: "/tmp/HD")))
    }
}
