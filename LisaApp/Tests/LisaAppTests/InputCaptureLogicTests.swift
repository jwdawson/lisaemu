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
}
