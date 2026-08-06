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
public struct DC42Image {
    public enum Error: Swift.Error, Equatable {
        /// Container header is too short.
        case headerTooShort
        /// Container size does not match expected header dimensions (too small or has trailing garbage).
        case sizeMismatch(expected: Int, found: Int)
    }

    private let dataPlane: [UInt8]
    private let tagPlane: [UInt8]

    /// Initializes a DC42Image from raw container data.
    ///
    /// Validates the container format strictly by checking:
    /// - Header is at least 84 bytes
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

        // Extract tag plane
        let tagStart = dataEnd
        let tagEnd = tagStart + expectedTagLen
        let actualTagPlane = [UInt8](data.subdata(in: tagStart..<tagEnd))

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
