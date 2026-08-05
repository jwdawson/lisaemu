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

private func makeCOPS(clockBytes: @escaping () -> [UInt8] = { COPS.defaultHostClockBytes(now: Date(timeIntervalSince1970: 0)) })
    -> (cops: COPS, scheduler: FakeScheduler, interruptRaised: InterruptObserver) {
    let scheduler = FakeScheduler()
    let interruptPending = InterruptObserver()
    let cops = COPS(
        scheduleEvent: { delay, action in scheduler.schedule(delay, action) },
        currentCycle: { scheduler.now() },
        raiseInterrupt: { interruptPending.raise() },
        clearInterrupt: { interruptPending.clear() },
        hostClockBytes: clockBytes
    )
    return (cops, scheduler, interruptPending)
}

// MARK: - CRDY handshake (output/command path)

@Test func commandWriteDropsCRDYImmediately() {
    let (cops, _, _) = makeCOPS()
    #expect(cops.portBInput() & 0x40 != 0, "CRDY idles high (ready)")

    cops.handlePortAAccess(index: 15, value: 0x00, isWrite: true)   // the ROM's own POST probe uses register 15
    #expect(cops.portBInput() & 0x40 == 0, "CRDY drops the instant a command byte is written")
}

@Test func commandCompletesAfterPlausibleDelayRestoringCRDY() {
    let (cops, scheduler, _) = makeCOPS()
    cops.handlePortAAccess(index: 15, value: 0x00, isWrite: true)
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

// MARK: - Command decode

@Test func readClockCommandEnqueuesAClockReplyPacket() {
    let fixedBytes: [UInt8] = [0xE0, 0x11, 0x22, 0x33, 0x44, 0x00]
    let (cops, scheduler, interruptRaised) = makeCOPS(clockBytes: { fixedBytes })
    cops.reset()
    drainPowerOnStream(cops, scheduler)
    #expect(interruptRaised() == false, "FIFO drained")

    cops.handlePortAAccess(index: 1, value: COPS.Command.readClock, isWrite: true)
    // Two separate hops: the command's own ack delay, THEN (once the reply
    // is enqueued as a result of that ack firing) the first reply byte's
    // own delivery delay -- each is scheduled relative to the cycle at the
    // moment it's requested, not the cycle at the start of this test.
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
