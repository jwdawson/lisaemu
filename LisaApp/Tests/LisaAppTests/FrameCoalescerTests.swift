import Testing
@testable import LisaApp
@testable import LisaShell

/// Pure slot-logic coverage for `FrameCoalescer` (whole-branch-review
/// Important finding: "unthrottled mode can flood the main thread with
/// CGImage rebuilds") -- see that type's doc comment in
/// `LisaApp/Sources/AppModel.swift` for the offer/take protocol
/// `AppModel.wire(_:)` builds its coalescing fix on top of. `@testable
/// import LisaShell` is needed only to construct a `Frame` value directly
/// (its memberwise init is internal, not public -- `LisaShell`'s own
/// tests construct `Frame` the same way).
@Suite
struct FrameCoalescerTests {
    private func makeFrame(sequence: UInt64) -> Frame {
        Frame(bits: [], width: 1, height: 1, sequence: sequence)
    }

    @Test func firstOfferSchedulesAndLaterOffersDoNotUntilTaken() {
        let coalescer = FrameCoalescer()
        #expect(coalescer.offer(makeFrame(sequence: 1)), "nothing scheduled yet -- caller should schedule")
        #expect(!coalescer.offer(makeFrame(sequence: 2)), "already scheduled -- must not schedule a second apply")
        #expect(!coalescer.offer(makeFrame(sequence: 3)), "still not taken -- still must not re-schedule")
    }

    @Test func takeReturnsTheLatestOfferedFrameNotTheFirst() {
        let coalescer = FrameCoalescer()
        _ = coalescer.offer(makeFrame(sequence: 1))
        _ = coalescer.offer(makeFrame(sequence: 2))
        _ = coalescer.offer(makeFrame(sequence: 3))

        let taken = coalescer.take()
        #expect(taken?.sequence == 3, "stale intermediate frames (1, 2) must be dropped -- only the latest survives")
    }

    @Test func takeClearsTheSlotSoASubsequentTakeReturnsNil() {
        let coalescer = FrameCoalescer()
        _ = coalescer.offer(makeFrame(sequence: 1))
        #expect(coalescer.take() != nil)
        #expect(coalescer.take() == nil, "nothing pending after the first take -- must not redeliver")
    }

    @Test func takeReArmsOfferToScheduleAgain() {
        let coalescer = FrameCoalescer()
        #expect(coalescer.offer(makeFrame(sequence: 1)))
        #expect(!coalescer.offer(makeFrame(sequence: 2)))
        _ = coalescer.take()

        // Once consumed, the NEXT offer must schedule again -- otherwise
        // frames published after a take would never get applied at all.
        #expect(coalescer.offer(makeFrame(sequence: 3)), "must re-arm after take() so future frames still apply")
    }

    @Test func takeWithNothingPendingReturnsNil() {
        let coalescer = FrameCoalescer()
        #expect(coalescer.take() == nil)
    }

    /// Throttled mode publishes at a much lower, already-paced rate (per
    /// `AppModel.wire(_:)`'s doc comment) -- one offer/take round-trip per
    /// frame there, same as before the fix: this is the "coalescing is
    /// harmless" claim, pinned as a behavioral regression test rather than
    /// just asserted in a comment.
    @Test func offerThenImmediateTakeBehavesLikeUncoalescedSingleFrameDelivery() {
        let coalescer = FrameCoalescer()
        for sequence: UInt64 in 1...5 {
            #expect(coalescer.offer(makeFrame(sequence: sequence)), "every offer after a take schedules")
            #expect(coalescer.take()?.sequence == sequence, "every scheduled apply sees exactly that frame")
        }
    }
}
