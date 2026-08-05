# LisaEmu M1c — App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live, interactive Lisa: a SwiftUI macOS window showing the emulated screen updating in real time, with the host keyboard and mouse driving the COPS — boot POST live, and click the real boot menu's buttons with your actual mouse. (Spec §1/§4's "LisaApp", consciously deferred through M0-M1b; the floppy Insert/Eject menu lands with M2.)

**Architecture:** A new `LisaShell` library target (Foundation-only, fully testable) hosts `EmulationController`: a dedicated emulation thread that owns the `Machine` (satisfying the Musashi single-thread discipline — the M68K owner assertion enforces it for free), a command mailbox in, and vsync-cadence framebuffer snapshots + status out. `LisaApp` (SwiftUI executable target) stays thin: a framebuffer view (vImage 1-bit expansion → CGImage, aspect-corrected), menus, and NSEvent capture translated through a `KeyMap` (Lisa keycap table mined from the OS source) into `COPS.postKey`/`postMouse`. LisaCore is untouched except where seams already exist.

**Tech Stack:** SwiftUI + AppKit event monitors (LisaApp only), Accelerate/vImage + CoreGraphics for the blit (LisaApp only), Foundation-only LisaShell. LisaCore stays framework-free. **LisaApp is a real Xcode app project** (user decision): generated headlessly via XcodeGen 2.46 (installed at /opt/homebrew/bin/xcodegen) from a committed `project.yml`, depending on the repo's SPM package for LisaShell/LisaCore; built/verified via `xcodebuild`; developed/run in Xcode 27.

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m1c-app-shell` from main (`05039de`); commit per task, never amend; TDD where the layer permits (LisaShell fully; SwiftUI views get thin logic + manual verification checkpoints, honestly labeled).
- Never commit ROMs/images/Apple-derived artifacts. ROM at `~/Development/LisaROMs` (`LISAEMU_ROM_DIR` gating as established).
- Authorities: `docs/hardware-notes.md` (+ new §8 input codes, written in Task 2 from the controller-provided research report with citations; both-docs rule if anything refutes prior notes — note the COPS keyboard-ID placeholder $2F from M1b may be corrected here).
- Threading rule (load-bearing): the `Machine` is created ON the emulation thread and never touched from any other thread. All cross-thread traffic goes through the mailbox (input, commands) or immutable published snapshots (frames, status). The M68K debug owner-assertion is the enforcement backstop — no test may need to weaken it.
- CPU-driving tests under MusashiSuites; Swift warning-free; existing suites stay green; SwiftUI target must not break `swift test` (test target does not import LisaApp).
- Pacing: throttled mode targets real time (5,000,000 cycles/sec) with a drift-corrected governor (anchor to nominal time, not accumulated sleeps — the M1b vsync-drift lesson, cited); unthrottled runs flat out. Frame publication on the VideoTiming vsync cadence in both modes.
- Lisa pixel aspect: 720×364 displayed on a ~3:2 CRT area — vertical stretch ≈1.48. Default view applies aspect correction; a View menu toggle offers 1:1. (Exact factor documented in the view code; cosmetic, not hardware-modeled.)
- Xcode project convention: `LisaApp/project.yml` is the source of truth (committed); the generated `LisaApp/LisaApp.xcodeproj` is GITIGNORED and regenerated via `xcodegen generate --spec LisaApp/project.yml`; headless verification via `xcodebuild -project LisaApp/LisaApp.xcodeproj -scheme LisaApp build`. App is NOT sandboxed (dev tool reading ~/Development/LisaROMs directly; App Store is a non-goal — documented in project.yml comments). macOS deployment target 14.0 matching the package.
- One process at a time for tests; the app itself is run manually at checkpoints (build with xcodebuild, then `open` the built .app, or run from Xcode).

---

### Task 1: LisaShell target + EmulationController (thread, mailbox, pacing)

**Files:**
- Create: `Sources/LisaShell/EmulationController.swift`, `Sources/LisaShell/FramePublisher.swift`
- Modify: `Package.swift` (add `LisaShell` library target depending on LisaCore; add its test target membership)
- Test: `Tests/LisaShellTests/EmulationControllerTests.swift` (new test target; CPU-driving tests under MusashiSuites — note MusashiSuites lives in LisaCoreTests, so LisaShellTests defines its own `@Suite(.serialized)` parent with a comment cross-referencing the discipline, and LisaShellTests must NOT run concurrently with LisaCoreTests' CPU suites — verify SwiftPM runs test targets serially by default; if it runs them in parallel processes, that's fine (separate processes = separate Musashi globals) — confirm and document which)

**Interfaces:**
- `public final class EmulationController`: `init(romDirectory: URL) throws` — spawns the emulation thread; the thread creates Machine + loads ROM, then services the mailbox. `func start()` / `func pause()` / `func reset()` / `var throttled: Bool` (mailbox-set) / `func post(_ event: InputEvent)` where `enum InputEvent { case keyDown(UInt8), keyUp(UInt8), mouseDelta(dx: Int8, dy: Int8), mouseButton(down: Bool) }` (Lisa-side codes; host translation is Task 2's KeyMap in the app layer) / `func requestScreenshot(_ completion: @escaping (Data) -> Void)` (PNG-encoding stays app-side; this returns the raw 1bpp snapshot + dimensions via a small `Frame` struct).
- `FramePublisher`: `var onFrame: ((Frame) -> Void)?` called on the emulation thread at each vsync with `struct Frame { let bits: [UInt8]; let width: Int; let height: Int; let sequence: UInt64 }` — the app hops to the main thread itself. Status likewise: `struct EmuStatus { let cycles: UInt64; let halted: Bool; let throttled: Bool; let emulatedSeconds: Double }` published ~4 Hz.
- Pacing loop (throttled): each iteration runs Machine to `nominalStart + elapsedHostTime * 5_000_000` cycles (drift-corrected anchor), sleeping the remainder of a ~16.7ms frame slice; unthrottled runs continuous 1-vsync slices yielding for mailbox drains. Mailbox drained between slices; input events applied via the existing COPS/postKey seams ON the emulation thread.
- Tests (all headless, no UI): controller boots ROM to the menu with throttle OFF (reuses the documented 20M-cycle budget; assert POST markers via published status/frames — frames arrive, sequence increases, final frame >1% black per the established invariant); pause/start round-trip; reset() → boots again (warm reset arrives in M2 — HERE reset() tears down and recreates the Machine on the emulation thread, documented as the interim semantic, one-line pointer to the M2 task); input events reach COPS (post a key, then read... simplest observable: the COPS input FIFO length via a test-visible seam or an ioTrace-based observation — pick the least invasive and justify); throttle governor math unit-tested as a pure function (given host-elapsed, returns target cycles; drift stays bounded across simulated jitter).

- [ ] **Step 1:** Failing tests (governor math + controller lifecycle). **Step 2:** Implement. **Step 3:** Full suites green both ways (new target included). **Step 4:** Commit.

---

### Task 2: hardware-notes §8 + KeyMap (host → Lisa input translation)

**Files:**
- Create: `Sources/LisaShell/KeyMap.swift`, `Tests/LisaShellTests/KeyMapTests.swift`
- Modify: `docs/hardware-notes.md` (§8: the mined keycap table, mouse packet/button facts, keyboard IDs, modifier semantics — full citations; correct the COPS keyboard-ID placeholder if the research names the real US-layout ID, updating COPS.swift's default + its doc per the both-docs rule)
- Possibly modify: `Sources/LisaCore/COPS.swift` (keyboard-ID constant only)

**Interfaces:**
- `struct KeyMap`: `static func lisaKeycap(forMacKeyCode: UInt16) -> UInt8?` — complete mapping macOS virtual keycodes → Lisa 7-bit keycaps for every key the Lisa keyboard has (letters, digits, punctuation, Return, Tab, Backspace, Shift/Option/Command→Apple key, keypad); unmappable host keys return nil. Modifiers per the mined semantics (ordinary down/up keycap events if that's what the research shows). Mouse button per research (keyboard-stream keycap vs separate — implement what the source says).
- Tests: table completeness (every Lisa keycap the research lists is reachable from some Mac key); round-trip spot checks ('A', Return, Shift, keypad digits); no duplicate Mac keycode claims two Lisa caps.

- [ ] **Step 1:** Write §8 from the research report (keep every citation). **Step 2:** Failing KeyMap tests from the table. **Step 3:** Implement. **Step 4:** Suites green; commit.

---

### Task 3: LisaApp — Xcode project, window, framebuffer view, menus

**Files:**
- Create: `LisaApp/project.yml` (XcodeGen spec: app target "LisaApp", platform macOS 14.0, sources LisaApp/Sources, local package dependency on the repo root package for LisaShell, Info.plist properties inline, sandbox OFF with comment, scheme included), `LisaApp/Sources/LisaApp.swift` (App/Scene), `LisaApp/Sources/ScreenView.swift` (blit view), `LisaApp/Sources/AppModel.swift` (@Observable glue: controller lifecycle, frame → CGImage on main thread)
- Modify: `.gitignore` (add `LisaApp/LisaApp.xcodeproj/`), `README.md` (one line: generate with xcodegen)
- LisaCore/LisaShell stay UI-free — enforce by grep in the task. Package.swift is NOT modified (the app lives in the Xcode project, not as an SPM executable).
- Reference material for the implementer: macOS window/menu patterns in /Users/jdawson/.claude/plugins/cache/axiom-marketplace/axiom/3.1.2/skills/axiom-macos/skills/windows.md and menus-and-commands.md (WindowGroup/commands API).

**Interfaces:**
- `xcodegen generate --spec LisaApp/project.yml && xcodebuild -project LisaApp/LisaApp.xcodeproj -scheme LisaApp build` produces LisaApp.app; running it opens a window titled "LisaEmu": the live screen (vImage 1bpp→8bpp expand → CGImage per published frame; aspect-corrected default, View menu 1:1 toggle), a status bar (cycles, emulated seconds, throttle state, halted flag), menus via SwiftUI `.commands`: Machine → Start/Pause (⌘P), Reset (⌘R), Throttle (⌘T checkbox); File → Save Screenshot… (writes PNG via the controller's raw-frame request + app-side encoding, NSSavePanel default path outside any repo); ROM directory resolved from `LISAEMU_ROM_DIR` or `~/Development/LisaROMs` fallback, with a clear error alert if missing.
- Blit correctness is unit-testable at one seam: the 1bpp→CGImage conversion function lives in LisaShell-adjacent pure code? NO — vImage/CG allowed only in LisaApp per constraints; instead extract `expand1bppRow(_:into:)` pure-Swift bit-unpacking into LisaShell with tests, and LisaApp wraps it with CG. (Keeps the testable math tested without polluting layer rules.)
- Manual verification checkpoint (documented in the task report with a screenshot): app launches, POST runs LIVE (visible drawing), menu appears, status bar ticks. This is a human-visible milestone — the implementer captures it via the app's own Save Screenshot.

- [ ] **Step 1:** Failing tests for `expand1bppRow` (bit order matches the established MSB-first convention — cite Task 5/M1b; the function lives in LisaShell so `swift test` covers it). **Step 2:** Write project.yml, generate, implement app + model + view; iterate `xcodebuild` until green. **Step 3:** `swift test` suites green + `xcodebuild` build succeeds warning-free (app sources); manual run checkpoint documented via the app's own Save Screenshot. **Step 4:** Commit (project.yml + sources + .gitignore; NOT the .xcodeproj).

---

### Task 4: Input wiring — keyboard and mouse into the Lisa

**Files:**
- Create: `Sources/LisaApp/InputCapture.swift`
- Modify: `Sources/LisaApp/ScreenView.swift` (mouse tracking), `Sources/LisaApp/AppModel.swift`

**Interfaces:**
- Keyboard: NSEvent local monitor (keyDown/keyUp/flagsChanged) while the window is key → KeyMap → `controller.post(.keyDown/.keyUp)`; flagsChanged diffed into modifier down/up events per §8 semantics; menu-shortcut keys (⌘R etc.) NOT forwarded when handled by menus (document the precedence rule).
- Mouse: the ScreenView tracks movement in view coordinates → screen-space deltas scaled by the current view scaling (aspect toggle aware) → clamped Int8 packets `post(.mouseDelta)`; click/release → `.mouseButton` per §8's button mechanism. Pointer hidden + captured while over the Lisa screen with an explicit release gesture (⌘-escape or window resign — pick one, document it; do NOT trap the pointer without an escape).
- Manual verification checkpoint (the milestone's soul): boot live, move the mouse — the ROM menu's pointer follows; click STARTUP FROM — the ROM responds (its dialog/highlight, whatever it does — document with screenshots). If the ROM ignores input, debug via ioTrace (COPS bytes arriving?) and the §8 tables until it responds. Automated backstop: an integration test in LisaShellTests scripting postKey/postMouse and asserting the ROM's menu state changes (framebuffer hash moves from the idle anchor within N cycles of a click at the STARTUP FROM coordinates — coordinates documented from the trace).

- [ ] **Step 1:** Failing integration test (scripted click changes menu state). **Step 2:** Implement capture + wiring; iterate until the ROM responds. **Step 3:** Suites green; manual checkpoint documented with screenshots. **Step 4:** Commit.

---

### Task 5: Polish, demo, regression — M1c exit

**Files:**
- Create: `docs/m1c-demo.md`
- Modify: whatever polish requires (small, evidence-listed)

**Interfaces:**
- [ ] **Step 1:** Polish pass strictly limited to: window min/max size sanity, aspect toggle persistence (@AppStorage), throttle default ON, clean shutdown (emulation thread joined, no crash on window close), app icon SKIPPED (YAGNI).
- [ ] **Step 2:** docs/m1c-demo.md: how to run, what you can do (live POST, mouse on the menu), keyboard notes, screenshots referenced from ~/Development/LisaEmu-artifacts/ (m1c-live-menu.png etc., never committed).
- [ ] **Step 3:** Full regression: suites green both ways; full TomHarte release run (807147/0/192913); `swift run LisaApp` final manual checkpoint. Commit.
