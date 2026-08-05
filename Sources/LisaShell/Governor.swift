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
}
