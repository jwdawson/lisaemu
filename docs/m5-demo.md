# M5 demo — the Office System installs onto, and boots off, the Widget hard disk ⭐

M4 landed the OS **alive** at the Lisa 7/7 Office System installer, one honest
step short of the spec's ⭐: *"the Office System desktop, mouse/keyboard live."*
It stopped there for one reason — **no hard disk to install onto or boot from.**
M5 closed that gap end to end, in four movements:

1. **Task 1** derived the ProFile/Widget parallel-port protocol contract from the
   OS driver source (`hardware-notes.md` §10), citation-verified.
2. **Task 2** built the **Widget/ProFile hard-disk HLE** (`WidgetDrive`) and a
   **persistent image container** (`WidgetImage`, write-back + fsync) with a
   `T_Seagate` identity, plus the attach seam (`lisadbg --widget` / `widget
   create`, and the LisaApp *Widget* menu).
3. **Task 3** drove the **in-emulator installer** to lay the whole Office System
   down onto a blank Widget image — initialize all 19456 blocks, then copy five
   floppies across **real media swaps** — to the installer's own
   *"software has been installed"* completion.
4. **Task 4** **boots that installed system off the hard disk** — through the
   boot ROM's *own* parallel-port boot path — all the way to the **desktop, with
   a live mouse.** ⭐

This is the plain-language walkthrough. The full evidence + citations live in
`docs/rom-trace-notes.md` ("Checkpoint H", "Checkpoint K") and
`docs/hardware-notes.md` §9 (floppy media-change) + §10 (the ProFile/Widget
protocol).

## What M5 delivers, concretely

- A **blank Widget image** you create in-emulator (`.widget`, an all-zero
  Widget-10 container, 19456 × 532-byte blocks).
- The **real Office System installer** initializes it and copies the OS onto it —
  ~19456 blocks erased/verified, five install floppies copied across five live
  disk swaps (Widget write commands climb past 24 000; block 0 becomes a genuine
  `4E FA …` 68000 boot block).
- The **installed image boots off the hard disk** — the ROM's `prof_entry`
  routine reads block 0 off the Widget, the OS loader + OS pull their code and the
  Lisa File System off the disk (hundreds of single-block ProFile reads), and the
  Desktop Manager draws the **Office System desktop** — menu bar and icons — with
  the **mouse live** (a modal dialog answered by an on-screen click).
- **Zero halts, zero fatal faults** across both the install and the boot.

## Part 1 — create a blank Widget and install the Office System

Starting from a blank Widget image attached to the machine, with Office System
install disk 1 in the floppy drive, the installer is driven exactly like the M4
installer UI (click **Install**) — now with a target to install onto. The
journey, screen by screen (`~/Development/LisaEmu-artifacts/m5-install-*.png`):

1. **The installer finds the disk** (`m5-install-01`). The Install click runs the
   OS ProFile driver's `PROF_INIT` **live for the first time**; the Widget HLE
   answers its device-info handshake (drivetype + 19456-block discsize) and the
   installer asks *"Do you want to use the disk attached to the internal
   connector?"*
2. **Initialize** (`m5-install-02`). *"…not initialized… Continue"* → the whole
   **19456-block disk is erased/initialized**; every write persists to the image
   and the driver's read-back verify passes.
3. **Don't Share with MacWorks** (`m5-install-03`). The installer offers to share
   the disk with MacWorks; **Don't Share** gives the Office System the whole disk.
4. **Copy disk 1, then swap** (`m5-install-04`, `-05`, `-06`). The Office System
   startup software copies from the floppy to the Widget (floppy reads climb into
   the thousands; Widget write commands past 20 000), then: *"Please insert the
   Lisa Office System 2 micro diskette"* — **the first media swap.**
5. **Five real disk swaps** (`m5-install-06`). Disks **2, 3, 4, 5** each go in
   through the **real floppy media-change path** — eject the old disk, insert the
   new one, and the Sony driver's `bot_in` media-change interrupt wakes the
   installer's blocked mount so it reads and copies each disk (~700 floppy reads
   per disk).
6. **Reinsert the boot disk, and finish** (`m5-install-07`, `-08`). The last step
   reinserts install disk 1; the boot-disk **write session is retained** across
   the swap so `boot_remount` re-verifies the volume, the boot tracks + `system.=`
   files are written, and the installer reports **"The Lisa Office System
   software has been installed."** ✅

The result is a **bootable 10 MB Widget image** left at
`~/Development/LisaImages/OS31-installed.widget` (block 0 = a genuine `4EFA…`
68000 boot block).

## Part 2 — boot the installed system, to the desktop

With the installed image attached as the Widget, driving the boot menu to the
hard-disk item boots the OS off the disk. Screen by screen
(`~/Development/LisaEmu-artifacts/m5-boot-*.png`):

1. **The boot menu** (`m5-boot-01`). The same Rev H menu as always — the ROM
   never auto-boots; you pick the device.
2. **STARTUP FROM lists the hard disk** (`m5-boot-02`). Before M5 the list held
   only the floppy (⌘2); now the **Internal Hard Disk (⌘1)** appears above it —
   the ROM's own parallel-port probe finally sees the Widget.
3. **The boot loader runs off the disk** (`m5-boot-03`, the hourglass). The ROM's
   `prof_entry` routine reads block 0 (the LFS boot block) off the Widget and
   JMPs into it; the OS loader then pulls its code + the LFS off the hard disk —
   hundreds of single-block ProFile reads, all served by the Widget HLE. Once
   execution leaves ROM into the booted OS, the 22 app **Linkmaps resolve live**
   (`[lmfiler.DOCCONSI]`, `[NEWSEG1.DOPAGEBR]`, `[fpelems.RANDOMX]` …) — spec §4's
   symbol overlay finally has data.
4. **A real Office System dialog** (`m5-boot-04`): *"The startup disk was in use
   when the Lisa failed…"* — the normal dirty-volume notice (a boot marks the
   volume in-use). Click **Don't Check** to boot on.
5. **THE DESKTOP** (`m5-boot-05`, `m5-boot-06`): the Desktop Manager draws the
   menu bar **Desk / File/Print / Edit / Housekeeping** and the desktop icons
   **Preferences · Wastebasket · Clipboard · Internal Hard Disk** (the last is
   the Widget itself). A first-boot **clock/calendar** note draws (no RTC is
   modeled); **clicking its OK button dismisses it** — a modal dialog answered by
   a mouse click, i.e. **the mouse is live at the desktop.** ⭐

## The engineering behind it, in brief

Five pieces of source-grounded work carried the milestone; each is fully cited in
`rom-trace-notes.md` / `hardware-notes.md`:

- **The ProFile protocol contract (Task 1, §10).** Command bytes, `$55`/`$69`
  replies, the 532 = 512 + 20 block geometry, and the `$C140C000` status mask —
  all derived from the OS `PROFILEASM` driver source (the brief's guess that
  `$02` = write-verify was *refuted*: `$02` is the format command).
- **The Widget HLE + persistent image (Task 2, §10.10).** `WidgetDrive` speaks
  the wire protocol; `WidgetImage` is a write-back container (fsync-flushed,
  reopen-proven) with the source-settled `T_Seagate` single-block identity and
  full 19456-block capacity.
- **The transport rework (Task 3).** The first *live* `PROF_INIT` proved the
  Task-2 transport wrong; it was rebuilt line-by-line against the driver: **BSY =
  Port B bit 1 as a level**, responses on **PORTA (VIA reg 15)**, **status-first**
  reads, **header-first** writes with a **read-back verify**.
- **The floppy media-change attention (Task 3, §9).** The five-disk swap needed
  the Sony driver's `bot_in`/`DISKSTAT` media-change interrupt (`DISK_INT`) plus a
  real eject — without it the installer's mount retry could never see the new
  disk.
- **The one-line boot fix (Task 4).** The ROM boots ProFile-family disks through
  its *own* routine `prof_entry` (`$FE1F70`), driving the parallel port at VIA1
  base **`$FCD901`** — the same physical register file as the OS driver's
  `$FCD801`, a different address alias. `IODispatcher` had forwarded the Widget's
  PORT-B command strobe for `$FCD801` only, so the ROM's boot strobe at `$FCD901`
  never reached the drive and STARTUP FROM showed only the floppy. Forwarding
  PORT-B writes for the `$FCD901` alias too (they are one register on real
  hardware) is the whole fix — strictly *more* faithful than the guard it
  replaced, and a no-op when no Widget is attached, so every prior floppy-boot and
  install checkpoint is unmoved.

## The honest frontier

M5 reaches the desktop — the spec's ⭐ — and stops there honestly:

- **The desktop is reached, but its apps are not yet exercised.** Opening the
  Internal Hard Disk window, running Filer operations, launching LisaWrite/
  LisaDraw off the desktop — those are the natural next demo. The Linkmaps are now
  live to annotate them.
- **No RTC (COPS real-time clock) is modeled.** Hence the **clock-not-set** note
  every boot; the north star's *"working clock"* clause is the honest remaining
  gap — the natural **M6 headline** (see below). The dirty-volume dialog is
  likewise a genuine first-boot OS notice, not an emulator fault.
- **Session-overlay retention is keyed to object identity, not disk identity.**
  Fine for the linear install→boot flow; arbitrary UI-driven multi-swaps would
  need a per-image overlay store.
- **The multi-block / `T_Widget` path (§10.6) is unimplemented by design** — the
  single-block `T_Seagate` protocol is what the install and boot exercise.
- **Deferred/parked (unchanged from prior milestones):** the soft-power / Power
  menu (deferred repeatedly), `$C015` vs. 800K double-sided handling, the parked
  1 MB-POST divergence at `$FE099C`, and the **POST-time crossed-out "42"
  ProFile icon** — note this last one still fails at POST time (the M5 fix changed
  only the *menu-time* device probe; the power-on menu framebuffer is byte-
  identical to the M1b anchor, crossed-out icon and all).

## Reproduce

Prerequisites: the Rev H ROM pair (e.g. under `~/Development/LisaROMs`) and the
five-disk Office System 3.1 install set (e.g. `~/Development/LisaImages/
Lisa_Office_System_3.1/`).

> A boot **WRITES** to the Widget volume (the OS marks the LFS in-use). Treat
> `OS31-installed.widget` as precious — copy it first and boot the copy.

### Create a blank Widget image

- **In the app:** *File ▸ Create Blank Widget Image…* — choose a destination; a
  fresh all-zero Widget-10 image is created and attached (writes persist to the
  file).
- **In `lisadbg`:** at the prompt, `widget create <path>.widget` — creates and
  attaches a blank Widget image (19456 blocks).

### Run the install (interactive, in the app)

1. Attach a blank Widget (*File ▸ Create Blank Widget Image…*).
2. Insert Office System install disk 1 (*File ▸ Insert Disk…* / ⌘I / drag-and-drop).
3. Click the on-screen **STARTUP FROM…**, pick the floppy, and let the OS boot to
   the installer.
4. Click **Install**; answer the prompts (**Continue**, **Don't Share**).
5. When the installer asks for each next disk, use *File ▸ Insert Disk…* to feed
   disks **2 → 3 → 4 → 5** (each eject/insert drives the real media-change path),
   then reinsert disk 1 at the final prompt.
6. The installer reports **"The Lisa Office System software has been installed."**
   The Widget image now holds a bootable Office System.

### Boot the installed system (scripted, in `lisadbg`)

```
LISAEMU_ROM_DIR=~/Development/LisaROMs \
swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget ~/Development/LisaImages/OS31-installed.widget   # boot a COPY
```

Then, at the prompt, drive the boot menu and click through:

```
g 18000000        # POST -> the Rev H boot menu (RESTART / CONTINUE / STARTUP FROM)
click 420 182     # "STARTUP FROM..."  (opens the device list)
g 8000000
click 88 33       # the top device item = the HARD DISK (the Widget, item ⌘1)
g 60000000        # prof_entry reads block 0; the OS loader + OS come up off the disk
g 150000000       # boot progress -> the first Office System dialog
click 595 72      # "Don't Check" on the dirty-volume notice
g 380000000       # the Desktop Manager builds the desktop off the Widget
click 585 118     # "OK" on the clock/calendar note  (proves live mouse)
sc ~/Development/LisaEmu-artifacts/m5-boot-06-desktop.png
```

`d`/`t`/status output gets the Linkmap-symbol overlay (`sym`/`symbase`;
`LISAEMU_LINKMAP_DIR` or the default `Lisa_Source` path) — and unlike M4, it now
resolves live, because the booted Office System app code is exactly what the 22
Linkmaps cover.

### Boot the installed system (interactive, in the app)

*File ▸ Choose Widget Image…* → pick a **copy** of `OS31-installed.widget`, then
click the on-screen **STARTUP FROM…** and pick the **Internal Hard Disk**. The
boot runs on its own to the desktop; click **Don't Check** and **OK** to dismiss
the two first-boot dialogs.

### The regression tests (the automated vehicle)

```
LISAEMU_ROM_DIR=~/Development/LisaROMs \
LISAEMU_DISK_DIR=~/Development/LisaImages \
LISAEMU_WIDGET_DIR=~/Development/LisaImages \
  swift test -c release
```

- `ROMWidgetBootTests.checkpointK_romBootsInstalledOSOffTheWidget` (env-gated on
  `LISAEMU_ROM_DIR` + `LISAEMU_WIDGET_DIR` holding `OS31-installed.widget`) pins
  the **boot**: the Widget serves > 100 ProFile reads, the CPU executes booted
  code outside the ROM window, the framebuffer leaves the boot-menu anchor, no
  halt. It always works on a temp COPY — the canonical image is never mutated.
- `checkpointI_installClickFindsTheWidgetDisk` pins the disk-found precursor;
  `checkpointJ` pins the first media-change **swap** (disk-2 mount + read after
  the eject/insert). The full five-disk install run stays **narrative**
  (too long/stateful for CI — the screenshots are the artifact).

The desktop itself is deliberately **not** an exact framebuffer hash: it is
reached only after two click-through dialogs whose feedback-loop timing makes an
exact-cycle anchor fragile for CI, so `checkpointK` pins the robust behavioural
proof and `m5-boot-06-desktop.png` is the narrative artifact.

## Screenshots

Captured to `~/Development/LisaEmu-artifacts/` (referenced by path, never
committed — they render Apple's ROM/OS-drawn UI, same rule as M2–M4's artifacts):

- **Install** — `m5-install-01-disk-found` · `-02-initialize` · `-03-macworks` ·
  `-04-insert-disk2` · `-05-installing-startup-sw` · `-06-copying-disk2` ·
  `-07-reinsert-disk1` · `-08-complete`.
- **Boot** — `m5-boot-01-startup-menu` · `-02-device-list` · `-03-loader-hourglass`
  · `-04-dirty-volume-dialog` · `-05-desktop-clocknote` · `-06-desktop`.

## The M5 checkpoint journey, in one line each

- **Checkpoint H (Tasks 1–3):** the installer's disk scan — from *"finds no hard
  disk"* (Task 1 prep), to the Widget attached and probed (Task 2), to the
  install **driven to completion** across five real disk swaps (Task 3), leaving
  the bootable image.
- **Checkpoint I (Task 3):** the **Install click finds the Widget** — `PROF_INIT`'s
  live device-info handshake completes (disk-found anchor).
- **Checkpoint J (Task 3 round 2):** the **first media-change swap** — disk 2
  mounts and reads after a real eject/insert (the exact round-1 hang, now moving).
- **Checkpoint K (Task 4) ⭐:** the **desktop** — the installed OS boots off the
  Widget through the ROM's own `prof_entry` path to the Office System desktop,
  live mouse.

## M6 candidates

- **A working clock (RTC / COPS clock).** The north star's *"working clock"*
  clause is the honest remaining gap — modeling the COPS real-time clock removes
  the clock-not-set dialog and completes the ⭐ line. The natural M6 headline.
- **Exercising the desktop apps.** Open the Internal Hard Disk window, run Filer
  operations, launch LisaWrite/LisaDraw off the desktop — now that the Linkmaps
  resolve live.
- **Session-overlay retention by disk identity**, for arbitrary UI-driven swaps.
- **The multi-block / `T_Widget` path (§10.6)**, if a workload ever needs it.
- **The long-deferred niceties:** the soft-power / Power menu, `$C015`/800K
  double-sided handling, and the parked `$FE099C` 1 MB-POST divergence.
