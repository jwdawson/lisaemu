import Foundation

/// Loads and interleaves the two 8KB Lisa boot-ROM chip images into the
/// single 16KB byte stream `Bus.loadROM` expects.
public enum ROMImage {
    public enum Error: Swift.Error, Equatable {
        /// `even`/`odd` were not the same length.
        case lengthMismatch(even: Int, odd: Int)
    }

    /// Interleaves two same-length ROM chip dumps into one big-endian
    /// 68000 byte stream: output byte `i` is `even[i/2]` when `i` is even,
    /// `odd[i/2]` when `i` is odd. Throws `.lengthMismatch` if the two
    /// inputs are not the same length (the real chips are always 8KB each,
    /// giving a 16KB result, but this function only requires equal
    /// lengths so small synthetic halves are easy to test with).
    ///
    /// Lane order verified empirically (Task 6) against the real Lisa boot
    /// ROM (`341-0175-H.BIN` / `341-0176-H.BIN`, 8KB each): `341-0175-H`
    /// ("even") supplies the *high* byte of each big-endian word, and
    /// `341-0176-H` ("odd") supplies the *low* byte. Confirmed by checking
    /// the reset vector at the start of the interleaved image (first 4
    /// bytes = initial SSP, next 4 = initial PC):
    ///
    ///   - `even`=0175 high / `odd`=0176 low (this order): SSP=`$00000480`
    ///     (a plausible low-RAM stack pointer) and PC=`$00FE00F6`, which
    ///     masks to the 24-bit address `$FE00F6` -- squarely inside the ROM
    ///     window/mirror (`$FE0000-$FE3FFF`). The interleave also contains
    ///     the ASCII landmark string `"SERVICE MODE"` (at offset `0x52`).
    ///   - The swapped order (0176 high / 0175 low) instead produces
    ///     SSP=`$00008004` and PC=`$FE00F600`, which masks to `$00F600` --
    ///     nowhere near the ROM window -- garbage, and does not contain
    ///     "SERVICE MODE" anywhere. So the order documented above (and
    ///     implemented below) is the verified-correct one.
    public static func interleave(even: Data, odd: Data) throws -> [UInt8] {
        guard even.count == odd.count else {
            throw Error.lengthMismatch(even: even.count, odd: odd.count)
        }
        let evenBytes = [UInt8](even)
        let oddBytes = [UInt8](odd)
        var out = [UInt8](repeating: 0, count: evenBytes.count * 2)
        for i in 0..<evenBytes.count {
            out[2 * i] = evenBytes[i]
            out[2 * i + 1] = oddBytes[i]
        }
        return out
    }

    /// Reads `341-0175-H.BIN` and `341-0176-H.BIN` from `directory` and
    /// interleaves them per `interleave(even:odd:)`. Real ROM binaries are
    /// never checked into this repo; callers point `directory` at a local
    /// copy (see `LISAEMU_ROM_DIR` in the test suite / `lisadbg --rom`).
    public static func load(directory: URL) throws -> [UInt8] {
        let even = try Data(contentsOf: directory.appendingPathComponent("341-0175-H.BIN"))
        let odd = try Data(contentsOf: directory.appendingPathComponent("341-0176-H.BIN"))
        return try interleave(even: even, odd: odd)
    }
}
