import Foundation
import Testing
@testable import LisaCore

// MARK: - Synthetic container round-trip

/// Builds a minimal valid DC42 container with specified data and tag planes.
private func makeDC42Container(
    imageName: String = "TEST",
    dataPlane: [UInt8],
    tagPlane: [UInt8]
) -> Data {
    var container = Data()

    // Header: 84 bytes
    // 0-63: image name as Pascal string
    let nameBytes = Array(imageName.utf8)
    let pascalString = Data([UInt8(nameBytes.count)]) + Data(nameBytes)
    container.append(pascalString)
    // Pad to 64 bytes
    container.append(Data(repeating: 0, count: 64 - pascalString.count))

    // 64-67: data length (big-endian UInt32)
    var dataLen = UInt32(dataPlane.count).bigEndian
    container.append(Data(bytes: &dataLen, count: MemoryLayout<UInt32>.size))

    // 68-71: tag length (big-endian UInt32)
    var tagLen = UInt32(tagPlane.count).bigEndian
    container.append(Data(bytes: &tagLen, count: MemoryLayout<UInt32>.size))

    // 72-79: checksums (8 bytes, we'll leave as zeros for synthetic tests)
    container.append(Data(repeating: 0, count: 8))

    // 80-83: format bytes (we'll leave as zeros for synthetic tests)
    container.append(Data(repeating: 0, count: 4))

    // Then the data plane
    container.append(Data(dataPlane))

    // Then the tag plane
    container.append(Data(tagPlane))

    return container
}

@Test func syntheticContainerCanBeCreatedAndRoundTripped() throws {
    // Create a minimal synthetic container: 1 block (512 bytes data) + 12 bytes tag
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)

    let container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    let image = try DC42Image(data: container)
    #expect(image.blockCount == 1)

    let readData = image.data(block: 0)
    #expect(readData.count == 512)
    #expect(readData == dataPlane)

    let readTag = image.tag(block: 0)
    #expect(readTag.count == 12)
    #expect(readTag == tagPlane)
}

@Test func containerWith800BlocksWorks() throws {
    let blockCount = 800
    let dataSize = blockCount * 512
    let tagSize = blockCount * 12

    let dataPlane = (0..<dataSize).map { UInt8($0 & 0xFF) }
    let tagPlane = [UInt8](repeating: 0xCC, count: tagSize)

    let container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    let image = try DC42Image(data: container)
    #expect(image.blockCount == 800)

    // Verify first block
    let data0 = image.data(block: 0)
    #expect(data0.count == 512)

    // Verify last block
    let data799 = image.data(block: 799)
    #expect(data799.count == 512)

    // Verify tag sizes
    let tag0 = image.tag(block: 0)
    #expect(tag0.count == 12)
}

@Test func rejectsSizeMismatchWhenDataLengthHeaderIsTooLarge() throws {
    // Header claims 999 bytes of data, but container only has 512
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)

    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    // Corrupt the data length field (at offset 64) to be larger than actual
    var wrongDataLen: UInt32 = 999
    container.replaceSubrange(64..<68, with: Data(bytes: &wrongDataLen, count: 4))

    #expect(throws: DC42Image.Error.self) {
        _ = try DC42Image(data: container)
    }
}

@Test func rejectsSizeMismatchWhenTagLengthHeaderIsTooLarge() throws {
    // Header claims 999 bytes of tags, but container only has 12
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)

    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    // Corrupt the tag length field (at offset 68) to be larger than actual
    var wrongTagLen: UInt32 = 999
    container.replaceSubrange(68..<72, with: Data(bytes: &wrongTagLen, count: 4))

    #expect(throws: DC42Image.Error.self) {
        _ = try DC42Image(data: container)
    }
}

@Test func rejectsSizeMismatchWhenContainerIsTruncated() throws {
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)

    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    // Truncate the container (remove last 100 bytes)
    container.removeLast(100)

    #expect(throws: DC42Image.Error.self) {
        _ = try DC42Image(data: container)
    }
}

@Test func rejectsSizeMismatchWhenContainerHasTrailingGarbage() throws {
    // Header understates size: actual container has trailing garbage/corruption
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)

    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    // Append 500 bytes of garbage (simulating concatenation or corruption)
    container.append(Data(repeating: 0xFF, count: 500))

    #expect(throws: DC42Image.Error.self) {
        _ = try DC42Image(data: container)
    }
}

// MARK: - Tagless containers (M2 review Finding 1 -- FloppyController's
// `performRead` used to trap calling `image.tag(block:)` on an empty tag
// plane; the fix is here, at load time: synthesize zero tags rather than
// storing an empty plane)

@Test func taglessContainerInsertsAndTagReadsReturnSynthesizedZeroTags() throws {
    // tagLen == 0 in the header, and no tag plane bytes in the container at
    // all -- exactly what a wild Mac-disk DC42 (or any tagless source) looks
    // like, and exactly what drag-and-drop invites.
    let blockCount = 2
    let dataPlane = (0..<(blockCount * 512)).map { UInt8($0 & 0xFF) }
    let container = makeDC42Container(dataPlane: dataPlane, tagPlane: [])

    let image = try DC42Image(data: container)
    #expect(image.blockCount == blockCount)

    for block in 0..<blockCount {
        // Data plane is untouched by the tagless fix.
        let data = image.data(block: block)
        #expect(data.count == 512)

        // Tag plane is synthesized, not left empty -- must not trap, and
        // must read back as all zeros.
        let tag = image.tag(block: block)
        #expect(tag.count == 12)
        #expect(tag.allSatisfy { $0 == 0 }, "tagless container should synthesize zero tags for block \(block)")
    }
}

@Test func rejectsTagLengthThatIsNeitherZeroNorBlockAligned() throws {
    // 1 block of data -> the only valid tag lengths are 0 (tagless) or 12
    // (blockCount * 12). 6 is neither.
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)
    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    var wrongTagLen = UInt32(6).bigEndian   // header field is big-endian
    container.replaceSubrange(68..<72, with: Data(bytes: &wrongTagLen, count: 4))

    var caught: DC42Image.Error?
    do {
        _ = try DC42Image(data: container)
    } catch let error as DC42Image.Error {
        caught = error
    }
    #expect(caught == .tagLengthMismatch(expected: 12, found: 6),
            "expected a typed tagLengthMismatch, got \(String(describing: caught))")
}

@Test func rejectsDataLengthThatIsNotAMultipleOf512() throws {
    let dataPlane = [UInt8](repeating: 0xAA, count: 512)
    let tagPlane = [UInt8](repeating: 0xBB, count: 12)
    var container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)

    var wrongDataLen = UInt32(500).bigEndian   // header field is big-endian; not a multiple of 512
    container.replaceSubrange(64..<68, with: Data(bytes: &wrongDataLen, count: 4))

    var caught: DC42Image.Error?
    do {
        _ = try DC42Image(data: container)
    } catch let error as DC42Image.Error {
        caught = error
    }
    #expect(caught == .dataLengthNotBlockAligned(500),
            "expected a typed dataLengthNotBlockAligned, got \(String(describing: caught))")
}

@Test func returnsZeroBasedArraysForNonZeroBlocks() throws {
    // Verify that returned arrays are zero-based, not parent-indexed.
    // This is critical for Task 4 (FloppyController) to safely index block data.
    let blockCount = 5
    let dataSize = blockCount * 512
    let tagSize = blockCount * 12

    // Create data where each byte is its position in the full array
    let dataPlane = (0..<dataSize).map { UInt8($0 & 0xFF) }
    let tagPlane = (0..<tagSize).map { UInt8($0 & 0xFF) }

    let container = makeDC42Container(dataPlane: dataPlane, tagPlane: tagPlane)
    let image = try DC42Image(data: container)

    // Check block 3 (middle of 5 blocks)
    // Its data should start at index 3*512 = 1536 in the original plane
    let block3Data = image.data(block: 3)
    #expect(block3Data.count == 512)
    // First byte of block 3 should be 0x00 (1536 & 0xFF), indexed as block3Data[0]
    #expect(block3Data[0] == UInt8(1536 & 0xFF))
    // Second byte should be 0x01 (1537 & 0xFF), indexed as block3Data[1]
    #expect(block3Data[1] == UInt8(1537 & 0xFF))

    // Check block 3 tags similarly
    let block3Tag = image.tag(block: 3)
    #expect(block3Tag.count == 12)
    // First byte of block 3 tag should be at index 3*12 = 36 in original, so 0x24 (36 & 0xFF)
    #expect(block3Tag[0] == UInt8(36 & 0xFF))
    // Second byte at index 37 in original
    #expect(block3Tag[1] == UInt8(37 & 0xFF))
}

// MARK: - Real DC42 image (env-gated)

private let diskDir = ProcessInfo.processInfo.environment["LISAEMU_DISK_DIR"]

@Suite(.enabled(if: diskDir != nil, "Set LISAEMU_DISK_DIR to run real-disk tests"))
struct RealDC42ImageTests {
    @Test func loadRealOS31InstallDisk() throws {
        let imagePath = URL(fileURLWithPath: diskDir!)
            .appendingPathComponent("OS31_Install_1.dc42")

        let image = try DC42Image.load(url: imagePath)
        #expect(image.blockCount == 800)

        // Block 0 data should begin with 4E FA (JMP boot instruction)
        let block0 = image.data(block: 0)
        #expect(block0.count == 512)
        #expect(block0[0] == 0x4E)
        #expect(block0[1] == 0xFA)

        // Tag plane should be non-empty (not all zeros)
        var tagHasNonZero = false
        for block in 0..<image.blockCount {
            let tag = image.tag(block: block)
            for byte in tag {
                if byte != 0 {
                    tagHasNonZero = true
                    break
                }
            }
            if tagHasNonZero { break }
        }
        #expect(tagHasNonZero, "expected tag plane to contain non-zero bytes")
    }
}

// MARK: - looksLikeDC42 content probe (M9)

/// The probe backs LisaApp's drag-and-drop filter, where `.image` is
/// ambiguous: it is both the classic Disk Copy 4.2 extension and the
/// extension this project's Widget hard-disk images use. It must agree with
/// `init(data:)` -- anything it accepts, the parser accepts.
@Test func looksLikeDC42AgreesWithTheParser() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dc42probe-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // A real (tagged) container, and a tagless one -- both parse, both probe true.
    for (name, tagged) in [("tagged.image", true), ("tagless.image", false)] {
        let blocks = 4
        var c = Data([4]); c.append(contentsOf: Array("TEST".utf8))
        c.append(Data(repeating: 0, count: 64 - c.count))
        var dl = UInt32(blocks * 512).bigEndian; c.append(Data(bytes: &dl, count: 4))
        var tl = UInt32(tagged ? blocks * 12 : 0).bigEndian; c.append(Data(bytes: &tl, count: 4))
        c.append(Data(repeating: 0, count: 12))
        c.append(Data(repeating: 0xAB, count: blocks * 512))
        if tagged { c.append(Data(repeating: 0xCD, count: blocks * 12)) }
        let url = try write(c, name)
        #expect(DC42Image.looksLikeDC42(url: url), "\(name) should probe true")
        #expect(throws: Never.self) { _ = try DC42Image.load(url: url) }
    }

    // A Widget-shaped file (all zeros, 532-byte blocks) must probe FALSE --
    // this is the case the probe exists for.
    let widgetish = try write(Data(repeating: 0, count: 532 * 64), "HD.image")
    #expect(!DC42Image.looksLikeDC42(url: widgetish))

    // Truncated, oversized and nonexistent all probe false rather than throw.
    var short = Data([4]); short.append(Data(repeating: 0, count: 40))
    #expect(!DC42Image.looksLikeDC42(url: try write(short, "short.image")))
    #expect(!DC42Image.looksLikeDC42(url: dir.appendingPathComponent("nope.image")))
}
