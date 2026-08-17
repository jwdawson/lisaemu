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
                    model.insertDiskIfRequested()
                    model.runAutoScreenshotIfRequested()
                    model.runPrintTestIfRequested()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Insert Disk…") {
                    presentInsertDiskPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Eject") {
                    model.ejectFloppy()
                }

                Divider()

                // M5 Task 2: the Widget hard disk. "Choose" opens an existing
                // image; "Create Blank" makes a fresh Widget-10 image and
                // attaches it (the installer then formats-and-populates it).
                // Widget writes PERSIST to the file (write-back, §10.10) --
                // unlike the floppy's read-only session overlay.
                Button("Choose Widget Image…") {
                    presentChooseWidgetPanel()
                }
                Button("Create Blank Widget Image…") {
                    presentCreateWidgetPanel()
                }
                Button("Detach Widget") {
                    model.detachWidget()
                }
            }
            CommandGroup(after: .saveItem) {
                Button("Save Screenshot…") {
                    presentSaveScreenshotPanel()
                }
            }
            // M6 Task 1 CLOSES the consciously-deferred Power menu item
            // (M1c/M2 Task 7 deferred "power on/off via COPS", spec §4, until
            // soft power had somewhere to GO). It now does: "Power" presses
            // the Lisa's soft-power button (`COPS.pressPowerButton()`), the OS
            // runs its own clean shutdown, and the machine stops
            // (`AppModel.poweredOff`).
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

                // ⌘⌥P (not ⌘-something bare): the soft-power button runs the
                // OS's real shutdown -- a deliberate, hard-to-fat-finger action
                // distinct from Start/Pause (⌘P). Disabled once already powered
                // off (nothing to shut down until a Reset boots afresh).
                Button("Power (Shut Down)") {
                    model.pressPowerButton()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.poweredOff)

                Divider()

                // M7 Task 4: printer status indicator, default connected. A
                // checked Toggle so the menu shows the current state; unchecking
                // makes the app drop incoming print jobs (acts as an unplugged
                // printer). The OS-side Serial-B config is separate (§11.6).
                Toggle("Printer Connected (Serial B)", isOn: Bindable(model).printerConnected)
                Toggle("PFG Installed (SCC socket)", isOn: Bindable(model).pfgInstalled)

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

    /// File > Insert Disk… (M2 Task 7, ⌘I). `NSOpenPanel` filtered to the
    /// floppy-image extensions -- DC42 has no registered system UTType, so
    /// this constructs them BY EXTENSION (`UTType(filenameExtension:)`),
    /// matching the drag-and-drop filter
    /// (`AppModel.isFloppyImageFile`, `ScreenView.swift`'s `.onDrop`).
    /// **M9: `.image`/`.img` joined `.dc42`** -- Mac-era disks ship as
    /// `Something.image` while being DC42 containers inside. Falls back
    /// to `.data` (accept anything) if `UTType(filenameExtension:)` somehow
    /// returns `nil` -- it shouldn't for a well-formed extension string,
    /// but degrading to "no filter" is strictly safer than crashing on a
    /// force-unwrap for a cosmetic panel filter.
    @MainActor
    private func presentInsertDiskPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let floppyTypes = ["dc42", "image", "img"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = floppyTypes.isEmpty ? [.data] : floppyTypes

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.insertFloppy(url: url)
        }
    }

    /// File > Choose Widget Image… (M5 Task 2): opens an existing `.widget`
    /// hard-disk image and attaches it. Same `UTType(filenameExtension:)`
    /// pattern as `presentInsertDiskPanel`.
    @MainActor
    private func presentChooseWidgetPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "widget") ?? .data]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.attachWidget(url: url)
        }
    }

    /// File > Create Blank Widget Image… (M5 Task 2): `NSSavePanel` for a
    /// destination path; `attachWidget(url:)` then CREATES an all-zero blank
    /// Widget-10 image there on demand (§10.10) and attaches it. Default
    /// directory is the same repo-sibling artifacts dir screenshots use --
    /// never inside the repo (Global Constraint: never commit images).
    @MainActor
    private func presentCreateWidgetPanel() {
        let artifactsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/LisaEmu-artifacts")
        try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let panel = NSSavePanel()
        panel.directoryURL = artifactsDir
        panel.nameFieldStringValue = "LisaEmu-Widget.widget"
        panel.allowedContentTypes = [UTType(filenameExtension: "widget") ?? .data]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // A brand-new path -> attachWidget creates the blank on demand.
            model.attachWidget(url: url)
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
