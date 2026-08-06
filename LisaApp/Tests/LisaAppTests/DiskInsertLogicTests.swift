import Foundation
import Testing
@testable import LisaApp

/// Pure-logic coverage for M2 Task 7's disk-insert filter --
/// `AppModel.isDC42File(_:)`, the predicate shared by drag-and-drop
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
        #expect(AppModel.isDC42File(URL(fileURLWithPath: "/tmp/OS31_Install_1.dc42")))
    }

    @Test func acceptsUppercaseOrMixedCaseExtension() {
        #expect(AppModel.isDC42File(URL(fileURLWithPath: "/tmp/Disk.DC42")))
        #expect(AppModel.isDC42File(URL(fileURLWithPath: "/tmp/Disk.Dc42")))
    }

    @Test func rejectsOtherExtensions() {
        #expect(!AppModel.isDC42File(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!AppModel.isDC42File(URL(fileURLWithPath: "/tmp/rom.bin")))
    }

    @Test func rejectsNoExtension() {
        #expect(!AppModel.isDC42File(URL(fileURLWithPath: "/tmp/OS31_Install_1")))
    }

    @Test func isPurelyLexicalNoFilesystemCheck() {
        // pathExtension is purely lexical (no filesystem stat), so a
        // nonexistent/bogus path named "*.dc42" still reads as accepted
        // here -- documented, not a bug: the real gate against a
        // bogus/nonexistent path is `EmulationController.insertFloppy`'s
        // `DC42Image.load(url:)` try/catch -> `onDiskError`, not this
        // lexical pre-filter (see that method's doc comment, "never a
        // crash").
        #expect(AppModel.isDC42File(URL(fileURLWithPath: "/tmp/does-not-exist.dc42")))
    }
}
