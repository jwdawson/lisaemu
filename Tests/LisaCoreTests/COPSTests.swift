import Foundation
import Testing
@testable import LisaCore

// Protocol-level, CPU-free tests for the COPS HLE endpoint (Task 4). No
// `Bus`/`Machine`/`M68K` involved -- these drive `COPS` directly through its
// injected scheduler/clock/interrupt closures and the same
// `portAInput`/`portBInput`/`handlePortAAccess` surface `IODispatcher` wires
// onto `VIA6522`. Because no CPU is driven, this suite does NOT need
// `MusashiSuites` serialization (matching `VIA6522Tests.swift`'s reasoning).
//
// See `COPS.swift`'s type doc comment for the full protocol this models,
// including the CRDY-lives-on-Port-B-not-Port-A correction to
// hardware-notes.md §4 established by this task's ROM trace.

/// A tiny deterministic fake of `Machine`'s cycle clock + event queue, so
/// these tests can drive COPS's "plausible cycle delay" scheduling without
/// a real `Machine`/CPU.
private final class FakeScheduler {
    private(set) var cycle: UInt64 = 0
    private var events: [(due: UInt64, action: () -> Void)] = []

    func schedule(_ delay: UInt64, _ action: @escaping () -> Void) {
        events.append((due: cycle + delay, action: action))
    }

    func now() -> UInt64 { cycle }

    /// Advances the fake clock to `target` and fires every event now due,
    /// in the order they were scheduled -- including events newly scheduled
    /// by an action that just fired (e.g. a command's ack scheduling a
    /// clock-reply byte's delivery), as long as their due cycle is also
    /// `<= target`.
    func advance(to target: UInt64) {
        cycle = target
        while let idx = events.firstIndex(where: { $0.due <= cycle }) {
            let action = events.remove(at: idx).action
            action()
        }
    }

    func advance(by delta: UInt64) { advance(to: cycle + delta) }
}

/// Consumes the full power-on stream (`COPS.powerOnResetPacket`: `$80` +
/// keyboard ID) via genuine handshake reads, one delivery-delay hop at a
/// time, so tests that care about what comes AFTER power-on don't need to
/// hardcode its byte count.
private func drainPowerOnStream(_ cops: COPS, _ scheduler: FakeScheduler) {
    let totalBytes = COPS.powerOnResetPacket.count
    for _ in 0..<totalBytes {
        scheduler.advance(by: COPS.byteDeliveryDelayCycles)
        cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    }
}

/// Callable (`interruptRaised()`) like the plain closure this replaces, plus
/// `clear()` -- used by `pendingByteReassertsItsInterruptIfExternallyCleared`
/// to simulate the real VIA2 `IFR2 = $7F` write that clears the flag
/// through a path COPS's `clearInterrupt` closure never sees.
private final class InterruptObserver {
    private(set) var pending = false
    func raise() { pending = true }
    func clear() { pending = false }
    func callAsFunction() -> Bool { pending }
}

private func makeCOPS(clockSource: @escaping () -> Date = { Date(timeIntervalSince1970: 0) })
    -> (cops: COPS, scheduler: FakeScheduler, interruptRaised: InterruptObserver) {
    let scheduler = FakeScheduler()
    let interruptPending = InterruptObserver()
    let cops = COPS(
        scheduleEvent: { delay, action in scheduler.schedule(delay, action) },
        currentCycle: { scheduler.now() },
        raiseInterrupt: { interruptPending.raise() },
        clearInterrupt: { interruptPending.clear() },
        clockSource: clockSource
    )
    return (cops, scheduler, interruptPending)
}

// MARK: - CRDY handshake (output/command path)

@Test func commandWriteDropsCRDYButSuppressesItForExactlyOneSubsequentRead() {
    // M4 Task 1: the OLD (pre-M4) model dropped CRDY the same instant a
    // command byte was written, AND that drop was immediately visible to
    // the very next read -- see COPS.swift's type doc comment "M4 Task 1"
    // for why that breaks the OS's own COPSCMD (Phase A writes then
    // IMMEDIATELY tests, in the same instruction pair; if that test could
    // ever see anything but "still ready", Phase A would loop forever). The
    // corrected model still drops CRDY synchronously with the write, but
    // gates its VISIBILITY by read count, not cycle count (see that doc
    // comment for why a cycle-based delay doesn't survive
    // `Machine.run(until:)`'s burst execution): the FIRST read after the
    // drop-triggering write still reports ready; every read after that
    // reports the real dropped state.
    let (cops, _, _) = makeCOPS()
    #expect(cops.portBInput() & 0x40 != 0, "CRDY idles high (ready)")

    cops.handlePortAAccess(index: 15, value: 0x00, isWrite: true)   // the ROM's own POST probe uses register 15
    #expect(cops.portBInput() & 0x40 != 0,
            "the FIRST read after the write still sees ready -- the OS's write-then-immediate-test pair depends on this")
    #expect(cops.portBInput() & 0x40 == 0,
            "the SECOND read (and every read after) sees the real dropped state")
}

@Test func commandCompletesAfterPlausibleDelayRestoringCRDY() {
    let (cops, scheduler, _) = makeCOPS()
    cops.handlePortAAccess(index: 15, value: 0x00, isWrite: true)
    _ = cops.portBInput()   // consume the one suppressed (still-ready) read
    #expect(cops.portBInput() & 0x40 == 0)

    scheduler.advance(by: COPS.commandAckDelayCycles - 1)
    #expect(cops.portBInput() & 0x40 == 0, "not yet -- delay hasn't fully elapsed")

    scheduler.advance(by: 1)
    #expect(cops.portBInput() & 0x40 != 0, "CRDY returns to ready after the plausible delay")
}

@Test func commandWriteViaHandshakeRegisterAlsoDrivesCRDY() {
    // Register 1 (the "real" handshake ORA) must behave identically to
    // register 15 for the send side -- the ROM's own routine only exercises
    // 15, but the OS driver may use either.
    let (cops, scheduler, _) = makeCOPS()
    cops.handlePortAAccess(index: 1, value: 0x7C, isWrite: true)
    _ = cops.portBInput()   // consume the one suppressed (still-ready) read
    #expect(cops.portBInput() & 0x40 == 0)
    scheduler.advance(by: COPS.commandAckDelayCycles)
    #expect(cops.portBInput() & 0x40 != 0)
}

@Test func unrecognizedCommandBytesStillAckTheHandshake() {
    // The ROM's own POST presence probe sends $00, $70, $50, $60 -- none of
    // which are in hardware-notes.md's OS-derived command table. These must
    // still complete the CRDY handshake (so the ROM's presence check
    // succeeds) even though COPS doesn't recognize them.
    for probe: UInt8 in [0x00, 0x70, 0x50, 0x60] {
        let (cops, scheduler, _) = makeCOPS()
        cops.handlePortAAccess(index: 15, value: probe, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
        #expect(cops.portBInput() & 0x40 != 0, "probe byte $\(String(probe, radix: 16)) should still ack")
    }
}

// MARK: - M4 Task 1: the OS's own COPSCMD retry+poll shape (LIBHW-DRIVERS:829-887)

/// Simulates the OS's own `COPSCMD` (LIBHW-DRIVERS:829-887, byte-identical
/// to the live `$520824` OS driver per task-1-report.md's disassembly
/// cross-check) directly against `COPS`+`FakeScheduler`: Phase A rewrites
/// the command byte and tests CRDY on every retry (real 68000 timing: the
/// `MOVE.B`-then-`BTST` pair at `$520848`/`$52084C` has zero intervening
/// instructions -- modeled here as a write immediately followed by a test,
/// zero elapsed cycles between them, the worst case for catching a
/// same-instant drop); Phase B is up to 14 back-to-back `BTST`/`Bcc` checks
/// (`$520850`-`$520892`) waiting for CRDY to THEN drop; Phase C
/// (DDRA2 = `$FF`, fixed delay, DDRA2 = `$00`, `$520894`-`$5208A2`) is not
/// modeled at all -- `COPS` has no bit-level Port A bus simulation, so a
/// pure data-direction change is not separately observable here (see the
/// type doc comment "M4 Task 1"). Per-instruction cycle costs below are
/// plausible approximations (classic MC68000 timing: `MOVE.B Dn,(d16,An)`
/// ~=12, `BTST Dn,(An)`/`Bcc` ~=8-10), not Musashi-exact -- same "plausible,
/// not cycle-exact" bar the rest of this type's timing already uses.
@Test func osCOPSCMDRetryThenPollThenDropSequenceCompletes() {
    let (cops, scheduler, _) = makeCOPS()
    drainPowerOnStream(cops, scheduler)   // realistic idle COPS, as the OS would find it

    let writeCost: UInt64 = 12
    let testCost: UInt64 = 8

    // Phase A.
    var phaseARetries = 0
    var sawReadyRightAfterWrite = false
    while phaseARetries < 50 {
        cops.handlePortAAccess(index: 15, value: 0x7C, isWrite: true)   // COPSCMD's own $7C (enable mouse interrupts)
        scheduler.advance(by: writeCost)
        let ready = cops.portBInput() & 0x40 != 0
        scheduler.advance(by: testCost)
        if ready { sawReadyRightAfterWrite = true; break }
        phaseARetries += 1
    }
    #expect(sawReadyRightAfterWrite,
            "Phase A must eventually observe CRDY still ready right after a write -- the OLD instant-drop model could NEVER do this, hence the M3/M4 frontier hang")
    #expect(phaseARetries == 0,
            "on an idle COPS the very first write's own test should already read ready -- the OS/ROM's typical fast path")

    // Phase B.
    var phaseBChecks = 0
    var sawDrop = false
    while phaseBChecks < 14 {
        let notReady = cops.portBInput() & 0x40 == 0
        scheduler.advance(by: testCost)
        phaseBChecks += 1
        if notReady { sawDrop = true; break }
    }
    #expect(sawDrop,
            "Phase B's 14-check window must observe the drop -- otherwise COPSCMD loops back to Phase A forever, re-creating the frontier hang")

    // Phase C is a no-op for COPS (DDRA2 only); CRDY still rises on its own
    // schedule afterward, ready for the NEXT command.
    scheduler.advance(by: COPS.commandAckDelayCycles)
    #expect(cops.portBInput() & 0x40 != 0, "CRDY is ready again for the next command")
}

/// Models the ROM's own `$FE0956` `SendCOPSCommand` end-to-end (hardware-notes.md
/// §4 "Command Protocol"): single write, poll for CRDY==0 (loop 1, up to the
/// ROM's own 1562-iteration timeout), a near-instant redundant second poll
/// (loop 2), DDRA2 = `$FF` (not modeled), poll for CRDY==1 (the ack, loop
/// "step 5"), DDRA2 = `$00`. Must still complete under the corrected model.
@Test func romsPollThenDriveThenAckPatternStillCompletes() {
    let (cops, scheduler, _) = makeCOPS()
    drainPowerOnStream(cops, scheduler)

    cops.handlePortAAccess(index: 15, value: 0x00, isWrite: true)   // the ROM's own POST probe byte

    var loop1Iterations = 0
    while cops.portBInput() & 0x40 != 0 && loop1Iterations < 1562 {
        scheduler.advance(by: 20)
        loop1Iterations += 1
    }
    #expect(loop1Iterations < 1562, "loop 1 must observe the drop well inside the ROM's own timeout")
    #expect(cops.portBInput() & 0x40 == 0, "loop 2's first check already sees it dropped -- near-instant, per the M1b trace")

    var ackIterations = 0
    while cops.portBInput() & 0x40 == 0 && ackIterations < 1562 {
        scheduler.advance(by: 20)
        ackIterations += 1
    }
    #expect(ackIterations < 1562, "the ack (step 5) must arrive well inside the ROM's own timeout")
    #expect(cops.portBInput() & 0x40 != 0, "CRDY reads ready again -- COPS acknowledging receipt")
}

/// M4 Task 1: reg-15 (no-handshake) PEEKS -- Port A reads, never writes --
/// must never perturb CRDY (a Port B concern), including while a command's
/// own drop/ack schedule is in flight (the ROM's presence probe and the
/// OS's input-FIFO peeks both rely on this never happening). Also verifies
/// Port A peeks don't accidentally consume the Port B
/// `suppressCRDYDropForNextRead` gate meant for the sender's OWN next
/// `portBInput` read.
@Test func reg15PeeksNeverPerturbCRDYEvenDuringAnInFlightCommand() {
    let (cops, scheduler, _) = makeCOPS()
    drainPowerOnStream(cops, scheduler)

    for _ in 0..<5 { cops.handlePortAAccess(index: 15, value: 0, isWrite: false) }
    #expect(cops.portBInput() & 0x40 != 0, "bare peeks on an idle COPS never drop CRDY")

    cops.handlePortAAccess(index: 15, value: 0x7C, isWrite: true)
    for _ in 0..<5 {
        cops.handlePortAAccess(index: 15, value: 0, isWrite: false)   // Port A peek -- unrelated port
        scheduler.advance(by: 4)
    }
    #expect(cops.portBInput() & 0x40 != 0,
            "the suppressed first CRDY read still shows ready -- untouched by the interleaved Port A peeks")
    #expect(cops.portBInput() & 0x40 == 0, "the second CRDY read now shows the real dropped state")

    for _ in 0..<5 { cops.handlePortAAccess(index: 15, value: 0, isWrite: false) }
    #expect(cops.portBInput() & 0x40 == 0, "peeks during the not-ready window neither re-raise nor re-drop it")

    scheduler.advance(by: COPS.commandAckDelayCycles)
    #expect(cops.portBInput() & 0x40 != 0, "the ack still fires on schedule despite the interleaved peeks")
}

// MARK: - Command decode

/// Drives a `$02` read-clock command through the ack + delivery delays and
/// returns the full delivered input stream (`$80` frame + 6-byte payload).
private func readClockStream(_ cops: COPS, _ scheduler: FakeScheduler) -> [UInt8] {
    cops.handlePortAAccess(index: 1, value: COPS.Command.readClock, isWrite: true)
    // Two hops: the command's own ack delay, then (once the reply is
    // enqueued by that ack firing) the first reply byte's delivery delay.
    scheduler.advance(by: COPS.commandAckDelayCycles)
    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    var received: [UInt8] = []
    for _ in 0..<7 {   // $80 + 6 payload bytes ($E0|year + 5 data)
        received.append(cops.portAInput())
        cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
        scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    }
    return received
}

/// M6 Task 2: the `$02` reply is a REAL clock, byte-for-byte DERIVED from
/// the OS's own COPS parser (`COPS4`/`COPS3`, libhw-DRIVERS:1212-1185) and
/// the clock/calendar packing (libhw-TIMERS:600-606). The reply payload is
/// `[$E0|yearNibble, dayHi:dayMid, dayLo:hourHi, hourLo:minHi, minLo:secHi,
/// secLo:tenths]` with BCD date fields and a 16-year-rollover year nibble.
///
/// This pins the encoding for a FIXED injected `Date` -- 2023-04-10
/// 13:45:30.5 UTC (epoch 1681134330.5), day-of-year 100, year nibble
/// `(2023-1980)&$F = $B`. The expected bytes are hand-derived from the
/// packing rule, NOT by calling the encoder (see the type doc comment for
/// the full derivation): year `$B`, day 100 -> BCD `1,0,0`; 13:45:30 ->
/// `1,3 4,5 3,0`; tenths `5`.
@Test func readClockReplyEncodesHostTimeAsParserBCD() {
    let fixedDate = Date(timeIntervalSince1970: 1_681_134_330.5)
    // selector $E0|$B=$EB; b1=dH:dT=$10; b2=dO:hH=$01; b3=hL:mH=$34;
    // b4=mL:sH=$53; b5=sL:tenths=$05.
    let expectedPayload: [UInt8] = [0xEB, 0x10, 0x01, 0x34, 0x53, 0x05]
    let (cops, scheduler, interruptRaised) = makeCOPS(clockSource: { fixedDate })
    cops.reset()
    drainPowerOnStream(cops, scheduler)
    #expect(interruptRaised() == false, "FIFO drained")

    let received = readClockStream(cops, scheduler)
    #expect(received == [0x80] + expectedPayload)
}

/// Feeding those same reply bytes back through a real Lisa `ClockToDate`
/// (libhw-TIMERS:695-766) must recover 2023 / day 100 / 13:45:30 -- a
/// round-trip against the OS consumer, closing the loop the type doc opens.
/// This models the parser's fold (`$EB` -> ClockHigh=$0B10; data ->
/// ClockLow=$01345305) and the BCD unpack, in Swift, as an independent
/// oracle for the byte layout.
@Test func readClockReplyRoundTripsThroughClockToDateSemantics() {
    let payload: [UInt8] = [0xEB, 0x10, 0x01, 0x34, 0x53, 0x05]
    // Parser fold (DRIVERS:1214-1176): selector low nibble -> year; byte1
    // completes ClockHigh; bytes 2..5 are ClockLow.
    let clockHigh = UInt16(0x0F & payload[0]) << 8 | UInt16(payload[1])
    var clockLow: UInt32 = 0
    for b in payload[2...] { clockLow = (clockLow << 8) | UInt32(b) }
    #expect(clockHigh != 0x0FFF, "a set clock is NOT the not-set sentinel")
    // ClockToDate BCD unpack (TIMERS:711-754).
    let year = 1980 + Int(clockHigh >> 8 & 0x0F)
    let dayHi = Int(clockHigh >> 4 & 0x0F), dayMid = Int(clockHigh & 0x0F)
    let dayLo = Int(clockLow >> 28 & 0x0F)
    let day = dayHi * 100 + dayMid * 10 + dayLo
    let hour = Int(clockLow >> 24 & 0x0F) * 10 + Int(clockLow >> 20 & 0x0F)
    let minute = Int(clockLow >> 16 & 0x0F) * 10 + Int(clockLow >> 12 & 0x0F)
    let second = Int(clockLow >> 8 & 0x0F) * 10 + Int(clockLow >> 4 & 0x0F)
    // Year nibble $B (=(2023-1980)&$F=11) decodes to 1980+11 = 1991: the
    // 16-year rollover window (TIMERS:596,711-713) maps 2023 -> displayed
    // 1991 (2023 - 32). The nibble round-trips exactly; the DISPLAYED year is
    // the in-window representative, which is the whole point of the windowing.
    #expect(year == 1991)
    #expect(day == 100)
    #expect(hour == 13 && minute == 45 && second == 30)
}

/// The set sequence `$2C -> $10xN -> $25` (TIMERS:652-680) commits a new
/// clock, and a subsequent `$02` read returns THAT clock, not host time --
/// the "set it changes reads" contract. The 16 nibbles SetClock would send
/// for 2023/day100/13:45:30.5 are hand-derived: the high longword
/// `$00000B10` (`0,0,0,0,0,B,1,0`) then the low longword `$01345305`
/// (`0,1,3,4,5,3,0,5`); dropping the 5 fill zeros yields the same payload
/// the host-time test pins.
@Test func setClockSequenceChangesSubsequentReads() {
    // Inject a DIFFERENT host time (epoch 0 = 1970, out of window) so a pass
    // can only come from the SET value, never a host-clock fallback.
    let (cops, scheduler, _) = makeCOPS(clockSource: { Date(timeIntervalSince1970: 0) })
    cops.reset()
    drainPowerOnStream(cops, scheduler)

    let setNibbles: [UInt8] = [0,0,0,0,0, 0xB,1,0, 0,1,3,4,5,3,0,5]
    cops.handlePortAAccess(index: 15, value: 0x2C, isWrite: true)   // open set window
    scheduler.advance(by: COPS.commandAckDelayCycles)
    for n in setNibbles {
        cops.handlePortAAccess(index: 15, value: 0x10 | n, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
    }
    cops.handlePortAAccess(index: 15, value: 0x25, isWrite: true)   // commit
    scheduler.advance(by: COPS.commandAckDelayCycles)

    let received = readClockStream(cops, scheduler)
    #expect(received == [0x80, 0xEB, 0x10, 0x01, 0x34, 0x53, 0x05],
            "a set clock, not the 1970 host fallback, is returned")
}

@Test func writeClockNibbleCommandsAccumulateInOrder() {
    // Raw $10 nibbles OUTSIDE a $2C..$25 window are still logged (provenance)
    // but do not build a stored clock.
    let (cops, scheduler, _) = makeCOPS()
    for n: UInt8 in [0x1, 0xA, 0xF] {
        cops.handlePortAAccess(index: 15, value: 0x10 | n, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
    }
    #expect(cops.clockSetNibbles == [0x1, 0xA, 0xF])
}

/// Power-off clock semantics (MACHINE:425/427/473): `$21`/`$23` leave the
/// clock ON (a set value survives, subsequent `$02` still returns it); `$20`
/// turns the clock OFF (subsequent `$02` returns the `0FFF..` not-set
/// sentinel, TIMERS:608-609).
@Test func powerOffClockOnPreservesButClockOffClears() {
    func setThenPowerOff(_ off: UInt8) -> [UInt8] {
        let (cops, scheduler, _) = makeCOPS(clockSource: { Date(timeIntervalSince1970: 0) })
        cops.reset()
        drainPowerOnStream(cops, scheduler)
        let setNibbles: [UInt8] = [0,0,0,0,0, 0xB,1,0, 0,1,3,4,5,3,0,5]
        cops.handlePortAAccess(index: 15, value: 0x2C, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
        for n in setNibbles {
            cops.handlePortAAccess(index: 15, value: 0x10 | n, isWrite: true)
            scheduler.advance(by: COPS.commandAckDelayCycles)
        }
        cops.handlePortAAccess(index: 15, value: 0x25, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
        cops.handlePortAAccess(index: 15, value: off, isWrite: true)   // power off
        scheduler.advance(by: COPS.commandAckDelayCycles)
        return readClockStream(cops, scheduler)
    }
    // $21 (clock on): the set clock is preserved.
    #expect(setThenPowerOff(0x21) == [0x80, 0xEB, 0x10, 0x01, 0x34, 0x53, 0x05])
    // $23 (reboot later, clock on): also preserved.
    #expect(setThenPowerOff(0x23) == [0x80, 0xEB, 0x10, 0x01, 0x34, 0x53, 0x05])
    // $20 (clock off): cleared to the not-set sentinel.
    #expect(setThenPowerOff(0x20) == [0x80] + COPS.notSetClockReply)
    #expect(setThenPowerOff(0x20)[1...] == [0xEF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            "not-set folds to ClockHigh=$0FFF, ClockLow=$FFFFFFFF")
}

@Test func powerCommandsAreLogged() {
    let (cops, scheduler, _) = makeCOPS()
    let commands: [UInt8] = [0x20, 0x21, 0x23, 0x25, 0x2C, 0x2D]
    for c in commands {
        cops.handlePortAAccess(index: 15, value: c, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
    }
    #expect(cops.powerCommandLog == commands)
}

@Test func powerOffCommandsFireTheSeamAndAreLogged() {
    // hardware-notes.md §7 "Soft Power Control": $20/$21/$23 are the three
    // POWER-OFF commands (MACHINE:425/427/473). Each must fire the onPowerOff
    // seam (so Machine can stop cleanly) AND still be logged.
    for cmd: UInt8 in [0x20, 0x21, 0x23] {
        let scheduler = FakeScheduler()
        var powerOffs = 0
        let cops = COPS(scheduleEvent: { d, a in scheduler.schedule(d, a) },
                        currentCycle: { scheduler.now() },
                        raiseInterrupt: {}, clearInterrupt: {},
                        onPowerOff: { powerOffs += 1 })
        cops.handlePortAAccess(index: 15, value: cmd, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
        #expect(powerOffs == 1, "command $\(String(cmd, radix: 16)) powers off")
        #expect(cops.powerCommandLog == [cmd])
    }
}

@Test func clockTimerCommandsDoNotPowerOff() {
    // $25/$2C/$2D are clock/timer configuration (hardware-notes.md §7), NOT
    // power-off -- the reboot-alarm $2D is logged but must NOT stop the
    // machine (the wake-at-alarm half is deferred; see COPS.processCommand).
    for cmd: UInt8 in [0x25, 0x2C, 0x2D] {
        let scheduler = FakeScheduler()
        var powerOffs = 0
        let cops = COPS(scheduleEvent: { d, a in scheduler.schedule(d, a) },
                        currentCycle: { scheduler.now() },
                        raiseInterrupt: {}, clearInterrupt: {},
                        onPowerOff: { powerOffs += 1 })
        cops.handlePortAAccess(index: 15, value: cmd, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
        #expect(powerOffs == 0, "command $\(String(cmd, radix: 16)) is not a power-off")
        #expect(cops.powerCommandLog == [cmd], "still logged for provenance")
    }
}

@Test func pressPowerButtonEnqueuesResetDispatchStream() {
    // hardware-notes.md §4/§8: the power button reaches the OS as a two-byte
    // reset-dispatch packet -- $80 ("reset code follows", State 0 -> State 4)
    // then $FB (State 4 "power button" sub-code). COPS puts exactly those two
    // faithful bytes on the input FIFO; the OS's DRIVERS handler is what turns
    // $FB into a synthesized pseudo-keycap $08. (This pins that COPS sends
    // $FB, NOT a synthesized $08 -- correcting the M1b-era shorthand.)
    let (cops, scheduler, _) = makeCOPS()
    cops.reset()
    drainPowerOnStream(cops, scheduler)

    cops.pressPowerButton()
    var received: [UInt8] = []
    for _ in 0..<2 {
        scheduler.advance(by: COPS.byteDeliveryDelayCycles)
        received.append(cops.portAInput())
        cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    }
    #expect(received == [0x80, 0xFB])
}

@Test func mouseEnableCommandSetsFlag() {
    let (cops, scheduler, _) = makeCOPS()
    #expect(cops.mouseInterruptsEnabled == false)
    cops.handlePortAAccess(index: 15, value: 0x7C, isWrite: true)
    scheduler.advance(by: COPS.commandAckDelayCycles)
    #expect(cops.mouseInterruptsEnabled == true)
}

// MARK: - Input FIFO: power-on stream, gating, interrupt

@Test func powerOnStreamDeliversResetCodeThenKeyboardID() {
    let (cops, scheduler, interruptRaised) = makeCOPS()
    cops.reset()

    #expect(interruptRaised() == false, "nothing ready yet -- delivery is delayed")
    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(interruptRaised() == true)
    #expect(cops.portAInput() == 0x80, "reset code first")

    // No-handshake (register 15) read must NOT consume the byte.
    cops.handlePortAAccess(index: 15, value: 0, isWrite: false)
    #expect(interruptRaised() == true, "peek read must not clear the interrupt")
    #expect(cops.portAInput() == 0x80, "peek read must not advance the FIFO")

    // A genuine handshake (register 1) read consumes it.
    cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    #expect(interruptRaised() == false, "consuming read clears the interrupt")

    // Gated: the keyboard-ID byte isn't visible until its own delay elapses.
    #expect(cops.portAInput() == 0xFF, "idle bus until the next byte is actually delivered")
    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(interruptRaised() == true)
    #expect(cops.portAInput() == COPS.placeholderKeyboardID)
}

@Test func postedBytesQueueAndDeliverStrictlyOneAtATimeInOrder() {
    let (cops, scheduler, interruptRaised) = makeCOPS()
    cops.reset()
    drainPowerOnStream(cops, scheduler)
    #expect(interruptRaised() == false, "power-on stream drained")

    cops.postKey(code: 0x41, down: true)
    cops.postKey(code: 0x41, down: false)

    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(interruptRaised() == true)
    #expect(cops.portAInput() == 0x80 | 0x41, "bit7 set = key down")

    // The second key event must NOT already be visible -- gated on the
    // first being consumed.
    cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    #expect(cops.portAInput() == 0xFF, "second byte not delivered yet")

    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(cops.portAInput() == 0x41, "bit7 clear = key up")
}

/// Regression pin for hardware-notes.md §8 "Mouse": "Button: keycap `$06`
/// in the KEYBOARD stream (down = `$86`, up = `$06`) -- NOT part of the
/// delta packet." M1c Task 4's `LisaShell.EmulationController` briefly
/// posted Task 1's placeholder keycap (`$7F`, Command/Apple) instead --
/// caught by a ROM-gated integration test
/// (`EmulationControllerTests.mouseAndClickDriveTheRealBootMenu`) but not
/// by anything in the default (no-`LISAEMU_ROM_DIR`) `swift test` path.
/// This pins the correct byte-level COPS behavior for `$06` directly, no
/// ROM/CPU required, so a future regression on the constant is caught by
/// every `swift test` run, not only the ROM-gated one.
@Test func mouseButtonKeycapProducesTheDocumentedCOPSBytes() {
    let (cops, scheduler, _) = makeCOPS()
    cops.reset()
    drainPowerOnStream(cops, scheduler)

    cops.postKey(code: 0x06, down: true)
    cops.postKey(code: 0x06, down: false)

    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(cops.portAInput() == 0x86, "mouse-button down = $86 (bit 7 set | $06)")
    cops.handlePortAAccess(index: 1, value: 0, isWrite: false)

    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(cops.portAInput() == 0x06, "mouse-button up = $06 (bit 7 clear)")
}

@Test func postMouseEnqueuesAThreeBytePacket() {
    let (cops, scheduler, _) = makeCOPS()
    cops.reset()
    drainPowerOnStream(cops, scheduler)

    cops.postMouse(dx: -5, dy: 10)

    var received: [UInt8] = []
    for _ in 0..<3 {
        scheduler.advance(by: COPS.byteDeliveryDelayCycles)
        received.append(cops.portAInput())
        cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    }
    #expect(received == [0x00, UInt8(bitPattern: -5), 10])
}

@Test func resetClearsPriorStateAndRedeliversPowerOnStream() {
    let (cops, scheduler, interruptRaised) = makeCOPS()
    cops.reset()
    cops.handlePortAAccess(index: 15, value: 0x7C, isWrite: true)   // enable mouse
    scheduler.advance(by: COPS.commandAckDelayCycles)
    #expect(cops.mouseInterruptsEnabled == true)

    cops.reset()
    #expect(cops.mouseInterruptsEnabled == false, "reset clears decoded command state")
    #expect(cops.portBInput() & 0x40 != 0, "CRDY back to idle/ready")

    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(interruptRaised() == true, "power-on stream re-delivered")
    #expect(cops.portAInput() == 0x80)
}

@Test func pendingByteReassertsItsInterruptIfExternallyCleared() {
    // Regression test for the desync this task's ROM trace found
    // (task-4-report.md "The IFR2 desync"): the real ROM does a blanket
    // "IFR2 = $7F" (clear all VIA2 interrupt flags) housekeeping write
    // during its own driver-init, well before it ever reads Port A. That
    // write reaches VIA2 (hence its IFR bits) directly -- COPS is never
    // told about it, so its `clearInterrupt` closure is never called. A
    // real "data ready" condition that's still true must keep re-asserting
    // regardless (`armReassertTimer`), or the CPU's later no-timeout poll
    // loop (`$FE2DC6-$FE2DCE`) would wait forever for a flag that can never
    // come back.
    let (cops, scheduler, interruptRaised) = makeCOPS()
    cops.reset()
    drainPowerOnStream(cops, scheduler)   // isolate a single pending byte below -- nothing else queued
    interruptRaised.clear()

    cops.postKey(code: 0x41, down: true)
    scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    #expect(interruptRaised() == true, "precondition: byte pending")

    interruptRaised.clear()   // simulate the external IFR2=$7F clear COPS has no hook into
    #expect(interruptRaised() == false)

    scheduler.advance(by: COPS.interruptReassertDelayCycles)
    #expect(interruptRaised() == true, "the still-pending byte's interrupt must reassert")
    #expect(cops.portAInput() == 0x80 | 0x41, "the byte itself is unaffected -- only the flag was wiped")

    // Consuming it for real must stop the reassert timer.
    cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
    #expect(interruptRaised() == false)
    interruptRaised.clear()
    scheduler.advance(by: COPS.interruptReassertDelayCycles * 3)
    #expect(interruptRaised() == false, "no reassert once genuinely consumed")
}
