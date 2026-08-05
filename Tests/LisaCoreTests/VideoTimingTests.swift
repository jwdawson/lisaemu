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

// MARK: - CPU-driving integration (MusashiSuites: builds a Machine, hence an
// M68K -- Musashi is a process-global singleton) -- confirms the wiring
// through IODispatcher/Bus/Machine, not just VideoTiming in isolation.

extension MusashiSuites {
    @Suite struct VideoTimingIntegrationTests {
        private func spinningMachine(ramSize: Int = 0x10000) -> Machine {
            let m = Machine(ramSize: ramSize)
            m.bus.write32(0x0, 0x3000)
            m.bus.write32(0x4, 0x400)
            m.bus.load([0x60, 0xFE], at: 0x400)   // BRA.s spin
            m.reset()
            return m
        }

        @Test
        func vsyncTickSetsStatusRegisterBit2ThroughRealBusAccess() {
            let m = spinningMachine()
            m.run(until: VideoTiming.cyclesPerVsync + 1000)
            #expect(m.bus.read8(0xFC_F801) & 0x04 != 0, "status register bit 2 should be set after a vsync period")
        }

        @Test
        func machineAssertsLevel1WhenArmedVsyncFiresThroughRealBusAccess() {
            let m = spinningMachine()
            #expect(m.vsyncPending == false)
            m.bus.write8(0xFC_E01A, 0)   // VRIRENB -- arm via a real bus write
            m.run(until: VideoTiming.cyclesPerVsync + 1000)
            #expect(m.vsyncPending == true, "an armed vsync fire should assert Machine's level-1 IRQ source")
        }

        @Test
        func unarmedVsyncNeverAssertsLevel1ThroughRealBusAccess() {
            let m = spinningMachine()
            m.run(until: VideoTiming.cyclesPerVsync + 1000)
            #expect(m.bus.read8(0xFC_F801) & 0x04 != 0, "status bit still sets")
            #expect(m.vsyncPending == false, "never armed -- must not assert level 1")
        }

        @Test
        func e018AccessClearsArmedVsyncPendingThroughRealBusAccess() {
            let m = spinningMachine()
            m.bus.write8(0xFC_E01A, 0)   // arm
            m.run(until: VideoTiming.cyclesPerVsync + 1000)
            #expect(m.vsyncPending == true)

            m.bus.write8(0xFC_E018, 0)   // VertReset/VRIRDIS
            #expect(m.vsyncPending == false, "$E018 access should disarm and clear the asserted IRQ")
            #expect(m.bus.read8(0xFC_F801) & 0x04 == 0, "and clear the status register bit")
        }

        /// End-to-end autovector delivery, the same shape as
        /// `InterruptTests.viaTimerInterruptRunsLevel1AutovectorHandler` but
        /// for the vsync source instead of VIA1's timer -- proves the level-1
        /// IRQ line genuinely reaches Musashi's autovector dispatch, not just
        /// `Machine.vsyncPending` flipping in isolation.
        @Test
        func armedVsyncDeliversARealLevel1AutovectorInterrupt() {
            let m = Machine(ramSize: 0x10000)
            m.bus.write32(0x0, 0x3000)
            m.bus.write32(0x4, 0x400)
            m.bus.write32(0x64, 0x500)   // level-1 autovector handler ($64 = 25*4)
            m.bus.load([
                0x46, 0xFC, 0x20, 0x00,                              // MOVE.W #$2000,SR (accept level 1+)
                0x13, 0xFC, 0x00, 0x00, 0x00, 0xFC, 0xE0, 0x1A,      // MOVE.B #$00,$FCE01A.L (VRIRENB -- arm)
                0x60, 0xFE,                                          // spin
            ], at: 0x400)
            m.bus.load([
                0x52, 0x82,                                          // ADDQ.L #1,D2
                0x13, 0xFC, 0x00, 0x00, 0x00, 0xFC, 0xE0, 0x18,      // MOVE.B #$00,$FCE018.L (VertReset -- ack)
                0x4E, 0x73,                                          // RTE
            ], at: 0x500)
            m.reset()
            m.cpu[.d2] = 0   // see InterruptTests.loadProgram's doc comment: D2 isn't reset by a real 68000 reset

            m.run(until: VideoTiming.cyclesPerVsync + 5000)

            #expect(m.cpu[.d2] == 1, "level-1 autovector handler should have run once, acknowledging via $E018")
            #expect(m.halted == false)
        }

        @Test
        func framebufferSnapshotThroughRealMachineHonorsVideoPageLatch() {
            let m = spinningMachine(ramSize: 0x2_0000)
            // Page 1 (physical 0x8000) is avoided here -- that address is
            // ALSO segment 0's SLIM MMU port (`Bus.slimSorgPortAccess`,
            // `docs/hardware-notes.md` "Register Port Addressing": every
            // 128KB-aligned segment has its SLIM port at `base + $8000`),
            // so a plain `write8` there while `setupMode == true` would hit
            // the MMU port intercept, not RAM. Page 2 (physical 0x10000)
            // has no such collision.
            m.bus.write8(0xFC_E800, 0x02)   // page 2 -> physical 0x10000
            m.bus.write8(0x1_0000, 0x99)
            let snap = m.bus.framebufferSnapshot()
            #expect(snap.count == Bus.framebufferByteCount)
            #expect(snap[0] == 0x99)
        }
    }
}
