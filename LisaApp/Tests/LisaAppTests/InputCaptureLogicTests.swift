import AppKit
import Testing
@testable import LisaApp

/// Pure-logic coverage for `InputCapture`'s two code-review-fixed bugs
/// (M1c Task 4 fix round):
///
/// 1. `isReservedMenuShortcut` defeated by Caps Lock (`mods == .command`
///    compared the WHOLE flag set, so `.capsLock` being set alongside
///    `.command` broke the match).
/// 2. Releasing pointer capture while the emulated mouse button was still
///    down left the Lisa believing the button was stuck.
///
/// Both fixes are pure functions/state machines (`InputCapture
/// .isReservedMenuShortcut(modifierFlags:keyCode:)`, `CaptureState`) with
/// zero `NSCursor`/`CGAssociateMouseAndMouseCursorPosition`/`AppModel` side
/// effects, specifically so they're testable here without a live app,
/// window, or emulation controller -- see each type's doc comment in
/// `LisaApp/Sources/InputCapture.swift`.
@Suite
struct InputCaptureLogicTests {
    // MARK: - isReservedMenuShortcut / Caps Lock (Important 1)

    @Test func reservedShortcutRecognizedWithoutCapsLock() {
        // kVK_ANSI_P = 0x23 -- matches LisaEmuApp.swift's Command-P Pause/Start.
        #expect(InputCapture.isReservedMenuShortcut(modifierFlags: [.command], keyCode: 0x23))
    }

    @Test func reservedShortcutStillRecognizedWithCapsLockEngaged() {
        // THE bug: with Caps Lock physically engaged, modifierFlags also
        // carries .capsLock, and the original exact-equality comparison
        // against .command failed -- Command-P/R/T forwarded to the Lisa
        // AND the menu action fired.
        #expect(InputCapture.isReservedMenuShortcut(modifierFlags: [.command, .capsLock], keyCode: 0x23)) // P
        #expect(InputCapture.isReservedMenuShortcut(modifierFlags: [.command, .capsLock], keyCode: 0x0F)) // R
        #expect(InputCapture.isReservedMenuShortcut(modifierFlags: [.command, .capsLock], keyCode: 0x11)) // T
    }

    @Test func unboundKeyIsNeverAReservedShortcutEvenWithCapsLock() {
        #expect(!InputCapture.isReservedMenuShortcut(modifierFlags: [.command], keyCode: 0x00)) // A -- unbound
        #expect(!InputCapture.isReservedMenuShortcut(modifierFlags: [.command, .capsLock], keyCode: 0x00))
    }

    @Test func reservedKeyWithoutCommandIsNotAShortcut() {
        #expect(!InputCapture.isReservedMenuShortcut(modifierFlags: [], keyCode: 0x23))
        #expect(!InputCapture.isReservedMenuShortcut(modifierFlags: [.shift], keyCode: 0x23))
    }

    @Test func reservedKeyWithExtraNonCapsLockModifierIsNotAShortcut() {
        // Command-Shift-P is a different chord entirely -- unlike Caps
        // Lock, Shift must NOT be silently ignored.
        #expect(!InputCapture.isReservedMenuShortcut(modifierFlags: [.command, .shift], keyCode: 0x23))
    }

    // MARK: - CaptureState / button-stuck-down (Important 2)

    @Test func mouseDownCapturesAndPostsButtonDown() {
        var state = CaptureState()
        let effects = state.mouseDown()
        #expect(effects == CaptureState.Effects(shouldCapture: true, postButtonDown: true))
        #expect(state.mouseCaptured)
        #expect(state.buttonDown)
    }

    @Test func secondMouseDownWhileAlreadyCapturedDoesNotRecapture() {
        var state = CaptureState()
        _ = state.mouseDown()
        let effects = state.mouseDown()
        #expect(!effects.shouldCapture, "already captured -- must not re-capture")
        #expect(effects.postButtonDown, "still a real click -- still posts down")
    }

    @Test func normalClickCycleReleasesWithNoCompensatingUp() {
        var state = CaptureState()
        _ = state.mouseDown()
        let upEffects = state.mouseUp()
        #expect(upEffects == CaptureState.Effects(postButtonUp: true))
        #expect(!state.buttonDown)

        let releaseEffects = state.release()
        #expect(!releaseEffects.postButtonUp, "button was already up -- no compensating event needed")
        #expect(releaseEffects.shouldRelease)
        #expect(!state.mouseCaptured)
    }

    @Test func releaseWhileButtonStillDownPostsCompensatingButtonUp() {
        // THE bug: Command-Escape (or a window resign-key) while the
        // physical button is still held must not leave the Lisa's
        // emulated mouse button stuck down.
        var state = CaptureState()
        _ = state.mouseDown()
        #expect(state.buttonDown)

        let effects = state.release()
        #expect(effects.postButtonUp, "compensating up must be reported")
        #expect(effects.shouldRelease)
        #expect(!state.buttonDown)
        #expect(!state.mouseCaptured)
    }

    @Test func releaseWhenNotCapturedIsANoOp() {
        var state = CaptureState()
        #expect(state.release() == CaptureState.Effects())
    }

    @Test func mouseUpWhileNotCapturedIsIgnored() {
        var state = CaptureState()
        #expect(state.mouseUp() == CaptureState.Effects())
    }

    @Test func fullDragCaptureClickDragReleaseSequenceNeverDoubleReportsButtonUp() {
        var state = CaptureState()
        _ = state.mouseDown()          // captures + button down
        let up = state.mouseUp()       // normal release of the physical button
        #expect(up.postButtonUp)
        let release = state.release()  // later, capture released with the button already up
        #expect(!release.postButtonUp, "must not double-report an up the caller already posted")
    }

    // MARK: - CaptureState / duplicate mouseUp (M1c Task 5 ledger fold)

    @Test func duplicateMouseUpWhileCapturedDoesNotDoubleReportButtonUp() {
        // THE fold: mouseUp() previously guarded only on `mouseCaptured`,
        // not `buttonDown` -- so a second mouseUp callback for the same
        // physical release (still captured, button already balanced)
        // would report a phantom second button-up to the Lisa.
        var state = CaptureState()
        _ = state.mouseDown()
        let firstUp = state.mouseUp()
        #expect(firstUp == CaptureState.Effects(postButtonUp: true))
        #expect(!state.buttonDown)

        let duplicateUp = state.mouseUp()
        #expect(duplicateUp == CaptureState.Effects(), "button already up -- must not double-report")
        #expect(state.mouseCaptured, "capture itself is untouched by a spurious up")
    }

    // MARK: - ModifierKeycapTracker / focus-loss resync (Important 3a:
    // "keyboard modifier state never resynced on focus loss (stuck
    // Command after Command-Tab)")
    //
    // `InputCapture.resyncModifiers()` (called from the resign-key
    // observer that already releases mouse capture) is a thin wrapper:
    // post a `.keyUp` for every keycap `ModifierKeycapTracker.resync()`
    // returns, then reset `previousModifierFlags`. These tests cover the
    // pure tracker directly -- see that type's doc comment in
    // `InputCapture.swift` for why (unit-testable without a real
    // `NSEvent`/`AppModel`/window, same pattern as `CaptureState`).

    @Test func focusLossWithCommandDownReturnsTheCommandKeycapAndResets() {
        var tracker = ModifierKeycapTracker()
        tracker.setKeycap(0x7F, down: true) // Command, per hardware-notes.md §8
        #expect(tracker.down == [0x7F])

        let owedUps = tracker.resync()
        #expect(owedUps == [0x7F], "focus loss must post a balancing keyUp($7F) for the stuck Command")
        #expect(tracker.down.isEmpty, "the tracker itself must be reset -- nothing left tracked as down")
    }

    @Test func modifierResyncIsIdempotentWhenNothingIsDown() {
        var tracker = ModifierKeycapTracker()
        #expect(tracker.resync() == [], "nothing down -- resync must be a no-op, not post spurious keyUps")
        // Calling it again (e.g. two focus-loss events in a row) must stay a no-op.
        #expect(tracker.resync() == [])
    }

    @Test func resyncReturnsEveryTrackedKeycapAndClearsAll() {
        var tracker = ModifierKeycapTracker()
        tracker.setKeycap(0x7E, down: true) // Shift
        tracker.setKeycap(0x7F, down: true) // Command
        tracker.setKeycap(0x7C, down: true) // L-Option
        #expect(tracker.resync() == [0x7C, 0x7E, 0x7F], "every tracked-down keycap must be returned")
        #expect(tracker.down.isEmpty)
    }

    @Test func settingAKeycapUpRemovesItFromTheTrackerBeforeAnyFocusLoss() {
        // The ordinary (non-buggy) path: a modifier goes down then up
        // again while this window stays key -- resync afterward must not
        // report it (it was never "stuck").
        var tracker = ModifierKeycapTracker()
        tracker.setKeycap(0x7F, down: true)
        tracker.setKeycap(0x7F, down: false)
        #expect(tracker.resync() == [])
    }

    // MARK: - shouldForwardKeyUp / stuck non-modifier keycap (Important 3b:
    // "per-event shortcut suppression can leave a keycap stuck down")

    @Test func downTrackingWinsOverReservedShortcutSuppression() {
        // THE bug: P held down (forwarded, not a shortcut by itself), then
        // Command pressed, then P released -- the release event's chord
        // LOOKS like "Command-P" (a reserved shortcut) even though the
        // matching down was already forwarded. The up must still go out,
        // or the Lisa is left believing P ($44) is stuck down forever.
        #expect(InputCapture.shouldForwardKeyUp(wasForwardedDown: true, isReservedMenuShortcut: true))
    }

    @Test func suppressionStillAppliesWhenNoMatchingDownWasEverForwarded() {
        // The ordinary Command-P case: the DOWN was suppressed (it matched
        // the reserved shortcut from the start), so the UP must also stay
        // suppressed -- there is no compensating forward to balance.
        #expect(!InputCapture.shouldForwardKeyUp(wasForwardedDown: false, isReservedMenuShortcut: true))
    }

    @Test func ordinaryKeyUpWithNoShortcutInvolvedIsAlwaysForwarded() {
        #expect(InputCapture.shouldForwardKeyUp(wasForwardedDown: true, isReservedMenuShortcut: false))
        #expect(InputCapture.shouldForwardKeyUp(wasForwardedDown: false, isReservedMenuShortcut: false))
    }
}
