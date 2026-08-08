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
/// **DISKCMD-during-completion-window (M3 Task 3 doc note, no behavior
/// change).** `commandInFlight` -- the flag this rejection guard checks --
/// only spans the FIRST delay, `commandDelayCycles` (go-byte write until
/// `processGoByte` decodes it). For `excmd`'s readdisk/writedisk sub-
/// commands, `performExCmd` calls `clearDiskCmd()` (dropping
/// `commandInFlight`) as soon as it has read the staged parameters --
/// BEFORE the SECOND delay, `completionDelayCycles`, during which the
/// completion line actually rises (`raiseCompletionLineAfterDelay`). So
/// there is a real window -- between DISKCMD clearing and the completion
/// line asserting -- where this guard does NOT reject a new DISKCMD write;
/// a second command issued in that window is accepted immediately and
/// scheduled normally. This mirrors real hardware's own two-phase
/// handshake (SONYASM:136-157's "response := waitint": the command ack and
/// the interrupt arrival are two separate events, not one), so a real
/// driver polling DISKCMD alone would see the identical "ready for a new
/// command" window before the first command's interrupt has actually
/// fired -- issuing a second command there without also waiting for the
/// first's completion would be a driver protocol violation on real
/// hardware too, not something this model is uniquely permissive about.
/// What IS a modeling simplification: `completionLineAsserted`/the
/// level-1-pending signal this type drives are single flags, not a queue,
/// so two commands' completion events racing in that window would have the
/// second's `raiseCompletionLineAfterDelay` silently coalesce with (not
/// queue behind) the first's -- undefended, because no traced boot path
/// (checkpoint C's block reads, the Task 6 loader's LFS reads, or the
/// unclamp/eject teardown) has ever been observed to issue back-to-back
/// `excmd`s without waiting for completion first.
///
/// ## Completion line polarity -- CONFIRMED (Task 5): the ROM's read
    /// routine calls a wait-completion subroutine at `$FE1E3E` (`bsr $fe1e3e`
    /// from `$FE1D94`); the actual poll instruction, 8 bytes into that
    /// subroutine past its `move.l D2,D3` timeout-counter setup, is
    /// `$FE1E46: btst #$4,(A3)` / `$FE1E4A: bne $fe1e54`, A3=$FCDD81 (M3 Task
    /// 3 precision fix: the polling instruction itself is `$FE1E46`, not the
    /// subroutine's `$FE1E3E` entry point -- see docs/rom-trace-notes.md
    /// "The read routine" for the full disassembly) -- it spins until
    /// PORTB2 bit 4 is SET, so this model's idle=0/asserted=1
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
        /// **Modeled as a benign no-op (M3 Task 3 doc note).** `unclamp` is
        /// unimplemented -- it falls into `performExCmd`'s `default` branch
        /// like every other unsupported sub-command, so this model answers
        /// it with `ErrorCode.notIssued` (DISKERR 9) rather than performing
        /// any real head-unclamp effect. This is deliberately harmless, not
        /// an oversight: the only observed caller is the loader's
        /// `shutdown`/eject teardown (source-ldmicro:184-203,
        /// docs/hardware-notes.md §9 "Command Protocol"), which issues
        /// `unclamp` -> `clristat ($85)` -> `clrmask ($87)`/parm (`$88`) and
        /// waits ONLY on the VIA2-PB4 completion line -- it never reads
        /// DISKERR after `unclamp`, so a nonzero error code here is
        /// unobservable to it. Confirmed by the M2 Task 6 live trace
        /// (docs/rom-trace-notes.md "Sanity-negative sweep"): the loader's
        /// `unclamp` call completes the teardown regardless of this
        /// answer, on every traced boot path through the `trap #6` gate.
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

    /// DISKSTAT (`$5F`) = the 6504's `int_stat` record (SONY:84-90, packed
    /// MSB-first): bit7 `bot_int` (an interrupt occurred), bit6 `bot_done` (an
    /// I/O request completed), bit5 `unused` (SONY has no button), bit4 `bot_in`
    /// (a disk is present). The OS's `DISK_INT` reads this byte on every level-1
    /// floppy interrupt (SONY:469-481). `DISKSTAT $5F` is "INTERRUPT SOURCE"
    /// (SONYASM:22-23).
    /// I/O completion sets bot_int+bot_done together (`excmd` read/write/unclamp).
    private static let diskStatIntDoneBits: UInt8 = 0xC0   // bot_int | bot_done
    /// DISKSTAT bit4 `bot_in` -- disk-present. Set on the media-change
    /// (`insertWhileRunning`) attention and kept in sync with disk-presence for
    /// fidelity, alongside the dedicated DISKIN cell.
    private static let diskStatInBit: UInt8 = 0x10         // bot_in
    /// bit7 `bot_int` alone -- the "an interrupt occurred" flag, ORed with
    /// `bot_in` for a media-change attention (no `bot_done`, since a media
    /// change is not an I/O-request completion).
    private static let diskStatIntBit: UInt8 = 0x80        // bot_int
    /// Every interrupt-source bit `clristat` must clear (bot_int+bot_done+bot_in;
    /// bit5 unused). The `notop` drive-select nibble (bits 3-0) is preserved.
    private static let diskStatInterruptBits: UInt8 = 0xD0

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
    /// Count of `writedisk` commands that actually stored a block into the
    /// session overlay (M4 Task 4 round 4). `writeAttempts` keeps counting
    /// every issued `writedisk` (including failed ones), preserving the
    /// M2/M3 counter semantics the boot pins used.
    public private(set) var blocksWritten = 0
    public private(set) var lastError: UInt8 = 0

    /// **Session-scoped write-through (M4 Task 4 round 4).** The OS writes
    /// to the boot floppy during FS mount/startup (e.g. the parameter-memory
    /// snapshot rewrite, FS metadata updates); a dropped write means the OS
    /// later re-reads stale bytes -- guaranteed metadata corruption. Writes
    /// land here, in memory, keyed by DC42 block number; `performRead`
    /// consults this overlay before the backing image. The `.dc42` image
    /// object (and its file) is NEVER mutated. `insert(_:)` clears the
    /// overlay (a fresh insertion = a fresh session); `reset()` deliberately
    /// does NOT (a warm reboot does not un-write a real floppy's media).
    private var sessionOverlay: [Int: (data: [UInt8], tag: [UInt8])] = [:]

    /// Count of go-bytes fully processed (every `clearDiskCmd()` call, i.e.
    /// every `processGoByte`/`performExCmd` completion -- `nulcmd`/`seek`/
    /// `clristat`/`enabstat`/`clrmask`/`goaway` as well as `excmd`'s
    /// readdisk/writedisk/unsupported sub-commands). M2 Task 7's app-layer
    /// `EmuStatus.diskActivity` is defined directly off this: "the floppy
    /// processed a command since the last status publish" -- a simple
    /// monotonic counter, diffed by the caller (`EmulationController`)
    /// across its own polling interval, rather than this type tracking any
    /// notion of "time since" itself (which would duplicate the polling
    /// cadence that already lives one layer up).
    public private(set) var commandsProcessed = 0

    // MARK: - Media

    /// True once a disk image is inserted; DISKIN (`$41`) and DISKFLG
    /// (`$13`, single/double-sided) reflect it immediately -- no delay
    /// modeled (unlike command execution, media insertion is not a 68000-
    /// visible protocol exchange).
    public var isInserted: Bool { image != nil }

    /// **`$C015` vs. double-sided images -- a known, documented
    /// inconsistency (M3 Task 3 doc note, not fixed here).** `insert(_:)`
    /// happily accepts a double-sided (1600-block) DC42 image and sets
    /// DISKFLG (`window[Cell.diskFlg]`) accordingly, below -- but
    /// `$FCC015` (`adr_intdisk`, the board-ID byte real hardware reads to
    /// distinguish twiggy/single-sided-Sony/double-sided-Sony,
    /// docs/hardware-notes.md "Board IDs") is a STATIC `IODispatcher` stub
    /// hardcoded to `1` (single-sided), independent of whatever media this
    /// method inserts -- see hardware-notes.md's "Board IDs" section for
    /// the citation and the same note mirrored there. On real hardware
    /// `$C015` describes the DRIVE's fixed capability, not the inserted
    /// disk, so a double-sided image in a single-sided-reporting model is
    /// an inconsistent combination no real Lisa configuration could
    /// produce. Harmless today (no traced boot path reads `$C015` after
    /// insertion, and M2/M3's install images are all single-sided 400K),
    /// but a future task inserting a genuine 800K double-sided image should
    /// make `$C015` configurable (or derive it from the inserted image)
    /// rather than leaving the two signals able to disagree -- parked as an
    /// M4-ish resolution path, not implemented here (out of this task's
    /// doc-only/behavioral-item-1-only scope).
    public func insert(_ image: DC42Image) {
        sessionOverlay.removeAll()   // fresh insertion = fresh write session
        blocksWritten = 0
        self.image = image
        window[Cell.diskIn] = 1
        window[Cell.diskFlg] = image.blockCount > Self.blocksPerSide ? 1 : 0
        // DISKIN ($41) is the persistent presence cell. DISKSTAT bit4 `bot_in`
        // is NOT a presence mirror -- it is the media-change INTERRUPT bit,
        // raised only by `insertWhileRunning` and cleared by `clristat` (SONY
        // int_stat is event bits read on the level-1 interrupt). Setting it on
        // a bare power-on insert would make every later I/O completion carry a
        // stale bot_in and spuriously re-trigger DISK_INT's gooddisk/KEYPUSHED.
    }

    public func eject() {
        image = nil
        window[Cell.diskIn] = 0
        window[Cell.diskFlg] = 0
    }

    /// **Insert a disk while the machine is running (M5 Task 3 round 2).** Sets
    /// presence like `insert(_:)`, then raises the **media-change attention**
    /// the OS waits on: a level-1 floppy interrupt with `int_stat` = `bot_int` +
    /// `bot_in` (no `bot_done`). The OS's `DISK_INT` (SONY:469-481) sees `bot_in`
    /// and sets `disk_present := gooddisk` + `KEYPUSHED`, which wakes an app
    /// blocked in a `Mount` retry loop (e.g. the installer's "insert disk N"
    /// prompt) so it re-reads and mounts the new volume. This is the runtime
    /// counterpart of the OS-commanded eject (`unclamp`, `performExCmd`), and the
    /// path the mailbox `insertFloppy` uses while the OS is up.
    ///
    /// Bare `insert(_:)` deliberately does NOT raise this: it is the power-on
    /// path (a disk already present at boot), where the ROM expects no
    /// attention -- so every boot test (checkpoint E/G/H/I) stays unmoved.
    public func insertWhileRunning(_ image: DC42Image) {
        insert(image)
        raiseInterruptAfterDelay(intStatBits: Self.diskStatIntBit | Self.diskStatInBit)
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
        commandsProcessed = 0
        dropCompletionLine()
        if let image {
            window[Cell.diskIn] = 1
            window[Cell.diskFlg] = image.blockCount > Self.blocksPerSide ? 1 : 0
            // DISKSTAT bot_in is an interrupt-event bit, not a presence mirror
            // (see insert(_:)); a warm reset leaves it clear (window is zeroed).
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
            // "Clear all current interrupts" (SONY DISK_INT:466). Clears every
            // int_stat source bit -- bot_int+bot_done AND bot_in (the media-
            // change bit), preserving the notop drive-select nibble.
            window[Cell.diskStat] &= ~Self.diskStatInterruptBits
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
        commandsProcessed += 1
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
            performWrite(track: Int(trak), sector: Int(sec), side: Int(head))
        case .unclamp:
            // **OS-commanded eject (M5 Task 3 round 2).** The Sony driver's
            // `dskunclamp` (SONY:679-688) queues an `unclamp` request and sets
            // `disk_present := nodisk` itself; the controller physically ejects
            // the media. Model both halves: actually remove the disk (was a
            // no-op before -- the other half of the media-change gap), then
            // complete the request with a normal bot_done interrupt (bot_in is
            // now clear -- no disk). (Struck the old "unclamp is a benign no-op"
            // record; see the SubCommand.unclamp doc + hardware-notes §9.)
            eject()
            setError(ErrorCode.none)
            raiseCompletionLineAfterDelay()
        default:
            // format/verify/formattrk/verifytrk/read_bf/write_bf, or a byte
            // matching none of them: unsupported in this HLE.
            setError(ErrorCode.notIssued)
            raiseCompletionLineAfterDelay()
        }
    }

    /// Session write-through (see `sessionOverlay`): captures the block the
    /// OS driver staged in the window -- data on the ODD lane at `$400`
    /// (`START_WRITE`, SOURCE-SONYASM:323-380: `movep` stride 2 into
    /// DISKHDR+24 = DISKDATA), packed 12-byte tag on the ODD lane at `$3E8`
    /// (SONYASM:304-321) -- the exact mirror of `performRead`'s layout.
    private func performWrite(track: Int, sector: Int, side: Int) {
        guard image != nil,
              let block = Self.blockNumber(track: track, sector: sector, side: side),
              block < image!.blockCount else {
            log("FloppyController: writedisk rejected -- no disk or bad geometry, track=\(track) sector=\(sector) side=\(side)")
            setError(ErrorCode.write)
            raiseCompletionLineAfterDelay()
            return
        }
        var data = [UInt8](repeating: 0, count: 512)
        var tag = [UInt8](repeating: 0, count: 12)
        for i in 0..<512 { data[i] = window[Cell.diskData + 1 + 2 * i] }
        for i in 0..<12 { tag[i] = window[Cell.diskHdr + 1 + 2 * i] }
        sessionOverlay[block] = (data: data, tag: tag)
        blocksWritten += 1
        log("FloppyController: writedisk block \(block) stored in the session overlay (track=\(track) sector=\(sector) side=\(side)); the .dc42 image is untouched")
        setError(ErrorCode.none)
        raiseCompletionLineAfterDelay()
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
        // Session write-through: a block the OS wrote THIS session reads
        // back from the overlay, not the pristine image.
        let overlaid = sessionOverlay[block]
        let data = overlaid?.data ?? image.data(block: block)
        let tag = overlaid?.tag ?? image.tag(block: block)
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
        raiseInterruptAfterDelay(intStatBits: Self.diskStatIntDoneBits)
    }

    /// Raise the level-1 floppy interrupt after the completion delay, ORing the
    /// given `int_stat` bits into DISKSTAT (`bot_int|bot_done` for an I/O
    /// completion, `bot_int|bot_in` for a media-change attention).
    private func raiseInterruptAfterDelay(intStatBits: UInt8) {
        scheduleEvent(Self.completionDelayCycles) { [weak self] in
            guard let self else { return }
            self.window[Cell.diskStat] |= intStatBits
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
