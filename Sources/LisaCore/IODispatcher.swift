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

    /// HLE Widget/ProFile parallel hard disk (M5 Task 2) -- see
    /// `WidgetDrive`'s type doc comment. Attached behind VIA1 (the Hard Disk
    /// VIA): Port A (data bus) via `via1.portAInput`/`onPortAAccess`, Port B
    /// (BSY/DISCONNECT status + CMD/DIR strobe) via `via1.portBInput` and the
    /// Port-B write forward in `write` below. Detached by default, so it
    /// changes nothing on the no-widget boot path (docs/hardware-notes.md
    /// §10.9). Its completion interrupt is VIA1 IFR bit 1 (level 1, §10.2).
    let widget: WidgetDrive

    private var contextBit1 = false
    private var contextBit2 = false

    /// VIA1 IFR bit 1 -- the CB-latched BSY/completion interrupt the Widget
    /// raises on command completion (docs/hardware-notes.md §10.2). Level 1
    /// via `bus.via1.irqAsserted`, the same path VIA1 timers use.
    private static let widgetInterruptFlagBit: UInt8 = 0x02

    init(bus: Bus) {
        self.bus = bus
        // `via2`/`via1` (not `self`) captured below -- `self` cannot escape
        // into a closure until every stored property (including `cops`/
        // `widget`, being computed right here) has a value; the VIA instances
        // are already fully initialized (their default initializers ran
        // before this body).
        let via2Ref = via2
        let via1Ref = via1
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
        // Widget HLE on VIA1 -- completion interrupt is VIA1 IFR bit 1
        // (§10.2), raised/cleared on the same `via1` instance the register
        // windows route to. No `self` capture yet (same DI reasoning as
        // `videoTiming`/`floppy` above).
        widget = WidgetDrive(
            scheduleEvent: { [weak bus] delay, action in bus?.scheduleEvent(delay, action) },
            raiseInterrupt: { [weak via1Ref] in via1Ref?.setInterruptFlag(Self.widgetInterruptFlagBit) },
            clearInterrupt: { [weak via1Ref] in via1Ref?.clearInterruptFlag(Self.widgetInterruptFlagBit) }
        )
        // `self` is fully initialized as of the line above -- safe to
        // capture from here on.
        via2.portAInput = cops.portAInput
        // VIA1 Port A/B carry the Widget parallel data bus + status (§10.2).
        // Detached, these read as an idle pulled-up bus, unchanged from the
        // pre-M5 default -- see `WidgetDrive`'s "Default = detached" note.
        via1.portAInput = { [weak self] in self?.widget.portAInput ?? 0xFF }
        via1.portBInput = { [weak self] in self?.widget.portBInput ?? 0xFF }
        via1.onPortAAccess = { [weak self] _, value, isWrite in
            if isWrite { self?.widget.portAWrite(value) }
        }
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
        noteWidgetRegionAccess(offset)
        record(offset: offset, value: value, isWrite: false)
        return value
    }

    func write(_ offset: UInt32, _ value: UInt8) {
        noteWidgetRegionAccess(offset)
        if let (via, index) = Self.viaRegisterIndex(offset) {
            viaInstance(via).write(index, value)
            // Forward the Widget's Port-B control strobe (CMD/DIR, §10.2). The
            // OS driver bit-bangs it via HWBASE Port B (`$FCD801` reg 0) and
            // the HWSTATUS mirror (`$FCDC01`) -- NOT the ROM floppy path's
            // `$FCD901`, which is deliberately excluded here. A no-op while
            // the Widget is detached.
            if via == 1, Self.isWidgetPortBOffset(offset, index: index) {
                widget.portBWrite(value)
            }
        } else if !applyLatch(offset) {
            applyNonLatchWrite(offset, value)
        }
        record(offset: offset, value: value, isWrite: true)
    }

    /// The two VIA1 offsets that carry the Widget driver's Port-B control
    /// strobe: HWBASE Port B (`$FCD801` register 0) and its HWSTATUS mirror
    /// (`$FCDC01`), per docs/hardware-notes.md §10.1-10.2. The `$FCD901`
    /// mirror (the ROM floppy handshake's Port B) is intentionally NOT
    /// included -- the Widget must not react to floppy-path Port B traffic.
    private static func isWidgetPortBOffset(_ offset: UInt32, index: Int) -> Bool {
        if offset == 0xDC01 { return true }
        return index == 0 && offset >= 0xD801 && offset <= 0xD801 + 15 * 8
    }

    /// Count of accesses (read or write) to the OS ProFile/Widget driver's
    /// VIA1 region -- the `$FCD801` HWBASE register file and the `$FCDC01`/
    /// `$FCDC05` HWSTATUS/hwddrb mirrors (docs/hardware-notes.md §10.1). The
    /// `$FCD901` ROM-floppy mirror is deliberately excluded. **M5 Task 2 live
    /// probe / Task 1 Q1 seam:** `PROF_INIT`/`PROFASM` have never run on our
    /// machine (§10.9), so this stays 0 on the boot-to-installer path; the
    /// first time it goes non-zero is the moment the OS driver actually starts
    /// driving the Widget (Task 3's frontier). A pure diagnostic -- nothing
    /// branches on it, exactly like `vsyncResetCount`.
    private(set) var widgetRegionAccesses = 0
    /// The `Bus` cycle of the FIRST widget-region access, or `nil` if none yet
    /// -- pairs with `widgetRegionAccesses` for the Task 3 trace.
    private(set) var firstWidgetRegionAccessCycle: UInt64?

    private func noteWidgetRegionAccess(_ offset: UInt32) {
        let inHwbase = offset >= 0xD801 && offset <= 0xD801 + 15 * 8
        guard inHwbase || offset == 0xDC01 || offset == 0xDC05 else { return }
        widgetRegionAccesses += 1
        if firstWidgetRegionAccessCycle == nil {
            firstWidgetRegionAccessCycle = bus.cycleProvider()
        }
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
        // $F801 bit 2 (vertical-retrace) is ACTIVE-LOW: 0 == retrace pending,
        // 1 == not pending. Established from the OS source at Checkpoint E (M4
        // Task 3): the OS's Level1 handler (LIBHW-DRIVERS `Level1`) does
        // `BTST #2,StatusRegister+1 / BNE (skip VertRetrace)` -- comment
        // "branch if NOT vertical retrace" -- so a PENDING retrace must expose
        // bit 2 = 0 for the handler to service (and ack via `VertRetrace`'s
        // `$E018` write). Our earlier active-high model (bit2 = pending?4:0)
        // stormed the OS's level-1 handler: it read bit2=1 as "not retrace",
        // never acked, and `Machine.vsyncPending` held level 1 asserted
        // forever. The ROM's own bit-2 self-test is polarity-agnostic (a
        // soft-fail either way -- docs/rom-trace-notes.md "Trace checkpoint B"),
        // so every ROM anchor is unmoved. See "Checkpoint E".
        case 0xF801: return (statusByte & ~0x04) | (videoTiming.pending ? 0 : 0x04)
        // $FCC031 = DiskROMId (LIBHW-DRIVERS:135), the I/O-board disk-ROM
        // ident byte. M4 Task 4 round 4: was a 0x00 "pre-Pepsi" stub (benign
        // for the ROM, whose only gate is the bit7 Pepsi contrast tweak at
        // $FE0B24-$FE0B3C -- docs/rom-trace-notes.md "$C031 board ID"), but
        // the OS's BOOT_IO_INIT decodes it as the MACHINE IDENTITY
        // (SOURCE-STARTUP:1876-1890): signed >= 0 -> iob_lisa (Twiggy
        // Lisa 1), which made STARTUP:1970-1972 install the vestigial TWIGIO
        // stub driver (SOURCE-CD:750, body compiled out in OS 3.1 under
        // (*$IFC TWIGGYBUILD*), source-twiggy:1235/1237) on the boot-floppy
        // devrecs "#14#1"/"#14#2" -- the Checkpoint F orphaned-mount-read
        // stall. The Lisa 2/10 we model presents a Pepsi-class ID: bit7 set
        // (LIBHW-DRIVERS:581), bit5 clear (not LisaLite, :583), outside
        // [$A0,$DF] (iob_sony/iob_lite, STARTUP:1879-1885) -> with
        // $FCC015=1 below, iomodel = iob_pepsi (STARTUP:1886-1890). The
        // specific byte $88 is derived from the decode, not an external
        // ident table (the 6504 disk ROM is not in the source tree): any
        // bit7-set value outside [$A0,$DF] with bit5 clear satisfies every
        // decode the ROM and OS perform -- see docs/hardware-notes.md
        // "Board IDs" for the full derivation statement.
        case 0xC031: return 0x88
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
    /// stride ×8; VIA2 = `$DD81`, stride ×2.
    ///
    /// **M5 Task 2 -- the `$D801` VIA1 mirror is now also decoded.** The Rev H
    /// boot ROM's FLOPPY path uses the `$D901` mirror (which is why `$D801`
    /// was left unmapped through M4). But the OS ProFile/Widget driver's own
    /// `HWBASE = $FCD801` register file and `HWSTATUS = $FCDC01` /
    /// `hwddrb = $FCDC05` mirrors (PROFILE:253-256, LIBHW-DRIVERS:137;
    /// docs/hardware-notes.md §10.1) are a DIFFERENT code path on the same
    /// physical 6522 -- a real chip answers `$D101/$D801/$D901/$DC01` as
    /// mirrors. These are decoded to the SAME `via1` instance so the driver's
    /// accesses land where `WidgetDrive` is attached (§10.9 "Task-2 action").
    /// **UNVERIFIED live**: `PROF_INIT` has never run on our machine, so which
    /// mirror the driver actually drives is not yet trace-confirmed -- Task 3
    /// reconciles OBSERVED vs this decode (see the `$D801` note in §10.1). The
    /// `$DC01`/`$DC05` mirrors map to VIA1 Port B (index 0) / DDRB (index 2).
    private static func viaRegisterIndex(_ offset: UInt32) -> (via: Int, index: Int)? {
        if offset >= 0xD901, offset <= 0xD901 + 15 * 8, (offset - 0xD901) % 8 == 0 {
            return (1, Int((offset - 0xD901) / 8))
        }
        if offset >= 0xD801, offset <= 0xD801 + 15 * 8, (offset - 0xD801) % 8 == 0 {
            return (1, Int((offset - 0xD801) / 8))
        }
        if offset == 0xDC01 { return (1, 0) }   // HWSTATUS = ORB/IRB mirror (§10.1)
        if offset == 0xDC05 { return (1, 2) }   // hwddrb = DDRB mirror (§10.1)
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
