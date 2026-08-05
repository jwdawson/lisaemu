/// A single logged I/O-space bus access. `offset` is the low 17 bits of the
/// access -- either the offset within the flat `$FC0000-$FDFFFF` block
/// (setup mode) or the offset returned by `MMU.translate`'s `.io` case
/// (translated mode); both representations are identical (see
/// `Bus.access`). `cycles` is stamped from `Bus.cycleProvider` (Machine
/// wires this to `Machine.cycles`; defaults to a constant 0).
public struct IOAccess: Equatable {
    public let offset: UInt32
    public let value: UInt8
    public let isWrite: Bool
    public let cycles: UInt64
}

/// Handles every I/O-space register/latch access -- everything `Bus.access`
/// routes here once it has resolved a raw 17-bit I/O offset (either from
/// the flat `$FC0000-$FDFFFF` block while `Bus.setupMode == true`, or from
/// an `.io`-typed MMU segment once translation is active). SLIM/SORG MMU
/// port programming is handled directly by `Bus` instead (see
/// `Bus.slimSorgPortAccess`) because those ports are addressed per
/// 128KB segment block across the *whole* 24-bit space, not scoped to
/// IOSpace -- see docs/hardware-notes.md "Register Port Addressing".
///
/// Every address here is cited in docs/hardware-notes.md; this class is the
/// executable form of that reference.
final class IODispatcher {
    unowned let bus: Bus

    private static let ioTraceLimit = 4096
    private(set) var ioTrace: [IOAccess] = []
    private(set) var ioTraceDropped = 0

    /// $FCE800 -- video page latch (docs/hardware-notes.md "Video Latches").
    var videoPageLatch: UInt8 = 0
    /// $FCF801 -- status register low byte. Hardware-driven (bit 2 = vsync
    /// pending, M1b); CPU bus writes have no effect, but code (M1b, or
    /// tests standing in for it) can set this directly.
    var statusByte: UInt8 = 0
    /// $FCE018 / $FCE01A access counts -- "store flags, log" per the task
    /// brief; M1b will give these real vsync-interrupt semantics.
    private(set) var vsyncResetCount = 0
    private(set) var vsyncEnableCount = 0

    // VIA1 ($D801, stride 8) / VIA2 ($DC01, stride 2): 16-register logging
    // stubs. Reads default to 0; writes are stored so ROM read-back sees
    // what it wrote.
    private var via1 = [UInt8](repeating: 0, count: 16)
    private var via2 = [UInt8](repeating: 0, count: 16)

    private var contextBit1 = false
    private var contextBit2 = false

    init(bus: Bus) {
        self.bus = bus
    }

    /// A real (non-peek) read: applies any latch side effect (setup/context
    /// toggle, vsync count), returns the current value, and logs the
    /// access. Peek reads must go through a path that skips all of this --
    /// see `Bus.access`, which never calls `read`/`write` while
    /// `bus.peeking` is true, calling `currentValue` directly instead.
    func read(_ offset: UInt32) -> UInt8 {
        let value = currentValue(offset)
        applyLatch(offset)
        record(offset: offset, value: value, isWrite: false)
        return value
    }

    func write(_ offset: UInt32, _ value: UInt8) {
        if !applyLatch(offset) {
            applyNonLatchWrite(offset, value)
        }
        record(offset: offset, value: value, isWrite: true)
    }

    /// The value a read would currently return -- with NO side effects.
    /// Used both by `read` and directly by `Bus.access` for peek reads
    /// (which must observe current state without toggling any latch or
    /// logging to `ioTrace`).
    func currentValue(_ offset: UInt32) -> UInt8 {
        switch offset {
        case 0xE800: return videoPageLatch
        case 0xF801: return statusByte
        case 0xC031: return 0x00   // board ID: pre-Pepsi (0x00) until ROM trace says otherwise
        default:
            if let (via, index) = Self.viaRegisterIndex(offset) {
                return via == 1 ? via1[index] : via2[index]
            }
            // Genuinely unknown I/O-space offset (real IOSpace, $FC0000-
            // $FDFFFF, or the ROM's iospace nibble $9 -- both land here via
            // Bus's `.io` case). NOTE: translated-mode ROM access does NOT
            // route through here -- the M1a ledger's hypothesis that
            // prommmu (segment 127) uses access nibble $8 was refuted by
            // the boot trace (docs/rom-trace-notes.md OQ2): the ROM
            // actually programs segment 127 with nibble $F, which
            // `MMU.translate` now decodes as `.special`, a distinct case
            // `Bus.access` serves directly (ROM bytes / unknown-special
            // stub) before ever reaching `IODispatcher`. This default case
            // is only the real "unmapped I/O register" bucket now.
            return 0xFF
        }
    }

    /// Address-decoded setup/context latches: $E010/$E012 (setup on/off),
    /// $E008/$E00A (context bit1 off/on), $E00C/$E00E (context bit2
    /// off/on), plus the vsync counters. ANY access -- read or write --
    /// triggers these; the data byte is irrelevant
    /// (docs/hardware-notes.md "Setup Latch"/"Domain Context Latches").
    /// Returns whether `offset` was one of these (so `write` knows not to
    /// also fall into the VIA/video default-write path).
    @discardableResult
    private func applyLatch(_ offset: UInt32) -> Bool {
        switch offset {
        case 0xE010: bus._setSetupModeForTesting(true)
        case 0xE012: bus._setSetupModeForTesting(false)
        case 0xE008: contextBit1 = false; syncDomain()
        case 0xE00A: contextBit1 = true; syncDomain()
        case 0xE00C: contextBit2 = false; syncDomain()
        case 0xE00E: contextBit2 = true; syncDomain()
        case 0xE018: vsyncResetCount += 1
        case 0xE01A: vsyncEnableCount += 1
        default: return false
        }
        return true
    }

    private func applyNonLatchWrite(_ offset: UInt32, _ value: UInt8) {
        switch offset {
        case 0xE800: videoPageLatch = value
        case 0xF801, 0xC031: break   // hardware-driven; CPU writes have no effect
        default:
            if let (via, index) = Self.viaRegisterIndex(offset) {
                if via == 1 { via1[index] = value } else { via2[index] = value }
            }
            // Everything else: unknown I/O space -- write has no effect
            // beyond being logged (below).
        }
    }

    private func syncDomain() {
        bus.domain = (contextBit1 ? 1 : 0) | (contextBit2 ? 2 : 0)
    }

    private static func viaRegisterIndex(_ offset: UInt32) -> (via: Int, index: Int)? {
        if offset >= 0xD801, offset <= 0xD801 + 15 * 8, (offset - 0xD801) % 8 == 0 {
            return (1, Int((offset - 0xD801) / 8))
        }
        if offset >= 0xDC01, offset <= 0xDC01 + 15 * 2, (offset - 0xDC01) % 2 == 0 {
            return (2, Int((offset - 0xDC01) / 2))
        }
        return nil
    }

    /// Logs an access to the unknown sub-range of `.special` (prom, MMU
    /// nibble `$F`) space -- offsets `$4000-$1FFFF` within segment 127,
    /// above the 16KB ROM mirror. `hardware-notes.md §2` places the SNUM
    /// (serial number) region somewhere up here per the OS source's
    /// `iospacemmu`/`prommmu` base-address table, but no trace has reached
    /// it yet (M1b Task 1 scope is only "run past the setup-drop
    /// boundary"), so `Bus.access` calls this directly -- never through
    /// `read`/`write`, since this isn't real IOSpace-decoded hardware, just
    /// a diagnostic record of an access this emulator doesn't yet model --
    /// to log the touch for a later task's trace without applying any of
    /// the latch/VIA side effects real I/O gets.
    func logUnknownSpecial(offset: UInt32, value: UInt8, isWrite: Bool) {
        record(offset: offset, value: value, isWrite: isWrite)
    }

    private func record(offset: UInt32, value: UInt8, isWrite: Bool) {
        let access = IOAccess(offset: offset, value: value, isWrite: isWrite, cycles: bus.cycleProvider())
        if ioTrace.count < Self.ioTraceLimit {
            ioTrace.append(access)
        } else {
            ioTraceDropped += 1
        }
    }
}
