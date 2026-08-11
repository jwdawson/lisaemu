import Foundation

/// High-level emulation (HLE) of the Lisa's COPS ("Cheap Old Peripheral
/// System" / keyboard-mouse-clock-power-management microcontroller),
/// reachable from the 68000 only through VIA2 -- Port A (`$FCDD83`/`$FCDD9F`,
/// register index 1/15) for data, DDRA2 (`$FCDD87`, register index 3) to flip
/// the shared bus's direction, and Port B bit 6 (`$FCDD81`, register index
/// 0) for the CRDY handshake line.
///
/// ## CRDY lives on Port B, NOT Port A -- refuting hardware-notes.md §4
///
/// The OS-source `libhw-DRIVERS` listing hardware-notes.md §4 was built from
/// describes CRDY as "VIA2 Port A bit 6". The Rev H boot ROM's own COPS
/// presence/command routine (`$FE0956`-`$FE09C0`, disassembled live under
/// this task's trace -- see docs/rom-trace-notes.md "COPS" section and
/// task-4-report.md for the full transcript) refutes that: every CRDY poll
/// in that routine is `btst #6,(A1)` with `A1 = $FCDD81` -- offset 0 from the
/// VIA2 base, i.e. **PORTB2**, not PORTA2 (`$FCDD83`, offset 2). Confirmed
/// independently by a direct register dump at the stall (`m fcdd80 20` under
/// `lisadbg`): `DDRB2 = $0E` (bits 1/2/3 output only -- bit 6 is an input,
/// consistent with CRDY being COPS-driven), `DDRA2 = $00` (Port A still
/// fully input at that point, before the routine's own DDRA2=$FF flip). Data
/// (the command byte, and later input bytes) is on Port A, exactly as
/// hardware-notes.md says; only the handshake bit's PORT is wrong there.
/// hardware-notes.md §4 is updated in lockstep with this file to record the
/// correction (marked refuted, not deleted, per the both-docs rule).
///
/// ## The command-send protocol, as the ROM actually drives it
///
/// `$FE0956`'s subroutine (parameter D0 = command byte), reverse-engineered
/// instruction-by-instruction:
///
/// 1. Write D0 to IORA2 (register 15, offset `$1E` -- the explicitly
///    "no-handshake" ORA alias) while DDRA2 is still `$00` (input): this
///    STAGES the byte in the VIA's output-register storage without
///    physically driving Port A's pins yet (real 6522 behavior: DDR gates
///    whether OR contents reach the pins).
/// 2. Poll CRDY (PORTB2 bit 6) until it reads 0 (loop `$FE097C-$FE0982`,
///    1562-iteration timeout).
/// 3. A short delay (`mulu.w #1,D0` -- cycle padding, not a real
///    multiplication), then poll CRDY==0 again (loop `$FE098C-$FE0992`,
///    same 1562-iteration timeout) -- this second loop reads as
///    functionally redundant against the first (CRDY has already settled
///    to 0) and in practice exits on its very first check.
/// 4. DDRA2 = `$FF` (register 3, offset `$06`) -- Port A now actually
///    drives the staged byte onto the bus. This is the real "send".
/// 5. Poll CRDY until it reads 1 again (loop `$FE099A-$FE09A0`, OPPOSITE
///    polarity from steps 2-3, same timeout) -- COPS acknowledging receipt.
/// 6. A ~10-iteration delay, then DDRA2 = `$00` (back to input -- COPS/other
///    bus users can drive Port A again).
/// 7. IER2 |= `$82` (register 14: set mode, bit 1) -- enables the VIA2
///    "COPS interrupt pending" source (hardware-notes.md §3's IFR2 bit 1)
///    for whatever comes next on the input side.
/// 8. On EITHER timeout, `ori #1,CCR` sets the carry flag (caller-visible
///    error return via `bcs`); success returns with carry clear.
///
/// ~~This model reduces that whole dance to: writing ORA (index 1 OR 15)
/// drops CRDY immediately (steps 2-3 always see 0 with zero/near-zero
/// iterations, matching the ROM's own observed near-instant loop-2 exit),
/// and a `Machine`-scheduled event some `commandAckDelayCycles` later
/// decodes the command and raises CRDY back to 1 (satisfying step 5) --
/// "plausible cycle delay", not instant, per the task brief, and
/// comfortably inside the ROM's ~1562-iteration (tens of thousands of
/// cycles) timeout either way.~~ SUPERSEDED by M4 Task 1 below -- the
/// "drops immediately" half of this was the M2-era shortcut that the OS's
/// own COPS driver cannot survive (see "M4 Task 1" below). The delayed-rise
/// half (ack after `commandAckDelayCycles`) is unchanged.
///
/// ## M4 Task 1 -- the OS's own `COPSCMD` needs a non-instant drop, cited
///
/// The loaded OS (`$520824`, LIBHW-DRIVERS:829-887 `COPSCMD`, byte-identical
/// between the compiled 3.1 image and the source per a live disassembly at
/// the frontier -- both sites match instruction-for-instruction) drives the
/// SAME protocol as the ROM but adds an outer retry shell around it:
///
/// 1. **Phase A** (`$520842`-`$52084E`, source `@0`/`@1`): write D0 to IORA2
///    (register 15, offset `$1E`, IDENTICAL to the ROM's step 1) while
///    briefly re-enabling interrupts around each attempt; test CRDY
///    (PORTB2 bit 6); if it reads 0, loop back and REWRITE the command byte,
///    retrying. Falls through once a test reads CRDY==1 ("ready").
/// 2. **Phase B** (`$520850`-`$520892`, source's 14 unrolled `BTST`/`BEQ`
///    pairs): test CRDY again, up to 14 times back-to-back, waiting for it
///    to drop to 0. If none of the 14 checks see 0, falls back to Phase A
///    (rewrites the command byte again). Otherwise falls through to Phase C.
/// 3. **Phase C** (`$520894`-`$5208A2`, source `@2`): DDRA2 = `$FF`, a fixed
///    ~10-iteration delay, DDRA2 = `$00` -- NO further CRDY poll (unlike the
///    ROM's step 5 ack-wait; `COPSCMD` just returns).
///
/// Critically, Phase A and Phase B BOTH run, and CRDY is expected to have
/// ALREADY dropped, BEFORE Phase C's DDRA2 flip ever executes -- the same
/// ordering the ROM's own routine uses (steps 2-3 before step 4). So for
/// BOTH senders, cited: **the reg-15 write is the drop's trigger, not the
/// DDRA2 flip** (an earlier hypothesis in hardware-notes.md/the M4 plan
/// guessed the flip gates it -- refuted by this disassembly evidence, struck
/// there per the both-docs rule). DDRA2 is not modeled by `COPS` at all: our
/// HLE has no bit-level Port A bus simulation, so a data-direction change has
/// no separately observable effect here.
///
/// The OLD instant-drop model breaks Phase A specifically: `handleCommandWrite`
/// set `crdyHigh = false` synchronously, so the `MOVE.B`-then-`BTST` pair at
/// `$520848`/`$52084C` (write immediately followed by test, zero intervening
/// instructions) ALWAYS observed the just-self-inflicted drop and ALWAYS
/// looped back to `$520842` -- forever (the M3 Task 4 frontier hang). Phase A
/// can only ever succeed if a write-then-immediate-test pair sees the OLD
/// (still-ready) state, which requires the drop to lag the write by more than
/// one instruction's worth of cycles -- but Phase B's very next 14 checks (a
/// few instructions later) must THEN see it dropped, or it loops back to
/// Phase A and repeats forever with the identical problem (whatever the delay
/// is, it must fit inside that ~14-check window measured from the write).
///
/// **The fix is a READ-COUNT gate, not a cycle-count delay**
/// (`suppressCRDYDropForNextRead`): the write still drops `crdyHigh`
/// synchronously (same instant as the pre-M4 model), but the VERY NEXT
/// `portBInput` read after that specific drop is suppressed -- it reports
/// the pre-drop (ready) state once, and every read after THAT reflects the
/// real dropped state. Concretely: Phase A's own write-then-test pair IS
/// that suppressed read (sees ready, exits Phase A on the first try, the
/// common case); Phase B's very first check is the NEXT read after that
/// (suppression already consumed), so it deterministically sees not-ready
/// immediately. The ROM's loop 1 similarly takes its first check as the
/// suppressed (still-ready) read and its second check as the real drop --
/// two iterations, not one, but still comfortably inside its 1562-iteration
/// timeout -- and loop 2 (which starts several reads further along) sees the
/// already-dropped state on its own first check, exactly matching this type
/// doc comment's pre-M4 "near-instant loop-2 exit" note above.
///
/// An earlier version of this fix used a short `scheduleEvent`-based cycle
/// delay (`commandLatchDelayCycles`, ~64 cycles) instead of this read-count
/// gate, and it broke under `Machine.run(until:)`'s BURST execution
/// (confirmed by `ROMFloppyBootTests` regressing -- see task-1-report.md):
/// `Bus`'s injected `scheduleEvent` closure computes a scheduled event's due
/// cycle from `Machine.cycles`, which is only updated once an ENTIRE
/// `cpu.run(cycles:)` burst finishes -- so a callback firing mid-burst (a
/// VIA2 port-A write, synchronously invoked from inside Musashi's
/// `m68k_execute`) sees a STALE "now", off by up to `Machine.irqPollQuantum`
/// (1024) cycles. A 64-cycle delay scheduled against that stale baseline can
/// already be overdue by the time `Machine.run(until:)` next drains its
/// event queue, collapsing back to an effectively-synchronous drop --
/// reproducing the exact bug this task exists to fix, but only under burst
/// execution (single-`step()`-driven runs, whose "now" is far less stale,
/// happened to still work, which is why this needed a live-boot
/// re-validation to catch, not just the protocol-level unit tests). The
/// read-count gate needs no cycle scheduling for the drop's visibility at
/// all, so it is exact and execution-granularity-independent by
/// construction. The rise still uses `scheduleEvent(commandAckDelayCycles)`
/// as before -- its ~400-cycle target has thousands of cycles of slack
/// against both senders' ~1562-iteration timeouts, so the same staleness is
/// harmless there, exactly as it always was pre-M4 (when only the rise was
/// scheduled at all). DDRA2 is not modeled by `COPS`: our HLE has no
/// bit-level Port A bus simulation, so a data-direction change alone has no
/// separately observable effect here. Reg-15 peeks (reads) never call
/// `handleCommandWrite` at all (see `handlePortAAccess` below) -- no model,
/// old, cycle-delay, or read-count, lets a peek perturb CRDY.
///

/// ## Command bytes (docs/hardware-notes.md §4 "Command Bytes")
///
/// The ROM's own POST presence probe (`$FE093E-$FE0954`) sends `$00`,
/// `$70`, `$50`, `$60` in sequence -- none of which are in the OS-derived
/// table below (they read as boot-ROM-only diagnostic/self-test opcodes,
/// undocumented in the OS driver source). This model ACKs any command byte
/// (completes the CRDY handshake) whether or not it recognizes it --
/// recognized bytes additionally drive the documented side effect; anything
/// else is a harmless no-op past the handshake.
///
/// ## Input FIFO (bytes COPS delivers TO the CPU)
///
/// One byte at a time, each becoming visible on Port A (`portAInput`) and
/// raising VIA2 IFR2 bit 1 (docs/hardware-notes.md §3) the instant it is
/// ready, per the state machine in hardware-notes.md §4 "Input Packet State
/// Machine". A genuine handshake read (register 1, offset `$02`/`IORA2`)
/// consumes the byte -- clears the interrupt flag and, after another
/// `byteDeliveryDelayCycles`, makes the next queued byte ready, if any. A
/// no-handshake read (register 15) is a peek: it does NOT consume anything,
/// mirroring the real CA1-vs-no-handshake register distinction the ROM's
/// own command routine relies on (`VIA6522.onPortAAccess`'s doc comment).
///
/// ## Power-on stream and the `$02` clock reply
///
/// - Power-on (`powerOnResetPacket`): `$80` (reset code follows -- state 4)
///   + the keyboard-ID sub-code (`placeholderKeyboardID`, `$3F` -- Final US,
///   76-key, per LEGENDS:583-596,660-859 and hardware-notes.md §8
///   "Keyboard ID"; the byte is masked with `$3F` by software, so
///   manufacturer bits 7-6 are don't-care -- CAVEAT: no factory log
///   confirms real hardware's manufacturer bits). M1b Task 7 reached the
///   boot menu with a `$2F` stand-in and established the packet's SHAPE
///   from the ROM's own reset-dispatch (a keyboard-ID reset is exactly
///   these 2 bytes); M1c Task 2's keyboard-input research corrected the
///   VALUE -- `$2F` is actually a UK layout code, not US -- see that
///   constant's doc comment and docs/rom-trace-notes.md "POST completion
///   (Task 7)". The stream is fidelity-only, not load-bearing: the ROM
///   draws the identical menu even with no power-on stream at all (verified
///   unaffected by this ID correction too -- see task-2-report.md).
///
/// ## M6 Task 2 -- the `$02` reply is now a REAL clock, parser-derived
///
/// ~~`$02` (read clock) reply: `$80, $E0, <4-byte big-endian host Unix
/// time>, $00` -- BEST-EFFORT PLACEHOLDER (hardware-notes gives no
/// byte-level format for the 5-byte clock payload). `$E0` (state-4 "clock
/// start", year nibble left `0`) framed behind `$80`...~~ SUPERSEDED. That
/// M1b-era placeholder shipped raw big-endian Unix-time bytes as if they
/// were the clock payload; the OS's own parser reads them as BCD and gets
/// garbage (an invalid day/hour), which is exactly why the Office System
/// showed its "clock not set" Note (see task-2-report.md live proof). The
/// real byte format is NOT a guess -- it is DERIVED from the OS's own COPS
/// input parser, `COPS3`/`COPS4` in libhw-DRIVERS:1161-1219, cross-checked
/// against the packing comment libhw-TIMERS:600-609 and the `ClockToDate`
/// consumer libhw-TIMERS:695-766. Documented in full in hardware-notes.md
/// §4 "Read-Clock ($02) Reply Format". Summary of the contract:
///
/// - The OS sends `$02`; `Clock` (TIMERS:619-641) then spins reading Port A,
///   feeding each byte to the `COPS` interrupt parser, until `ClockReady`.
/// - COPS replies with a 7-byte input stream: `$80` (State 0 -> State 4
///   "reset code follows"), then `$E0|year` (State 4 clock-start; the low
///   nibble is the year, DRIVERS:1216), then 5 data bytes (State 3,
///   DRIVERS:1161-1185). `ClockBytes` counts exactly 5, so the packet is
///   `$80` + 6 bytes.
/// - The clock/calendar is 6 nib-packed bytes (TIMERS:600-606):
///   `0000yyyy dddddddd ddddhhhh hhhhmmmm mmmmssss sssstttt` -- year binary
///   (1980=0), day-of-year (1..366), hour, minute, second, tenths all BCD.
///   The State-4 selector byte carries `yyyy` in its low nibble (the top
///   `0000` alarm nibble is dropped into the `$E` selector high nibble); the
///   5 State-3 data bytes are the remaining 5 packed bytes verbatim. So the
///   reply payload is `[$E0|yearNibble, dayHi:dayMid, dayLo:hourHi,
///   hourLo:minHi, minLo:secHi, secLo:tenths]`.
/// - Year windowing: the hardware year field is 4 bits and rolls over every
///   16 years (TIMERS:596); `ClockToDate` maps nibble `n` -> `1980+n`,
///   range 1980..1995 (TIMERS:687,711-713). Host years are mapped by the
///   same 16-year rollover: `yearNibble = (hostYear - 1980) & 0x0F` (e.g.
///   2026 -> nibble 14 -> displayed 1994). Faithful to the silicon, and it
///   keeps the desktop showing a plausible in-window date. See
///   `clockReplyBytes(from:)`.
/// - "Not set" sentinel: `0FFF FFFFFFFF` (TIMERS:608-609, DRIVERS:505-506).
///   When our modeled clock is OFF (a `$20` power-off cleared it) the reply
///   payload is `[$EF, $FF, $FF, $FF, $FF, $FF]`, which the parser folds to
///   `ClockHigh=$0FFF, ClockLow=$FFFFFFFF` -- the exact uninitialized
///   pattern, so the OS correctly re-shows "not set".
///
/// The boot ROM does not send `$02` on the path to the menu; the Office
/// System does, once, while building the desktop -- that read is what this
/// format satisfies.
public final class COPS {
    // MARK: - Tunable timing ("plausible", not cycle-exact -- see the type
    // doc comment). All comfortably inside the ROM's ~1562-iteration CRDY
    // poll timeouts (tens of thousands of cycles per loop).

    /// Cycles from a command-byte write (ORA, register 1 or 15) -- or more
    /// precisely, from the drop becoming VISIBLE (`handleCommandWrite`'s doc
    /// comment: the drop itself is a read-count gate, not cycle-scheduled)
    /// -- until CRDY returns to 1 and the command's decoded side effect (if
    /// any) takes place.
    static let commandAckDelayCycles: UInt64 = 400
    /// Cycles from a queued byte becoming eligible for delivery (FIFO was
    /// idle, or the previous byte was just consumed) until it actually
    /// appears on Port A and raises the interrupt.
    static let byteDeliveryDelayCycles: UInt64 = 300
    /// Cadence at which an undelivered/unconsumed pending byte's interrupt
    /// re-asserts -- see `armReassertTimer`'s doc comment for why this
    /// exists (a trace-found ROM/COPS desync, not a documented hardware
    /// value).
    static let interruptReassertDelayCycles: UInt64 = 4000

    /// CRDY (docs/hardware-notes.md §4, corrected above): PORTB2 bit 6.
    private static let crdyBit: UInt8 = 0x40
    /// VIA2 IFR2 bit 1: "COPS interrupt pending" (hardware-notes.md §3).
    /// `internal`, not `private`: `IODispatcher` needs it too, to wire
    /// `raiseInterrupt`/`clearInterrupt` onto the real `VIA6522.set/clear
    /// InterruptFlag` calls.
    static let interruptFlagBit: UInt8 = 0x02

    /// US keyboard ID, Final-US 76-key layout: `$3F` (LEGENDS:583-596,
    /// 660-859; masked with `$3F` by software -- DRIVERS:1106-1108,
    /// KEYBD:1256 -- so manufacturer bits 7-6 are don't-care). See
    /// hardware-notes.md §8 "Keyboard ID" for the full derivation.
    ///
    /// M1c Task 2 correction: M1b's value here was `$2F`, an unresearched
    /// stand-in that turns out to be the UK layout code, not US. Still
    /// named "placeholder" because the CAVEAT from the research stands: no
    /// factory log confirms real hardware's manufacturer bits, so `$3F`
    /// (manufacturer bits `00`) is the simplest mask-equivalent choice, not
    /// a uniquely confirmed byte -- see the type doc comment "Power-on
    /// stream" for the packet-shape history.
    static let placeholderKeyboardID: UInt8 = 0x3F
    /// The unsolicited reset announcement COPS delivers after its own
    /// self-test: `$80` ("reset code follows" -- hardware-notes.md §4 State
    /// 0 -> State 4) + a keyboard-ID sub-code (State 4, `$00-$DF`). Per that
    /// state machine a keyboard-ID reset packet is EXACTLY these two bytes:
    /// the 5-byte data payload belongs to State 3, reached only from a
    /// State-4 CLOCK-START sub-code (`$E0-$EF`), never a keyboard ID -- and
    /// the ROM's own reset-dispatch confirms this (the keyboard-ID branch at
    /// `$FE2D7C` stores the ID and loops WITHOUT reading 5 more bytes; only
    /// the `$E0-$EF` branch `$FE2D82` falls into the 5-byte loop at
    /// `$FE2D9E`).
    ///
    /// M1b Task 7 correction: Task 4 appended 5 trailing `$00` bytes here on
    /// a misreading of that dispatch as "unconditional 5 bytes after any
    /// sub-code". Removing them reaches the byte-identical boot menu (same
    /// framebuffer hash -- see docs/rom-trace-notes.md "POST completion
    /// (Task 7)"), and each was `$00`, the State-0 MOUSE-packet marker, so
    /// leaving them queued was a latent phantom-mouse-event hazard. The
    /// power-on stream is not load-bearing for reaching the menu at all (the
    /// menu draws even with an empty stream -- it is driven by the
    /// command-handshake path); this 2-byte packet is kept purely for
    /// fidelity (a real COPS is not silent at power-on) and exercises the
    /// reset-dispatch path. The keyboard-ID VALUE remains a placeholder.
    static let powerOnResetPacket: [UInt8] = [0x80, placeholderKeyboardID]

    // MARK: - Command bytes (docs/hardware-notes.md §4 "Command Bytes")

    enum Command {
        static let readClock: UInt8 = 0x02
        static let disableClockPrepSetClock: UInt8 = 0x2C
        static let writeClockNibbleBase: UInt8 = 0x10   // $10-$1F, low nibble = data
        static let enableClockDisableTimer: UInt8 = 0x25
        static let powerOffClockOff: UInt8 = 0x20
        static let powerOffClockOn: UInt8 = 0x21
        static let disableTimerSetRebootAlarm: UInt8 = 0x2D
        static let powerOffRebootLater: UInt8 = 0x23
        static let enableMouseInterrupts: UInt8 = 0x7C
    }

    // MARK: - Dependencies (all injected so protocol-level tests can drive
    // COPS with a fake clock/scheduler, no `Machine`/CPU required)

    private let scheduleEvent: (UInt64, @escaping () -> Void) -> Void
    private let currentCycle: () -> UInt64
    private let raiseInterrupt: () -> Void
    private let clearInterrupt: () -> Void
    /// M6 Task 1 (soft power): fired the instant a power-OFF command byte
    /// (`$20`/`$21`/`$23` -- hardware-notes.md §7 "Soft Power Control",
    /// MACHINE:425/427/473) is decoded, so the machine can stop executing
    /// cleanly. `Bus.powerOffHandler` -> `Machine.powerState = .off` is the
    /// real wiring; defaults to a no-op so protocol-level tests (and any
    /// caller that doesn't care about power) pay nothing. Distinct from
    /// `raiseInterrupt`: this is a one-way "the OS asked to be powered down"
    /// edge, not a VIA flag. The reboot-later alarm half of `$23`/`$2D`
    /// (waking at a scheduled time) is NOT modeled -- see `processCommand`.
    private let onPowerOff: () -> Void
    /// Injectable clock source for the `$02` read-clock reply
    /// (`enqueueClockReply` -> `clockReplyBytes(from:)`) -- `Date()` is
    /// LisaCore's only source of nondeterminism, and the Office System
    /// exercises this path once while building the desktop. Defaults to the
    /// real host clock; tests inject a fixed `Date` for a deterministic reply
    /// byte sequence. Fold-in from the M1b final review; M6 Task 2 made the
    /// encoding a real parser-derived BCD clock.
    private let clockSource: () -> Date

    // MARK: - CRDY / output (command) state

    private var crdyHigh = true
    /// M4 Task 1: set for exactly one PORTB2 read after a write that just
    /// transitioned `crdyHigh` true->false -- that ONE read (the sender's
    /// own write-then-immediately-test instruction pair) still sees the
    /// pre-drop (ready) state; every read after it sees the real dropped
    /// state. See `handleCommandWrite`'s doc comment for why this is a
    /// read-count gate, not a cycle-count delay.
    private var suppressCRDYDropForNextRead = false

    // MARK: - Port A / input FIFO state

    private var inputQueue: [UInt8] = []
    private var byteReady = false
    private var pendingByte: UInt8 = 0xFF
    private var deliveryScheduled = false

    // MARK: - Decoded command state, observable for tests/diagnostics

    /// Every recognized power-management command byte, in the order COPS
    /// received them (docs/hardware-notes.md §7 "Power Commands"). "Logged"
    /// per the task brief -- no power semantics are otherwise modeled.
    public private(set) var powerCommandLog: [UInt8] = []
    /// Low nibble of every `$10|n` "write clock nibble" command received,
    /// in order.
    public private(set) var clockSetNibbles: [UInt8] = []
    /// Set by `$7C` ("enable mouse interrupts (16ms)", hardware-notes.md §4).
    public private(set) var mouseInterruptsEnabled = false

    // MARK: - Clock ("keep it") state -- M6 Task 2

    /// Whether the modeled RTC currently holds a valid time. `true` by
    /// default (a real Lisa's battery-backed clock keeps running across soft
    /// power-off, TIMERS:596-598, so a freshly-booted machine finds it set --
    /// which is what kills the Office System's "clock not set" Note). A `$20`
    /// power-off (clock OFF, MACHINE:425) clears it; `$21`/`$23` (clock ON,
    /// MACHINE:427/473) preserve it. When `false`, `$02` replies with the
    /// `0FFF FFFFFFFF` uninitialized sentinel (TIMERS:608-609).
    public private(set) var clockRunning = true
    /// A clock the OS explicitly SET via the `$2C -> $10xN -> $25` sequence
    /// (TIMERS:652-680), stored as the 6-byte `$02` reply payload
    /// (`[$E0|year, ...5 data bytes]`). `nil` = no explicit set, so `$02`
    /// replies from the injected `clockSource` (host time). Once set, every
    /// subsequent `$02` read returns THIS value (the "set it changes reads"
    /// contract); it does not tick -- the OS reads the clock rarely (boot,
    /// file stamps) and a fixed set value is deterministic and sufficient.
    private var setClockReply: [UInt8]?
    /// True between a `$2C` (prep set-clock, TIMERS:656) and its closing
    /// `$25` (enable clock, TIMERS:673): the window during which `$10|n`
    /// nibbles are accumulated into `setSequenceNibbles` for this set.
    private var setSequenceActive = false
    /// Nibbles collected since the last `$2C`, in send order. SetClock sends
    /// 16 (TIMERS:659-671: 2 outer x 8 inner); the clock is the last 11
    /// (5 leading zeros from the high longword's zero-fill are dropped) --
    /// see `finishSetSequence`.
    private var setSequenceNibbles: [UInt8] = []

    /// Total bytes currently queued for delivery to the CPU, including one
    /// already "ready" on Port A (`byteReady`) but not yet consumed via a
    /// handshake read, if any. Read-only; no behavior depends on it or is
    /// gated by it. Undercounts by up to 1 while a byte is "in flight"
    /// (`deliveryScheduled == true`, removed from `inputQueue` but not yet
    /// `byteReady` -- see `scheduleDeliveryIfIdle`): that byte is counted
    /// in neither term for the `byteDeliveryDelayCycles` window between the
    /// two.
    ///
    /// M1c shell hook (docs/superpowers/plans/2026-08-05-m1c-app-shell.md
    /// Task 1, "input events reach COPS" test): `EmulationController` runs
    /// `Machine` on a dedicated thread, so a test can't peek at a live
    /// `Machine`'s state directly -- it has to go through a synchronous,
    /// thread-safe debug hook. That hook needs SOME public, synchronous
    /// signal that changes the instant `postKey`/`postMouse` enqueues a
    /// byte, without requiring the CPU to run forward through a full
    /// COPS/VIA2/ROM handshake first (which would make the test dependent
    /// on real ROM boot timing). The task brief named two options: this
    /// FIFO-length seam, or an `ioTrace`-based observation. `ioTrace`
    /// (`IODispatcher.logAccess`) does not cover VIA/COPS port accesses at
    /// all (only IOSpace latch/decode-level touches -- see
    /// `Bus.mmuPortWrites`/`ioTrace`'s doc comments and
    /// `ROMBootTests.romTouchesIOAndProgramsMMU`'s "SLIM/SORG port writes go
    /// through `Bus.slimSorgPortAccess`, not `ioTrace`"), so an ioTrace-based
    /// test would need to boot all the way to the menu and race real ROM
    /// polling timing to observe an indirect side effect. This one-line,
    /// read-only counter is strictly less invasive: it adds no new behavior,
    /// changes no existing code path, and gives an immediate, deterministic
    /// signal with zero cycle advancement required.
    public var pendingInputCount: Int {
        inputQueue.count + (byteReady ? 1 : 0)
    }

    // MARK: - VIA2 wiring

    /// Assign directly to `via2.portAInput`.
    public lazy var portAInput: () -> UInt8 = { [weak self] in
        guard let self else { return 0xFF }
        return self.byteReady ? self.pendingByte : 0xFF
    }
    /// Assign directly to `via2.portBInput`. M4 Task 1: the ONE read right
    /// after a fresh drop-triggering write is suppressed (see
    /// `suppressCRDYDropForNextRead`'s doc comment) -- every other read
    /// reflects `crdyHigh` normally.
    public lazy var portBInput: () -> UInt8 = { [weak self] in
        guard let self else { return 0xFF }
        if self.suppressCRDYDropForNextRead {
            self.suppressCRDYDropForNextRead = false
            return 0xFF
        }
        guard !self.crdyHigh else { return 0xFF }
        return 0xFF & ~Self.crdyBit
    }

    public init(scheduleEvent: @escaping (UInt64, @escaping () -> Void) -> Void,
                currentCycle: @escaping () -> UInt64,
                raiseInterrupt: @escaping () -> Void,
                clearInterrupt: @escaping () -> Void,
                clockSource: @escaping () -> Date = { Date() },
                onPowerOff: @escaping () -> Void = {}) {
        self.scheduleEvent = scheduleEvent
        self.currentCycle = currentCycle
        self.raiseInterrupt = raiseInterrupt
        self.clearInterrupt = clearInterrupt
        self.clockSource = clockSource
        self.onPowerOff = onPowerOff
    }

    /// Resets all COPS state and (re-)delivers the power-on stream. Callers
    /// (`Machine.reset()`) MUST call this AFTER clearing whatever event
    /// queue backs `scheduleEvent` -- otherwise a reset would wipe out the
    /// very power-on event this schedules. Real hardware: COPS itself is
    /// reset alongside everything else at power-on/reset.
    public func reset() {
        crdyHigh = true
        suppressCRDYDropForNextRead = false
        inputQueue.removeAll()
        byteReady = false
        pendingByte = 0xFF
        deliveryScheduled = false
        powerCommandLog.removeAll()
        clockSetNibbles.removeAll()
        mouseInterruptsEnabled = false
        // A battery-backed RTC survives reset with a valid time (TIMERS:596-
        // 598); default it running and unset-by-OS, so `$02` reads live host
        // time and the desktop shows a sane date without any set sequence.
        clockRunning = true
        setClockReply = nil
        setSequenceActive = false
        setSequenceNibbles.removeAll()
        for byte in Self.powerOnResetPacket {
            enqueue(byte)
        }
    }

    // MARK: - VIA2 onPortAAccess hook

    /// Assign to `via2.onPortAAccess`.
    public func handlePortAAccess(index: Int, value: UInt8, isWrite: Bool) {
        if isWrite {
            handleCommandWrite(value)
        } else if index == 1 {
            // Register 1 (handshake) consumes the pending byte; register 15
            // (no-handshake) is a peek with no side effect -- see the type
            // doc comment "Input FIFO".
            handleByteConsumed()
        }
    }

    // MARK: - Output (command) path

    /// M4 Task 1 (type doc comment "M4 Task 1"): the drop from a fresh write
    /// is real and synchronous (`crdyHigh = false` happens immediately, same
    /// as the pre-M4 model) -- but the VERY NEXT `portBInput` read after
    /// THAT SPECIFIC write is suppressed, showing the pre-drop (ready) state
    /// once, before reads start reflecting the real dropped state. This is a
    /// READ-COUNT gate, not a cycle-count delay, DELIBERATELY: an earlier
    /// version of this fix used a short `scheduleEvent` delay
    /// (`commandLatchDelayCycles`) instead, and it broke under
    /// `Machine.run(until:)`'s burst execution -- `Bus`'s `scheduleEvent`
    /// closure computes a scheduled event's due cycle from `Machine.cycles`,
    /// which is only updated AFTER a whole CPU burst completes (up to
    /// `Machine.irqPollQuantum`, 1024 cycles, stale relative to the instant
    /// a mid-burst VIA2 write callback actually fires) -- so a 64-cycle
    /// delay scheduled mid-burst could already be overdue by the time
    /// `Machine.run(until:)` next drains its event queue, collapsing back to
    /// the same "drops the instant the write happens" bug this task exists
    /// to fix (confirmed via `ROMFloppyBootTests` regressing under this
    /// exact mechanism -- see task-1-report.md). The read-count gate needs
    /// no cycle scheduling at all for the drop itself, so it is immune to
    /// that staleness: it is exact under `step()`, `run(until:)`, and any
    /// other execution granularity. The rise (`commandAckDelayCycles` later)
    /// keeps using `scheduleEvent` as before -- its ~400-cycle target has
    /// thousands of cycles of slack against both senders' ~1562-iteration
    /// timeouts, so the same staleness is harmless there (as it always was
    /// pre-M4, when only the rise was scheduled).
    private func handleCommandWrite(_ command: UInt8) {
        if crdyHigh {
            crdyHigh = false
            suppressCRDYDropForNextRead = true
        }
        scheduleEvent(Self.commandAckDelayCycles) { [weak self] in
            self?.processCommand(command)
            self?.crdyHigh = true
        }
    }

    private func processCommand(_ command: UInt8) {
        switch command {
        case Command.readClock:
            enqueueClockReply()
        case Command.writeClockNibbleBase...(Command.writeClockNibbleBase | 0x0F):
            let nibble = command & 0x0F
            clockSetNibbles.append(nibble)
            // Inside a `$2C..$25` set window, this nibble is part of the clock
            // the OS is writing (TIMERS:663-668). Outside one (e.g. the
            // PowerCycle `$2D` reboot-alarm nibbles, MACHINE:466-469), it is
            // still logged above but does not touch the stored clock.
            if setSequenceActive { setSequenceNibbles.append(nibble) }
        case Command.disableClockPrepSetClock:
            // `$2C` disable-clock/prep-set (TIMERS:656): opens the set window.
            powerCommandLog.append(command)
            setSequenceActive = true
            setSequenceNibbles.removeAll()
        case Command.enableClockDisableTimer:
            // `$25` enable-clock/disable-timer (TIMERS:673): closes the set
            // window and commits the accumulated nibbles as the new clock.
            powerCommandLog.append(command)
            finishSetSequence()
        case Command.disableTimerSetRebootAlarm:
            // `$2D` set clock for a reboot alarm (MACHINE:462). Logged for
            // provenance; the physical timed WAKE is not modeled (see below).
            powerCommandLog.append(command)
        case Command.powerOffClockOn, Command.powerOffRebootLater:
            // `$21`/`$23` power off with the clock LEFT ON (MACHINE:427/473):
            // the battery-backed RTC keeps its time across the power-off, so
            // the stored clock is PRESERVED. `$23` ("reboot later") also arms
            // a wake alarm on real hardware; that timed WAKE is DEFERRED (see
            // the deferral note below).
            powerCommandLog.append(command)
            onPowerOff()
        case Command.powerOffClockOff:
            // `$20` power off with the clock OFF (MACHINE:425): the RTC stops
            // and loses its time, so subsequent `$02` reads return the
            // uninitialized `0FFF..` sentinel (TIMERS:608-609). The OS only
            // issues `$20` when it already read the clock as unset (PowerDown,
            // MACHINE:423-425), so this is a faithful mirror, not a
            // data-loss surprise.
            powerCommandLog.append(command)
            clockRunning = false
            setClockReply = nil
            onPowerOff()
        case Command.enableMouseInterrupts:
            mouseInterruptsEnabled = true
        default:
            break   // unrecognized (e.g. the ROM's own POST probe bytes) -- handshake-only ack
        }
        // DEFERRED (M7): the `$23`/`$2D` timed-reboot WAKE half. PowerCycle
        // (MACHINE:447-480) sends `$2D` + 5 alarm nibbles + `$23` to power off
        // and wake after N seconds -- but ONLY when the clock is already set
        // (MACHINE:451-456 falls back to a plain PowerDown otherwise). Now
        // that our clock reads as set, that path becomes reachable; modeling
        // the wake needs host-time alarm scheduling that RE-POWERS the
        // Machine (Task 1's `powerState` in reverse), which is out of this
        // task's read/set/keep scope. The alarm nibbles are captured in
        // `clockSetNibbles` for provenance. Source expectation on delivery:
        // MACHINE:447-480. Documented in hardware-notes.md §4/§7.
    }

    /// Commits a completed `$2C..$25` set sequence (TIMERS:652-680) into
    /// `setClockReply`. SetClock sends 16 nibbles (2 outer x 8 inner loops,
    /// TIMERS:659-671): the high clock longword's 8 nibbles (5 leading zeros
    /// from its `AND #$0FFF` zero-fill, then year + 2 day nibbles) followed
    /// by the low longword's 8 (the remaining day nibble + hour/minute/second/
    /// tenths). The meaningful clock is the LAST 11 nibbles
    /// `[year, dayHi, dayMid, dayLo, hourHi, hourLo, minHi, minLo, secHi,
    /// secLo, tenths]`; we drop the 5 leading fill nibbles and repack into the
    /// 6-byte `$02` reply payload `[$E0|year, ...5 data bytes]` -- the exact
    /// inverse of the `COPS4`/`COPS3` parser (DRIVERS:1212-1185).
    private func finishSetSequence() {
        setSequenceActive = false
        guard setSequenceNibbles.count >= 11 else {
            // Malformed/short sequence: leave the prior clock untouched.
            setSequenceNibbles.removeAll()
            return
        }
        let n = Array(setSequenceNibbles.suffix(11))
        setSequenceNibbles.removeAll()
        let selector = 0xE0 | (n[0] & 0x0F)
        setClockReply = [selector,
                         (n[1] << 4) | n[2], (n[3] << 4) | n[4],
                         (n[5] << 4) | n[6], (n[7] << 4) | n[8],
                         (n[9] << 4) | n[10]]
        clockRunning = true
    }

    private func enqueueClockReply() {
        enqueue(0x80)
        for byte in currentClockReplyPayload() {
            enqueue(byte)
        }
    }

    /// The 6-byte `$02` reply payload for the modeled clock's current state:
    /// the uninitialized sentinel when the clock is off, an explicitly-set
    /// value if the OS set one, else live host time. See the type doc comment
    /// "M6 Task 2 -- the `$02` reply".
    private func currentClockReplyPayload() -> [UInt8] {
        guard clockRunning else { return Self.notSetClockReply }
        if let set = setClockReply { return set }
        return Self.clockReplyBytes(from: clockSource())
    }

    /// The `0FFF FFFFFFFF` "clock not set since battery loss" pattern
    /// (TIMERS:608-609) as a `$02` reply payload: `$EF` (State-4 clock-start,
    /// year nibble `$F`) + five `$FF`. The parser folds this to
    /// `ClockHigh=$0FFF, ClockLow=$FFFFFFFF` (DRIVERS:1214-1185), the exact
    /// value `ClockToDate` treats as uninitialized (DRIVERS:505-506).
    static let notSetClockReply: [UInt8] = [0xEF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    /// Encodes a host `Date` into the 6-byte `$02` reply payload
    /// `[$E0|yearNibble, dayHi:dayMid, dayLo:hourHi, hourLo:minHi,
    /// minLo:secHi, secLo:tenths]`, per the clock/calendar packing
    /// (TIMERS:600-606) and the parser (DRIVERS:1212-1185). Day is day-of-
    /// year (1..366, TIMERS:687); hour/minute/second/tenths and each day
    /// digit are BCD; year is the 16-year-rollover nibble `(year-1980)&$F`
    /// (TIMERS:596,711-713). Decoded in a FIXED UTC Gregorian calendar so the
    /// byte sequence is a pure function of the `Date` (tests inject a fixed
    /// `Date`; `Date()` is LisaCore's only nondeterminism).
    public static func clockReplyBytes(from date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .hour, .minute, .second, .nanosecond], from: date)
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = c.year ?? 1980
        let yearNibble = UInt8((year - 1980) & 0x0F)
        let dH = UInt8((dayOfYear / 100) % 10)
        let dT = UInt8((dayOfYear / 10) % 10)
        let dO = UInt8(dayOfYear % 10)
        let hH = UInt8(((c.hour ?? 0) / 10) % 10), hL = UInt8((c.hour ?? 0) % 10)
        let mH = UInt8(((c.minute ?? 0) / 10) % 10), mL = UInt8((c.minute ?? 0) % 10)
        let sH = UInt8(((c.second ?? 0) / 10) % 10), sL = UInt8((c.second ?? 0) % 10)
        let tenths = UInt8(((c.nanosecond ?? 0) / 100_000_000) % 10)
        return [0xE0 | yearNibble,
                (dH << 4) | dT, (dO << 4) | hH,
                (hL << 4) | mH, (mL << 4) | sH,
                (sL << 4) | tenths]
    }

    // MARK: - Input path (FIFO -> Port A + interrupt)

    private func enqueue(_ byte: UInt8) {
        inputQueue.append(byte)
        scheduleDeliveryIfIdle()
    }

    private func handleByteConsumed() {
        guard byteReady else { return }
        byteReady = false
        pendingByte = 0xFF
        clearInterrupt()
        scheduleDeliveryIfIdle()
    }

    private func scheduleDeliveryIfIdle() {
        guard !byteReady, !deliveryScheduled, !inputQueue.isEmpty else { return }
        deliveryScheduled = true
        let next = inputQueue.removeFirst()
        scheduleEvent(Self.byteDeliveryDelayCycles) { [weak self] in
            guard let self else { return }
            self.deliveryScheduled = false
            self.pendingByte = next
            self.byteReady = true
            self.raiseInterrupt()
            self.armReassertTimer()
        }
    }

    /// Re-asserts IFR2 bit 1 on a recurring cadence for as long as a byte
    /// remains undelivered, self-cancelling once it's consumed.
    ///
    /// TRACE-FOUND BUG FIX: without this, a real ROM sequence desyncs COPS
    /// from the VIA -- observed live under this task's trace (see
    /// task-4-report.md "The IFR2 desync"). The power-on stream's `$80`
    /// raises IFR2 bit 1 within microseconds of reset, but the ROM doesn't
    /// get around to reading Port A until much later; in between, its own
    /// VIA2 driver-init sequence does a blanket `IFR2 = $7F` ("clear all"
    /// housekeeping, hardware-notes.md §3) that wipes the bit via a route
    /// (`VIA6522.write(13, ...)`) COPS has no hook into. With only a
    /// one-shot `raiseInterrupt()`, `byteReady` stays permanently `true`
    /// (nothing re-delivers what's "already" pending) while IFR2 reads
    /// `$00` forever -- the CPU's poll loop (`$FE2DC6-$FE2DCE`, no timeout)
    /// then hangs forever waiting for a flag that will never come back.
    /// Real hardware doesn't have this failure mode: a physical "data
    /// ready" condition that's still true keeps re-asserting regardless of
    /// a premature software flag-clear; this timer is the HLE model of
    /// that self-healing behavior, without needing to thread a new
    /// COPS-specific hook through the otherwise address/device-agnostic
    /// `VIA6522` core.
    private func armReassertTimer() {
        scheduleEvent(Self.interruptReassertDelayCycles) { [weak self] in
            guard let self, self.byteReady else { return }
            self.raiseInterrupt()
            self.armReassertTimer()
        }
    }

    // MARK: - Public keyboard/mouse injection (later milestones)

    /// Enqueues a keyboard event: bit 7 = down/up, bits 6-0 = keycap
    /// (docs/hardware-notes.md §4, Input Packet State Machine, State 0).
    public func postKey(code: UInt8, down: Bool) {
        enqueue((down ? 0x80 : 0x00) | (code & 0x7F))
    }

    /// Enqueues a 3-byte mouse-movement packet: `$00` (state 0 -> state 1
    /// marker) followed by dx, dy (states 1/2).
    public func postMouse(dx: Int8, dy: Int8) {
        enqueue(0x00)
        enqueue(UInt8(bitPattern: dx))
        enqueue(UInt8(bitPattern: dy))
    }

    /// Presses the soft-power button (M6 Task 1). COPS delivers the button as
    /// a two-byte reset-dispatch packet on its input stream: `$80` ("reset
    /// code follows" -- State 0 -> State 4, hardware-notes.md §4 Input Packet
    /// State Machine) followed by `$FB` (State 4 "power button" sub-code,
    /// DRIVERS:1227-1232, hardware-notes.md §4/§8). This is exactly what a
    /// real COPS puts on the wire; the OS's own COPS input handler is what
    /// synthesizes the pseudo-keycap `$08` down/up from `$FB` (the M1b-era
    /// note that COPS itself sends `$08` was imprecise -- COPS sends `$FB`,
    /// the OS makes the `$08`; corrected in lockstep in hardware-notes.md
    /// §4/§7/§8). Modeling the faithful `$FB` (not a synthesized `$08`) means
    /// the OS runs its real DRIVERS dispatch, exactly as on hardware.
    ///
    /// Same shape as `postKey`/`postMouse`: the bytes go through the ordinary
    /// input FIFO (`enqueue`), delivered one at a time via the CRDY/IFR2
    /// handshake -- no special path.
    public func pressPowerButton() {
        enqueue(0x80)   // State 0 -> State 4: "reset code follows"
        enqueue(0xFB)   // State 4: power-button sub-code
    }
}
