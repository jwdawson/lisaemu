# M6 demo — a Lisa you can use: clean boot, right clock, desktop work, clean shutdown ⭐

M5 landed the spec's ⭐ — the Office System **desktop**, booted off an installed
Widget hard disk, with the mouse live. But it reached the desktop and stopped
there honestly: the clock wasn't set (a "clock/calendar is not set" note drew on
every boot), the keyboard had never been exercised at the desktop, and there was
no way to turn the machine off except to stop the emulator. M6 closes all of
that. The result is not a new frontier of the boot — it is the Lisa become a
**machine in daily use**, running its own **whole power cycle**:

1. **Task 1 — SOFT POWER.** The power button runs the OS's *own* shutdown
   (`FS_ShutDown` → `GiveUpGhost` → `PowerDown`, honored as COPS `$21`), a clean
   power-off that leaves the next boot **free of the dirty-volume dialog**.
2. **Task 2 — THE RTC.** A real COPS real-time clock: the `$02` read reply is
   derived byte-for-byte from the OS's *own* clock parser, the set-sequence is the
   exact inverse of `SetClock`, and the **clock-not-set note is gone**.
3. **Task 3 — LIVING ON THE DESKTOP.** Real Filer work (a folder torn off and
   **keyboard-renamed** "Reports"), and **LisaWrite installed from its diskette,
   launched, and typed into** — closing M5's keyboard-at-desktop gap.
4. **Task 4 — quality.** Explicit test skips, throwing Widget writes, the
   bare-eject decision documented-with-citation, and the session-overlay-by-
   identity question deferred with a real tradeoff analysis.

This is the plain-language walkthrough. The full evidence + citations live in
`docs/rom-trace-notes.md` ("Checkpoint L", "Checkpoint M") and
`docs/hardware-notes.md` §4/§7 (COPS power + power-off/clock semantics) and the
`$02` clock format section.

## What M6 delivers, concretely

- **A whole power cycle.** The machine powers **on** (boot off the Widget) and
  **off** (the OS's own soft-power shutdown), like a real Lisa — and the clean
  shutdown makes the *next* boot skip the dirty-volume dialog.
- **A working clock.** The Office System reads the date/time off the emulated
  COPS RTC and stamps it into the desktop (torn-off folders auto-name `Folders
  08/11`); the clock-not-set note no longer appears.
- **A desktop worked in.** The Internal Hard Disk window opens, all four Filer
  menus pull down, a folder is torn off a stationery pad and **renamed from the
  keyboard**, and **LisaWrite** — installed from its diskette through the OS's own
  move-to-hard-disk flow — is launched and **typed into**.
- **Zero halts, zero fatal faults** across the whole loop.

## Part 1 — power on: a clean boot with the right clock

Booting a *clean* copy of `OS31-installed.widget` to the desktop
(`~/Development/LisaEmu-artifacts/m6-clock-*.png`, `m6-power-*.png`):

1. **The dirty-volume dialog, one last time** (`m6-clock-01`, `m6-power-02`). A
   fresh copy of the image still carries the in-use mark from whatever left it —
   *"The startup disk was in use when the Lisa failed…"*. Click **Don't Check**.
   (M6's own clean shutdown, Part 3, is what makes this disappear on the *next*
   boot.)
2. **The desktop — with no clock note** (`m6-clock-02`, `m6-power-08`). Before M6
   every boot drew a *"Note: The Lisa clock/calendar is not set"* alert, because
   the old placeholder `$02` reply parsed as an invalid BCD date. Now the OS reads
   a valid date off the RTC and **draws no note at all** — the desktop comes up
   clean: menu bar **Desk / File/Print / Edit / Housekeeping**, icons
   **Preferences · Wastebasket · Clipboard · Internal Hard Disk**.
3. **The clock is live** (`m6-clock-03`). The date is the host clock, mapped
   through the Lisa's own format — with one faithful quirk: the Lisa's silicon
   carries the **year in 4 bits** (1980-based, rolling every 16 years, TIMERS:596),
   so a **2026** host clock is displayed by the OS as **1994**. That is the real
   hardware's window, not an emulator shortcut — the day, hour, minute, and second
   are exact, and torn-off objects date-stamp `MM/DD` correctly.

The clock is not a mock: the `$02` reply stream is reconstructed byte-for-byte
from the OS's own COPS clock parser (`DRIVERS` `COPS3`/`COPS4`), and setting the
clock replays the exact inverse of the OS's `SetClock` nibble loop. See
`hardware-notes.md` "Read-Clock ($02) Reply Format and Set-Clock Sequence".

## Part 2 — desktop work: the Filer, and LisaWrite typed into

With the desktop up, it is driven as a machine in use
(`m6-desktop-*.png`, `m6-lisawrite-*.png`):

1. **Open the Internal Hard Disk** (`m6-desktop-filer-open`) from the **Desk**
   menu (it lists the desktop's objects). The window shows `Empty Folders`,
   `Clock`, `Calculator`.
2. **The four Filer menus** (`m6-desktop-menu-desk` · `-fileprint` · `-edit` ·
   `-housekeeping`) — pulled down as real **press-drag-release** pull-downs (not
   click-latched), items context-sensitive per selection.
3. **Tear off a folder and rename it** (`m6-desktop-tearoff-folder`,
   `-folder-final`). `Empty Folders` is a **stationery pad**: *File/Print ▸ Tear
   Off Stationery* makes a new folder, auto-named `Folders 08/11` (the RTC date,
   live). The fresh name is in edit mode, so typing replaces it — typed
   **`Reports`** from the keyboard: a genuine keyboard-at-desktop interaction.
4. **Preferences, and the Duplicate modal** (`m6-desktop-preferences`,
   `-duplicate-modal`) — the real Filer flows, including the *"you must move the
   duplicate before you do anything else"* modal.
5. **Insert the LisaWrite diskette at the live desktop** (`m6-lisawrite-01`,
   `-02`). Inserting through the **media-change path** raises the Sony driver's
   `bot_in` attention; the OS mounts and reads the diskette's catalog **with no UI
   interaction** and draws its icon (`LisaWrite 1 - 3.1`), window showing
   `LisaWrite Paper`, `LisaWrite Examples`, `LisaWrite`, `American Dictionary`.
6. **Install the tool the OS's own way** (`m6-lisawrite-03`, `-04`). Dragging the
   `LisaWrite` tool icon onto the Internal Hard Disk icon raises the OS's *"The
   Lisa is moving 'LisaWrite' to 'Internal Hard Disk'"* Wait dialog; the tool is
   installed onto the Widget (the image gains ~141 KB of changed bytes — it
   persisted).
7. **Tear off a document, launch, and TYPE** (`m6-lisawrite-05` … `-08`). *Tear
   Off Stationery* on `LisaWrite Paper` makes `LisaWrite Paper 08/11`; *Open*
   launches the tool (the menu bar becomes LisaWrite's — Type Style, Format ¶,
   Page Layout, Search, Spelling — with a blinking caret); and
   **`Hello from LisaEmu-- M6 Task 3.`** is typed into the document — caps,
   digits, spaces, and punctuation through the COPS make/break + Final-US KeyMap
   path. **Keyboard-at-desktop, closed.**

Throughout the Filer work, the §4 Linkmap symbol overlay resolves the running PC
to **named Filer procedures** live (`flrAll.WALKTREE`, `flrAll.ERASEOBJ`,
`lmfiler.DOCCONSI`, `lmlist.DFILTER`, …) — high-confidence because the running app
*is* the Filer. (The one honest overlay caveat is in "The honest frontier".)

## Part 3 — power off: the OS shuts itself down, cleanly

Back at the desktop, pressing the **soft-power button** runs the OS's *own*
shutdown (`m6-power-05`, `m6-clock-04`):

- `COPS.pressPowerButton()` puts `$80,$FB` on the real COPS input stream; the OS
  decodes it (DRIVERS `COPS4`) into pseudo-keycap `$08` down+up, which userland
  turns into a shutdown request → Root `kill_power` → **`FS_ShutDown`**
  (flush + unmount every volume, including the boot disk) → **`GiveUpGhost`**
  (contrast → 255, screen black) → **`PowerDown`**, which — the clock running —
  sends COPS **`$21`**. The emulator honors `$21` and drives
  `Machine.powerState = .off`: a clean stop (`halted = false`), and a subsequent
  run advances **zero** cycles. The framebuffer goes fully black
  (`m6-power-05-shutdown`).
- **The dirty-volume proof** (`m6-power-07`, `-08`). Because `FS_ShutDown` wrote
  the volume back **not-in-use**, rebooting the *same* image comes up through the
  normal *"Wait — Office System Release 3.1"* progress with **no dirty-volume
  dialog** — only the (now absent, thanks to Task 2) clock note would have
  followed. A real machine's clean power-down.

That the OS chose to send `$21` (PowerDown's *clock-running* path) rather than
`$20` (clock-clear) is itself the OS **attesting that it believes the clock** —
the RTC and the soft-power path corroborate each other. See
`rom-trace-notes.md` "Checkpoint L" and `hardware-notes.md` §7.

## The engineering behind it, in brief

Each piece is fully cited in `rom-trace-notes.md` / `hardware-notes.md`:

- **Soft power (Task 1, §7).** The whole chain is the OS's own: `pressPowerButton`
  puts `$80,$FB` on the FIFO → DRIVERS `$FB`→key `$08` → Shell/Desktop `PowerOff`
  → `kill_power` → `FS_ShutDown` → `GiveUpGhost` → `PowerDown` → COPS `$20`/`$21`.
  A dedicated `Machine.powerState` (`.off` distinct from a HALT) short-circuits
  run/step; reset restores `.on`. The old `$25` mislabel in the power table was
  corrected out — it is `SetClock`'s enable-clock, not a power command (TIMERS:673).
- **The RTC (Task 2).** The `$02` reply is reconstructed from the OS's own parser
  (DRIVERS `COPS3`/`COPS4`, TIMERS packing `0000yyyy dddddddd …`), the set-sequence
  is the traced inverse of `SetClock`'s 16-nibble ROL loop, and `ClockToDate` is an
  independent oracle for both. The year window is the hardware's real 4-bit rollover.
- **Desktop driving (Task 3).** `lisadbg` gained the input verbs the desktop needs
  — `press`/`release`/`moveto` (Office System menus are press-drag-release
  pull-downs), `drag` (menu selection and icon-to-disk copy), and `insert`/`eject`
  (the runtime media-change path) — all thin wrappers over the existing
  `COPS`/`FloppyController` paths, parse-tested.
- **Quality (Task 4).** The env-gated Widget-boot checkpoints skip *explicitly*
  (named SKIPPED without assets, not a silent guard-return); `WidgetImage` writes
  through throwing FileHandle APIs; and the bare-eject / session-overlay decisions
  are documented with citations rather than papered over.

## The honest frontier

M6 makes the Lisa usable end to end and stops at **breadth, not a wall**:

- **The 4-bit year window displays 1994 for a 2026 host.** This is faithful to the
  real hardware (the Lisa's RTC carries the year in 4 bits, 1980-based); the day,
  hour, minute, and second are exact. Not a bug — a documented hardware limit.
- **No timed reboot-alarm wake.** `PowerCycle`'s `$23`/`$2D` "reboot later" half is
  deferred: `$23` powers off but schedules no wake, because no RTC *alarm* is
  modeled yet (cited MACHINE:447-480). An M7 candidate.
- **The power button is honored only at the live desktop**, not while a modal
  dialog is frontmost (the dialog's own event loop owns the keycap queue) — matches
  how the OS routes the pseudo-keycap, not an emulator fault.
- **The symbol overlay names Filer code correctly, but not a *different* app's.**
  The 22 Linkmaps merge into one flat table with no per-app relocation, so a name
  shown while a non-Filer app is frontmost may be a merged-table collision. The
  honest rule (ledgered): trust a resolved name only when the running app is known
  to be that symbol's app. Per-app `baseOffset` relocation is an M7 candidate.
- **App breadth is unexercised**, by choice: the other tools (LisaCalc/Draw/…) and
  printing (*Monitor the Printer…*) are natural next demos, not blockers.

## Reproduce

Prerequisites: the Rev H ROM pair (e.g. under `~/Development/LisaROMs`), a bootable
`OS31-installed.widget` (built by M5's install; see `docs/m5-demo.md`), and — for
the LisaWrite step — the LisaWrite 3.1 disk-1 image.

> A boot **WRITES** to the Widget volume, and the desktop work + install below
> mutate it further. Treat `OS31-installed.widget` as precious — **copy it first
> and drive the copy.**

```sh
cp ~/Development/LisaImages/OS31-installed.widget /tmp/lisa-work.widget

LISAEMU_ROM_DIR=~/Development/LisaROMs \
swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget /tmp/lisa-work.widget
```

### The daily loop, at the `lisadbg` prompt

```
# --- power on: boot off the Widget to the desktop (the M5 boot path) ---
g 18000000        # POST -> the Rev H boot menu
click 420 182     # "STARTUP FROM..."
g 8000000
click 88 33       # top device = the Internal Hard Disk (the Widget)
g 60000000        # prof_entry reads block 0; the OS comes up off the disk
g 150000000       # -> the first Office System dialog
click 595 72      # "Don't Check" on the dirty-volume notice
g 380000000       # the Desktop Manager builds the desktop
sc ~/Development/LisaEmu-artifacts/m6-clock-02-desktop-nonote.png   # NO clock note

# --- desktop work: a folder, renamed from the keyboard ---
# Filer menus are PRESS-DRAG-RELEASE pull-downs, not click-latched:
press 40 12       # hold down on the "File/Print" title
moveto 40 80      # step down to "Tear Off Stationery" (incremental!)
release           # release on the item -> a new folder "Folders 08/11"
type Reports      # the fresh name is in edit mode -> keyboard rename

# --- install + type into LisaWrite ---
insert ~/Development/LisaImages/.../682-0093-B_LisaWrite1_3.1.dc42  # fill in your local Lisa_Office_System_3.1 subdirectory
g 40000000        # the OS honors bot_in, mounts + reads the diskette
# (open the diskette window, drag the LisaWrite tool onto the Hard Disk icon,
#  tear off a document, Open it, then:)
type Hello from LisaEmu-- M6 Task 3.
sc ~/Development/LisaEmu-artifacts/m6-lisawrite-07-typed.png

# --- power off: the OS shuts itself down, cleanly ---
power             # COPS $80,$FB -> the OS's own FS_ShutDown/GiveUpGhost/PowerDown
g 120000000       # -> $21 issued, powerState = OFF, screen black
sc ~/Development/LisaEmu-artifacts/m6-power-05-shutdown.png
```

Reboot the *same* `/tmp/lisa-work.widget` and the dirty-volume dialog is **gone**
(the clean shutdown wrote the volume not-in-use).

New `lisadbg` verbs this milestone: `press <x> <y>` / `release` /
`moveto <x> <y>` (press-drag-release menus), `drag <x1> <y1> <x2> <y2>`,
`insert <path.dc42>` / `eject` (the media-change path), and `power` (the
soft-power button). Two driving gotchas: the framebuffer is **720 wide** (a click
at `x ≥ 720` is silently off-screen), and menu highlight tracking needs
**incremental** `moveto` steps (a single big jump skips the OS's per-move
highlight).

### The regression tests (the automated vehicle)

```sh
LISAEMU_ROM_DIR=~/Development/LisaROMs \
LISAEMU_DISK_DIR=~/Development/LisaImages \
LISAEMU_WIDGET_DIR=~/Development/LisaImages \
LISAEMU_LINKMAP_DIR="<path to Linkmaps 3.0>" \
  swift test -c release
```

- `checkpointL_softPowerOSShutsItselfDownFromTheDesktop` pins the **soft-power**
  proof: desktop reached → button → `powerState == .off`, `!halted`, a documented
  power-off byte in `powerCommandLog`.
- `checkpointM_disketteInsertedAtDesktopMounts` pins the **desktop-in-use** slice:
  boot to the desktop, `insertWhileRunning` the LisaWrite diskette, assert the OS
  mounts + reads it.
- Both are env-gated (real ROM + `OS31-installed.widget`; `checkpointM` also needs
  the LisaWrite disk-1 image) and always run on a temp **copy** — the canonical
  image is never mutated. Like `checkpointK`, they assert *state*, not an exact
  framebuffer: the desktop is reached through feedback-timed dialog clicks, so the
  screenshots are the narrative artifact and the checkpoints pin the robust
  behavioural proof.

## Screenshots

Captured to `~/Development/LisaEmu-artifacts/` (referenced by path, never
committed — they render Apple's ROM/OS-drawn UI, same rule as M2–M5's artifacts):

- **Power cycle** — `m6-power-02-dirty-firstboot` · `-04-desktop` ·
  `-05-shutdown` · `-07-reboot-progress` · `-08-reboot-clock`.
- **Clock** — `m6-clock-01-dirty-volume` · `-02-desktop-nonote` ·
  `-03-desktop-settled` · `-04-poweroff`.
- **Filer** — `m6-desktop-clean` · `-filer-open` · `-menu-desk` · `-menu-fileprint`
  · `-menu-edit` · `-menu-housekeeping` · `-tearoff-folder` · `-folder-final` ·
  `-duplicate-modal` · `-preferences` · `-preferences-main`.
- **LisaWrite** — `m6-lisawrite-01-inserted` · `-02-diskwindow` · `-03-copy` ·
  `-04-copydone` · `-05-tearoff` · `-06-launch` · `-07-typed` · `-08-typed2`.

## The M6 checkpoint journey, in one line each

- **Checkpoint L (Task 1) ⭐:** the **soft power-off** — the desktop responds to
  the power button by running the OS's own `FS_ShutDown`/`GiveUpGhost`/`PowerDown`,
  honored as COPS `$21`; the clean shutdown makes the next boot skip the
  dirty-volume dialog.
- **Task 2 — the RTC:** a real COPS clock derived from the OS's own parser; the
  clock-not-set note is gone; the OS's `$21`-not-`$20` shutdown attests it believes
  the clock. (North-star "working clock" clause, closed.)
- **Checkpoint M (Task 3) ⭐:** the **desktop in use** — Filer navigate/create/
  keyboard-rename/Preferences, and LisaWrite installed, launched, and **typed
  into**. (North-star "working keyboard" at the desktop, closed.)

**The north star is met in full:** *boot from power-on through the real Rev H ROM
and Lisa OS 3.1 to the Office System desktop, with working mouse, keyboard, and
clock* — with the two honest caveats above (the 4-bit year displays 1994; no timed
wake yet).

## M7 candidates

- **Timed reboot-alarm wake** — model the RTC alarm so `PowerCycle`'s `$23`/`$2D`
  "reboot later" schedules a real wake (cited MACHINE:447-480).
- **Per-app symbol relocation** — a per-app `baseOffset` so the merged Linkmap
  table names a *non-Filer* app's code correctly (the one overlay caveat).
- **Deeper app coverage** — the other tools (LisaCalc/LisaDraw/…) and printing
  (*Monitor the Printer…*), now that the desktop is fully live.
- **The long-deferred niceties** — `$C015`/800K double-sided handling, the parked
  1 MB-POST divergence at `$FE099C`, session-overlay retention by disk identity,
  and a synthetic double-click detector (the OS's time-based detector doesn't fire
  on injected click pairs).
