import Foundation

/// Represents a DC42 disk image in memory (read-only).
///
/// DC42 is the standard disk image format used for Lisa floppies and hard drives.
/// The format consists of an 84-byte header, followed by a data plane (512 bytes per block),
/// and a tag plane (12 bytes per block).
///
/// Header layout (84 bytes):
/// - Bytes 0-63: Image name as Pascal string (length byte + name)
/// - Bytes 64-67: Data length in bytes (big-endian UInt32)
/// - Bytes 68-71: Tag length in bytes (big-endian UInt32)
/// - Bytes 72-79: Checksums (reserved for future use)
/// - Bytes 80-83: Format bytes (reserved for future use)
///
/// For a standard 400KB floppy:
/// - Data length: 409,600 bytes (800 blocks × 512 bytes)
/// - Tag length: 9,600 bytes (800 blocks × 12 bytes)
///
/// ## Tagless containers
///
/// Some DC42 containers in the wild -- commonly ones sourced from Mac disks
/// rather than Lisa disks, which is exactly what drag-and-drop invites --
/// carry `tagLen == 0`: a valid container with no tag plane at all. This
/// type accepts those: `init(data:)` synthesizes an all-zero tag plane
/// (`blockCount * 12` bytes) so every other API behaves exactly as if a
/// real, all-zero tag plane had been read from the container -- `tag(block:)`
/// never traps. Zero tags read as "no filesystem metadata" to the Lisa FS;
/// the ROM's read path itself just copies tag bytes through regardless of
/// content, so a tagless image inserts and reads back fine here, and the
/// Lisa-side boot fails benignly (not a crash) if it needed real tags. Any
/// OTHER tag length -- nonzero but not exactly `blockCount * 12` -- is
/// rejected as a malformed container (``Error/tagLengthMismatch(expected:found:)``),
/// not silently coerced.
public struct DC42Image {
    public enum Error: Swift.Error, Equatable {
        /// Container header is too short.
        case headerTooShort
        /// Container size does not match expected header dimensions (too small or has trailing garbage).
        case sizeMismatch(expected: Int, found: Int)
        /// Header's data length is not a whole multiple of 512 bytes, so it
        /// cannot be divided into an integral number of blocks.
        case dataLengthNotBlockAligned(Int)
        /// Header's tag length is neither 0 (tagless -- see the type doc
        /// comment "Tagless containers") nor exactly `blockCount * 12`.
        case tagLengthMismatch(expected: Int, found: Int)
    }

    private let dataPlane: [UInt8]
    private let tagPlane: [UInt8]

    /// Initializes a DC42Image from raw container data.
    ///
    /// Validates the container format strictly by checking:
    /// - Header is at least 84 bytes
    /// - Data length is a whole multiple of 512 bytes
    /// - Tag length is either 0 (tagless -- see the type doc comment
    ///   "Tagless containers"; a zero tag plane is synthesized) or exactly
    ///   `blockCount * 12`
    /// - Container size matches exactly: header (84) + data + tag planes
    ///   (rejects truncated or corrupted images with trailing garbage)
    ///
    /// - Parameter data: Raw container bytes (header + data plane + tag plane, exact size)
    /// - Throws: ``Error`` if validation fails
    public init(data: Data) throws {
        // Minimum header size is 84 bytes
        guard data.count >= 84 else {
            throw Error.headerTooShort
        }

        // Read data length from offset 64 (big-endian UInt32)
        let dataLenBytes = data.subdata(in: 64..<68)
        let expectedDataLen = Int(UInt32(bigEndian: dataLenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

        // Read tag length from offset 68 (big-endian UInt32)
        let tagLenBytes = data.subdata(in: 68..<72)
        let expectedTagLen = Int(UInt32(bigEndian: tagLenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

        // Data length must divide evenly into 512-byte blocks -- blockCount
        // (and therefore the tag-length check just below) is meaningless
        // otherwise.
        guard expectedDataLen % 512 == 0 else {
            throw Error.dataLengthNotBlockAligned(expectedDataLen)
        }
        let blockCount = expectedDataLen / 512

        // Tag length must be either 0 (tagless container -- a zero tag plane
        // is synthesized below, see the type doc comment "Tagless
        // containers") or exactly one 12-byte tag per block. Anything else
        // is a malformed/corrupt container, rejected outright rather than
        // silently truncated or padded.
        guard expectedTagLen == 0 || expectedTagLen == blockCount * 12 else {
            throw Error.tagLengthMismatch(expected: blockCount * 12, found: expectedTagLen)
        }

        // Container must be exactly: header + data plane + tag plane
        // Rejects both truncation and trailing garbage.
        let expectedTotalSize = 84 + expectedDataLen + expectedTagLen
        guard data.count == expectedTotalSize else {
            throw Error.sizeMismatch(expected: expectedTotalSize, found: data.count)
        }

        // Extract data plane
        let dataStart = 84
        let dataEnd = dataStart + expectedDataLen
        let actualDataPlane = [UInt8](data.subdata(in: dataStart..<dataEnd))

        // Extract tag plane -- or synthesize an all-zero one for a tagless
        // container (expectedTagLen == 0), so `tag(block:)` never traps on
        // an empty plane. See the type doc comment "Tagless containers".
        let actualTagPlane: [UInt8]
        if expectedTagLen == 0 {
            actualTagPlane = [UInt8](repeating: 0, count: blockCount * 12)
        } else {
            let tagStart = dataEnd
            let tagEnd = tagStart + expectedTagLen
            actualTagPlane = [UInt8](data.subdata(in: tagStart..<tagEnd))
        }

        self.dataPlane = actualDataPlane
        self.tagPlane = actualTagPlane
    }

    /// Number of 512-byte blocks in the data plane.
    public var blockCount: Int {
        dataPlane.count / 512
    }

    /// Retrieves the 512-byte data for a given block.
    ///
    /// Returns a zero-based array that can be safely indexed with subscripts 0..<512.
    ///
    /// - Parameter block: Block index (0-based)
    /// - Returns: 512-byte array copy of the block data
    /// - Precondition: `block` must be in range `0..<blockCount`
    public func data(block: Int) -> [UInt8] {
        precondition(block >= 0 && block < blockCount, "block \(block) out of range [0..<\(blockCount)]")
        let start = block * 512
        let end = start + 512
        return Array(dataPlane[start..<end])
    }

    /// Retrieves the 12-byte tag for a given block.
    ///
    /// Returns a zero-based array that can be safely indexed with subscripts 0..<12.
    ///
    /// - Parameter block: Block index (0-based)
    /// - Returns: 12-byte array copy of the block tag
    /// - Precondition: `block` must be in range `0..<blockCount`
    public func tag(block: Int) -> [UInt8] {
        precondition(block >= 0 && block < blockCount, "block \(block) out of range [0..<\(blockCount)]")
        let start = block * 12
        let end = start + 12
        return Array(tagPlane[start..<end])
    }

    /// Cheap CONTENT probe: does the file at `url` look like a DC42
    /// container? Reads only the 84-byte header and checks the declared
    /// plane sizes against the file's actual length -- it never loads the
    /// data plane, so probing a 10MB Widget image costs one small read.
    ///
    /// Exists because `.image` is the classic Disk Copy 4.2 extension AND
    /// the extension this project's Widget hard-disk images use, so the
    /// extension alone cannot tell a floppy from a hard disk. Applies
    /// exactly the same size arithmetic `init(data:)` does, so a file this
    /// returns `true` for is one `init(data:)` will accept (barring I/O
    /// failure); `false` means "don't bother", never "definitely invalid".
    ///
    /// Returns `false` for anything unreadable, so a caller can treat it as
    /// a pure predicate.
    public static func looksLikeDC42(url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size >= 84,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 84), header.count == 84 else { return false }

        let dataLen = Int(UInt32(bigEndian: header.subdata(in: 64..<68).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let tagLen = Int(UInt32(bigEndian: header.subdata(in: 68..<72).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard dataLen > 0, dataLen % 512 == 0 else { return false }
        let blockCount = dataLen / 512
        guard tagLen == 0 || tagLen == blockCount * 12 else { return false }
        return 84 + dataLen + tagLen == size
    }

    /// Loads a DC42 image from a file URL.
    ///
    /// - Parameter url: File URL pointing to the DC42 image file
    /// - Returns: A new ``DC42Image`` instance
    /// - Throws: File I/O errors or ``Error`` if validation fails
    public static func load(url: URL) throws -> DC42Image {
        let data = try Data(contentsOf: url)
        return try DC42Image(data: data)
    }
}
