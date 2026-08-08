import Foundation
import Testing
@testable import LisaCore

// MARK: - WidgetImage: persistent raw-block hard-disk image container
//
// The Widget/ProFile image is a RAW, headerless container of N x 532-byte
// blocks (512 data + 20 tag), write-back persistent (docs/hardware-notes.md
// §10.10) -- the opposite of the floppy's read-only .dc42 session overlay.
// Synthetic blank images in temp dirs: NO env gating (an all-zero blank is
// not Apple data).

/// A fresh, unique scratch URL under the system temp dir; the caller creates
/// (or lets WidgetImage create) the file and removes it in a defer.
private func scratchURL(_ name: String = "widget") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).widget")
}

@Test func blankImageCreationProducesZeroedFileOfExpectedSize() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try WidgetImage(createBlankAt: url, blockCount: 4)
    #expect(image.blockCount == 4)

    // File on disk is exactly N x 532 bytes.
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(size == 4 * WidgetImage.bytesPerBlock)
    #expect(size == 4 * 532)

    // Every block reads back as zeros (data + tag).
    for block in 0..<4 {
        let data = image.data(block: block)
        #expect(data.count == 512)
        #expect(data.allSatisfy { $0 == 0 })
        let tag = image.tag(block: block)
        #expect(tag.count == 20)
        #expect(tag.allSatisfy { $0 == 0 })
    }
}

@Test func defaultBlankImageHasWidget10Geometry() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // Default N = 19456 (§10.8 chosen Widget-10 representative).
    let image = try WidgetImage(createBlankAt: url)
    #expect(image.blockCount == WidgetImage.defaultBlockCount)
    #expect(image.blockCount == 19456)

    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(size == 19456 * 532)
    #expect(size == 10_350_592)
}

@Test func writeBlockRoundTrips() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try WidgetImage(createBlankAt: url, blockCount: 8)
    let data = Data((0..<512).map { UInt8($0 & 0xFF) })
    let tag = Data((0..<20).map { UInt8(0xA0 &+ UInt8($0)) })

    try image.write(block: 5, data: data, tag: tag)

    #expect(image.data(block: 5) == data)
    #expect(image.tag(block: 5) == tag)
    // Neighbours untouched.
    #expect(image.data(block: 4).allSatisfy { $0 == 0 })
    #expect(image.data(block: 6).allSatisfy { $0 == 0 })
}

@Test func writePersistsAcrossReopen() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let data = Data((0..<512).map { UInt8((0x100 - $0) & 0xFF) })
    let tag = Data((0..<20).map { _ in UInt8(0x5A) })

    do {
        let image = try WidgetImage(createBlankAt: url, blockCount: 16)
        try image.write(block: 9, data: data, tag: tag)
        try image.flush()
    }

    // Reopen the same file: the written block must survive (write-back
    // persistence, §10.10).
    let reopened = try WidgetImage(contentsOf: url)
    #expect(reopened.blockCount == 16)
    #expect(reopened.data(block: 9) == data)
    #expect(reopened.tag(block: 9) == tag)
    #expect(reopened.data(block: 0).allSatisfy { $0 == 0 })
}

@Test func rejectsEmptyImageFile() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)

    var caught: WidgetImage.Error?
    do {
        _ = try WidgetImage(contentsOf: url)
    } catch let error as WidgetImage.Error {
        caught = error
    }
    #expect(caught == .emptyImage)
}

@Test func rejectsTruncatedNonBlockAlignedFile() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // Three whole blocks plus 100 stray bytes -- not a whole multiple of 532.
    let strayCount = 3 * 532 + 100
    try Data(repeating: 0, count: strayCount).write(to: url)

    var caught: WidgetImage.Error?
    do {
        _ = try WidgetImage(contentsOf: url)
    } catch let error as WidgetImage.Error {
        caught = error
    }
    #expect(caught == .sizeNotBlockAligned(size: strayCount, bytesPerBlock: 532))
}

@Test func rejectsNonPositiveBlockCount() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }

    var caught: WidgetImage.Error?
    do {
        _ = try WidgetImage(createBlankAt: url, blockCount: 0)
    } catch let error as WidgetImage.Error {
        caught = error
    }
    #expect(caught == .invalidBlockCount(0))
    // Nothing should have been created on the invalid path.
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func reopenExistingImageReportsBlockCountFromFileSize() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 0, count: 40 * 532).write(to: url)

    let image = try WidgetImage(contentsOf: url)
    #expect(image.blockCount == 40)
}

/// M5 final review: `lisadbg`'s `widget create <path>` command must refuse
/// to clobber a file that's already there -- pointed at a genuine install
/// (e.g. `OS31-installed.widget`), an unguarded `createBlankAt` would
/// silently zero-truncate it (a boot WRITES; this command shouldn't
/// destroy). `guardCreatable` is the pre-flight check the command surface
/// calls before `createBlankAt`; it leaves `createBlankAt` itself
/// unchanged (the app's NSSavePanel path still relies on
/// overwrite-after-confirmation).
@Test func guardCreatableRejectsAnExistingFile() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // Simulate a real installed image: non-trivial content, not a blank
    // WidgetImage-created file.
    let precious = Data((0..<1024).map { UInt8($0 & 0xFF) })
    try precious.write(to: url)

    var caught: WidgetImage.Error?
    do {
        try WidgetImage.guardCreatable(at: url)
    } catch let error as WidgetImage.Error {
        caught = error
    }
    #expect(caught == .alreadyExists(path: url.path))

    // The guard must not itself touch the file.
    let survived = try Data(contentsOf: url)
    #expect(survived == precious)
}

/// The mirror case: no file at the target path yet, so the guard is a
/// silent no-op and the normal create-blank path proceeds.
@Test func guardCreatableAllowsAFreshPath() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))

    #expect(throws: Never.self) {
        try WidgetImage.guardCreatable(at: url)
    }

    // Still nothing on disk -- guarding creates nothing itself.
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
