/// Convenience access-type tags for `SegmentRegister.make`. These map
/// directly onto the SLIM access nibble (`do_an_mmu`/`ReadMMU`; see
/// docs/hardware-notes.md §1) -- they exist only to make test/call-site code
/// readable; the hardware itself has no such enum, only the raw nibble.
public enum SegmentAccessKind: Equatable {
    case readOnly   // $5
    case stack      // $6
    case readWrite  // $7
    case io         // $8
}

/// A hardware MMU segment register pair, exactly as `ReadMMU`/`WriteMMU`
/// see it (LIBHW/libhw-MACHINE.TEXT.unix.txt:611-685): two 12-bit raw
/// registers, SORG (origin, in 512-byte pages) and SLIM (access nibble in
/// bits 11-8, limit byte in bits 7-0). Both are masked to 12 bits on every
/// set, matching the real hardware's `AND.W #$0FFF`.
public struct SegmentRegister: Equatable {
    private var _sorg: UInt16 = 0
    private var _slim: UInt16 = 0

    public var sorg: UInt16 {
        get { _sorg }
        set { _sorg = newValue & 0x0FFF }
    }
    public var slim: UInt16 {
        get { _slim }
        set { _slim = newValue & 0x0FFF }
    }

    public init(sorg: UInt16 = 0, slim: UInt16 = 0) {
        self.sorg = sorg
        self.slim = slim
    }

    /// Builds a raw SORG/SLIM pair from friendlier terms, for tests and
    /// M0-era call sites. `originPage` is the raw SORG value (the physical
    /// page, in 512-byte pages, that address decode is anchored to -- see
    /// `MMU.translate`'s uniform `physical = (sorg << 9) + offset` formula,
    /// which applies identically to stack segments once SORG already holds
    /// the hardware-adjusted value). `limitPages` is 1...256.
    ///
    /// Encoding of `limitPages` into SLIM's low byte differs by access type,
    /// per `do_an_mmu` (LDASM:403-425):
    ///   - readOnly/readWrite/io: two's-complement page count, `0x100 -
    ///     limitPages` (so 256 pages encodes as byte 0).
    ///   - stack: direct `limitPages - 1` (do_an_mmu stores `length - 1`
    ///     after its origin adjustment, NOT a two's-complement count).
    public static func make(originPage: UInt16, limitPages: Int, access: SegmentAccessKind) -> SegmentRegister {
        precondition((1...256).contains(limitPages), "limitPages must be 1...256")
        let nibble: UInt16
        let limitByte: UInt16
        switch access {
        case .readOnly:
            nibble = 0x5
            limitByte = UInt16((0x100 - limitPages) & 0xFF)
        case .stack:
            nibble = 0x6
            limitByte = UInt16((limitPages - 1) & 0xFF)
        case .readWrite:
            nibble = 0x7
            limitByte = UInt16((0x100 - limitPages) & 0xFF)
        case .io:
            nibble = 0x8
            limitByte = UInt16((0x100 - limitPages) & 0xFF)
        }
        return SegmentRegister(sorg: originPage, slim: (nibble << 8) | limitByte)
    }
}

public struct MMUFault: Error, Equatable {
    public enum Reason: Equatable { case invalidSegment, limitViolation, writeToReadOnly }
    public let logical: UInt32
    public let reason: Reason
    public init(logical: UInt32, reason: Reason) {
        self.logical = logical; self.reason = reason
    }
}

/// Result of `MMU.translate`. `.io` is distinct from `.memory` because I/O
/// segments (SLIM access nibble $8, and the ROM-discovered nibble $9 --
/// docs/rom-trace-notes.md OQ2) route to the IODispatcher rather than RAM.
/// `.special` (nibble $F) is the ROM's own prom/special-space decode,
/// carrying the offset within the 128KB segment; `Bus` routes it to ROM
/// bytes / an unknown-special stub rather than either `.memory` or `.io`
/// (see `Bus.access`'s doc comment).
public enum Translation: Equatable {
    case memory(UInt32)
    case io(UInt32)
    case special(UInt32)
    case fault(MMUFault)
}

public struct MMU {
    public static let segmentSize: UInt32 = 0x2_0000   // 128 KB (OS: maxmmusize)
    public var domains: [[SegmentRegister]] =
        Array(repeating: Array(repeating: SegmentRegister(), count: 128), count: 4)

    /// Translates a logical address through the given domain's segment map,
    /// decoding the raw SORG/SLIM registers exactly as `do_an_mmu`/`ReadMMU`
    /// do (docs/hardware-notes.md §1):
    ///
    ///   - `accessNibble = (slim >> 8) & 0xF`: $5 readOnly, $6 stack,
    ///     $7 readWrite, $8 io. Any other nibble (including $C, the
    ///     hardware's own "absent" code) is absent -> `.invalidSegment` --
    ///     EXCEPT the two ROM-discovered nibbles below.
    ///   - $9 (iospace) and $F (prom/special) are hardwired special-space
    ///     decodes the Rev H boot ROM itself programs (seg126 SLIM=$901,
    ///     seg127 SLIM=$F00 at $FE0118/$FE0120 -- docs/rom-trace-notes.md
    ///     OQ2), not page-limited memory-type windows like $5/$6/$7/$8:
    ///     modeled as FULL-SEGMENT, limit byte ignored entirely. $9 routes
    ///     to `.io` (identically to $8); $F routes to the new `.special`.
    ///     docs/hardware-notes.md §1 documents both as newly-observed,
    ///     absent from the OS source's `do_an_mmu` constant set.
    ///   - Page size is 512 bytes; a segment spans 256 pages (128 KB).
    ///   - readOnly/readWrite/io: `limitPages = (0x100 - (slim & 0xFF)) &
    ///     0xFF`, with a result of 0 meaning 256 pages (two's-complement
    ///     page count, LDASM:414). Valid while `pageOffset < limitPages`.
    ///   - stack: `limitPages = (slim & 0xFF) + 1` (1...256) -- a DIRECT
    ///     count, not two's-complement. See the derivation below.
    ///   - Physical address is `((sorg & 0xFFF) << 9 + offsetWithinSegment)
    ///     & 0x1F_FFFF` for every mapped type (memory and stack alike); `io`
    ///     returns the bare offset instead (`.io(offset:)`) for the
    ///     IODispatcher. The `& 0x1F_FFFF` is load-bearing, not cosmetic:
    ///     the physical page number the hardware forms is
    ///     `(SORG + pageWithinSegment)` truncated to SORG's 12-bit register
    ///     width, so it WRAPS modulo 4096 pages -- a 21-bit / 2 MB physical
    ///     space. The OS loader relies on this: `initmmutil` (LDASM:174-252)
    ///     programs `mmucodemmu` (seg 84) with a *negative* origin page
    ///     `SORG = (utiladr>>9) - 32` (for `utiladr=$800`, page `-28` = the
    ///     12-bit value `$FE4`), points TRAP #6's vector at
    ///     `mmusegorg+bit_14 = $A84000`, and expects that virtual address to
    ///     decode back to physical `$800` where it copied `do_an_mmu`:
    ///     `(-28 + 32) mod 4096 = 4` -> `$800`. WITHOUT the wrap the same
    ///     access lands at `$FE4<<9 + $4000 = $200800`, past 2 MB, and the
    ///     first inter-segment call gate fetches garbage -- the M3 Task 1
    ///     gate. See docs/rom-trace-notes.md "Gate diagnosis (M3 Task 1)".
    ///
    /// ### Stack window derivation
    ///
    /// `do_an_mmu`'s stack case (LDASM:403-412) transforms the *software*
    /// SMT origin/length into the *hardware* SORG/SLIM it programs:
    /// ```
    /// if length == 0: length := 256          ; max_seg
    /// origin := origin + length - $100        ; hw_adjust
    /// length := length - 1                    ; stored as SLIM's low byte
    /// ```
    /// So the raw SORG register this code decodes is already
    /// `origin_smt + length - 256`, and SLIM's low byte is already
    /// `length - 1` (hence the direct, non-two's-complement decode above).
    ///
    /// Substituting `sorg = origin_smt + length - 256` into the uniform
    /// physical formula `physical = (sorg << 9) + offset`:
    ///   - at `offset = (256 - length) * 512` (the LOWEST offset for which
    ///     `pageOffset >= 256 - length` holds): `physical = origin_smt *
    ///     512` -- the true start of the backing RAM.
    ///   - at `offset = 0x1FFFF` (top of the 128 KB segment): `physical =
    ///     origin_smt * 512 + length * 512 - 1` -- the end of that same
    ///     `length`-page RAM window.
    ///
    /// So the `length`-page backing RAM is mapped into the TOP `length`
    /// pages of the 256-page logical segment; the bottom `256 - length`
    /// pages are unbacked. That is the grow-down shape: a stack pointer
    /// starts near the top of the segment and descends toward (and must
    /// stay within) the backing region, exactly like `limitPages` bytes of
    /// real stack sitting at the high end of a 128 KB window.
    ///
    /// - Parameter isSupervisor: Carries the CPU's current supervisor/user
    ///   mode. No supervisor-conditional rule is enforced yet -- the
    ///   parameter exists so M1b hardware rules can be added without another
    ///   signature change; behavior is currently identical regardless of its
    ///   value.
    public func translate(_ logical: UInt32, domain: Int,
                          isSupervisor: Bool, isWrite: Bool) -> Translation {
        let addr = logical & 0xFF_FFFF
        let seg = Int(addr >> 17)
        let offsetInSegment = addr & (Self.segmentSize - 1)
        let pageOffset = Int(offsetInSegment >> 9)
        let r = domains[domain][seg]
        let nibble = (r.slim >> 8) & 0xF
        let limitByte = Int(r.slim & 0xFF)

        switch nibble {
        case 0x5, 0x7, 0x8:   // readOnly, readWrite, io
            if nibble == 0x5 && isWrite {
                return .fault(MMUFault(logical: addr, reason: .writeToReadOnly))
            }
            let raw = (0x100 - limitByte) & 0xFF
            let limitPages = raw == 0 ? 256 : raw
            guard pageOffset < limitPages else {
                return .fault(MMUFault(logical: addr, reason: .limitViolation))
            }
            if nibble == 0x8 {
                return .io(offsetInSegment)
            }
            return .memory(((UInt32(r.sorg & 0xFFF) << 9) &+ offsetInSegment) & 0x1F_FFFF)
        case 0x6:   // stack
            let limitPages = limitByte + 1
            guard pageOffset >= (0x100 - limitPages) else {
                return .fault(MMUFault(logical: addr, reason: .limitViolation))
            }
            return .memory(((UInt32(r.sorg & 0xFFF) << 9) &+ offsetInSegment) & 0x1F_FFFF)
        case 0x9, 0xF:
            // iospace ($9) / prom-special ($F): ROM-discovered hardwired
            // decodes, not limit-checked memory windows (see the doc
            // comment above). The ROM's own programmed limit bytes ($01 for
            // $901, $00 for $F00) are not treated as page counts here --
            // full 128KB segment, unconditionally.
            return nibble == 0x9 ? .io(offsetInSegment) : .special(offsetInSegment)
        default:    // $C (absent) and every other unassigned nibble
            return .fault(MMUFault(logical: addr, reason: .invalidSegment))
        }
    }
}
