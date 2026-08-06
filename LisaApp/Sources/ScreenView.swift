import AppKit
import LisaShell
import SwiftUI
import UniformTypeIdentifiers

/// The live Lisa screen (blit of `AppModel.image`) plus a one-line status
/// bar, per the plan's Task 3 interfaces ("a status bar (cycles, emulated
/// seconds, throttle state, halted flag)").
///
/// Aspect correction: the Lisa's 720x364 framebuffer is displayed on a
/// roughly 3:2 CRT area, so square source pixels render visibly squashed
/// unless stretched -- `AppModel.showActualSize == false` (the default)
/// applies `ScreenView.verticalStretch`; the View menu's "Actual Size
/// (1:1)" toggle (`LisaApp.swift`) switches to unstretched source pixels.
/// This is a cosmetic display choice only, not a hardware model (see the
/// plan's Global Constraints, "Lisa pixel aspect").
struct ScreenView: View {
    @Environment(AppModel.self) private var model

    /// Created lazily in `.onAppear` (needs `model`, which `@Environment`
    /// only makes available once the view is actually inserted into the
    /// hierarchy -- not from a property initializer) and torn down in
    /// `.onDisappear`. See `InputCapture.swift`'s doc comment for the
    /// keyboard/mouse wiring this owns.
    @State private var inputCapture: InputCapture?

    /// Cosmetic vertical stretch factor for the default (non-1:1) view --
    /// see the plan's Global Constraints: "vertical stretch ~1.48".
    static let verticalStretch: CGFloat = 1.48

    /// Nominal framebuffer dimensions (matches `LisaCore.VideoTiming`'s
    /// `framebufferWidth`/`framebufferHeight`, 720x364 -- hardcoded here
    /// rather than imported: `LisaApp` depends on `LisaShell`, not
    /// `LisaCore`, directly; see `LisaShell.Frame`'s doc comment for the
    /// same layering). Used only for the aspect-ratio calculation below,
    /// which is display geometry, not emulation behavior.
    private static let framebufferWidth: CGFloat = 720
    private static let framebufferHeight: CGFloat = 364

    private var displaySize: CGSize {
        model.showActualSize
            ? CGSize(width: Self.framebufferWidth, height: Self.framebufferHeight)
            : CGSize(width: Self.framebufferWidth, height: Self.framebufferHeight * Self.verticalStretch)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(displaySize, contentMode: .fit)
                } else {
                    ProgressView("Booting…")
                        .foregroundStyle(.white)
                }
                // Mouse input: layered into the SAME ZStack (and therefore
                // sharing the ZStack's own `.aspectRatio(displaySize,
                // contentMode: .fit)` below) so this view's `NSView.bounds`
                // exactly matches the Lisa screen `Image`'s on-screen pixel
                // rect -- see `InputCapture.handleMouseMoved`'s doc comment
                // for why that equivalence is what makes delta scaling
                // correct without separate coordinate-space math.
                if let inputCapture {
                    MouseCaptureRepresentable(capture: inputCapture)
                }
            }
            .aspectRatio(displaySize, contentMode: .fit)
            .frame(minWidth: 360, minHeight: 220)

            statusBar
        }
        .alert("Could Not Load ROM", isPresented: .constant(model.startupError != nil)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            Text(model.startupError ?? "")
        }
        // M2 Task 7: dismissible (unlike the fatal ROM alert above) --
        // see `AppModel.diskError`'s doc comment.
        .alert("Could Not Insert Disk",
               isPresented: Binding(get: { model.diskError != nil },
                                     set: { if !$0 { model.dismissDiskError() } })) {
            Button("OK", role: .cancel) { model.dismissDiskError() }
        } message: {
            Text(model.diskError ?? "")
        }
        // M2 Task 7: drag-and-drop of a .dc42 file anywhere onto the window
        // inserts it -- the same `insertFloppy(url:)` entry point as File >
        // Insert Disk…/`--insert-disk`. `NSItemProvider.loadItem` runs its
        // completion off the main thread (undocumented but empirically
        // true, and not contractually main-thread per its own API), so the
        // `AppModel` call is hopped back to main explicitly rather than
        // assumed synchronous.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, AppModel.isDC42File(url) else { return }
                DispatchQueue.main.async {
                    model.insertFloppy(url: url)
                }
            }
            return true
        }
        .onAppear {
            if inputCapture == nil {
                let capture = InputCapture(model: model)
                capture.start()
                inputCapture = capture
            }
        }
        .onDisappear {
            inputCapture?.stop()
            inputCapture = nil
        }
    }

    private var statusBar: some View {
        HStack {
            if let status = model.status {
                Text("cycles: \(status.cycles)")
                Divider().frame(height: 12)
                Text(String(format: "emulated: %.1fs", status.emulatedSeconds))
                Divider().frame(height: 12)
                Text(status.throttled ? "throttled" : "unthrottled")
                if status.halted {
                    Divider().frame(height: 12)
                    Text("HALTED").foregroundStyle(.red)
                }
                if status.diskInserted {
                    Divider().frame(height: 12)
                    diskIndicator(active: status.diskActivity)
                }
            } else {
                Text("starting…")
            }
            Spacer()
            // Subtle mouse-capture hint (M1c Task 4) -- reflects
            // `InputCapture.mouseCaptured` so it flips the instant capture
            // engages/releases (click / Command-Escape / window resign-key).
            Text(inputCapture?.mouseCaptured == true ? "mouse captured -- ⌘⎋ to release" : "click to capture mouse")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// M2 Task 7's status-strip disk indicator: a small colored dot (an
    /// SF Symbol was deliberately avoided here -- there is no well-known
    /// "floppy disk" glyph in the system symbol set to reach for with
    /// confidence, and a missing/wrong symbol name fails silently at
    /// runtime rather than at build time) plus a "DISK" label, shown only
    /// while `EmuStatus.diskInserted` is true (see `statusBar`, above).
    /// `active` (`EmuStatus.diskActivity`) recolors the dot green -- the
    /// "activity flash": since it only ever reflects the MOST RECENT
    /// ~0.25s status publish (`EmulationController`'s own publish cadence),
    /// a real floppy access shows as a brief green flash rather than a
    /// literal instantaneous blink, which is the right granularity for a
    /// human glancing at the status strip.
    private func diskIndicator(active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text("DISK")
        }
    }
}

// MARK: - Mouse tracking view (AppKit bridge)

/// Thin `NSView` used only for its `NSTrackingArea`-based hit-testing and
/// mouse-event callbacks -- AppKit routes `mouseDown`/`mouseUp`/
/// `mouseMoved`/`mouseDragged` to this view exactly when the event is
/// within ITS bounds, so `InputCapture` never has to do manual
/// window-space/SwiftUI-coordinate-space math to know "is this click on
/// the Lisa screen." See `InputCapture.swift`'s "Mouse" doc comment.
private final class MouseCaptureNSView: NSView {
    var capture: InputCapture?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.mouseMoved` here delivers moved events scoped to this view
        // without needing `NSWindow.acceptsMouseMovedEvents` set globally;
        // `.inVisibleRect` keeps the area correct across SwiftUI resizes
        // without this class having to observe frame changes itself.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capture?.handleMouseDown()
    }

    override func mouseUp(with event: NSEvent) {
        capture?.handleMouseUp()
    }

    override func mouseMoved(with event: NSEvent) {
        capture?.handleMouseMoved(deltaX: event.deltaX, deltaY: event.deltaY, viewSize: bounds.size)
    }

    /// While the left button is held, AppKit delivers `mouseDragged`
    /// instead of `mouseMoved` -- both carry the same raw `deltaX`/`deltaY`
    /// and both need forwarding (dragging IS moving, as far as the Lisa's
    /// relative-delta protocol is concerned).
    override func mouseDragged(with event: NSEvent) {
        capture?.handleMouseMoved(deltaX: event.deltaX, deltaY: event.deltaY, viewSize: bounds.size)
    }
}

private struct MouseCaptureRepresentable: NSViewRepresentable {
    let capture: InputCapture

    func makeNSView(context: Context) -> MouseCaptureNSView {
        let view = MouseCaptureNSView()
        view.capture = capture
        return view
    }

    func updateNSView(_ nsView: MouseCaptureNSView, context: Context) {
        nsView.capture = capture
    }
}

#Preview {
    ScreenView()
        .environment(AppModel())
}
