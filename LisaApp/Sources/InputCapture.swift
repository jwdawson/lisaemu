import AppKit
import CoreGraphics
import LisaShell
import Observation

/// Wires host (macOS) keyboard and mouse input into the Lisa, per the plan's
/// M1c Task 4 interfaces. Owns:
///
/// - A pair of `NSEvent` local monitors (`keyDown`/`keyUp`/`flagsChanged`,
///   and the mouse-button/-move stream via `MouseCaptureView`, below) that
///   translate host input into `LisaShell.InputEvent`s and post them through
///   `AppModel.post(_:)`.
/// - Pointer capture state (`mouseCaptured`) for the "click to capture,
///   Command-Escape to release" flow `ScreenView`'s status bar surfaces a
///   hint for.
///
/// ## Keyboard precedence: menu shortcuts vs. the Lisa
///
/// `NSEvent.addLocalMonitorForEvents` fires BEFORE `NSApplication.sendEvent`
/// -- i.e. before SwiftUI's `.commands`/`CommandGroup` key-equivalent
/// matching ever sees the event. That means simply forwarding every keyDown
/// to the Lisa would NOT stop the menu from also firing: the local monitor
/// doesn't own the event, it only observes/can-veto it. `LisaEmuApp.swift`'s
/// three bound shortcuts (Command-P Pause/Start, Command-R Reset,
/// Command-T Throttle) are matched explicitly here (`isReservedMenuShortcut`)
/// and simply NOT forwarded to the Lisa -- the event is still returned
/// unmodified from the monitor, so AppKit's normal dispatch (and therefore
/// the SwiftUI menu command) proceeds exactly as if this class didn't
/// exist. Empirically verified (manual run, see task-4-report.md): pressing
/// Command-P toggles Pause/Start and nothing reaches the Lisa; pressing an
/// UNBOUND Command-key combination (e.g. Command-S, Command-A -- neither is
/// a `LisaEmuApp.swift` shortcut) both forwards Command (via
/// `flagsChanged`) and the letter key to the Lisa, per the brief's "Command
/// is a real Lisa key" -- the Lisa keyboard driver (hardware-notes.md §8,
/// "Modifiers": "the OS combines them into shift state itself") is
/// responsible for whatever it does with an unrecognized Command-chord, not
/// this layer.
///
/// ## Auto-repeat
///
/// Host key-repeat (`event.isARepeat`) is deliberately NOT forwarded --
/// hardware-notes.md §8 "Auto-Repeat": real Lisa keyboard hardware sends
/// exactly one down edge per physical press: the Lisa OS's own software
/// timer (`RepeatCheck`) does the repeating from that single held-down
/// state, not from repeated down messages. Forwarding the host's
/// synthesized repeat keyDowns would desync that model (multiple down
/// edges for one physical hold).
///
/// ## CapsLock
///
/// hardware-notes.md §8 "Modifiers": CapsLock (`$7D`) is a **latching** key
/// -- "the OS tracks lock state itself" -- and macOS sends exactly ONE
/// `flagsChanged` per physical toggle (not a down-then-up pair like other
/// modifiers). The generic bit-diff logic in `handleFlagsChanged` handles
/// this correctly without a special case: `.capsLock` transitioning 0->1
/// (locking) emits `.keyDown($7D)`; transitioning 1->0 (unlocking) emits
/// `.keyUp($7D)` -- exactly "down on lock, up on unlock" per the brief.
///
/// ## Modifier tracking: a coarse-bit simplification (documented limitation)
///
/// `handleFlagsChanged` diffs `event.modifierFlags` against the previous
/// snapshot using `NSEvent.ModifierFlags`' COARSE categories (`.shift`,
/// `.option`, `.command`, `.capsLock`) -- there is no public, documented API
/// to distinguish "which physical key" beyond the triggering event's own
/// `keyCode` (used to pick the correct Lisa keycap for THIS transition).
/// For Shift this is exactly correct: hardware-notes.md §8 says both
/// physical shift keys map to the SAME Lisa keycap (`$7E`, "the OS ORs
/// left/right into a single bit anyway"), so "some shift held" is precisely
/// the right question to ask. For Option it is a known, accepted gap: L-
/// and R-Option map to DIFFERENT Lisa keycaps (`$7C`/`$4E`), but macOS's
/// coarse `.option` bit does not distinguish them -- holding L-Option then
/// ALSO pressing R-Option will not emit a second down (the coarse bit was
/// already set), and releasing one while the other stays held will not emit
/// an up. Both-Option-keys-simultaneously is a rare edge case; single-key
/// Option use (the overwhelming common case) works correctly. A fully
/// correct implementation would need undocumented per-key device-dependent
/// modifier bits, which this codebase avoids relying on (matching the
/// brief's own "track previous NSEvent.ModifierFlags" framing, not a
/// per-physical-key bitmask).
///
/// ## Mouse
///
/// See `MouseCaptureView.swift` for the `NSView`/`NSTrackingArea` side
/// (view-scoped hit-testing, so this class never does manual window-space
/// coordinate math) and `handleMouseMoved`/`applyCapture`/`releaseCapture`
/// below for delta scaling, fractional-remainder accumulation, and the
/// capture/escape-hatch mechanics.
@MainActor
@Observable
final class InputCapture {
    /// Drives `ScreenView`'s "click to capture / Command-Escape to
    /// release" status-bar hint. Forwards through `captureState` (below)
    /// rather than being its own stored `Bool` -- see that property's doc
    /// comment.
    var mouseCaptured: Bool { captureState.mouseCaptured }

    private weak var model: AppModel?
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var previousModifierFlags: NSEvent.ModifierFlags = []

    /// Pure pointer-capture/button state machine -- see `CaptureState`'s
    /// own doc comment (code-review fix, M1c Task 4 fix round: "capture
    /// release with the button held leaves the emulated button stuck
    /// down"). `private(set)`, not `private`: `mouseCaptured` below reads
    /// through it, and `@Observable` needs the read to go through an
    /// actual stored-property access for `ScreenView`'s status-bar hint to
    /// update reactively.
    private(set) var captureState = CaptureState()

    /// Fractional leftover from the last `handleMouseMoved` scaling pass,
    /// per axis -- see that method's doc comment for why this exists (slow
    /// trackpad/mouse movement scaled down to Lisa-pixel space would
    /// otherwise round to 0 and be silently lost every event).
    private var pendingDX: Double = 0
    private var pendingDY: Double = 0

    /// Host Carbon virtual keycodes bound to a `LisaEmuApp.swift`
    /// `.commands` keyboard shortcut (all Command-only chords): `kVK_ANSI_P`
    /// (Pause/Start), `kVK_ANSI_R` (Reset), `kVK_ANSI_T` (Throttle) -- see
    /// this type's "Keyboard precedence" doc comment, above. Kept in sync
    /// BY HAND with `LisaEmuApp.swift`'s `CommandMenu("Machine")`; there is
    /// no shared source of truth to derive this from (SwiftUI's
    /// `.keyboardShortcut` isn't introspectable from outside the view
    /// builder that declared it).
    /// `nonisolated`: read by the `nonisolated static func
    /// isReservedMenuShortcut`, below -- a `Set<UInt16>` constant is
    /// trivially `Sendable`/safe to read from any isolation domain, but
    /// static stored properties of a `@MainActor` type default to
    /// `@MainActor` isolation regardless (only certain "simple literal"
    /// types get an automatic exemption; a collection literal doesn't), so
    /// this needs the explicit annotation.
    private nonisolated static let reservedMenuShortcutKeyCodes: Set<UInt16> = [0x23, 0x0F, 0x11] // P, R, T

    /// `kVK_Escape` -- not in `KeyMap` (the Lisa keyboard predates
    /// Escape), used here only to recognize Command-Escape, the pointer
    /// capture release gesture.
    private static let escapeKeyCode: UInt16 = 0x35

    /// Modifier categories with a Lisa keycap equivalent -- Control and
    /// Function are deliberately excluded (no Lisa key; `KeyMap` has no
    /// case for their virtual keycodes either, so including them would be
    /// inert, but omitting them here documents the intent directly).
    private static let trackedModifierFlags: [NSEvent.ModifierFlags] = [.shift, .option, .command, .capsLock]

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle (start/stop from `ScreenView.onAppear`/`onDisappear`)

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
        // Escape hatch #2 (the brief requires at least one; this class
        // implements both): losing key-window status -- Cmd-Tab away,
        // clicking another app, a system dialog stealing focus -- auto-
        // releases capture so the pointer is never trapped somewhere the
        // user can no longer see this window to press Command-Escape.
        // Single-window app (`LisaEmuApp.swift` uses `Window`, not
        // `WindowGroup`), so "any window resigned key" is unambiguous.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // CODE-REVIEW FIX: `queue: .main` guarantees this closure runs
            // synchronously on the main thread/main actor's executor, but
            // `NotificationCenter`'s closure parameter type isn't (can't
            // be -- it's a non-isolated, non-`@Sendable`-by-contract
            // framework signature) statically known to the compiler as
            // `@MainActor`-isolated, so calling the `@MainActor`-isolated
            // `releaseCapture()` here without asserting isolation was a
            // real (reproduced) build warning: "call to main actor-isolated
            // instance method 'releaseCapture()' in a synchronous
            // nonisolated context." `MainActor.assumeIsolated` asserts (and
            // dynamically checks in debug builds) exactly the guarantee
            // `queue: .main` already provides, rather than adding a
            // pointless extra `DispatchQueue.main.async` hop for something
            // that's already synchronously on main.
            MainActor.assumeIsolated {
                self?.releaseCapture()
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        releaseCapture()
    }

    // MARK: - Keyboard

    /// Pure predicate, extracted out of `NSEvent` (which unit tests can't
    /// cheaply synthesize) so it's directly testable -- see
    /// `LisaAppTests/InputCaptureLogicTests.swift`.
    ///
    /// CODE-REVIEW FIX: the original version compared
    /// `modifierFlags.intersection(.deviceIndependentFlagsMask) ==
    /// .command` exactly. With Caps Lock physically engaged, `modifierFlags`
    /// also carries `.capsLock`, so `mods` became `[.command, .capsLock] !=
    /// .command` -- the reserved-shortcut check silently failed, and
    /// Command-P/R/T would ALSO forward to the Lisa while the menu action
    /// still fired (AppKit's own key-equivalent matching ignores Caps Lock
    /// for letter shortcuts, so the menu was never the thing that broke).
    /// `.capsLock` is subtracted before the comparison so its state is
    /// irrelevant to shortcut recognition, matching AppKit's own behavior.
    /// `nonisolated`: a pure function of its parameters (no access to any
    /// `InputCapture` instance/actor-isolated state) -- without this,
    /// static members of a `@MainActor`-isolated type inherit that
    /// isolation by default, which would force test callers (running in a
    /// plain nonisolated/background test executor) to `await` a call that
    /// touches no actor-isolated state at all.
    nonisolated static func isReservedMenuShortcut(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        let mods = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        return mods == .command && reservedMenuShortcutKeyCodes.contains(keyCode)
    }

    private func isReservedMenuShortcut(_ event: NSEvent) -> Bool {
        Self.isReservedMenuShortcut(modifierFlags: event.modifierFlags, keyCode: event.keyCode)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == Self.escapeKeyCode, event.modifierFlags.contains(.command) {
                releaseCapture() // Command-Escape: pointer-capture release gesture, not forwarded.
            } else if isReservedMenuShortcut(event) {
                break // Let LisaEmuApp.swift's menu command handle it -- see "Keyboard precedence" above.
            } else if !event.isARepeat, let keycap = KeyMap.lisaKeycap(forMacKeyCode: event.keyCode) {
                model?.post(.keyDown(keycap))
            }
        case .keyUp:
            if !isReservedMenuShortcut(event), let keycap = KeyMap.lisaKeycap(forMacKeyCode: event.keyCode) {
                model?.post(.keyUp(keycap))
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    /// Diffs `event.modifierFlags` against the previous snapshot -- see
    /// this type's "Modifier tracking" doc comment for the coarse-bit
    /// design and its documented Option-key limitation.
    private func handleFlagsChanged(_ event: NSEvent) {
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { previousModifierFlags = current }
        for bit in Self.trackedModifierFlags {
            let was = previousModifierFlags.contains(bit)
            let now = current.contains(bit)
            guard was != now, let keycap = KeyMap.lisaKeycap(forMacKeyCode: event.keyCode) else { continue }
            model?.post(now ? .keyDown(keycap) : .keyUp(keycap))
        }
    }

    // MARK: - Mouse (called by `MouseCaptureView.swift`'s `NSView`)

    /// A left-mouse-down inside `ScreenView`'s tracking view: captures the
    /// pointer if not already captured (click-to-capture), then always
    /// forwards the click itself as a Lisa mouse-button-down -- the click
    /// that captures the pointer is a real click as far as the Lisa is
    /// concerned too, matching how the Lisa's relative-only mouse protocol
    /// (hardware-notes.md §8 "Mouse": delta packets, no absolute position)
    /// has no notion of "where the host cursor is" to get out of sync with.
    /// All actual state transitions (what counts as "captured," whether a
    /// compensating up is owed later) live in `captureState`, below --
    /// this method only translates its reported `Effects` into real
    /// side effects (AppKit calls, posting to the Lisa).
    func handleMouseDown() {
        let effects = captureState.mouseDown()
        if effects.shouldCapture { applyCapture() }
        if effects.postButtonDown { model?.post(.mouseButton(down: true)) }
    }

    func handleMouseUp() {
        let effects = captureState.mouseUp()
        if effects.postButtonUp { model?.post(.mouseButton(down: false)) }
    }

    /// `viewSize` is the tracking `NSView`'s own `bounds.size` at the
    /// moment of the event (see `MouseCaptureView.swift`) -- since that
    /// view is layered into the same `ZStack`/`.aspectRatio(...,
    /// contentMode: .fit)` as the Lisa screen `Image` in `ScreenView.swift`,
    /// its size tracks the actual on-screen pixel size of the displayed
    /// Lisa framebuffer exactly, aspect-toggle and window-resize both
    /// included -- no separate `GeometryReader`/window-coordinate math
    /// needed.
    ///
    /// Scaling: `deltaX`/`deltaY` arrive in host screen POINTS, independent
    /// of view size; multiplying by `lisaPixelWidth/viewSize.width` (and
    /// the Y equivalent) converts to Lisa-pixel-space deltas for the
    /// CURRENT display scale. `pendingDX`/`pendingDY` accumulate the
    /// fractional remainder every call (rather than truncating and
    /// discarding it) so that slow movement -- where a single event's
    /// scaled delta is `< 1` Lisa pixel -- is never silently lost; it
    /// simply accumulates across events until it crosses a whole-pixel
    /// boundary. Per-packet clamping to `Int8` (hardware-notes.md §8
    /// "Delta packet: ... dx (signed byte), dy (signed byte)") only
    /// subtracts the CLAMPED amount from the pending remainder, so an
    /// oversized single-event delta (a fast flick) carries its overflow
    /// into subsequent packets instead of being dropped outright.
    func handleMouseMoved(deltaX: CGFloat, deltaY: CGFloat, viewSize: CGSize) {
        guard mouseCaptured, viewSize.width > 0, viewSize.height > 0 else { return }
        let scaleX = Double(lisaPixelWidth) / Double(viewSize.width)
        let scaleY = Double(lisaPixelHeight) / Double(viewSize.height)
        pendingDX += Double(deltaX) * scaleX
        pendingDY += Double(deltaY) * scaleY

        let dxInt = Int(pendingDX.rounded(.towardZero))
        let dyInt = Int(pendingDY.rounded(.towardZero))
        guard dxInt != 0 || dyInt != 0 else { return }

        let dx = Int8(clamping: dxInt)
        let dy = Int8(clamping: dyInt)
        pendingDX -= Double(dx)
        pendingDY -= Double(dy)
        model?.post(.mouseDelta(dx: dx, dy: dy))
    }

    private var lisaPixelWidth: CGFloat { 720 } // Bus.framebufferWidth -- see ScreenView.swift's own hardcoded copy for why this isn't imported from LisaCore.
    private var lisaPixelHeight: CGFloat {
        (model?.showActualSize == true) ? 364 : 364 * ScreenView.verticalStretch
    }

    // MARK: - Capture / release

    private func applyCapture() {
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0) // de-associate: raw deltas keep flowing past screen edges while hidden
    }

    /// Called by: Command-Escape (`handle(_:)`), window resign-key
    /// (`start()`'s observer), and `stop()`. Idempotent -- safe to call
    /// when not currently captured (`captureState.release()` is a no-op
    /// then).
    ///
    /// CODE-REVIEW FIX: previously this only flipped `mouseCaptured` and
    /// undid the cursor hide/associate -- with no compensating mouse-button
    /// event. If the user pressed the physical button, then released
    /// capture WHILE STILL HOLDING IT (Command-Escape or a window
    /// resign-key mid-drag both reach here without an intervening
    /// `handleMouseUp()`), the Lisa would be stuck believing its mouse
    /// button was held down forever -- the next `handleMouseUp()` after a
    /// fresh capture would see `captureState.mouseCaptured == true` again
    /// but never balance the phantom down. `captureState.release()` now
    /// reports a compensating `postButtonUp` itself whenever a button was
    /// left down, applied here BEFORE the cursor is restored.
    func releaseCapture() {
        let effects = captureState.release()
        if effects.postButtonUp { model?.post(.mouseButton(down: false)) }
        guard effects.shouldRelease else { return }
        pendingDX = 0
        pendingDY = 0
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
}

/// Pure pointer-capture/button state machine, extracted out of
/// `InputCapture` for unit testing without needing real `NSCursor`/
/// `CGAssociateMouseAndMouseCursorPosition`/`AppModel` side effects
/// (code-review fix, M1c Task 4 fix round: "capture release with the
/// button held leaves the emulated button stuck down" -- see
/// `LisaAppTests/InputCaptureLogicTests.swift`). Every mutating method
/// reports the concrete side effects its caller should perform; this type
/// performs none of them itself, which is exactly what makes it testable
/// with plain `#expect` assertions on its return value.
struct CaptureState: Equatable {
    private(set) var mouseCaptured = false
    private(set) var buttonDown = false

    /// Explicit, so callers (including tests) get a plain, internally
    /// accessible `CaptureState()` -- without this, the compiler-synthesized
    /// memberwise init would be `private` (matching the `private(set)`
    /// properties' setter access), making `CaptureState()` uncallable from
    /// outside this file, including `@testable import`.
    init() {}

    struct Effects: Equatable {
        var shouldCapture = false
        var postButtonDown = false
        var postButtonUp = false
        var shouldRelease = false
    }

    mutating func mouseDown() -> Effects {
        var effects = Effects()
        if !mouseCaptured {
            mouseCaptured = true
            effects.shouldCapture = true
        }
        buttonDown = true
        effects.postButtonDown = true
        return effects
    }

    /// Guards on `buttonDown` (not just `mouseCaptured`) so a duplicate
    /// `mouseUp` -- e.g. two `NSView` mouse-up callbacks for one physical
    /// release, or a `mouseUp` arriving after the button was already
    /// balanced by `release()`'s compensating up -- never double-reports a
    /// button-up to the Lisa (M1c Task 5 ledger fold: pre-existing shape,
    /// cheap hardening; see `InputCaptureLogicTests`).
    mutating func mouseUp() -> Effects {
        guard mouseCaptured, buttonDown else { return Effects() }
        buttonDown = false
        return Effects(postButtonUp: true)
    }

    /// If the button is still down when capture is released (see
    /// `InputCapture.releaseCapture`'s doc comment for the exact scenario
    /// this guards against), reports a COMPENSATING button-up FIRST so the
    /// emulated Lisa button is never left stuck down.
    mutating func release() -> Effects {
        guard mouseCaptured else { return Effects() }
        var effects = Effects()
        if buttonDown {
            effects.postButtonUp = true
            buttonDown = false
        }
        mouseCaptured = false
        effects.shouldRelease = true
        return effects
    }
}
