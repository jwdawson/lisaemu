# M7 demo — The Printer: the Lisa prints ⭐

M6 made the Lisa a **machine in daily use** — booted off the Widget, clock set,
Filer worked, LisaWrite typed into, and a clean soft-power shutdown. It could do
everything but put ink on paper. M7 closes that: the emulated Lisa **prints**.
The Office System's own C.Itoh/ImageWriter driver renders a document to a raster
byte stream, pushes it out **Serial B** through a new register-level Z8530 SCC,
and the emulator turns those bytes back into pages — captured headless as PNGs
(`lisadbg`) or handed to the standard **macOS print panel** (`LisaApp`), where
"Save as PDF" comes free.

```
LisaWrite ▸ Print
  → OS ciprint/ImageWriter driver renders + streams escape codes out Serial B
  → SCC8530 channel B ($FCD205), Level-6 Tx-empty interrupt driving bytes 2..N
  → PrinterPort byte sink
  → ImageWriterInterpreter (escape stream → 1bpp page rasters)
  → PrintJobSpooler (job closes on a host-time idle window; NO form-feed byte)
  → { lisadbg --printer-dir → per-page PNGs | LisaApp NSPrintOperation panel }
```

This is the plain-language walkthrough. The full evidence + citations live in
`docs/rom-trace-notes.md` ("Checkpoint N") and `docs/hardware-notes.md`
§11 ("SCC / Serial B", §11.4 the driver transmit discipline, §11.5 the POST
probe, §11.6 the PM-persistence verdict) and §12 (the ImageWriter contract).

## What M7 delivers, concretely

- **The Lisa prints.** The live Office System's ImageWriter driver puts a raster
  byte stream on Serial B and the emulator reassembles it into pages — the M7 ⭐.
- **A real Z8530 SCC.** The four-year-old `0xFF` register stub is gone; Serial B
  is a register-level Z8530 (two-step pointer protocol, WR file, RR0 Tx-empty,
  the data register at `$FCD205`) driven byte-for-byte by the OS's own RS-232
  discipline — including the **Level-6 Tx-empty interrupt** that actually moves
  the bytes after the first.
- **Printer config that survives a power cycle** — configured once in the OS's
  own Preferences, persisting across a full power-off with **zero emulator PM
  code** (the write-through Widget snapshot carries it — §11.6).
- **Two capture paths, one pipeline** — `lisadbg --printer-dir` writes per-page
  PNGs headlessly; `LisaApp` presents the standard macOS print panel per job.

## Part 0 — the user flow (read this first)

Three things trip up a first-time run; a real QA pass hit "no printer" on all
three. Get these right and it just works:

1. **Serial B specifically.** The ImageWriter must be connected to the **Serial B
   Connector** in Preferences, not Serial A (channel A is the boot-inited console
   channel; the printer pipeline is wired to channel B at `$FCD205`).
2. **A full power cycle — relaunch, not warm reset.** The OS reads the printer
   config from parameter memory **only at boot** (`INIT_CDS`). After saving the
   config you must **power the machine off and boot it again** (in `lisadbg`: a
   fresh process; in `LisaApp`: quit and relaunch). A warm `Machine ▸ Reset` is
   **not** a power cycle and additionally hits a separate pre-existing Widget-boot
   defect (boot error 42 — see "The honest frontier").
3. **The same disk image.** Persistence rides the boot volume's snapshot, so you
   must reboot **the same Widget image** you configured. Boot a fresh copy and the
   config is not there — you'd be configuring a different machine's disk.

## Part 1 — configure the printer (the OS's own Preferences)

Booting `OS31-installed.widget` (which already has LisaWrite and a test document)
to the desktop, the printer is configured once through the authentic Office
System workflow (`~/Development/LisaEmu-artifacts/m7-connect-devices-serialb.png`):

1. **Open Preferences** from the desktop (the `Preferences` icon).
2. **Connect Devices** → the device-connection panel, a schematic of the Lisa's
   ports.
3. **Serial B Connector** → the list of devices that can hang off Serial B.
4. **Imagewriter / ‖ DMP** — select the ImageWriter (the Apple Dot Matrix family
   device; the `ciprint` driver's target).
5. **File/Print ▸ Set Aside Everything** (put away) — the OS writes the new
   configuration to parameter memory **and** snapshots it to the boot volume on
   the Widget. `m7-connect-devices-serialb` shows Serial B claimed by the
   ImageWriter.

## Part 2 — power off, then boot the same image again

The config only takes effect on the **next** boot, because `INIT_CDS` reads the
printer's device record from PM at boot time and not afterward.

- **Power off** (the M6 soft-power path — `power` at the `lisadbg` prompt, or
  `LisaApp` Machine ▸ Shut Down ⌘⌥P), then **boot the same Widget image again**.
- **The config persisted — for free** (`m7-reboot-serialb-persisted.png`). On the
  fresh boot the ImageWriter is still connected to Serial B, with **no emulator PM
  code written at all.** Task 1 had flagged a possible ~20–40-line `reset()`
  PM-sparing fix as *maybe required*; it was not. `INIT_CDS`/`READ_PMEM` reload
  the config from the `PMSnapshot` on the write-through Widget (the RAM copy is
  volatile — `floppy.reset()` zeroes the shared-RAM PM at `$FCC180` — but the
  disk snapshot is authoritative). This faithfully matches real hardware, which
  also loses battery-less shared-RAM PM on power loss and rebuilds it from the
  boot volume. The load-bearing fact is the **round-trip**: config survives a
  reboot and re-enables channel B, which the live print then proves end to end
  (§11.6, strike-not-erase of Task 1's "maybe required").

## Part 3 — print from LisaWrite

With the printer configured and the machine rebooted:

1. **Open the document** (the canonical image carries a LisaWrite document,
   *"This is a test of the lisa write application"*).
2. **File/Print ▸ Print… ▸ OK.** The print dialog now reads *"Print on ImageWriter
   Printer — serial port B"* (`m7-print-panel-lisa.png`) — the OS knows the
   printer is there because the config survived the reboot. Confirming the dialog
   sends the job.
3. **The raster streams out Serial B.** The ImageWriter driver renders the page
   and transmits it as an escape-code byte stream — the first byte polled, then
   every byte after driven off the Level-6 Tx-empty interrupt (Part 5). A single
   LisaWrite page is **9229 bytes** on the wire.
4. **The Lisa believes it printed** (`m7-print-done-lisa.png`) — the print dialog
   dismisses and the desktop returns, exactly as with a real ImageWriter.

### Headless capture — `lisadbg --printer-dir`

`lisadbg` taps the same pipeline and writes closed jobs as PNGs:

```
LISAEMU_ROM_DIR=~/Development/LisaROMs \
  swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget /tmp/copy.widget --printer-dir /tmp/pngs
# ... drive the UI (click / press / moveto / release / type) to print ...
printer     # flush the open job + report: Serial-B bytes=9229 jobsWritten=1 pagesWritten=1
```

The printed page lands as `/tmp/pngs/…png` — captured to the artifacts dir as
`m7-print-01.png`, the LisaWrite document rendered as an ImageWriter dot-matrix
page.

New `lisadbg` commands this milestone: **`--printer-dir <path>`** (closed jobs →
per-page 1bpp→grayscale PNGs), **`printer`** (flush the open job + report
counters), **`reset`** (warm reset).

## Part 4 — the macOS print panel (LisaApp)

In the app, a closed job arrives on `AppModel.onPrintJob` → main thread → the
standard **`NSPrintOperation` print panel** renders the pages, each MediaBox
sized from its DPI (Portrait Hi-Res = 576×792 pt = 8"×11"). **"Save as PDF"**
works straight from the panel. The pure, unit-tested `PrintDocument.makePDFData`
produces the identical geometry, captured as `m7-print-panel-render.pdf` /
`.png`. The **Machine** menu carries a **"Printer Connected (Serial B)"**
indicator (default connected); toggling it off drops jobs on the floor, the same
as pulling the cable.

> The interactive `NSPrintOperation` panel can't be screenshotted in the headless
> CI context ("could not create image from display"); the identical render path
> is proven by the `makePDFData` unit test **and** the committed
> `m7-print-panel-render` PDF/PNG (the app's own output for the same pages).

## Part 5 — the engineering behind it, in brief

Each piece is fully cited in `hardware-notes.md` §11–§12 / `rom-trace-notes.md`
"Checkpoint N":

- **The serial contract (Task 1, §11).** `RSBASE = $FCD201` was chased at last
  (`source-mover:46`, closing a years-old "not chased" gap): four Z8530 registers
  at odd addresses stride 2 (`$FCD201` B-ctrl, `$FCD203` A-ctrl, `$FCD205`
  B-data, `$FCD207` A-data), with `$FCD241` a channel-B-control **mirror**. The
  whole driver discipline — the two-step WR pointer protocol, the `dinit`
  register file, the transmit path, and the Tx-empty interrupt arming — was
  derived from the OS's own RS-232 source, every constant cited.

- **The real Z8530 (Task 2, §11.5).** `SCC8530` replaced the `0xFF` stub across
  `$FCD2xx` (including the `$FCD241` POST alias). The POST probe turned out to be
  **presence-only** — a bus-error-guarded read whose values are never compared,
  which is *why* the `0xFF` stub had passed POST for years. Swapping in real
  registers left every POST/menu FNV **byte-identical**.

- **The ImageWriter contract (Task 3, §12).** `ImageWriterInterpreter` +
  `PrintJobSpooler`, derived from the OS's `CiDev` driver — with two findings that
  overturned the design spec's assumptions:
  - **There is NO form-feed byte.** Page eject is line-feed accumulation MOD the
    page length (`cPg144ths`); a page break *is* the overflow. The spec's "page
    emitted on form feed" was wrong — there is no `chr(12)` anywhere in the Ci
    path (grep-verified). Jobs instead close on a host-time **idle window**.
  - **`ESC g` fast graphics is the serial path** (densities 72–160 bpi, 8-dot
    columns). A hand-authored synthetic 5×7 font renders text bytes (the real
    column data lives in external asm not in the source tree — an honest modeling
    decision). Golden-tested across seven densities, LF-overflow page breaks, and
    partial-page flush.

- **The Level-6 Tx-empty interrupt (Task 4, §11.4) — the load-bearing rework.**
  The first live print emitted **one byte** then stalled. Root cause, from the
  rsASM `XMIT` ISR: the OS driver polls and sends only the **first** byte, then
  drives every byte after off the **Level-6 Tx-empty interrupt** — which Task 2
  had deliberately left unwired (correctly for the *boot* path, since channel B
  is never inited at boot, but wrong about the driver's transmit model). Wiring it
  faithfully to the Z8530 + the ISR — the Tx-empty **latch** set on every data
  write, `irqAsserted = latch && WR1-bit1 && WR9-MIE`, OR'd into the CPU's Level 6
  — made the same print emit its full **9229 bytes**. Boot is unaffected (all
  gates read zero until the OS arms channel B; POST/menu FNV + all 13 full-env
  checkpoints byte-identical). Task 2's "no Level-6 by design" note is annotated
  **REFUTED — "wrong in reasoning, harmless in effect at boot"** (strike-not-erase
  in `task-2-report.md`, `hardware-notes §5`, and the `SCC8530` class doc). The
  Level-6 `RSINT` dispatch's **RR2** read is modeled explicitly (it had been
  served by a lucky-zero unknown-register fallback).

## The honest frontier

M7 makes the Lisa print end to end and stops at **breadth, not a wall**:

- **Interlace vertical doubling.** The printed page is correct and legible but
  shows a vertical doubling — the ImageWriter's two-pass 144-vpi interlace lands
  adjacent half-bands on adjacent rows under the interpreter's simplified vertical
  mapping (Task 3 decision 3). True interleaved-pass geometry is driven by
  external `PrVBand`/`PrHBand` asm (not the Pascal source); a pixel-true 144-vpi
  follow-up.
- **Warm reset + Widget boot → boot error 42.** A warm `Machine.reset()` followed
  by a Widget boot hits boot error 42 at the menu (a fresh power cycle boots
  cleanly). This is a **pre-existing** warm-reset/Widget-boot interaction, not the
  printer feature (the M7 diff touches no reset paths; all FNVs identical); the
  config→reboot flow uses a fresh boot, matching real "power cycle" behavior. A
  real defect for a later milestone.
- **The two-boot integration test asserts `bytes > 1000`, not a pinned page
  raster.** An in-process **second** Machine's print stalls at a 2 KB buffer
  boundary — a **hypothesis** (residual Musashi-singleton global state after the
  first in-process Machine), with only the observable confirmed: a single process
  reaches the full 9229 bytes, any in-process second Machine stalls at 2 KB.
  `bytes > 1000` (deterministic 2048) still proves the load-bearing chain
  (config-persistence-across-reboot **and** the Level-6 transport — without either
  it's 0 or 1 byte); the full-page raster is pinned robustly by
  `PrinterPipelineTests` + the headless `m7-print-01.png`.
- **The exact `pm_DevConfig` (slot,chan,dev) triple is not decoded.** It was
  observed only as a CDS-style odd-lane table (`$FCC181…`, `$F8`-record-
  separated); a precise decode wasn't pinned because the monitor's read of
  `$FCC180` is CPU-domain-dependent. The reproducible, load-bearing fact is the
  round-trip, which the live print proves.
- **Receive-side serial remains future.** The SCC is transmit-only for now — the
  receive path is a stub. But the register-level SCC built here is the
  **foundation** for LisaTerminal and the LisaBug serial console (§"Out of
  scope").
- **Daisy wheel / Canon inkjet remain future** — the `PrinterPort` seam
  accommodates them later; the ImageWriter was the fidelity-first choice.

## The M8 roster

- **Receive-side serial** — LisaTerminal / LisaBug serial console, built on the
  SCC receive path (the transmit-side SCC is done and is their foundation).
- **Pixel-true 144-vpi interlace** — model the interleaved two-pass band geometry
  (external `PrVBand`/`PrHBand`) so the printed page has no vertical doubling.
- **Daisy wheel / Canon** — a second and third printer device through the
  `PrinterPort` seam (text-only daisy wheel; Canon inkjet).
- **The warm-reset/Widget-boot error 42** — root-cause the pre-existing
  interaction so `Machine ▸ Reset` of a Widget-booted OS works.
- **Deferred niceties** — the `pm_DevConfig` triple decode; the 2 KB
  second-Machine stall root cause; timed reboot-alarm wake and per-app symbol
  relocation (carried from M6).

## Reproduce

Prerequisites: the Rev H ROM pair (e.g. under `~/Development/LisaROMs`) and a
bootable `OS31-installed.widget` with LisaWrite installed (built by M5's install;
see `docs/m5-demo.md` and `docs/m6-demo.md`).

> A boot **WRITES** to the Widget volume, and configuring the printer mutates it
> further. Treat `OS31-installed.widget` as precious — **copy it first and drive
> the copy.** (Both the config-save and the reboot below must use the *same*
> copy — that is how persistence works.)

```sh
cp ~/Development/LisaImages/OS31-installed.widget /tmp/lisa-work.widget

LISAEMU_ROM_DIR=~/Development/LisaROMs \
swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget /tmp/lisa-work.widget --printer-dir /tmp/pngs
```

### The print flow, at the `lisadbg` prompt

```
# --- power on: boot the Widget to the desktop (the M5/M6 boot path) ---
# ... g / click through the boot menu to the Office System desktop ...

# --- configure the printer (once) ---
# open Preferences -> Connect Devices -> Serial B Connector -> Imagewriter / DMP
# File/Print -> Set Aside Everything   (writes PM + the disk snapshot)
power             # soft power-off (the M6 path)

# --- POWER CYCLE: a FRESH boot of the SAME image (relaunch lisadbg) ---
# ... boot /tmp/lisa-work.widget again -> the ImageWriter is still on Serial B ...

# --- print from LisaWrite ---
# open the document, File/Print -> Print... -> OK
g 40000000        # the raster streams out Serial B (Level-6 driven)
printer           # flush + report: bytes=9229 jobsWritten=1 pagesWritten=1
# -> /tmp/pngs/<job>.png  (the printed page; artifacts copy = m7-print-01.png)
```

### The regression checkpoint (the automated vehicle)

```sh
LISAEMU_ROM_DIR=~/Development/LisaROMs \
LISAEMU_DISK_DIR=~/Development/LisaImages \
LISAEMU_WIDGET_DIR=~/Development/LisaImages \
LISAEMU_LINKMAP_DIR="<path to Linkmaps 3.0>" \
  swift test -c release
```

- `ROMPrinterTests` boots the installed OS, scripts Preferences → Serial B →
  ImageWriter → Set Aside, **reboots** (a fresh Machine on the same write-through
  Widget), opens LisaWrite and prints — asserting Serial-B `transmittedCount >
  1000` (the deterministic proof of the whole chain: config-persistence-across-
  reboot **and** the Level-6 transport; see the frontier note on why it's
  `> 1000` rather than a pinned page).
- `PrinterPipelineTests` / the `ImageWriterInterpreter` golden tests pin the
  full-page raster robustly (FNV on non-trivial rasters, seven densities,
  LF-overflow breaks, partial flush).
- The **macOS** side is pinned by `PrintDocumentTests` (`makePDFData`: pages →
  multi-page PDF, each MediaBox from DPI) under `xcodebuild test -scheme LisaApp`.

## Screenshots

Captured to `~/Development/LisaEmu-artifacts/` (referenced by path, never
committed — they render Apple's ROM/OS-drawn UI and Apple document content, same
rule as M2–M6's artifacts):

- **Config + persistence** — `m7-connect-devices-serialb` (ImageWriter claimed on
  Serial B) · `m7-reboot-serialb-persisted` (still connected after a power cycle).
- **Print** — `m7-print-panel-lisa` (the OS's *"Print on ImageWriter Printer —
  serial port B"* dialog) · `m7-print-done-lisa` (the desktop after printing) ·
  `m7-print-01` (the printed page, an ImageWriter dot-matrix render of the
  LisaWrite document).
- **macOS panel** — `m7-print-panel-render.pdf` / `.png` (LisaApp's own
  `makePDFData` output for the same pages; identical geometry to the interactive
  `NSPrintOperation` panel).

## The M7 milestone, in one line each

- **Task 1 — the serial contract:** `RSBASE = $FCD201` chased at last; the whole
  Z8530 driver discipline derived from the OS source; the POST probe shown to be
  presence-only; PM located in disk-controller shared RAM with a boot-volume
  snapshot for persistence.
- **Task 2 — the real SCC:** `SCC8530` register-level Z8530 replaces the `0xFF`
  stub, POST/menu FNVs byte-identical.
- **Task 3 — the ImageWriter interpreter:** the `CiDev` contract derived (no
  form-feed byte; `ESC g` fast graphics; 72–160 bpi; synthetic 5×7 font),
  golden-tested.
- **Task 4 — THE LISA PRINTS ⭐:** live Office System → Serial B → pages; the
  Level-6 Tx-empty interrupt rework; PM persistence free via the boot-volume
  snapshot; `lisadbg --printer-dir` PNGs + the LisaApp print panel.

**The north star is met:** the emulated Lisa **prints** — configured through its
own Preferences, persisting the config across a power cycle, and streaming a real
ImageWriter raster out Serial B to a PNG or the macOS print panel — with the
honest caveats above (interlace vertical doubling; receive-side serial and the
other printer devices are future).
