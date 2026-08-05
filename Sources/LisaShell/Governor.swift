import Foundation

/// Drift-corrected pacing math for throttled mode
/// (docs/superpowers/plans/2026-08-05-m1c-app-shell.md Task 1 "Pacing").
///
/// Anchored to a FIXED nominal start time rather than accumulated per-slice
/// sleep durations -- the M1b vsync-drift lesson (the same anchoring
/// principle `VideoTiming`'s self-rescheduling vsync event relies on:
/// each tick is scheduled `cyclesPerVsync` cycles from the PREVIOUS tick's
/// actual fire cycle, not from some drifting wall-clock accumulator).
/// Computing each slice's target independently from `anchor` means a late
/// or early individual slice never compounds into permanent drift: the next
/// slice's target is still exactly where it should be relative to `anchor`,
/// so the governor self-corrects on the very next iteration. Pure and
/// side-effect free (no clock reads of its own) so it is unit-testable
/// without a real `Thread`/`Machine` -- see `EmulationController`'s
/// "Threading"/"Pacing" doc comment for how the emulation loop drives this.
enum Governor {
    /// 5,000,000 Hz CPU clock (matches `VideoTiming.cyclesPerVsync`'s own
    /// derivation and every other M1a/M1b cycle-rate reference).
    static let cyclesPerSecond: Double = 5_000_000
    /// ~60Hz nominal frame slice -- a wall-clock time budget, not a cycle
    /// count (contrast `VideoTiming.cyclesPerVsync`, which IS a cycle
    /// count for the same nominal cadence).
    static let nominalSlice: TimeInterval = 1.0 / 60.0

    /// How many emulated cycles SHOULD have executed by `now`, given
    /// emulation nominally started at `anchor`. Clamped to 0 if `now`
    /// precedes `anchor` (defensive; should not happen in practice).
    static func targetCycles(anchor: TimeInterval, now: TimeInterval,
                              cyclesPerSecond: Double = Governor.cyclesPerSecond) -> UInt64 {
        let elapsed = max(0, now - anchor)
        return UInt64((elapsed * cyclesPerSecond).rounded(.down))
    }

    /// How long to sleep after a slice that took `sliceDuration` wall-clock
    /// seconds, to fill out the rest of a nominal ~16.7ms frame slice.
    /// Never negative: an overrun slice (e.g. a burst of catch-up cycles
    /// after the host was briefly busy) sleeps 0 -- the NEXT call to
    /// `targetCycles` (anchored, not accumulated) naturally absorbs the
    /// overrun without it compounding into permanent drift.
    static func sleepInterval(sliceDuration: TimeInterval,
                               nominalSlice: TimeInterval = Governor.nominalSlice) -> TimeInterval {
        max(0, nominalSlice - sliceDuration)
    }

    /// Catch-up ceiling for a single throttled slice, in cycles: "5 vsyncs'
    /// worth" (whole-branch-review Important finding: "unbounded catch-up
    /// slice after host suspend can hang quit"). Expressed via
    /// `nominalSlice` (this type's own ~60Hz nominal cadence) rather than
    /// importing `LisaCore.VideoTiming.cyclesPerVsync` -- `Governor` is
    /// deliberately Foundation-only/`LisaCore`-independent (see this file's
    /// top doc comment: "no clock reads of its own", unit-testable without
    /// a real `Machine`), and the two cadences are the same nominal ~60Hz
    /// figure by construction (`EmulationController`'s "Pacing" doc
    /// comment).
    static let defaultMaxCatchUpCycles: UInt64 = UInt64(5 * nominalSlice * cyclesPerSecond)

    /// Drift-corrected AND catch-up-clamped target for one throttled slice.
    ///
    /// `targetCycles(anchor:now:)` alone is unbounded: if the host thread is
    /// suspended for real wall-clock time (system sleep, a long debugger
    /// pause, a busy host scheduler) and then resumes, `now - anchor` can be
    /// hours, so the naive target can demand hours of emulated cycles in a
    /// SINGLE `machine.run(until:)` call. That call is uninterruptible (no
    /// mailbox drain happens mid-slice -- see `EmulationController`'s
    /// "Threading" doc comment: the mailbox is only drained BETWEEN slices),
    /// so a marathon slice like that starves `.pause`/`.shutdown`/input for
    /// its entire duration -- observably, quitting the app while the host
    /// wakes from sleep can hang for as long as the sleep lasted.
    ///
    /// The fix: if the naive target would demand more than `maxCatchUpCycles`
    /// beyond `cyclesDone` (what's already run), don't hand that marathon to
    /// `machine.run(until:)` at all. Instead RE-ANCHOR as if emulation had
    /// been running continuously up to exactly `cyclesDone` at `now` --
    /// i.e. drop the unearned catch-up on the floor and resume normal
    /// per-slice pacing from here. `cyclesDone` cycles are "owed" wall-clock
    /// time already spent, so the returned anchor is `now` shifted back by
    /// that much (the same formula `EmulationController` uses to establish
    /// the INITIAL anchor on start/reset/throttle-toggle) -- this makes the
    /// very next `targetCycles(anchor:now:)` call resume tracking real time
    /// exactly from `cyclesDone` forward, with no discontinuity and no
    /// silently-dropped-then-suddenly-replayed catch-up.
    ///
    /// Pure (no clock reads, no side effects) -- see this file's top doc
    /// comment for why that matters for testability; `EmulationController`
    /// is the sole caller and owns replacing its `throttleAnchor` with the
    /// returned `anchor` every throttled slice.
    static func clampedTargetCycles(anchor: TimeInterval, now: TimeInterval, cyclesDone: UInt64,
                                     maxCatchUpCycles: UInt64 = Governor.defaultMaxCatchUpCycles,
                                     cyclesPerSecond: Double = Governor.cyclesPerSecond)
        -> (target: UInt64, anchor: TimeInterval) {
        let naiveTarget = targetCycles(anchor: anchor, now: now, cyclesPerSecond: cyclesPerSecond)
        guard naiveTarget > cyclesDone, naiveTarget - cyclesDone > maxCatchUpCycles else {
            return (naiveTarget, anchor)
        }
        let reanchored = now - Double(cyclesDone) / cyclesPerSecond
        return (cyclesDone, reanchored)
    }
}
