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

/// M2 Task 2 fold-in: `COPS` takes an injectable `clockSource: () -> Date`
/// (default `{ Date() }`, `Date()` being LisaCore's only nondeterminism)
/// instead of a raw byte-array override, used by the `$02` read-clock
/// reply. This test injects a FIXED `Date` and asserts the deterministic
/// reply byte sequence that `COPS.defaultHostClockBytes(now:)` produces
/// from it (per hardware-notes.md §4's currently-understood, best-effort
/// placeholder clock-payload format -- see that function's doc comment;
/// this test is exercising/pinning what IS modeled, not asserting a
/// verified-correct real-hardware byte layout).
@Test func readClockCommandEnqueuesAClockReplyPacket() {
    // 0x1122_3344 seconds since the epoch -> big-endian bytes $11,$22,$33,$44
    // -- an explicit, hand-computed expectation (not literally CALLING
    // `defaultHostClockBytes(now:)` to generate it, which would make this
    // test tautological). (M2 Task 2 precision nit, folded in M3 Task 3:
    // "hand-computed" doesn't make this an INDEPENDENT ORACLE -- the
    // computation is the identical big-endian byte-swap the function under
    // test performs, just written out by hand, so a shared error in that
    // conversion logic would slip past both. This test is a genuine
    // REGRESSION PIN against an accidental future change to
    // `defaultHostClockBytes`'s byte layout/ordering -- it does NOT
    // independently verify that layout against real Lisa hardware; see the
    // type-level doc comment above for that same caveat stated once for
    // the whole placeholder clock-payload format.)
    let fixedDate = Date(timeIntervalSince1970: 0x1122_3344)
    let fixedBytes: [UInt8] = [0xE0, 0x11, 0x22, 0x33, 0x44, 0x00]
    let (cops, scheduler, interruptRaised) = makeCOPS(clockSource: { fixedDate })
    cops.reset()
    drainPowerOnStream(cops, scheduler)
    #expect(interruptRaised() == false, "FIFO drained")

    cops.handlePortAAccess(index: 1, value: COPS.Command.readClock, isWrite: true)
    // Three separate hops: the command's own latch delay, then its ack
    // delay, THEN (once the reply is enqueued as a result of that ack
    // firing) the first reply byte's own delivery delay -- each is
    // scheduled relative to the cycle at the moment it's requested, not the
    // cycle at the start of this test.
    scheduler.advance(by: COPS.commandAckDelayCycles)
    scheduler.advance(by: COPS.byteDeliveryDelayCycles)

    #expect(interruptRaised() == true, "clock reply's first byte should now be ready")
    #expect(cops.portAInput() == 0x80, "clock reply is framed as a reset-dispatch packet ($80 first)")

    var received: [UInt8] = []
    for _ in 0..<(1 + fixedBytes.count) {
        received.append(cops.portAInput())
        cops.handlePortAAccess(index: 1, value: 0, isWrite: false)
        scheduler.advance(by: COPS.byteDeliveryDelayCycles)
    }
    #expect(received == [0x80] + fixedBytes)
}

@Test func writeClockNibbleCommandsAccumulateInOrder() {
    let (cops, scheduler, _) = makeCOPS()
    for n: UInt8 in [0x1, 0xA, 0xF] {
        cops.handlePortAAccess(index: 15, value: 0x10 | n, isWrite: true)
        scheduler.advance(by: COPS.commandAckDelayCycles)
    }
    #expect(cops.clockSetNibbles == [0x1, 0xA, 0xF])
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
