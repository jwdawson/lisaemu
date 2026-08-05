import Foundation
import Testing
@testable import LisaCore

// CPU-free, protocol-level tests for `VideoTiming` (Task 5), mirroring
// `COPSTests.swift`'s shape: no `Bus`/`Machine`/`M68K` involved here -- these
// drive `VideoTiming` directly through its injected scheduler/IRQ closures,
// the same surface `IODispatcher` wires onto `Bus`/`Machine`. See
// `VideoTiming.swift`'s type doc comment for the modeled $E018/$E01A
// semantics this validates.

/// A tiny deterministic fake of `Machine`'s cycle clock + event queue --
/// identical in shape to `COPSTests.FakeScheduler` (kept as a private
/// duplicate rather than shared, matching that file's own precedent of
/// being self-contained).
private final class FakeScheduler {
    private(set) var cycle: UInt64 = 0
    private var events: [(due: UInt64, action: () -> Void)] = []

    func schedule(_ delay: UInt64, _ action: @escaping () -> Void) {
        events.append((due: cycle + delay, action: action))
    }

    /// Advances the fake clock to `target` and fires every event now due, in
    /// the order they were scheduled -- including events newly scheduled by
    /// an action that just fired (e.g. `fireVsync` rescheduling itself),
    /// as long as their due cycle is also `<= target`.
    func advance(to target: UInt64) {
        cycle = target
        while let idx = events.firstIndex(where: { $0.due <= cycle }) {
            let action = events.remove(at: idx).action
            action()
        }
    }

    func advance(by delta: UInt64) { advance(to: cycle + delta) }
}

private func makeVideoTiming() -> (timing: VideoTiming, scheduler: FakeScheduler, irqPending: () -> Bool) {
    let scheduler = FakeScheduler()
    var irq = false
    let timing = VideoTiming(
        scheduleEvent: { delay, action in scheduler.schedule(delay, action) },
        setIRQPending: { irq = $0 }
    )
    return (timing, scheduler, { irq })
}

// MARK: - Vsync scheduling + status bit

@Test func vsyncDoesNotFireBeforeItsSchedule() {
    let (timing, scheduler, _) = makeVideoTiming()
    timing.reset()
    #expect(timing.pending == false)
    scheduler.advance(by: VideoTiming.cyclesPerVsync - 1)
    #expect(timing.pending == false, "not yet -- one cycle short of the vsync period")
}

@Test func vsyncFiresOnScheduleAndSetsStatusBit2() {
    let (timing, scheduler, _) = makeVideoTiming()
    timing.reset()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true, "vsync should have fired, setting the status bit")
}

@Test func vsyncReschedulesItselfForTheNextPeriod() {
    let (timing, scheduler, _) = makeVideoTiming()
    timing.reset()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true)

    // Manually clear (as if the CPU acknowledged via $E018) so the second
    // firing is observable.
    timing.handleVertResetAccess()
    #expect(timing.pending == false)

    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true, "vsync must keep firing every period, not just once")
}

@Test func resetReschedulesTheVsyncEventFromZero() {
    let (timing, scheduler, _) = makeVideoTiming()
    timing.reset()
    scheduler.advance(by: VideoTiming.cyclesPerVsync / 2)
    timing.reset()   // Machine.reset()'s ordering: queue cleared, then this re-arms
    scheduler.advance(by: VideoTiming.cyclesPerVsync / 2)
    #expect(timing.pending == false, "reset restarts the countdown -- half the original period isn't enough post-reset")
    scheduler.advance(by: VideoTiming.cyclesPerVsync / 2)
    #expect(timing.pending == true, "a full period after the reset, it fires")
}

// MARK: - $E018 (VertReset/VRIRDIS) disarms + clears

@Test func vertResetClearsPendingBitAndDisarms() {
    let (timing, scheduler, irqPending) = makeVideoTiming()
    timing.reset()
    timing.handleVertEnableAccess()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true)
    #expect(irqPending() == true)

    timing.handleVertResetAccess()
    #expect(timing.pending == false)
    #expect(timing.armed == false)
    #expect(irqPending() == false)
}

@Test func vertResetIsANoOpWhenNothingWasPending() {
    let (timing, _, irqPending) = makeVideoTiming()
    timing.reset()
    timing.handleVertResetAccess()
    #expect(timing.pending == false)
    #expect(irqPending() == false)
}

// MARK: - $E01A (VRIRENB) arms -- and asserts the IRQ, level 1

@Test func armedVsyncAssertsIRQOnNextFire() {
    let (timing, scheduler, irqPending) = makeVideoTiming()
    timing.reset()
    #expect(irqPending() == false)

    timing.handleVertEnableAccess()
    #expect(timing.armed == true)
    #expect(irqPending() == false, "arming alone (nothing pending yet) must not assert")

    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(irqPending() == true, "an armed vsync fire must assert the IRQ")
    #expect(timing.pending == true)
}

@Test func unarmedVsyncSetsStatusBitButNeverAssertsIRQ() {
    let (timing, scheduler, irqPending) = makeVideoTiming()
    timing.reset()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true, "status bit is hardware-driven regardless of arming")
    #expect(irqPending() == false, "never armed -- must not assert level 1")
}

@Test func vertEnableAssertsImmediatelyIfAlreadyPending() {
    // The status bit can already be set (an unacknowledged vsync from
    // before arming) by the time software gets around to enabling the
    // interrupt -- real hardware must not wait for the NEXT vsync to
    // reflect that. See VideoTiming.swift's doc comment "the discriminating
    // behavior checkpoint B's ROM trace was used to validate".
    let (timing, scheduler, irqPending) = makeVideoTiming()
    timing.reset()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(timing.pending == true)
    #expect(irqPending() == false, "not armed yet")

    timing.handleVertEnableAccess()
    #expect(irqPending() == true, "arming while already pending asserts immediately")
}

@Test func vertResetThenVertEnableRequiresANewVsyncToAssert() {
    let (timing, scheduler, irqPending) = makeVideoTiming()
    timing.reset()
    timing.handleVertEnableAccess()
    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(irqPending() == true)

    timing.handleVertResetAccess()
    #expect(irqPending() == false)

    timing.handleVertEnableAccess()
    #expect(irqPending() == false, "re-arming right after a reset, with nothing pending, must not assert")

    scheduler.advance(by: VideoTiming.cyclesPerVsync)
    #expect(irqPending() == true, "the next vsync fires and asserts as expected")
}

// MARK: - Bus.framebufferSnapshot() -- CPU-free, bare Bus

@Test func framebufferSnapshotReadsPhysicalRAMAtDefaultPageZero() {
    let bus = Bus(ramSize: 0x1_0000)
    bus.write8(0x0, 0xAB)
    bus.write8(0x1, 0xCD)
    let snap = bus.framebufferSnapshot()
    #expect(snap.count == Bus.framebufferByteCount)
    #expect(snap[0] == 0xAB)
    #expect(snap[1] == 0xCD)
}

@Test func framebufferSnapshotHonorsVideoPageLatch() {
    // videoPageLatch is a 32KB-page number: physical base = latch << 15
    // (docs/hardware-notes.md §2 "VideoLatch"). Page 2 -> 0x10000.
    let bus = Bus(ramSize: 0x2_0000)
    bus.write8(0xFC_E800, 0x02)   // $FCE800 video page latch = 2
    #expect(bus.videoPageLatch == 0x02)
    bus.write8(0x1_0000, 0x5A)
    bus.write8(0x1_0001, 0xA5)
    let snap = bus.framebufferSnapshot()
    #expect(snap[0] == 0x5A)
    #expect(snap[1] == 0xA5)
}

@Test func framebufferSnapshotDiffersPerPageLatch() {
    let bus = Bus(ramSize: 0x2_0000)
    bus.write8(0x0, 0x11)          // page 0
    bus.write8(0x1_0000, 0x22)     // page 2
    bus.write8(0xFC_E800, 0x00)
    #expect(bus.framebufferSnapshot()[0] == 0x11)
    bus.write8(0xFC_E800, 0x02)
    #expect(bus.framebufferSnapshot()[0] == 0x22)
}

@Test func framebufferSnapshotOutOfRangePageReadsZeroWithoutCrashing() {
    // A page latch pointing past a smaller-than-max Bus.ram: real hardware
    // always has enough RAM behind any latch value it would actually be
    // programmed with, but this model must not crash on a synthetic
    // out-of-range test Bus (see VideoTiming.swift's doc comment).
    let bus = Bus(ramSize: 0x1000)   // much smaller than 32,760 + any page offset
    bus.write8(0xFC_E800, 0xFF)      // page 255 -> physical 0x7F8000, way past ram.count
    let snap = bus.framebufferSnapshot()
    #expect(snap.count == Bus.framebufferByteCount)
    #expect(snap.allSatisfy { $0 == 0 })
}

@Test func framebufferSnapshotTruncatesAtRAMEndWithoutCrashing() {
    // videoPageLatch = 0, but ram is smaller than a full framebuffer: the
    // tail bytes past ram.count must read 0, not crash.
    let bus = Bus(ramSize: 100)
    bus.write8(0, 0x7E)
    let snap = bus.framebufferSnapshot()
    #expect(snap.count == Bus.framebufferByteCount)
    #expect(snap[0] == 0x7E)
    #expect(snap[100] == 0, "past the end of the tiny backing RAM")
}
