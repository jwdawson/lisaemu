import Foundation
import Testing
@testable import LisaShell

@Suite
struct GovernorTests {
    @Test
    func targetCyclesIsProportionalToElapsedTime() {
        #expect(Governor.targetCycles(anchor: 0, now: 1) == 5_000_000)
        // Within 1 cycle of the ideal, not exactly equal: `now - anchor`
        // (10.1 - 10) is itself subject to binary floating-point rounding
        // (evaluates a hair under 0.1), and `targetCycles` floors -- the
        // same <1-cycle tolerance `driftStaysBoundedAcrossJitteredSlices`
        // uses below, for the same reason.
        #expect(abs(Int64(Governor.targetCycles(anchor: 10, now: 10.1)) - 500_000) <= 1)
        #expect(Governor.targetCycles(anchor: 100, now: 100) == 0)
    }

    @Test
    func targetCyclesClampsToZeroWhenNowPrecedesAnchor() {
        // Defensive: should not happen in practice (anchor is always
        // computed from a `now` at or before any later `now` passed in),
        // but must not underflow the UInt64 result.
        #expect(Governor.targetCycles(anchor: 100, now: 50) == 0)
    }

    @Test
    func sleepIntervalFillsRemainderAndNeverGoesNegative() {
        let nominal = Governor.nominalSlice
        #expect(Governor.sleepInterval(sliceDuration: 0) == nominal)
        #expect(abs(Governor.sleepInterval(sliceDuration: 0.005) - (nominal - 0.005)) < 1e-9)
        // A slice that overran the nominal budget sleeps 0, not negative.
        #expect(Governor.sleepInterval(sliceDuration: nominal * 3) == 0)
    }

    /// The core anchoring property: no matter how unevenly `now` advances
    /// between iterations (a stand-in for real scheduling jitter -- some
    /// slices run late, some early, some overrun), a loop that always
    /// catches `cyclesDone` up to `targetCycles(anchor:now:)` each
    /// iteration tracks true elapsed wall-clock time essentially exactly
    /// (within `floor()`'s own <1-cycle rounding) after every single
    /// iteration. This is the entire point of anchoring to a fixed nominal
    /// start rather than accumulating per-slice sleep durations: an
    /// accumulated-duration governor would drift permanently under this
    /// same jitter pattern (each late slice would UNDER-execute and never
    /// recover, each early one would OVER-execute and never give it back);
    /// this anchored one cannot, by construction.
    @Test
    func driftStaysBoundedAcrossJitteredSlices() {
        let anchor: TimeInterval = 1_000.0
        var cyclesDone: UInt64 = 0
        var now = anchor
        // A deliberately uneven mix: on-time, late (missed a slice due to
        // host contention), very late (a multi-slice stall), and early
        // (scheduler woke the thread up ahead of budget) slices.
        let jitters: [TimeInterval] = [
            0.0167, 0.0167, 0.0500, 0.0020, 0.0167,
            0.1000, 0.0010, 0.0167, 0.0167, 0.0300,
            0.0001, 0.0167, 0.0700, 0.0167, 0.0167,
        ]
        for jitter in jitters {
            now += jitter
            let target = Governor.targetCycles(anchor: anchor, now: now)
            let toRun = target > cyclesDone ? target - cyclesDone : 0
            cyclesDone += toRun

            // No permanent lag or lead survives a single iteration: having
            // just caught up, cyclesDone must exactly equal the anchored
            // target for `now`, regardless of how the last jitter behaved.
            #expect(cyclesDone == target)

            // Hard bound derived purely from real elapsed time: never a
            // runaway overrun, even right after a big jitter spike.
            let idealElapsed = now - anchor
            #expect(Double(cyclesDone) <= idealElapsed * Governor.cyclesPerSecond + 1)
        }

        let idealFinal = (now - anchor) * Governor.cyclesPerSecond
        #expect(Double(cyclesDone) >= idealFinal - 1)
        #expect(Double(cyclesDone) <= idealFinal + 1)
    }

    // MARK: - clampedTargetCycles (Important finding: "unbounded catch-up
    // slice after host suspend can hang quit")

    /// Small, in-budget gaps behave exactly like plain `targetCycles`
    /// (unclamped) -- the clamp must never interfere with ordinary
    /// frame-to-frame pacing, only genuine marathon catch-ups.
    @Test
    func clampedTargetCyclesPassesThroughWhenWithinBudget() {
        let anchor: TimeInterval = 100
        let now = anchor + Governor.nominalSlice // one nominal ~16.7ms slice's worth
        let cyclesDone: UInt64 = 0
        let (target, newAnchor) = Governor.clampedTargetCycles(anchor: anchor, now: now, cyclesDone: cyclesDone,
                                                                 maxCatchUpCycles: Governor.defaultMaxCatchUpCycles)
        #expect(target == Governor.targetCycles(anchor: anchor, now: now))
        #expect(newAnchor == anchor, "anchor must be untouched when no clamp is needed")
    }

    /// The core regression: a multi-hour gap (host suspended, e.g. system
    /// sleep) must NOT hand `machine.run(until:)` an hours-long target --
    /// it must re-anchor to `now` (relative to `cyclesDone` already run)
    /// instead, so the slice that actually executes stays bounded.
    @Test
    func clampedTargetCyclesReanchorsInsteadOfMarathonCatchUp() {
        let anchor: TimeInterval = 1_000
        let cyclesDone: UInt64 = 42
        let now = anchor + 3 * 3_600 // 3 hours later -- e.g. the host slept
        let maxCatchUp: UInt64 = Governor.defaultMaxCatchUpCycles

        let naive = Governor.targetCycles(anchor: anchor, now: now)
        #expect(naive - cyclesDone > maxCatchUp, "sanity: the naive target really would demand a marathon slice")

        let (target, newAnchor) = Governor.clampedTargetCycles(anchor: anchor, now: now, cyclesDone: cyclesDone,
                                                                 maxCatchUpCycles: maxCatchUp)
        #expect(target == cyclesDone, "clamped target must ask for zero NEW cycles this slice, not the marathon")
        #expect(target < naive, "must be far below the unclamped marathon target")

        // The re-anchored value must make the VERY NEXT call resume
        // tracking real elapsed time from `cyclesDone` forward, with no
        // discontinuity -- i.e. targetCycles(newAnchor, now) == cyclesDone.
        #expect(Governor.targetCycles(anchor: newAnchor, now: now) == cyclesDone)

        // And pacing from here on tracks real time normally again (no
        // permanent drift/lag introduced by the clamp).
        let later = now + 1.0 // one second further
        let nextTarget = Governor.targetCycles(anchor: newAnchor, now: later)
        #expect(nextTarget == cyclesDone + UInt64(Governor.cyclesPerSecond))
    }

    /// A gap exactly AT the ceiling must not clamp (only gaps that exceed
    /// it) -- a boundary check on the `>` in `clampedTargetCycles`.
    @Test
    func clampedTargetCyclesDoesNotClampExactlyAtTheCeiling() {
        let anchor: TimeInterval = 0
        let maxCatchUp: UInt64 = 1_000
        let cyclesDone: UInt64 = 0
        // Choose `now` so the naive target is exactly `cyclesDone + maxCatchUp`.
        let now = Double(maxCatchUp) / Governor.cyclesPerSecond
        let (target, newAnchor) = Governor.clampedTargetCycles(anchor: anchor, now: now, cyclesDone: cyclesDone,
                                                                 maxCatchUpCycles: maxCatchUp)
        #expect(target == Governor.targetCycles(anchor: anchor, now: now))
        #expect(newAnchor == anchor)
    }
}
