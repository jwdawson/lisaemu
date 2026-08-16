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
        /// **`$0D` -- host-set busy/ack flag the controller clears on
        /// command completion (M8, MacWorks Plus live trace).** Absent from
        /// SONYASM's equate table and from every Lisa OS path: the OS never
        /// reads or writes it, which is why six milestones never needed it.
        ///
        /// MacWorks Plus uses it as a second handshake alongside DISKCMD,
        /// booting System 6 off a MacWorks-formatted hard disk. Guest code at
        /// `$4242AE`-`$4242D4` (described rather than transcribed -- it is
        /// Apple/Sun-derived, and the repo takes no Apple-derived data):
        /// it stages DISKPARM = 0 and DISKDRIV = 2, sets this cell to `$FF`
        /// itself at `$4242B8`, writes go-byte `$84` to DISKCMD at
        /// `$4242BC`, then spins at `$4242C2` reading this cell until the
        /// controller zeroes it -- after which it reads DISKERR and stores
        /// the masked result into the Mac drive queue element's `dQFlags`.
        ///
        /// Go-byte `$84` is itself undocumented (SONY.TEXT:61-68 lists
        /// `$80`/`$81`/`$83`/`$85`/`$86`/`$87`/`$89`), so this model answers
        /// it the way it answers every other unrecognized go-byte -- a
        /// handshake-only ack -- and now also clears `$0D`, which is what
        /// the guest is actually waiting on. Without it the Finder draws its
        /// menu bar and then spins here forever with the watch cursor up:
        /// ~40,000 reads of `$FCC00D` per 2M cycles, and no desktop.
        static let diskAck = 0x0D
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
        /// **`clampcmd` = 9 -- Twiggy-only, deliberately NOT implemented
        /// (M8).** hardware-notes.md §9 lists 0-8 for the Sony and notes
        /// "Twiggy adds clampcmd=9" (twiggy:83), so the Lisa OS never
        /// issues it. MacWorks Plus DOES, in the hard-disk configuration:
        /// live trace at an insert with a Widget attached shows `$C003 W 09`
        /// + `$C005 W 80` + `$C001 W 81` (excmd), then `$C011 R 09` reading
        /// back this model's `notIssued`. The floppy-only path never issues
        /// it at all (zero occurrences in the same trace without
        /// `--widget`).
        ///
        /// Answering it as a success no-op was TRIED and REVERTED: DISKERR
        /// went 9 -> 0 as intended, but MacWorks still ejected the diskette
        /// immediately afterwards, so the clamp answer is not what gates
        /// that path -- MacWorks never reads a block from the floppy at all
        /// while it is looping on the hard disk. Since no source states what
        /// real Sony firmware returns for a Twiggy-only sub-command, an
        /// unfalsified guess that fixes nothing does not belong in the
        /// model. Revisit only with evidence that the answer matters.
        case clampcmd = 9
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

    /// **Snapshot / restore the write session for one physical diskette (M5
    /// Task 3 round 2).** A real diskette retains the blocks the OS wrote to it
    /// (e.g. the boot-time `overmount_stamp`/`mountinfo` written into the boot
    /// disk's MDDF) when it is ejected and later reinserted. The session overlay
    /// is per-drive and cleared on every `insert(_:)`, so a caller driving a
    /// multi-diskette flow (the installer's disk swaps) must snapshot the
    /// leaving disk's overlay and restore it when that SAME physical disk is
    /// reinserted -- otherwise the pristine `.dc42` returns the OLD MDDF stamp
    /// and the OS's `boot_remount` fails with E_BT_REMOUNT (1144, FSINIT2:466-
    /// 468). Modeling the medium, not mutating the `.dc42`.
    public func exportSessionOverlay() -> [Int: (data: [UInt8], tag: [UInt8])] {
        sessionOverlay
    }
    /// Restore a previously-`exportSessionOverlay()`'d write session onto the
    /// currently-inserted diskette (call AFTER the `insert`/`insertWhileRunning`
    /// that put the disk back). Also restores `blocksWritten` so the write
    /// counter reflects the retained session.
    public func importSessionOverlay(_ overlay: [Int: (data: [UInt8], tag: [UInt8])]) {
        sessionOverlay = overlay
        blocksWritten = overlay.count
    }

    // NOTE (M6 Task 4, considered and DEFERRED -- not implemented). An
    // automatic, per-image-IDENTITY overlay store (FloppyController itself
    // remembering each diskette's session, keyed by something intrinsic to
    // the image, and auto-restoring it on re-insertion) was evaluated as a
    // replacement for this caller-managed export/import pair, so an
    // arbitrary UI-driven swap (not just the installer's own scripted
    // sequence) wouldn't lose a diskette's session. Rejected for THIS pass
    // because every candidate identity key has a real failure mode, not a
    // merely theoretical one:
    //   - URL-keyed: `DC42Image` is a value type carrying no URL (loaded
    //     once, then detached from its source path everywhere but the
    //     caller) -- would require an API-widening `sourceURL:` parameter on
    //     `insert`/`insertWhileRunning` across every call site (Emulation-
    //     Controller, lisadbg, every test helper). Even then, re-inserting
    //     the SAME URL after the underlying file was edited externally would
    //     wrongly restore a session onto now-different bytes.
    //   - Content-digest-keyed (hash the data+tag planes): cheap to compute
    //     and needs no API change, but conflates two BYTE-IDENTICAL images
    //     as "the same disk" -- and that is not a theoretical edge case
    //     here: Apple's install floppies are mass-duplicated, so two
    //     genuinely distinct physical copies of the same disk (e.g. two
    //     pristine copies of Office System disk 1) are byte-identical by
    //     construction. Auto-restoring one's write session onto the OTHER
    //     copy on first insert would be silently wrong.
    //   - Composite (URL, content-digest): resolves both failure modes
    //     above, but combines both costs (the API-widening AND accepting
    //     "no identity" for any caller that can't supply a URL, e.g. a
    //     synthetic/in-memory test image) -- real, but wider-reaching than
    //     a "carried quality fix."
    // Left as-is: the caller-managed API above already gives the ONE party
    // who genuinely knows physical identity -- the human/UI layer choosing
    // to reinsert "the same diskette" -- the tool to preserve it explicitly;
    // FloppyController/DC42Image cannot reliably infer that identity from
    // bytes or a path alone. Scope estimate + full writeup: task-4-report.md
    // ("Fix 4" section).

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

    /// The byte DISKIN (`$41`) carries while media is present: **`$FF`, not
    /// a bare `1`** (M8, MacWorks Plus investigation).
    ///
    /// hardware-notes.md §9 documents DISKIN only as "nonzero = disk
    /// present", because the Lisa OS never looks closer: `ISDISKIN`
    /// (SONYASM:437-441) returns the raw byte and `hdinit` sets
    /// `disk_present := gooddisk` when `response <> 0` (SONY.TEXT:629-636).
    /// Any nonzero value satisfies that, so the original `1` was an
    /// unconstrained choice, never evidence.
    ///
    /// **MacWorks Plus 1.0.18 constrains it.** Its patched `.Sony` reads
    /// the cell ABSOLUTELY -- live `lisadbg` trace of guest code at
    /// `$41B892` (described rather than transcribed; it is Apple/Sun-derived
    /// and the repo takes no Apple-derived data): it compares the byte at
    /// `$FCC041` against `$FF`, proceeding only on equality, and otherwise
    /// loads `-65` (`offLinErr`) and returns it to the caller.
    ///
    /// With `1` in the cell every `_Read` returned offLinErr, the Mac drive
    /// queue element's `diskInPlace` stayed `0` forever (watched with `gw
    /// $1DE3` across 600M cycles, never written), and the boot could not
    /// pass its splash. `$FF` satisfies BOTH drivers -- it is the only
    /// value consistent with all known evidence, so it replaces the guess
    /// rather than being special-cased per guest.
    ///
    /// Corroboration from the same window: DISKSKING (`$19`) is documented
    /// `$FF while seeking` -- `$FF` is this firmware's true-flag idiom.
    static let diskInPresent: UInt8 = 0xFF

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
        window[Cell.diskIn] = Self.diskInPresent
        window[Cell.diskFlg] = image.blockCount > Self.blocksPerSide ? 1 : 0
        // DISKIN ($41) is the persistent presence cell. DISKSTAT bit4 `bot_in`
        // is NOT a presence mirror -- it is the media-change INTERRUPT bit,
        // raised only by `insertWhileRunning` and cleared by `clristat` (SONY
        // int_stat is event bits read on the level-1 interrupt). Setting it on
        // a bare power-on insert would make every later I/O completion carry a
        // stale bot_in and spuriously re-trigger DISK_INT's gooddisk/KEYPUSHED.
    }

    /// **User-forced eject (M6 Task 4 decision: bare, no OS-visible
    /// attention -- cited, not the asymmetric oversight it looks like next
    /// to `insertWhileRunning`).** Compare the other two eject/insert
    /// paths: `insertWhileRunning` deliberately raises the media-change
    /// attention on insertion, and the `unclamp` sub-command (`performExCmd`
    /// case `.unclamp`) -- the OS's OWN commanded eject -- completes with a
    /// normal `bot_done` interrupt. This method, by contrast, raises
    /// NOTHING: no DISKSTAT bits, no level-1 pending. That is the correct
    /// answer, not a gap, for three reasons:
    ///
    /// 1. Real hardware's ONLY commanded-eject path IS `unclamp` -- a
    ///    68000-driven solenoid (SONY dskunclamp:679-688). There is no
    ///    independent "the diskette was physically removed" sense line the
    ///    6504 reports as an interrupt; hardware-notes.md §9 "DISKIN"
    ///    documents `DISKIN` (`$41`) as a PASSIVE, POLLED presence cell read
    ///    synchronously at driver init (`ISDISKIN`, SONYASM:437-441), and §9
    ///    "Media-change attention" is explicit that `insertWhileRunning` is
    ///    "the ONLY runtime path that flips the cached presence" -- on the
    ///    INSERT side. No ejection-side counterpart interrupt is documented
    ///    for anything but the OS's own `unclamp`.
    /// 2. This emulator's user-menu "Eject" (`EmulationController.
    ///    ejectFloppy`, `lisadbg`'s `eject` command) therefore models a
    ///    scenario real hardware cannot physically produce mid-session: on a
    ///    real Lisa, media leaves the drive ONLY via the motorized eject the
    ///    OS itself commands, so "the user pulls the diskette while the OS
    ///    still thinks it's present" has no hardware analog to fault-match
    ///    in the first place -- there is no real interrupt this method could
    ///    cite even if we wanted one.
    /// 3. Given that, the real-hardware-accurate consequence of a stale
    ///    OS-side presence belief is: nothing tells it, and it finds out on
    ///    its OWN next access. `performRead`/`performWrite`'s existing
    ///    `guard image != nil` paths already raise a NORMAL completion
    ///    interrupt (`bot_int|bot_done`) carrying a read/write-class
    ///    DISKERR when `image` is nil -- exactly the "that access just
    ///    failed" signal a real drive with no media would produce on the
    ///    OS's next `excmd`. Bare `eject()` already reproduces that; it
    ///    would be WRONG to also synthesize a phantom "media removed"
    ///    interrupt no real 6504 firmware ever sends.
    ///
    /// Pinned by `FloppyControllerTests.bareEjectRaisesNoAttentionOrInterrupt`
    /// (no DISKSTAT bits, no level-1 pending, and the OS's own subsequent
    /// read correctly raises completion with a read DISKERR). Mirrored in
    /// docs/hardware-notes.md §9 "User-forced eject".
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
    static let blocksPerSide = 800

    /// `$FCC015` (`adr_intdisk`) -- the drive-capability byte the OS reads to
    /// tell drive types apart: **0 = Twiggy, 1 = single-sided Sony, 2 =
    /// double-sided Sony** (STARTUP:1747-1748, docs/hardware-notes.md
    /// "Board IDs").
    ///
    /// Was a static `1` stub in `IODispatcher`, which M3 Task 3 flagged as a
    /// latent inconsistency: `insert(_:)` accepts an 800K double-sided image
    /// and sets DISKFLG accordingly while `$C015` kept claiming
    /// single-sided -- a combination no real Lisa could produce. M8 takes
    /// the resolution path that note prescribed and derives it from the
    /// inserted media.
    ///
    /// **Physical caveat, stated because the model is deliberately loose
    /// here:** on real hardware this byte describes the DRIVE, which cannot
    /// change with the disk in it. Deriving it from the media is sound only
    /// under the assumption a double-sided diskette is only ever inserted
    /// into a drive that can read it -- true of any real configuration, and
    /// it keeps 400K media reading exactly `1` as before. If a future task
    /// ever needs to model a single-sided drive REJECTING 800K media, this
    /// becomes a configured drive property instead.
    /// True when the inserted image has more blocks than one side holds --
    /// i.e. an 800K double-sided diskette, whose block ordering interleaves
    /// the two sides per track (see `blockNumber`).
    var isDoubleSidedMedia: Bool { (image?.blockCount ?? 0) > Self.blocksPerSide }

    public var intDiskId: UInt8 {
        guard let image else { return 1 }
        return image.blockCount > Self.blocksPerSide ? 2 : 1
    }

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
            window[Cell.diskIn] = Self.diskInPresent
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
        // The other half of the handshake for guests that use it. Cleared
        // for EVERY command, not just the `$84` that revealed it: `$0D` is
        // the controller's "done with your request" signal and the Lisa OS
        // never reads it, so this cannot disturb any OS path. UNCERTAIN and
        // deliberately noted: this fires when the go-byte is consumed, which
        // for `excmd` is BEFORE the data transfer's completion interrupt --
        // if a guest is ever seen using `$0D` to wait on an excmd's DATA
        // rather than its ack, that guest will need the clear moved to
        // `raiseCompletionLineAfterDelay` instead.
        window[Cell.diskAck] = 0
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
              let block = Self.blockNumber(track: track, sector: sector, side: side,
                                           doubleSided: isDoubleSidedMedia),
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
        guard let block = Self.blockNumber(track: track, sector: sector, side: side,
                                           doubleSided: isDoubleSidedMedia),
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
    /// **Double-sided (800K) layout is INTERLEAVED BY TRACK (M8).** A Sony
    /// 800K image orders blocks track-major, side-minor: track 0 side 0's
    /// sectors, then track 0 side 1's, then track 1 side 0, and so on --
    /// NOT all of side 0 followed by all of side 1.
    ///
    /// The `side == 1 ? block + 800` form this replaces was written in M2
    /// when only single-sided 400K images existed and no traced path had
    /// ever read side 1; M3 Task 3 flagged the whole double-sided path as
    /// untested. MacWorks Plus's 800K installer is the first thing to
    /// exercise it, and it caught the error immediately: live trace shows
    /// it read (track 0, side 0, sectors 0/2/4) and then (track 0, **side
    /// 1**, sector 4). Interleaved that is block 16; under the old form it
    /// was block 804 -- deep in the middle of the volume. Every read
    /// returned DISKERR 0, so MacWorks got plausible-looking garbage rather
    /// than an error, and ejected the diskette as unreadable.
    ///
    /// `doubleSided` defaults to false, leaving the single-sided mapping
    /// (including its physically-meaningless `side 1 -> +800`, which no
    /// caller reaches for 400K media) byte-identical for every existing
    /// pin, notably `FloppyControllerTests`' full-range property test.
    static func blockNumber(track: Int, sector: Int, side: Int,
                            doubleSided: Bool = false) -> Int? {
        guard side == 0 || side == 1 else { return nil }
        guard let (secPerTrack, base) = zoneInfo(forTrack: track) else { return nil }
        guard sector >= 0, sector < secPerTrack else { return nil }
        // Blocks preceding this track, counting ONE side.
        let cumulative = base + (track % 16) * secPerTrack
        guard doubleSided else {
            return side == 0 ? cumulative + sector : cumulative + sector + blocksPerSide
        }
        return 2 * cumulative + side * secPerTrack + sector
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
