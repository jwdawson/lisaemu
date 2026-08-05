# M1c demo — the live app shell

Milestone M1c's exit criterion: a real macOS app window shows the emulated
Lisa booting live (not a one-shot `lisadbg` screenshot), and the host
keyboard/mouse drive it. This page shows how to run it and what to expect.

## How to run

The app (`LisaApp/`) is an Xcode project generated from a committed spec
(`LisaApp/project.yml`); the `.xcodeproj` itself is gitignored.

```sh
cd LisaEmu/LisaApp
xcodegen generate               # writes LisaApp.xcodeproj + Info.plist
```

Then either:

- **Open in Xcode** (`open LisaApp.xcodeproj`) and Run (⌘R), or
- **Build/run from the command line:**

  ```sh
  xcodebuild -project LisaApp.xcodeproj -scheme LisaApp -configuration Debug build
  open ~/Library/Developer/Xcode/DerivedData/LisaApp-*/Build/Products/Debug/LisaApp.app
  ```

The app resolves the ROM directory the same way `lisadbg --rom` and the
env-gated test suites do: `$LISAEMU_ROM_DIR` if set, else
`~/Development/LisaROMs`. If the ROM can't be loaded, the app opens anyway
and shows an alert (with a "Quit" button) rather than crashing or silently
showing a blank window.

## What you can do

- **Live POST:** the window shows the real Rev H boot ROM running --
  power-on self-test, then the startup menu -- frame by frame, not a single
  captured screenshot. The status bar (bottom of the window) shows cycle
  count, emulated seconds, throttle state, and a `HALTED` flag if the CPU
  ever halts.
- **Mouse on the menu:** click inside the screen to capture the pointer
  (cursor hides, raw deltas drive the Lisa's relative-mouse protocol); the
  status bar's hint flips to "mouse captured -- ⌘⎋ to release". Moving the
  captured mouse and clicking drives the ROM's own cursor and menu
  hit-testing -- e.g. clicking **STARTUP FROM…** opens the ROM's device
  list, exactly as it would on real hardware. Losing key-window status
  (⌘-Tab away, a system dialog stealing focus) auto-releases capture as a
  second escape hatch, so the pointer is never trapped somewhere Command-
  Escape can't reach.
- **Machine menu:** Pause/Start (⌘P), Reset (⌘R, tears down and recreates
  the emulated machine), and a Throttle toggle (⌘T, real-time-paced vs. as
  fast as possible -- **on by default**, see "Polish," below).
- **View menu:** "Actual Size (1:1)" toggles between the cosmetic
  ~1.48x vertical stretch (the Lisa's 720x364 framebuffer maps to a
  roughly 3:2 CRT area, so unstretched square pixels look visibly
  squashed) and the raw unstretched framebuffer. The choice **persists
  across launches** (`UserDefaults`, see "Polish," below).
- **File > Save Screenshot…:** PNG-encodes the current live frame and
  presents a save panel (default directory
  `~/Development/LisaEmu-artifacts`, a sibling of this repo -- screenshots
  of ROM-drawn UI are never committed).

## Keyboard notes

- `LisaShell.KeyMap` translates macOS Carbon virtual keycodes to Lisa
  7-bit keycaps for the full Final-US 76-key layout (see
  `docs/hardware-notes.md` §8 "Keycap Code Matrix") -- letters, digits,
  punctuation, the numeric keypad, Tab/Return/Backspace/Space, and the four
  Lisa modifier keycaps. Keys with no Lisa equivalent (function keys,
  Escape, Control -- the Lisa keyboard predates all of these) are simply
  not forwarded.
- **Modifiers are ordinary keys, not host modifier state:** Shift (`$7E`,
  either physical key -- the Lisa OS ORs left/right into one bit), L-Option
  (`$7C`) and R-Option (`$4E`, a real hardware distinction the app
  preserves for the single-key case; simultaneous L+R Option is a known,
  documented gap -- see `InputCapture.swift`'s "Modifier tracking" doc
  comment), and Command (`$7F`) all forward down/up edges like any other
  key. Three Command-only chords are reserved for app menu shortcuts
  (⌘P/⌘R/⌘T) and are NOT forwarded to the Lisa; every other Command-key
  combination (e.g. ⌘S, ⌘A) forwards normally, matching "Command is a real
  Lisa key" once you're past the app's own three bound shortcuts.
- **CapsLock is latching:** real Lisa hardware sends exactly one edge per
  physical toggle (not a down/up pair), and macOS's `flagsChanged` event
  for CapsLock does the same -- down (`$7D`) on lock, up on unlock. This
  falls out of the same generic modifier-diff logic as Shift/Option/
  Command, no special case needed. Caps Lock being engaged never breaks
  the app's own ⌘P/⌘R/⌘T shortcuts (a fixed bug -- see
  `InputCapture.isReservedMenuShortcut`'s doc comment).
- **Auto-repeat is intentionally NOT forwarded:** the real Lisa keyboard
  sends one down edge per physical press; the Lisa OS's own software timer
  does the repeating from that single held-down state. Forwarding the
  host's synthesized repeat keydowns would desync that model.

## Screenshots

Captured via the debug-only `--auto-screenshot <path>` launch argument
(saves a PNG after a fixed delay long enough for throttled POST to reach
the boot menu, then quits) rather than manual `NSSavePanel` interaction,
so they're reproducible from a script:

```sh
LisaApp.app/Contents/MacOS/LisaApp --auto-screenshot \
  ~/Development/LisaEmu-artifacts/m1c-live-menu.png
```

Referenced from outside the repo (`~/Development/LisaEmu-artifacts/`,
never committed -- they render Apple's ROM-drawn UI):

- `~/Development/LisaEmu-artifacts/m1c-task3-live-window.png` -- first live
  window checkpoint (M1c Task 3).
- `~/Development/LisaEmu-artifacts/m1c-task4-live-window.png` -- after
  input wiring (M1c Task 4).
- `~/Development/LisaEmu-artifacts/m1c-live-menu.png` -- current build
  (M1c Task 5), captured fresh via the command above; verified against the
  same 78,100-black-pixel invariant `ROMBootTests` uses (`magick
  m1c-live-menu.png -format %c histogram:info:-`).

## Polish (M1c Task 5)

- **Window min-size sanity:** the screen view has a `minWidth: 360,
  minHeight: 220` floor, so the window can't be resized down to something
  degenerate; `.windowResizability(.contentSize)` otherwise lets it grow
  freely.
- **Aspect-toggle persistence:** `AppModel.showActualSize` is read from
  and written back to `UserDefaults.standard` (the same store the
  `@AppStorage` property wrapper uses -- not the wrapper itself, which is
  designed for use inside a SwiftUI `View.body`, not a plain `@Observable`
  class; see `AppModel.swift`'s doc comment for why), so the View menu's
  "Actual Size (1:1)" choice survives a relaunch.
- **Throttle defaults ON:** `AppModel.throttled` starts `true` --
  real-time-paced emulation is the default experience; unthrottled
  ("as fast as possible") is an explicit opt-in via ⌘T.
- **Clean shutdown:** an `NSApplicationDelegateAdaptor` (`AppDelegate`,
  `LisaApp.swift`) makes the single-window app quit when its one window
  closes (`applicationShouldTerminateAfterLastWindowClosed`), and
  `applicationWillTerminate` explicitly joins the emulation thread
  (`AppModel.shutdown()` releases the `EmulationController`, whose
  `deinit` posts a `.shutdown` command and blocks until the emulation
  thread acknowledges and returns from its run loop) before the process
  exits, rather than leaving that to ARC's unreliable-at-process-exit
  teardown of the `App`'s `@State`. Verified manually: running the app
  with `--auto-screenshot` (which ends by calling `NSApp.terminate`, the
  same path a real quit takes) exits cleanly (exit code 0, ~61s
  wall-clock, no crash report, no leftover process) every time it was run
  during this task.
- App icon: skipped (YAGNI per the plan).

## Regression tests

```sh
swift test                                                    # LisaCore/LisaShell, debug
swift test -c release                                         # same, release
LISAEMU_ROM_DIR=$HOME/Development/LisaROMs swift test --filter ROMBootTests
cd LisaApp && xcodebuild -project LisaApp.xcodeproj -scheme LisaApp test  # InputCaptureLogicTests
```

See `docs/m1b-demo.md` for the ROM-boot regression test and its
correction note (M1c Task 3's review flagged `lisadbg`'s `sc`/`sca` as
possibly inverted relative to this app's screenshot pipeline; M1c Task 5's
investigation found `sc`'s PNG writer genuinely was -- and fixed it -- but
`sca`'s ASCII preview was not actually affected; see that note for the
full root-cause writeup).
