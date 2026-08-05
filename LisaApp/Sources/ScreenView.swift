import AppKit
import LisaShell
import SwiftUI

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
            } else {
                Text("starting…")
            }
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

#Preview {
    ScreenView()
        .environment(AppModel())
}
