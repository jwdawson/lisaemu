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
/// coordinate math) and `handleMouseMoved`/`captureMouse`/`releaseCapture`
/// below for delta scaling, fractional-remainder accumulation, and the
/// capture/escape-hatch mechanics.
@MainActor
@Observable
final class InputCapture {
    /// Drives `ScreenView`'s "click to capture / Command-Escape to
    /// release" status-bar hint.
    private(set) var mouseCaptured = false

    private weak var model: AppModel?
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var previousModifierFlags: NSEvent.ModifierFlags = []

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
    private static let reservedMenuShortcutKeyCodes: Set<UInt16> = [0x23, 0x0F, 0x11] // P, R, T

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
            self?.releaseCapture()
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

    private func isReservedMenuShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods == .command && Self.reservedMenuShortcutKeyCodes.contains(event.keyCode)
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
    func handleMouseDown() {
        if !mouseCaptured { captureMouse() }
        model?.post(.mouseButton(down: true))
    }

    func handleMouseUp() {
        guard mouseCaptured else { return }
        model?.post(.mouseButton(down: false))
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

    private func captureMouse() {
        guard !mouseCaptured else { return }
        mouseCaptured = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0) // de-associate: raw deltas keep flowing past screen edges while hidden
    }

    /// Called by: Command-Escape (`handle(_:)`), window resign-key
    /// (`start()`'s observer), and `stop()`. Idempotent -- safe to call
    /// when not currently captured.
    func releaseCapture() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        pendingDX = 0
        pendingDY = 0
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
}
