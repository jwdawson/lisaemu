# M5 demo — the Office System boots off the Widget, to the desktop ⭐

M4 landed the OS **alive** at the Office System installer, one honest step short
of the spec's ⭐: *"the Office System desktop, mouse/keyboard live."* It stopped
there for one reason — **no hard disk to install onto or boot from.** M5 closed
that gap: Task 2 built the Widget/ProFile hard-disk HLE, Task 3 drove the
in-emulator installer to lay the whole Office System down onto a Widget image,
and **Task 4 boots that installed system off the hard disk — all the way to the
desktop, with a live mouse.** This is the plain-language walkthrough; the full
evidence + citations are in `docs/rom-trace-notes.md` ("Checkpoint K") and
`docs/hardware-notes.md` §9-§10.

## What now happens on boot

Boot with the installed image attached as the Widget:

```
LISAEMU_ROM_DIR=~/Development/LisaROMs \
swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget ~/Development/LisaImages/OS31-installed.widget
```

> A boot WRITES to the volume (the OS marks the LFS in-use). Treat
> `OS31-installed.widget` as precious — copy it first and boot the copy.

Then, at the `lisadbg` prompt, drive the boot menu and click through:

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

The journey, screen by screen (`~/Development/LisaEmu-artifacts/m5-boot-*.png`):

1. **The boot menu** (`m5-boot-01`). Same Rev H menu as always — the ROM never
   auto-boots; you pick the device.
2. **STARTUP FROM lists the hard disk** (`m5-boot-02`). Before this task the list
   held only the floppy (⌘2); now the **Internal Hard Disk (⌘1)** appears above
   it — the ROM's own parallel-port probe finally sees the Widget.
3. **The boot loader runs off the disk** (`m5-boot-03`, the hourglass). The ROM's
   `prof_entry` routine reads block 0 (the LFS boot block) off the Widget and
   JMPs into it; the OS loader then pulls its code + the LFS off the hard disk —
   hundreds of single-block ProFile reads, all served by the Widget HLE.
4. **A real Office System dialog** (`m5-boot-04`): *"The startup disk was in use
   when the Lisa failed…"* — the normal dirty-volume notice (a boot marks the
   volume in-use). Click **Don't Check** to boot on.
5. **THE DESKTOP** (`m5-boot-05`, `m5-boot-06`): the Desktop Manager draws the
   menu bar **Desk / File/Print / Edit / Housekeeping** and the desktop icons
   **Preferences · Wastebasket · Clipboard · Internal Hard Disk** (the last is
   the Widget itself). A first-boot **clock/calendar** note draws (no RTC is
   modeled); **clicking its OK button dismisses it** — a modal dialog answered
   by a mouse click, i.e. **the mouse is live at the desktop.** ⭐

## The one engineering fix behind it

The ROM boots ProFile-family disks through its *own* parallel-port routine
(`prof_entry` = `$FE1F70`), which drives the port at VIA1 base **`$FCD901`** —
the same physical VIA1 register file as the OS driver's `$FCD801`, just a
different address alias, speaking the identical ProFile protocol (BSY on PORT B
bit 1, CMD/DIR strobe, the `$C140C000` status mask). Our `IODispatcher` had been
forwarding the Widget's PORT-B command strobe for the `$FCD801` alias only, so
the ROM's boot-time strobe at `$FCD901` never reached the drive — the probe
timed out and STARTUP FROM showed only the floppy. Forwarding PORT-B writes for
the `$FCD901` alias too (they are one register on real hardware) is the whole
fix. The floppy path only *reads* a different VIA1 pin and the forward is a
no-op when no Widget is attached, so every prior floppy-boot and install
checkpoint is unmoved. Full trace + citations: `docs/rom-trace-notes.md`
"Checkpoint K".

## Status

The spec's **M4 ⭐** is achieved over the Widget: the installed Office System
boots off the hard disk to a live desktop. `ROMWidgetBootTests
.checkpointK_romBootsInstalledOSOffTheWidget` (env-gated on `LISAEMU_ROM_DIR` +
`LISAEMU_WIDGET_DIR`) pins the boot; the desktop itself is the narrative artifact
(`m5-boot-06-desktop.png`). Remaining niceties (seeding a clean volume stamp / an
RTC so the two first-boot dialogs don't appear; exercising the app icons) are
content-shaping, not boot blockers — natural follow-ons for the M5 close.
