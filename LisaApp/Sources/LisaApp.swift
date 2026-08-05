import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// LisaEmu's app shell (M1c Task 3): a single window showing the live
/// emulated Lisa screen, driven by `AppModel`/`LisaShell.EmulationController`.
///
/// Uses `Window` (not `WindowGroup`) as the primary scene: `AppModel` is
/// genuinely singleton, process-wide state (one `EmulationController`
/// thread, one Lisa), so there is no legitimate second window to open --
/// `Window` matches that by construction (no "New Window" File-menu item,
/// no Cmd+N duplicate windows sharing one model). See
/// axiom-macos/skills/windows.md's anti-pattern #1 ("WindowGroup when you
/// need exactly one window") and #4 (using `Window` as the primary scene
/// is fine, even desirable, when there's no reason for the app to outlive
/// its one window) -- both consciously addressed by this choice.
@main
struct LisaEmuApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("LisaEmu", id: "main") {
            ScreenView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model // see AppDelegate's doc comment
                    model.runAutoScreenshotIfRequested()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save Screenshot…") {
                    presentSaveScreenshotPanel()
                }
            }
            CommandMenu("Machine") {
                Button(model.running ? "Pause" : "Start") {
                    model.toggleRunning()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("Reset") {
                    model.reset()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Toggle("Throttle", isOn: Bindable(model).throttled)
                    .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Actual Size (1:1)", isOn: Bindable(model).showActualSize)
            }
        }
    }

    /// File > Save Screenshot…: fetches the current raw frame from the
    /// emulation thread and PNG-encodes it app-side (per the plan's Task 1
    /// interfaces), then presents `NSSavePanel` for the destination.
    /// Default directory is `~/Development/LisaEmu-artifacts` -- a sibling
    /// of this repo, never inside it, matching the "never commit
    /// ROMs/images/Apple-derived artifacts" Global Constraint (screenshots
    /// of a booted ROM are exactly such an artifact).
    @MainActor
    private func presentSaveScreenshotPanel() {
        let artifactsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/LisaEmu-artifacts")
        try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let panel = NSSavePanel()
        panel.directoryURL = artifactsDir
        panel.nameFieldStringValue = "LisaEmu-Screenshot.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.requestScreenshotPNG { data in
                guard let data else { return }
                try? data.write(to: url)
            }
        }
    }
}

/// Backs `@NSApplicationDelegateAdaptor` above -- the two hooks
/// `Scene`/`.commands` alone cannot express (M1c Task 5 polish, "clean
/// shutdown"):
///
/// 1. `applicationShouldTerminateAfterLastWindowClosed`: `LisaEmuApp` uses
///    `Window`, not `WindowGroup` (see that type's doc comment -- `AppModel`
///    is genuinely singleton, one-Lisa state), so there is no legitimate
///    reason for the process to keep running headless once its one window
///    is closed. Without this override, AppKit's default behavior for a
///    non-document app is to keep running with no visible window.
/// 2. `applicationWillTerminate`: joins the emulation thread
///    (`AppModel.shutdown()`) BEFORE the process actually exits, rather
///    than leaving that to ARC's (unreliable, at process-exit time)
///    teardown of the `App` struct's `@State`.
///
/// `model` is `weak`: `LisaEmuApp`'s `@State model` already owns the
/// canonical strong reference; this delegate only needs to reach it to
/// call `shutdown()`, not extend its lifetime (and a strong cycle back
/// through the delegate would be pointless besides).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
