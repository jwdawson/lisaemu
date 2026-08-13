# M7 — Printing: Serial B → ImageWriter → PNG / the macOS print panel

M7 makes the emulated Lisa **print**. The OS's C.Itoh/ImageWriter driver puts a
raster byte stream on Serial B; the emulator turns it back into pages.

```
OS ImageWriter driver → SCC channel B ($FCD205) → PrinterPort → ImageWriterInterpreter
    → PrintJobSpooler (idle-window job close) → { lisadbg PNG | LisaApp NSPrintOperation }
```

## The pieces (Tasks 1–4)
- **SCC8530** (Task 2): register-level Z8530; channel-B transmit forwards bytes
  to a `PrinterPort`. Task 4 adds the **Level-6 Tx-empty interrupt** (below).
- **ImageWriterInterpreter + PrintJobSpooler** (Task 3): the ciprint escape
  stream → 1bpp page rasters, grouped into jobs that close on a 2 s host-time
  idle window (there is no form-feed byte — §12.5).
- **PrinterPipeline** (Task 4): bundles the `PrinterPort` adapter + interpreter
  + spooler into one attachable unit. `EmulationController` and `lisadbg` both
  wire it the same way (`bus.scc.channelB.printerPort = pipeline.printerPort`).

## Driving a real print (headless, `lisadbg`)

The canonical `OS31-installed.widget` already has **LisaWrite** installed and a
document ("This is a test of the lisa write application"). Print it:

1. **Configure the printer once (the OS's own Preferences).** Boot → open
   **Preferences** → **Connect Devices** → **Serial B Connector** →
   **Imagewriter / ‖ DMP** → **File/Print ▸ Set Aside Everything** (saves the
   config to parameter memory + a disk snapshot on the Widget). See
   `m7-connect-devices-serialb` in the artifacts.
2. **Reboot.** `INIT_CDS` reads the printer config from PM only at boot. The
   config **persists across a power cycle** via the write-through Widget
   snapshot (`m7-reboot-serialb-persisted`) — no emulator PM code needed (§11.6).
3. **Print.** Open the document, **File/Print ▸ Print… ▸ OK**. The dialog now
   reads *"Print on ImageWriter Printer — serial port B"* (`m7-print-panel-lisa`).
   The full raster streams out Serial B; `lisadbg --printer-dir` writes it as a
   PNG (`m7-print-01` — the document text, an ImageWriter dot-matrix render).

```
LISAEMU_ROM_DIR=~/Development/LisaROMs \
  swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --widget /tmp/copy.widget --printer-dir /tmp/pngs
# ... drive the UI (click/press/moveto/release/type) ...
printer     # flush + report: Serial-B bytes=9229 jobsWritten=1 pagesWritten=1
```

New `lisadbg` commands: **`--printer-dir <path>`** (jobs → per-page PNGs),
**`printer`** (flush the open job + report counters), **`reset`** (warm reset).

## The macOS app

A closed job arrives on `AppModel.onPrintJob` → the standard **`NSPrintOperation`
print panel** renders the pages (each sized from its DPI: Portrait Hi-Res =
576×792 pt = 8"×11"). "Save as PDF" works from the panel; the pure
`PrintDocument.makePDFData` produces the identical geometry
(`m7-print-panel-render.pdf/.png`). The **Machine** menu carries a
**"Printer Connected (Serial B)"** indicator (default connected).

## Two divergences the live OS exposed (the point of the task)

1. **Level-6 Tx-empty interrupt (fixed).** First live print emitted **one byte**
   then stalled. The OS `XMIT` ISR sends only the first byte polled and drives
   every byte after off the Level-6 Tx-empty interrupt (§11.4 step 5) — which
   Task 2 deliberately left unwired. Wiring it (`SCC8530.irqAsserted` → CPU
   Level 6) made the same print emit its full 9229-byte stream. Boot is
   unaffected (channel B is never inited at boot; all FNV checkpoints identical).
2. **Warm reset + Widget boot fails (known gap, out of M7 scope).** A warm
   `Machine.reset()` followed by a Widget boot hits **boot error 42** at the
   menu, whereas a fresh power cycle boots cleanly. So the printer config→reboot
   flow uses a fresh boot (a new process in `lisadbg`; a fresh controller in the
   integration test), matching real "power cycle" behavior. The warm-reset/
   Widget-boot interaction is a separate issue (the app's Machine ▸ Reset of a
   *Widget-booted* OS), noted for a later milestone.

## Raster fidelity note
The printed page shows the correct text but with a **vertical doubling**: the
ImageWriter's two-pass 144-vpi interlace lands adjacent half-bands on adjacent
rows under the interpreter's simplified vertical mapping (Task 3 decision 3,
flagged there). Content is legible and correct; true interleaved-pass geometry
(driven by the external `PrVBand`/`PrHBand` asm, not the Pascal source) is a
follow-up.
