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
    /// $FCF801 -- status register low byte, bits OTHER than bit 2 (vsync
    /// pending). CPU bus writes have no effect (hardware-driven register);
    /// tests can still set this directly to simulate an undetermined bit.
    /// Bit 2 itself is no longer stored here as of Task 5 -- it is owned by
    /// `videoTiming.pending` and OR'd in by `currentValue` below, since
    /// `VideoTiming` is now the sole real driver of that bit. `hardware-
    /// notes.md §5`: "bit1 meaning undetermined -- only bit2=vsync is
    /// documented".
    var statusByte: UInt8 = 0
    /// $FCE018 / $FCE01A access counts -- diagnostic-only now that Task 5
    /// gives these real semantics via `videoTiming.handleVertResetAccess`/
    /// `handleVertEnableAccess` (called alongside these counters below).
    private(set) var vsyncResetCount = 0
    private(set) var vsyncEnableCount = 0

    // VIA1 ($D901, stride 8) / VIA2 ($DD81, stride 2) -- ROM-observed bases
    // (docs/hardware-notes.md §3, docs/rom-trace-notes.md "Beyond the M1a
    // boundary"; the historical $D801/$DC01 OS-source equates are refuted
    // for the Rev H boot path). `let`, not `private`, so `Bus` can expose
    // them to `Machine` for timer ticking and IRQ-level computation (see
    // `Bus.via1`/`Bus.via2`) -- these two real 6522 register files are the
    // Task 3 replacement for the old dumb 16-byte logging stubs.
    let via1 = VIA6522()
    let via2 = VIA6522()

    /// HLE keyboard/mouse/clock/power-management microcontroller (Task 4),
    /// reachable only through VIA2 -- see `COPS`'s type doc comment for the
    /// full protocol (and the CRDY-lives-on-Port-B correction to
    /// hardware-notes.md §4).
    let cops: COPS

    /// Vsync timing source (Task 5) -- see `VideoTiming`'s type doc comment.
    /// Owned here like `cops`, wired to `Bus.scheduleEvent`/
    /// `Bus.vsyncInterruptHandler`.
    let videoTiming: VideoTiming

    /// HLE floppy controller (Task 4) -- see `FloppyController`'s type doc
    /// comment. Owns the `$C000-$C7FF` shared-RAM window and VIA2 PORTB2
    /// bit 4 (completion line), composed into `via2.portBInput` below
    /// alongside `cops`'s own bit 6 (CRDY).
    let floppy: FloppyController

    private var contextBit1 = false
    private var contextBit2 = false

    init(bus: Bus) {
        self.bus = bus
        // `via2` (not `self`) captured below -- `self` cannot escape into a
        // closure until every stored property (including `cops`, being
        // computed right here) has a value; `via2` itself is already fully
        // initialized (its own default initializer ran before this body).
        let via2Ref = via2
        cops = COPS(
            scheduleEvent: { [weak bus] delay, action in bus?.scheduleEvent(delay, action) },
            currentCycle: { [weak bus] in bus?.cycleProvider() ?? 0 },
            raiseInterrupt: { [weak via2Ref] in via2Ref?.setInterruptFlag(COPS.interruptFlagBit) },
            clearInterrupt: { [weak via2Ref] in via2Ref?.clearInterruptFlag(COPS.interruptFlagBit) }
        )
        // `videoTiming` doesn't capture `self` (only `bus`, weakly), so --
        // unlike the `via2.onPortAAccess` closure just below -- it could in
        // principle be assigned anywhere after `cops`. It's placed here,
        // still before `self` escapes into anything, purely to keep every
        // stored-property assignment together before the first
        // `self`-capturing closure (Swift's definite-initialization rule:
        // ALL stored properties must have a value before `self` can be
        // captured by any closure, even one that itself doesn't touch
        // `videoTiming`).
        videoTiming = VideoTiming(
            scheduleEvent: { [weak bus] delay, action in bus?.scheduleEvent(delay, action) },
            setIRQPending: { [weak bus] pending in bus?.vsyncInterruptHandler(pending) }
        )
        // Same reasoning as `videoTiming` above: no `self` capture yet.
        floppy = FloppyController(
            scheduleEvent: { [weak bus] delay, action in bus?.scheduleEvent(delay, action) },
            setLevel1Pending: { [weak bus] pending in bus?.floppyInterruptHandler(pending) }
        )
        // `self` is fully initialized as of the line above -- safe to
        // capture from here on.
        via2.portAInput = cops.portAInput
        via2.portBInput = { [weak self] in
            guard let self else { return 0xFF }
            var value = self.cops.portBInput()
            if self.floppy.completionLineAsserted {
                value |= 0x10   // VIA2 PORTB2 bit 4 -- see FloppyController's
                                 // "Completion line polarity" doc comment.
            } else {
                value &= ~0x10
            }
            return value
        }
        via2.onPortAAccess = { [weak self] index, value, isWrite in
            self?.cops.handlePortAAccess(index: index, value: value, isWrite: isWrite)
        }
    }

    /// A real (non-peek) read: applies any latch side effect (setup/context
    /// toggle, vsync count) for non-VIA offsets, returns the current value,
    /// and logs the access. Peek reads must go through a path that skips
    /// all of this -- see `Bus.access`, which never calls `read`/`write`
    /// while `bus.peeking` is true, calling `currentValue` directly
    /// instead. VIA registers route to `VIA6522.read(_:)`, which HAS side
    /// effects of its own (e.g. reading T1CL clears IFR6) -- that is
    /// exactly the point of splitting this from `currentValue` below, which
    /// stays side-effect-free for the peek path.
    func read(_ offset: UInt32) -> UInt8 {
        let value: UInt8
        if let (via, index) = Self.viaRegisterIndex(offset) {
            value = viaInstance(via).read(index)
        } else {
            value = currentValue(offset)
            applyLatch(offset)
        }
        record(offset: offset, value: value, isWrite: false)
        return value
    }

    func write(_ offset: UInt32, _ value: UInt8) {
        if let (via, index) = Self.viaRegisterIndex(offset) {
            viaInstance(via).write(index, value)
        } else if !applyLatch(offset) {
            applyNonLatchWrite(offset, value)
        }
        record(offset: offset, value: value, isWrite: true)
    }

    /// The value a read would currently return -- with NO side effects.
    /// Used both by `Bus.access` for peek reads (which must observe current
    /// state without toggling any latch, mutating any VIA register, or
    /// logging to `ioTrace`) and internally by `read` for the non-VIA
    /// offsets that have no read side effect of their own beyond the
    /// address-decoded latches `read` applies afterward. VIA offsets route
    /// to `VIA6522.peek(_:)`, the side-effect-free twin of `VIA6522.read`
    /// -- see that method's doc comment for why a peek must never reach
    /// `VIA6522.read` directly (T1CL/T2CL reads clear IFR bits on real
    /// hardware).
    func currentValue(_ offset: UInt32) -> UInt8 {
        switch offset {
        case 0xE800: return videoPageLatch
        case 0xF801: return statusByte | (videoTiming.pending ? 0x04 : 0)
        case 0xC031: return 0x00   // board ID: pre-Pepsi (0x00) until ROM trace says otherwise
        // $FCC015 (adr_intdisk, docs/hardware-notes.md §9 "Board IDs"):
        // 0=twiggy, 1=single-sided Sony, 2=double-sided Sony. Task 4 moves
        // this from unknown-I/O (0xFF) to 1 -- matches the 400K install
        // disks this HLE controller serves; Task 5 validates against the
        // boot path with trace evidence. Checked BEFORE the $C000-$C7FF
        // window case below since $C015 falls inside that range but is a
        // distinct hardware register, not one of FloppyController's named
        // protocol cells.
        case 0xC015: return 1
        // FloppyController's 2KB shared-RAM window (docs/hardware-notes.md
        // §9), Task 4. Checked after the two explicit board-ID cases above.
        case 0xC000...0xC7FF: return floppy.read(Int(offset - 0xC000))
        default:
            if let (via, index) = Self.viaRegisterIndex(offset) {
                return viaInstance(via).peek(index)
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
        case 0xE018: vsyncResetCount += 1; videoTiming.handleVertResetAccess()
        case 0xE01A: vsyncEnableCount += 1; videoTiming.handleVertEnableAccess()
        default: return false
        }
        return true
    }

    /// VIA writes are handled directly in `write` above (before this is
    /// ever reached), so this only covers the remaining non-latch,
    /// non-VIA offsets.
    private func applyNonLatchWrite(_ offset: UInt32, _ value: UInt8) {
        switch offset {
        case 0xE800: videoPageLatch = value
        case 0xF801, 0xC031, 0xC015: break   // hardware-driven; CPU writes have no effect
        case 0xC000...0xC7FF: floppy.write(Int(offset - 0xC000), value)
        default: break   // unknown I/O space -- write has no effect beyond being logged
        }
    }

    private func syncDomain() {
        bus.domain = (contextBit1 ? 1 : 0) | (contextBit2 ? 2 : 0)
    }

    /// Clears both domain-context latch bits and recomputes `bus.domain`
    /// back to 0 -- the M2 Task 2 warm-reset counterpart to the
    /// address-decoded $E008/$E00A/$E00C/$E00E handlers in `applyLatch`
    /// above, called directly (not via a synthetic bus access) since a
    /// hardware reset re-asserts these lines without the CPU issuing any
    /// bus cycle. `Bus.resetSetupAndContextLatches()` is the sole caller.
    func resetContextLatches() {
        contextBit1 = false
        contextBit2 = false
        syncDomain()
    }

    private func viaInstance(_ via: Int) -> VIA6522 {
        via == 1 ? via1 : via2
    }

    /// ROM-observed bases (docs/hardware-notes.md §3): VIA1 = `$D901`,
    /// stride ×8; VIA2 = `$DD81`, stride ×2. The historical OS-source
    /// equates ($D801/$DC01) are refuted for the Rev H boot path -- see
    /// docs/rom-trace-notes.md "Beyond the M1a boundary".
    private static func viaRegisterIndex(_ offset: UInt32) -> (via: Int, index: Int)? {
        if offset >= 0xD901, offset <= 0xD901 + 15 * 8, (offset - 0xD901) % 8 == 0 {
            return (1, Int((offset - 0xD901) / 8))
        }
        if offset >= 0xDD81, offset <= 0xDD81 + 15 * 2, (offset - 0xDD81) % 2 == 0 {
            return (2, Int((offset - 0xDD81) / 2))
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
