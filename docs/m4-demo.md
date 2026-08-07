# M4 demo — the OS boots to the Office System installer

M4's task list (the spec's "M4 Desktop ⭐ — mouse/keyboard/clock live; Office
System desktop" line) asked: past M3's stop (the loaded OS spinning forever in
its own COPS-driver handshake, `$520842-$52084E`), does the OS actually come
**alive** — take live interrupts, run its scheduler, put Office System on the
glass? The honest answer this milestone landed on: **yes, most of the way** —
the OS boots all the way to the **Lisa 7/7 Office System 3.0 installer dialog,
live on screen** (Finished / Repair / Install / Restore), running its own
multi-domain scheduler with both interrupt levels delivering to its own
handlers. It stops there — idling in the installer's event-wait loop — for one
honest reason: **no hard disk is modeled yet, so the installer has nowhere to
install to.** This document is the plain-language walkthrough; full evidence and
citations live in `docs/rom-trace-notes.md` ("Checkpoint E", "Checkpoint F",
"Checkpoint G") and `task-4-report.md`.

## What now happens on boot

Starting from M3's stop (the OS's own COPS driver spinning on a handshake line
at `$520842`):

1. **The COPS handshake completes** (M4 Task 1). M3's simplified controller
   model dropped the "command ready" line on every register write, which the
   ROM tolerated but the OS's own driver did not — it re-writes the command
   byte on every poll. Reworking the COPS CRDY signal to a read-count gate lets
   the OS driver's `$7C` ("enable mouse interrupts") command complete, opening
   the OS frontier. Every ROM pin stayed unchanged.
2. **The OS unmasks interrupts and takes its first live ones** (M4 Task 3).
   A single evidence-gated device fix — `$F801` bit-2 vertical-retrace polarity
   was inverted (we exposed it active-HIGH; the OS's own `Level1` handler proves
   it is active-LOW) — dissolved an interrupt storm that had pinned the CPU in
   the level-1 handler the instant SR dropped below `$2700`. With it fixed, the
   OS delivers its **first live interrupts straight into its own handlers**:
   level-1 ms-tick / vertical-retrace at `Level1` `$5208A6`, level-2 COPS at
   `Level2` `$520A52`. The hourglass/busy cursor is drawn — the OS's
   `VertRetrace` cursor code is now live.
3. **The machine identity is corrected and the real disk driver loads**
   (M4 Task 4). The OS reads `$FCC031` as its machine identity; our `0x00` stub
   decoded as a **Twiggy Lisa 1**, so the OS installed the `TWIGIO` driver whose
   entire body is compiled out of OS 3.1 — a do-nothing stub that accepted the
   boot-volume mount read and orphaned it. Returning `$88` (Lisa 2/10) sends the
   OS down the real config path: it loads `SYSTEM.CDD` + the Sony boot CD driver
   off the floppy, installs a real control block, and the mount read completes.
4. **The OS writes the floppy, and those writes are now kept** (M4 Task 4). The
   OS rewrites the boot volume's parameter-memory snapshot and FS metadata. A
   session-scoped write-through overlay captures every written block in memory
   (the `.dc42` on disk is never mutated) so re-reads see fresh bytes.
5. **The OS's fault-driven gate engine works** (M4 Task 4). Once multi-domain
   user processes start, the OS reaches swapped-out segments and syscall entry
   points through `$A0xxxxxx`-tagged jump entries that deliberately bus-fault;
   its recoverable-bus-error engine re-runs them. Stock Musashi pushed the wrong
   exception frame for a mid-jump fault, which corrupted a syscall parameter and
   tripped a fatal `System_Error(10201)`. The vendored core now pushes
   real-68000 group-0 frames for jump-site faults; the gates recover as designed.
6. **Office System comes up on screen.** Mount completes → `SYS_PROC_INIT` →
   multi-domain user processes → the desktop gray + menu-bar background draws →
   the **Lisa 7/7 Office System 3.0 installer dialog** draws and idles, awaiting
   mouse input.

## How far it gets, concretely

- **~670 floppy blocks read** (vs. 75 at the M3 stop) — the OS image, the Sony
  CD driver, and the installer's own resources.
- **First live interrupts delivered** to the OS's own `Level1`/`Level2`
  handlers; the scheduler runs across eleven-plus loaded code segments.
- **User mode reached** (SR drops to `$0000`/domain-1 user processes;
  observed in trace — the committed tests pin `minSR < $2700` and the
  S-bit); A5 changes as `SYS_PROC_INIT` creates the first processes.
- **Floppy writes kept**: within the pinned window `writeAttempts == blocksWritten`
  (28/28 stored, none dropped).
- **Recoverable gate faults** fire and recover by design (`busErrorPulseCount > 0`)
  — this is the OS's normal segment-swap / syscall mechanism, not a crash.
- **On screen:** the desktop background, then the installer dialog
  ("Finished / Repair / Install / Restore", ©1983,1984 Apple Computer).
- **Zero halts, zero fatal faults** the whole way — this is a live progression
  to an interactive idle, stable from ~8 M post-boot instructions through 400 M
  (the probe horizon).

## The honest frontier

The OS is **alive and interactive-ready**: it sits in the installer's event-wait
loop, polling for a mouse event that the harness does not post. Two honest,
distinct boundaries define where M4 stops:

1. **The installer awaits input.** Nothing is wrong — the installer's UI is on
   the glass and it is waiting for the user to click one of its buttons. Driving
   that UI (synthesizing mouse input at the installer's event-wait, clicking
   Install/Repair) is deferred to M5.
2. **Install finds no suitable disk.** When the install path *is* driven far
   enough (user-confirmed interactively), the installer reports **"can't find a
   suitable disk"** — which is *correct*: **no hard disk is modeled**. The
   Office System installer needs a target hard disk (Widget / ProFile) to
   install onto, and the emulator does not model one yet. **Modeling the
   Widget/ProFile hard disk (HLE) is THE M5 milestone** — it is the genuine
   boundary at last, not an emulation bug.

## Reproduce

Prerequisites, same as M2/M3: the Rev H ROM pair and `OS31_Install_1.dc42` (or
another OS 3.1 install-disk image), e.g. under `~/Development/LisaROMs` and
`~/Development/LisaImages`.

### In the app (interactive)

Launch `LisaApp`, insert the install disk (File > Insert Disk / ⌘I /
drag-and-drop), then click the on-screen "STARTUP FROM…" button and pick the
floppy. The real boot sequence drives on its own: the ROM's Sony loader reads
block 0, the OS loader runs from RAM, the disk-activity indicator flashes as
blocks stream in, the hourglass cursor appears, and then — with no further input
— the desktop background and the Office System installer dialog draw on the
glass. The machine then idles in the installer, awaiting a mouse click.

### In `lisadbg` (scripted, no UI)

`lisadbg`'s `bootdisk` command (M4 Task 2) drives the ROM past the boot menu,
through the loader, and into the loaded OS entirely on its own — no integration
test involved:

```
swift run -c release lisadbg \
  --rom $HOME/Development/LisaROMs \
  --disk $HOME/Development/LisaImages/OS31_Install_1.dc42
```

then type `bootdisk` and let it run. `d`/`t`/status output also gets a
Linkmap-symbol overlay (`sym`/`symbase`; `LISAEMU_LINKMAP_DIR` or the default
`Lisa_Source` path) — though note the honest coverage finding (M4 Task 2): all
22 available Linkmap files are Office System *application* maps, so the
`$520000+` kernel addresses this boot lives in currently resolve to no symbol.
The overlay is real and cited-verified; it just has no data for the kernel
range yet — the gold is once the desktop apps themselves run (M5+).

### The integration test (the automated regression vehicle)

```
LISAEMU_ROM_DIR=$HOME/Development/LisaROMs \
LISAEMU_DISK_DIR=$HOME/Development/LisaImages \
  swift test -c release --filter ROMFloppyBootTests
```

`ROMFloppyBootTests.checkpointG_officeSystemInstallerUIDraws` boots to the
loader, runs 10 M instructions, and asserts the whole result: no halt;
`unblk_req` executes; A5 changes (processes exist); user-mode execution at
domain latch 1; gates fire and recover; floppy writes stored (nothing dropped);
`blocksRead >= 600`; and the framebuffer equals the installer-dialog anchor
(FNV `0x04a19e4eb59704f4`, 60,107 set pixels). `checkpointE` pins the unmasking
+ first live interrupts. `checkpointF` was a transitional anchor for the
pre-fix I/O-completion stall state; it was superseded and removed once the
round-4 fix landed, so `checkpointG` above is the standing pin for the
post-fix boundary.

## Screenshots

Captured to `~/Development/LisaEmu-artifacts/` (referenced by path, never
committed — they render Apple's ROM/OS-drawn UI, same rule as M2/M3's artifacts):

- `m4-checkpoint-e.png` — the OS hourglass/busy cursor at the unmasking.
- `m4-checkpoint-f-os-boot-hourglass.png` — the mid-boot hourglass.
- `m4-checkpoint-g-desktop-background.png` — the desktop gray + menu-bar
  background (126,116 px at ~93.6 M cycles).
- `m4-checkpoint-g-installer-ui.png` — the **Office System 3.0 installer
  dialog** (Finished / Repair / Install / Restore; FNV `0x04a19e4eb59704f4`,
  60,107 px, ~118.3 M cycles).

## The three-checkpoint journey, in one line each

- **Checkpoint E (Task 3):** the *unmasking* — `$F801` vsync polarity fixed,
  the interrupt storm dissolved, first live interrupts into the OS's own
  handlers, hourglass drawn.
- **Checkpoint F (Task 4, rounds 1-3):** the boot stalls on a driver I/O
  request that is built but never started — traced, round by round, from a
  mis-called "event-wait" to a reqblk dispatched to a stub driver.
- **Checkpoint G (Task 4, rounds 4-5):** THE BREAKTHROUGH — the stub driver's
  root cause (`$FCC031` Twiggy-vs-Lisa-2 identity) plus two stacked divergences
  (dropped floppy writes; Musashi jump-gate frames) fixed, and the boot runs all
  the way to the installer UI on screen, user-confirmed live.

## M5 teaser: the Widget

The stop this milestone reaches is not an emulation bug — it is a genuinely new
subsystem the boot has never needed before: a **hard disk**. The Office System
installer's whole purpose is to install onto one, and it correctly reports it
can't find a suitable disk because the emulator models only the floppy. **M5 is
Widget/ProFile hard-disk HLE** — giving the installer a target to install onto,
then driving its UI (clicking Install) and watching for the next boundary. Also
carried to M5: driving the installer's mouse-input event-wait, the soft-power /
Power menu, `$C015` vs. 800K double-sided handling, and the parked 1 MB-POST
divergence at `$FE099C`. See `docs/rom-trace-notes.md` "Checkpoint G" for the
full evidence and the deferred-item roster.
