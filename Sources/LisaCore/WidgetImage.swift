import Foundation

/// A persistent Widget/ProFile hard-disk image: a RAW, headerless container
/// of `N` fixed-size blocks, each **532 bytes** = 512 data + 20 header/tag,
/// laid out contiguously `[block0: 512 data][block0: 20 tag][block1: ...]`
/// (docs/hardware-notes.md §10.10, §10.7-10.8).
///
/// ## Why raw, headerless, and write-back (the opposite of `DC42Image`)
///
/// `DC42Image` is a read-only, in-memory floppy container with an 84-byte
/// header and split data/tag planes; the floppy path deliberately never
/// mutates it, keeping writes in `FloppyController`'s per-session overlay
/// (§9). The hard disk is the persistent store, so this container is the
/// mirror image of that decision (§10.10):
///
/// - **Raw & headerless.** The Widget protocol exposes exactly data+header
///   per block (`PROFASM` `RDDATA`+`RDHDR`); a headerless raw image is the
///   least-assumption container. No DC42 header, no split planes -- block `b`
///   occupies bytes `[b*532, b*532+532)`, data first then the 20-byte tag.
/// - **Write-back, flushed per block.** Each `write(block:data:tag:)` is
///   written THROUGH to the backing file (at offset `block * 532`); `flush()`
///   fsyncs it. An installed system therefore survives across emulator
///   sessions. Flush granularity is per-block to bound data loss on an abrupt
///   exit (§10.10 "flushed per completed block write").
/// - **Blank-on-demand.** `init(createBlankAt:blockCount:)` writes an all-zero
///   `N*532` file; the emulator/tests create it (never committed). A zero
///   block reads back with a zero running-XOR checksum, which the OS driver
///   accepts as a valid unwritten block (§10.10, `PROFASM:591`).
///
/// A reference type (not a `struct` like `DC42Image`): it owns a mutable
/// backing file (a `FileHandle`) and mutates in place, so value semantics
/// would be actively wrong here.
public final class WidgetImage {
    /// Strict, typed validation errors -- same discipline as `DC42Image.Error`
    /// (reject malformed containers outright rather than silently coercing).
    public enum Error: Swift.Error, Equatable {
        /// The backing file is zero-length -- there is no block 0 to read.
        case emptyImage
        /// The backing file's size is not a whole multiple of `bytesPerBlock`
        /// (532) -- a truncated or corrupt image, rejected rather than
        /// rounded down to a partial last block.
        case sizeNotBlockAligned(size: Int, bytesPerBlock: Int)
        /// `createBlankAt` was asked for a non-positive block count.
        case invalidBlockCount(Int)
    }

    /// 512 payload bytes per block (§10.7).
    public static let dataBytesPerBlock = 512
    /// 20-byte on-disk header/tag per block (`disk_header equ 20`, LDPROF:41;
    /// §10.7). The 6522/Widget stores a real header the driver checksums, so
    /// tags are stored, not synthesized (§10.10).
    public static let tagBytes = 20
    /// 512 + 20 = 532 bytes on disk per block (§10.7-10.8, §10.10).
    public static let bytesPerBlock = dataBytesPerBlock + tagBytes
    /// Default block count = the historically documented Widget-10 geometry,
    /// 19456 blocks (§10.8; underivable-from-source, chosen representative).
    /// File size = 19456 * 532 = 10,350,592 bytes. `discsize` reported to
    /// PROF_INIT = this value; any count in `(9728, 30000]` lands the OS on
    /// the Widget path.
    public static let defaultBlockCount = 19456

    public let url: URL
    public let blockCount: Int

    /// In-memory mirror of the whole image, for O(1) reads. `write` keeps it
    /// in lockstep with the file (write-through), so a reopened image and a
    /// live one agree.
    private var storage: [UInt8]
    /// The backing file, opened for updating; `write` seeks + writes through
    /// it, `flush` fsyncs it. `nil` only after `close()`.
    private let handle: FileHandle

    /// Creates a fresh, all-zero image of `blockCount` blocks at `url`,
    /// overwriting anything already there, and opens it for read/write.
    ///
    /// - Throws: `Error.invalidBlockCount` for a non-positive count; a
    ///   Foundation file error if the file cannot be created/opened.
    public init(createBlankAt url: URL, blockCount: Int = defaultBlockCount) throws {
        guard blockCount > 0 else { throw Error.invalidBlockCount(blockCount) }
        let byteCount = blockCount * Self.bytesPerBlock
        // Zeroed file on demand (§10.10). `Data(count:)` is zero-filled.
        try Data(count: byteCount).write(to: url)
        self.url = url
        self.blockCount = blockCount
        self.storage = [UInt8](repeating: 0, count: byteCount)
        self.handle = try FileHandle(forUpdating: url)
    }

    /// Opens an existing image file, validating its size strictly.
    ///
    /// - Throws: `Error.emptyImage` for a zero-length file;
    ///   `Error.sizeNotBlockAligned` if the size is not a whole multiple of
    ///   `bytesPerBlock`; a Foundation file error if it cannot be read/opened.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 0 else { throw Error.emptyImage }
        guard data.count % Self.bytesPerBlock == 0 else {
            throw Error.sizeNotBlockAligned(size: data.count, bytesPerBlock: Self.bytesPerBlock)
        }
        self.url = url
        self.blockCount = data.count / Self.bytesPerBlock
        self.storage = [UInt8](data)
        self.handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
    }

    /// The 512-byte data payload of `block` (0-based). Traps on an
    /// out-of-range block -- a caller bug, exactly like `DC42Image.data`.
    public func data(block: Int) -> Data {
        precondition(block >= 0 && block < blockCount, "block \(block) out of range [0..<\(blockCount)]")
        let start = block * Self.bytesPerBlock
        return Data(storage[start..<(start + Self.dataBytesPerBlock)])
    }

    /// The 20-byte header/tag of `block` (0-based). Traps on an out-of-range
    /// block.
    public func tag(block: Int) -> Data {
        precondition(block >= 0 && block < blockCount, "block \(block) out of range [0..<\(blockCount)]")
        let start = block * Self.bytesPerBlock + Self.dataBytesPerBlock
        return Data(storage[start..<(start + Self.tagBytes)])
    }

    /// Writes `data` (512 bytes) + `tag` (20 bytes) to `block`, through to the
    /// backing file (write-back persistence, §10.10). Traps on an
    /// out-of-range block or a wrong-sized `data`/`tag` -- both caller bugs
    /// (`WidgetDrive` validates block range against `blockCount` and always
    /// supplies exactly 512/20 bytes before calling this).
    ///
    /// - Throws: a Foundation file error if the write fails.
    public func write(block: Int, data: Data, tag: Data) throws {
        precondition(block >= 0 && block < blockCount, "block \(block) out of range [0..<\(blockCount)]")
        precondition(data.count == Self.dataBytesPerBlock, "data must be \(Self.dataBytesPerBlock) bytes, got \(data.count)")
        precondition(tag.count == Self.tagBytes, "tag must be \(Self.tagBytes) bytes, got \(tag.count)")

        let start = block * Self.bytesPerBlock
        storage.replaceSubrange(start..<(start + Self.dataBytesPerBlock), with: data)
        storage.replaceSubrange((start + Self.dataBytesPerBlock)..<(start + Self.bytesPerBlock), with: tag)

        try handle.seek(toOffset: UInt64(start))
        handle.write(Data(data) + Data(tag))
    }

    /// Flushes buffered writes to stable storage (fsync). Called per completed
    /// block write by `WidgetDrive` (§10.10 "flushed per completed block
    /// write").
    public func flush() throws {
        try handle.synchronize()
    }
}
