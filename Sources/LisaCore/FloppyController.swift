import Foundation

/// High-level emulation (HLE) of the Lisa's internal Sony 400K floppy
/// controller (docs/hardware-notes.md §9), reachable from the 68000 through
/// a 2KB shared-RAM window at `$FCC000-$FCC7FF` -- real hardware's 6504
/// I/O-board microcontroller's memory. Modeled the same way `VIA6522`/`COPS`
/// model their own hardware: a plain register/byte-array store with exactly
/// one address-decoded side effect (the go-byte write at DISKCMD, offset
/// `$01`) that schedules a `Machine` event to do the "6504's" work, per the
/// task brief's "go-byte state machine" framing.
///
/// ## Protocol summary (full citations in docs/hardware-notes.md §9)
///
/// 1. The 68000 stages a sub-command's parameters (DISKPARM/DISKDRIV/
///    DISKHEAD/DISKSEC/DISKTRAK) then writes a go-byte to DISKCMD.
/// 2. This model schedules `commandDelayCycles` later, at which point the
///    go-byte is decoded (`processGoByte`). Simple commands (`nulcmd`,
///    `seek`, `clristat`, `enabstat`, `clrmask`, `goaway`) just apply their
///    documented state-flag effect and clear DISKCMD back to 0 (real
///    hardware: "the 6504 clears it when ready" -- the handshake the 68000
///    busy-waits on).
/// 3. `excmd` additionally executes the staged sub-command (`readdisk`
///    zone-maps track/sector/side to a linear block and copies 512 data
///    bytes + a 12-byte packed tag into the window; `writedisk` is
///    accept-and-discard, logged -- M2 is read-only; anything else is an
///    unsupported sub-command, DISKERR set). `readdisk`/`writedisk` are
///    "interrupt-generating" (SONYASM:136-157: "response := waitint"): a
///    SECOND scheduled delay (`completionDelayCycles`) after DISKCMD clears,
///    this model sets DISKSTAT's done/int bits and raises the completion
///    line. `seek` is explicitly documented "non-interrupting" and every
///    other simple command has no interrupt semantics documented either, so
///    only `excmd`'s readdisk/writedisk path raises the line.
///
/// ## Handshake / busy rejection
///
/// Real hardware's 68000 driver busy-waits `DISKCMD == 0` before writing a
/// new command (SONYASM:123-125); this model doesn't force that on a
/// caller, but a DISKCMD write that arrives while a previous command is
/// still in flight (scheduled but not yet cleared) is REJECTED outright --
/// logged and dropped, no new event scheduled, `window[DISKCMD]` left as
/// whatever the in-flight command's go-byte was -- rather than silently
/// clobbering/racing the pending command. This is a defensive HLE choice
/// (real silicon has no such guard; a real protocol violation would just be
/// undefined), not a cited hardware behavior.
///
/// ## Completion line polarity -- CONFIRMED (Task 5): the ROM's read
    /// routine waits at `$FE1E3E` (`btst #$4,(A3)` / `bne done`, A3=$FCDD81) --
    /// it spins until PORTB2 bit 4 is SET, so this model's idle=0/asserted=1
    /// choice is exactly right; block 0 reads to completion and the boot block
    /// executes under it (docs/rom-trace-notes.md "Floppy boot (checkpoint C)",
    /// `ROMFloppyBootTests`). Original design rationale, now validated:
///
/// hardware-notes.md §9 cites the completion line as "VIA2 PORTB2 bit 4
/// (`BTST #4` in the Level1 handler), level-1 autovector" but gives no
/// documented IDLE/ASSERTED polarity (unlike CRDY, whose busy=low/ready=high
/// shape is directly readable off the ROM's own poll-loop branches --
/// `COPS`'s type doc comment). This model chooses idle=0 (bit clear),
/// asserted=1 (bit set, matching DISKSTAT's own bit7 `bot_int` "set =
/// pending" convention) specifically because the alternative -- idle=1,
/// matching `VIA6522.portAInput`/`portBInput`'s all-ones default-float
/// convention `COPS`'s CRDY bit uses -- would make this bit read as
/// permanently "asserted" for every level-1 IRQ dispatch from the moment
/// this task lands, including ones unrelated to the floppy (VIA1 timer,
/// vsync) that the ROM already exercises on the current boot path, which is
/// a real risk to the M1b/M2 boot-menu anchors this task must not disturb.
/// The task brief calls for Task 5 to confirm/correct this against a real
/// ROM trace once the floppy driver path is actually reached.
///
/// ## Level-1 IRQ contribution
///
/// docs/hardware-notes.md §5 lists Twiggy/Sony floppy interrupts under
/// "Level 1" (alongside VIA1 timer, vertical retrace, parallel port) -- NOT
/// level 2, even though the completion line lives on VIA2's port B. That
/// means it cannot be modeled by folding into VIA2's own IFR/IER-driven IRQ
/// (VIA2 is wired to CPU level 2 -- see `Machine.tickVIAsAndUpdateIRQ`);
/// instead it needs its own direct level-1 contribution, exactly like
/// `VideoTiming`'s `vsyncPending` OR-term. `Machine.floppyPending` is that
/// third OR-term (see that property's doc comment).
public final class FloppyController {
    // MARK: - Cell offsets (relative to $FCC000, docs/hardware-notes.md §9)

    enum Cell {
        static let diskCmd = 0x01
        static let diskParm = 0x03
        static let diskDriv = 0x05
        static let diskHead = 0x07
        static let diskSec = 0x09
        static let diskTrak = 0x0B
        static let diskCnfm = 0x0F
        static let diskErr = 0x11
        static let diskFlg = 0x13
        static let diskSking = 0x19
        static let diskIn = 0x41
        static let diskStat = 0x5F
        static let diskCs = 0x95
        static let diskB2 = 0xB9
        static let cmdIndex = 0xFB
        static let pMemAd = 0x180
        static let diskHdr = 0x3E8

        /// AMBIGUITY (a) -- SETTLED (Task 5, ROM disassembly). The Rev H boot
        /// ROM's own read routine (twig_entry `$FE1D76`) reads the data buffer
        /// at `$FE1DC6: lea ($400,A0),A4` with `A0 = $FCC001`, then
        /// `movep.l` (stride 2), so the buffer BASE is **`$400`** (NOT the
        /// `$600` the SONYASM:221-231 FINISH_READ+1024 reading suggested), and
        /// the 512 data bytes live on the ODD lane of the window -- offsets
        /// `$401,$403,...,$7FF`. (`performRead` writes them there.) The tag
        /// buffer is the same shape one movep-group earlier (`$FE1DB0: lea
        /// ($3E8,A0),A4` -> `$3E9,$3EB,...,$3FF`). See docs/rom-trace-notes.md
        /// "Floppy boot (checkpoint C)".
        static let diskData = 0x400
    }

    /// The 2KB shared-RAM window, `$000-$7FF` relative to `$FCC000` (the
    /// task brief's `$C000-$C7FF` IODispatcher routing window).
    static let windowSize = 0x800

    // MARK: - Protocol constants (docs/hardware-notes.md §9)

    enum GoByte: UInt8 {
        case nulcmd = 0x80
        case excmd = 0x81
        case seek = 0x83
        case clristat = 0x85
        case enabstat = 0x86
        case clrmask = 0x87
        case goaway = 0x89
    }

    enum SubCommand: UInt8 {
        case readdisk = 0
        case writedisk = 1
        case unclamp = 2
        case format = 3
        case verify = 4
        case formattrk = 5
        case verifytrk = 6
        case readBf = 7
        case writeBf = 8
    }

    /// DISKERR raw byte values. hardware-notes.md §9 documents the OS-level
    /// error CODES the 68000 driver computes (`DISKERR + 1800`, e.g.
    /// `not_issued=1809`, `vererr=1821`, `read_err=1823`, `write_err=1824`)
    /// but never states the raw DISKERR byte the controller itself stores --
    /// INFERRED here as those constants minus the documented `1800` offset
    /// (9/21/23/24). Not independently cited; flagged for Task 5 to confirm
    /// once a real read/write error path is traced.
    enum ErrorCode {
        static let none: UInt8 = 0
        /// Unsupported/unrecognized sub-command -- "the driver resends the
        /// packet" per twiggy:1520-1525, the closest documented fit for "the
        /// controller could not execute what was asked."
        static let notIssued: UInt8 = 9
        static let verify: UInt8 = 21
        /// Used for BOTH "no disk present" and "out-of-range track/sector"
        /// on a `readdisk` sub-command -- intentional, not an oversight:
        /// §9's error table has no distinct no-disk code at this layer (only
        /// `not_issued`/`vererr`/`read_err`/`write_err` are documented), and
        /// a real driver reading DISKERR after a failed read sees a generic
        /// "the read didn't happen" signal either way.
        static let read: UInt8 = 23
        static let write: UInt8 = 24
    }

    /// DISKSTAT (`$5F`) bits actually driven by this model: bit7 `bot_int`,
    /// bit6 `bot_done` (hardware-notes.md §9; Sony uses the "bot" nibble
    /// only). Set together on `excmd` completion, cleared together by
    /// `clristat`.
    private static let diskStatIntDoneBits: UInt8 = 0xC0
    /// DISKSTAT bit4 `bot_in` -- kept in sync with disk-presence for
    /// fidelity, alongside the dedicated DISKIN cell.
    private static let diskStatInBit: UInt8 = 0x10

    /// Cycles from a DISKCMD go-byte write until it is decoded
    /// (`processGoByte`) -- "plausible", not cycle-exact, matching `COPS`'s
    /// tunable-timing precedent. Tune once Task 5's trace exercises this
    /// path against a real ROM timeout.
    static let commandDelayCycles: UInt64 = 2000
    /// Cycles from `excmd`'s data/tag copy + DISKCMD clear until the
    /// completion line actually raises -- the second, separate delay
    /// SONY.TEXT:136-157's "response := waitint" implies (completion is a
    /// hardware interrupt arriving some time after the command handshake
    /// itself completes, not synchronously with it).
    static let completionDelayCycles: UInt64 = 3000

    // MARK: - Dependencies (all injected, mirroring COPS/VideoTiming, so
    // protocol tests can drive this CPU-free)

    private let scheduleEvent: (UInt64, @escaping () -> Void) -> Void
    /// Reaches `Machine.floppyPending` -- the level-1 IRQ OR-term, see the
    /// type doc comment "Level-1 IRQ contribution".
    private let setLevel1Pending: (Bool) -> Void
    /// Fidelity-only diagnostic sink (write sub-command warning, rejected
    /// busy writes). Defaults to a no-op; `lisadbg`/tests may inject
    /// something that surfaces it.
    private let log: (String) -> Void

    public init(scheduleEvent: @escaping (UInt64, @escaping () -> Void) -> Void,
                setLevel1Pending: @escaping (Bool) -> Void,
                log: @escaping (String) -> Void = { _ in }) {
        self.scheduleEvent = scheduleEvent
        self.setLevel1Pending = setLevel1Pending
        self.log = log
    }

    // MARK: - Window storage

    private var window = [UInt8](repeating: 0, count: windowSize)
    private var image: DC42Image?
    /// True from the moment a go-byte is accepted until DISKCMD clears back
    /// to 0 -- see the type doc comment "Handshake / busy rejection".
    private var commandInFlight = false

    /// VIA2 PORTB2 bit 4 state -- see the type doc comment "Completion line
    /// polarity". `IODispatcher` composes this into `via2.portBInput`
    /// alongside `COPS`'s own bit 6 (CRDY).
    public private(set) var completionLineAsserted = false

    // MARK: - Disk-side stats (Task 6/7 assertions per the task brief)

    public private(set) var blocksRead = 0
    public private(set) var writeAttempts = 0
    public private(set) var lastError: UInt8 = 0

    // MARK: - Media

    /// True once a disk image is inserted; DISKIN (`$41`) and DISKFLG
    /// (`$13`, single/double-sided) reflect it immediately -- no delay
    /// modeled (unlike command execution, media insertion is not a 68000-
    /// visible protocol exchange).
    public var isInserted: Bool { image != nil }

    public func insert(_ image: DC42Image) {
        self.image = image
        window[Cell.diskIn] = 1
        window[Cell.diskFlg] = image.blockCount > Self.blocksPerSide ? 1 : 0
        window[Cell.diskStat] |= Self.diskStatInBit
    }

    public func eject() {
        image = nil
        window[Cell.diskIn] = 0
        window[Cell.diskFlg] = 0
        window[Cell.diskStat] &= ~Self.diskStatInBit
    }

    /// 800 blocks/side (`SNYSNGL`, hardware-notes.md §9) -- a single-sided
    /// 400K image has exactly this many; a double-sided image's `blockCount`
    /// exceeds it.
    private static let blocksPerSide = 800

    // MARK: - Reset (Machine.reset(), M2 Task 2 warm-reset path)

    /// In-flight command dropped, DISKCMD/DISKERR/DISKSTAT and the rest of
    /// the window cleared, completion line dropped -- but the inserted disk
    /// (`image`) is deliberately left untouched: real hardware's RESTART
    /// line doesn't eject media, and `Machine.reset()`'s own doc comment
    /// makes the same point about attached-device state surviving a warm
    /// reset. DISKIN/DISKFLG are recomputed from the surviving `image`
    /// right after the blanket clear.
    public func reset() {
        window = [UInt8](repeating: 0, count: Self.windowSize)
        commandInFlight = false
        blocksRead = 0
        writeAttempts = 0
        lastError = 0
        dropCompletionLine()
        if let image {
            window[Cell.diskIn] = 1
            window[Cell.diskFlg] = image.blockCount > Self.blocksPerSide ? 1 : 0
            window[Cell.diskStat] |= Self.diskStatInBit
        }
    }

    // MARK: - IODispatcher window access ($FCC000-$FCC7FF offsets 0-0x7FF)

    func read(_ offset: Int) -> UInt8 {
        guard offset >= 0, offset < window.count else { return 0xFF }
        return window[offset]
    }

    func write(_ offset: Int, _ value: UInt8) {
        guard offset >= 0, offset < window.count else { return }
        if offset == Cell.diskCmd {
            handleDiskCmdWrite(value)
            return
        }
        window[offset] = value
    }

    // MARK: - Go-byte state machine

    private func handleDiskCmdWrite(_ value: UInt8) {
        guard !commandInFlight else {
            log("FloppyController: DISKCMD write $\(String(value, radix: 16)) while busy -- rejected (driver protocol violation; real hardware requires busy-waiting DISKCMD==0)")
            return
        }
        window[Cell.diskCmd] = value
        commandInFlight = true
        scheduleEvent(Self.commandDelayCycles) { [weak self] in
            self?.processGoByte(value)
        }
    }

    private func processGoByte(_ value: UInt8) {
        switch GoByte(rawValue: value) {
        case .excmd:
            performExCmd()
            return   // performExCmd clears DISKCMD itself once staging is read
        case .clristat:
            window[Cell.diskStat] &= ~Self.diskStatIntDoneBits
            dropCompletionLine()
        case .enabstat, .clrmask, .goaway, .nulcmd, .seek, .none:
            break   // state-flag-only effects not otherwise modeled (or an
                    // unrecognized go-byte -- handshake-only ack, mirroring
                    // COPS's unrecognized-command precedent)
        }
        clearDiskCmd()
    }

    private func clearDiskCmd() {
        window[Cell.diskCmd] = 0
        commandInFlight = false
    }

    private func performExCmd() {
        let sub = window[Cell.diskParm]
        // DISKDRIV is read per protocol (the task brief: "excmd reads
        // DISKPARM + DRIV/HEAD/SEC/TRAK cells") but not consulted -- this
        // model has exactly one internal drive, so there is nothing to
        // select between; DISKHEAD (side) is what the zone map needs.
        _ = window[Cell.diskDriv]
        let head = window[Cell.diskHead]
        let sec = window[Cell.diskSec]
        let trak = window[Cell.diskTrak]
        clearDiskCmd()

        switch SubCommand(rawValue: sub) {
        case .readdisk:
            performRead(track: Int(trak), sector: Int(sec), side: Int(head))
        case .writedisk:
            writeAttempts += 1
            log("FloppyController: writedisk sub-command received -- accepted and discarded (read-only in M2), track=\(trak) sector=\(sec) side=\(head)")
            setError(ErrorCode.none)
            raiseCompletionLineAfterDelay()
        default:
            // unclamp/format/verify/formattrk/verifytrk/read_bf/write_bf,
            // or a byte matching none of them: unsupported in this HLE.
            setError(ErrorCode.notIssued)
            raiseCompletionLineAfterDelay()
        }
    }

    private func performRead(track: Int, sector: Int, side: Int) {
        guard let image else {
            setError(ErrorCode.read)
            raiseCompletionLineAfterDelay()
            return
        }
        guard let block = Self.blockNumber(track: track, sector: sector, side: side),
              block < image.blockCount else {
            setError(ErrorCode.read)
            raiseCompletionLineAfterDelay()
            return
        }
        let data = image.data(block: block)
        let tag = image.tag(block: block)
        // The 6504 shared RAM appears on the ODD bytes of the 68000's
        // $FCC000 window: the ROM's own read routine (twig_entry $FE1D76 ->
        // $FE1DB0/$FE1DC6) reads the tag and data buffers with `movep.l`
        // (stride 2) from base+1 -- `lea ($3E8,A0),A4` / `lea ($400,A0),A4`
        // where A0 = $FCC001 -- so tag byte i lands at window offset
        // $3E8+1+2i and data byte i at $400+1+2i. (The single-byte command
        // cells DISKCMD=$01/DISKPARM=$03/... are already at their odd
        // offsets, so this interleave only applies to the multi-byte
        // buffers.) Settles hardware-notes.md §9 ambiguity (a): the buffer
        // BASE is $400 (not $600), read stride-2 from the odd lane. See
        // docs/rom-trace-notes.md "Floppy boot (checkpoint C)".
        for i in 0..<512 { window[Cell.diskData + 1 + 2 * i] = data[i] }
        for i in 0..<12 { window[Cell.diskHdr + 1 + 2 * i] = tag[i] }
        blocksRead += 1
        setError(ErrorCode.none)
        raiseCompletionLineAfterDelay()
    }

    private func setError(_ code: UInt8) {
        window[Cell.diskErr] = code
        lastError = code
    }

    private func raiseCompletionLineAfterDelay() {
        scheduleEvent(Self.completionDelayCycles) { [weak self] in
            guard let self else { return }
            self.window[Cell.diskStat] |= Self.diskStatIntDoneBits
            self.completionLineAsserted = true
            self.setLevel1Pending(true)
        }
    }

    private func dropCompletionLine() {
        completionLineAsserted = false
        setLevel1Pending(false)
    }

    // MARK: - Zone mapping (CONVERT, docs/hardware-notes.md §9 "Sector
    // Addressing")

    /// (track, sector, side) -> linear DC42 block number -- the "inverse" of
    /// CONVERT (which natively maps block -> zone/track/sector/side; see the
    /// task brief). Zones: tracks 0-15 -> 12 sec/trk (base 0), 16-31 -> 11
    /// (base 192), 32-47 -> 10 (base 368), 48-63 -> 9 (base 528), 64-79 -> 8
    /// (base 672); 80 tracks/side, 800 blocks/side. Side 1 (double-sided)
    /// adds 800. `nil` for an out-of-range track/sector (bad-track error
    /// path).
    static func blockNumber(track: Int, sector: Int, side: Int) -> Int? {
        guard side == 0 || side == 1 else { return nil }
        guard let (secPerTrack, base) = zoneInfo(forTrack: track) else { return nil }
        guard sector >= 0, sector < secPerTrack else { return nil }
        let block = base + (track % 16) * secPerTrack + sector
        return side == 0 ? block : block + blocksPerSide
    }

    private static func zoneInfo(forTrack track: Int) -> (secPerTrack: Int, base: Int)? {
        switch track {
        case 0...15: return (12, 0)
        case 16...31: return (11, 192)
        case 32...47: return (10, 368)
        case 48...63: return (9, 528)
        case 64...79: return (8, 672)
        default: return nil
        }
    }
}
