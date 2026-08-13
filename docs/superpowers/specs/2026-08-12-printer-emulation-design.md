# LisaEmu Printer Emulation — Design

**Date:** 2026-08-12
**Status:** Approved design, pre-implementation
**Author:** jdawson + Claude

> **ACHIEVED (M7 close, 2026-08-13).** This design shipped: the emulated Lisa
> prints from the live Office System through a register-level Z8530 SCC on Serial
> B into `ImageWriterInterpreter`/`PrintJobSpooler`, captured as `lisadbg` PNGs
> and the LisaApp macOS print panel. Three design assumptions were **overturned by
> the OS source** and are annotated inline below (strike-not-erase):
> 1. **No form-feed byte.** The spec assumed "page emitted on form feed" + a
>    "form-feed + serial-idle" job boundary. The `CiDev` driver emits **no
>    `chr(12)`**; a page ejects on line-feed accumulation MOD the page length, and
>    jobs close on a host-time idle window alone (§12.5, Task 3).
> 2. **Level-6 Tx-empty interrupt, not transmit-side polling.** The driver polls
>    only the first byte and drives bytes 2..N off the **Level-6 Tx-empty
>    interrupt** (§11.4, Task 4) — the "transmit-buffer-empty status the driver
>    expects" is an interrupt path, not a poll.
> 3. **PM persistence: resolved FREE, not a separate roster item.** The open
>    question (below) resolved to ≈0 emulator code — the boot-volume snapshot the
>    Widget already writes through carries the config across a power cycle (§11.6,
>    Tasks 1+4).
>
> See `docs/m7-demo.md`, `docs/rom-trace-notes.md` "Checkpoint N", and
> `task-1..5-report.md`.

## Purpose

Print from the Lisa Office System (LisaWrite et al.) to the user's real
printer: the emulator interprets the Lisa's own printer output and hands
rendered pages to macOS's standard print panel. WYSIWYG fidelity — what the
Lisa renders is what prints.

**Chosen shape (from brainstorm):** Apple Dot Matrix / ImageWriter family
(the OS's `ciprint` driver, a raster graphics device) on **Serial B**, via a
new register-level **Z8530 SCC** emulation. Rejected alternatives: daisy
wheel (text-only output, same SCC cost, less fidelity — may ride later as a
bonus device); parallel-port printer (requires expansion-slot card
emulation, a whole new subsystem).

## Data flow

```
LisaWrite ▸ Print
  → OS ciprint driver (LIBPR/LibPr-ciprint) renders + streams ImageWriter
    escape codes out Serial B
  → SCC8530 (LisaCore) — new, register-level, transmit path
  → PrinterPort byte sink (Device seam, like COPS/floppy/Widget)
  → ImageWriterInterpreter (pure Swift, UI-free) — escape codes → dot rows
    → 1-bit page rasters; page emitted on form feed
      [M7 DEVIATION: no form-feed byte exists — page ejects on LF accumulation
       MOD page-length; §12.5]
  → Job spooler — pages accumulate; job closes on form-feed + serial-idle
    window (the ImageWriter protocol has no end-of-job marker)
      [M7: correct that there's no end-of-job marker; the boundary is the
       serial-idle window ALONE — there is no form-feed byte to combine it with]
  → LisaApp: standard macOS print panel (NSPrintOperation) with the
    rendered pages ("Save as PDF" comes free)
  → lisadbg: same tap headlessly — pages written as PNGs (test vehicle)
```

## Components

- **`Sources/LisaCore/SCC8530.swift`** — the frontier. Register-level Z8530,
  channels A/B, at the real Lisa base address (never chased — hardware-notes
  §"RSBASE not chased"; deriving it from the OS serial-driver sources is the
  first implementation task, the established evidence-first method, every
  constant cited). Scope: **transmit-side printing only** — the WR/RR
  register subset the OS driver actually exercises, transmit-buffer-empty
  status/interrupts per what the driver expects [M7: the "interrupts" clause is
  load-bearing — the driver polls only byte 1 and drives bytes 2..N off the
  Level-6 Tx-empty interrupt, wired in Task 4; §11.4], modem/handshake status
  lines pinned "printer ready," baud rate accepted and ignored (no real
  wire). Receive path remains a stub. The ROM's existing SCC probe (the
  `$D241`-era 0xFF stub satisfies POST today) must keep passing — POST/menu
  anchors are pinned.
- **`Sources/LisaCore/PrinterPort.swift`** — thin byte-sink seam between SCC
  channel B transmit and any printer implementation (the HLE↔LLE-style
  swap seam the spec's Device protocol prescribes).
- **`Sources/LisaShell/ImageWriterInterpreter.swift`** — pure, testable:
  C.Itoh 8510/ImageWriter escape-code state machine (graphics-mode dot
  columns, line spacing, margins, horizontal density modes; text-mode bytes
  rendered with the printer's font behavior as derived from the `ciprint`
  driver's actual usage — the OS source is the contract, the printer manual
  the cross-check) → fixed-size 1-bit page raster at printer dpi → emits
  completed pages (form feed or page-length overflow). [M7: shipped as
  page-length (LF-accumulation MOD `cPg144ths`) overflow ONLY — no form-feed byte
  exists in the `CiDev` path; §12.5. Text renders through a hand-authored
  synthetic 5x7 font (real column data lives in external asm).]
- **Job spooler** (LisaShell) — collects pages; closes the job after
  form-feed + a short transmit-idle window [M7: on the transmit-idle window ALONE
  — no form-feed byte; `PrintJobSpooler`, §12.5]; publishes the job to the app the
  same way frames/status publish today (thread-safe, main-thread hand-off).
- **LisaApp** — print-job presentation: NSPrintOperation with the standard
  panel per job; a Machine-menu indicator for "Printer connected (Serial B)"
  (default: connected). Cancel in the panel discards the job — the Lisa
  already believes it printed, exactly like tearing paper out of a real
  ImageWriter.
- **lisadbg** — `printer` status command + pages-to-PNG capture dir flag for
  headless testing.

## Lisa-side configuration

The user configures the printer once inside the Lisa: Preferences → Device
Connections → Serial B → Apple Dot Matrix-family printer. This is authentic
Office System workflow and scriptable with the M6 `click`/`type` primitives
for the integration test.

**Open question the evidence task must answer:** whether that configuration
survives a power cycle in our machine. It lives in Lisa "parameter memory,"
whose physical home this project has never chased (M5 established the OS
*reads* PM during boot device-config; where PM lives and whether our machine
retains it across power-off is unknown). If PM persistence is cheap, it
joins this milestone; if not, per-boot reconfiguration is documented as a
known limitation and PM persistence becomes its own roster item.

> **RESOLVED (M7, FREE — §11.6).** PM lives in disk-controller shared RAM
> (`$FCC180`), which `floppy.reset()` zeroes, so the RAM copy is volatile — but
> real cross-power-cycle persistence is the boot-volume **snapshot**
> (`Write_PMem` = `Paramem_Write` + `PMSnapshot`; reloaded at `INIT_CDS`/
> `READ_PMEM`), and our Widget write-through already carries it. So the config
> survives a power cycle **with zero emulator code** — the "cheap, joins this
> milestone" branch, at its limit. Task 1 had flagged a possible ~20–40-line
> `reset()` PM-sparing fix as *maybe required*; it was **not** required and was
> deliberately not taken (§11.6, strike-not-erase). Caveat: the config→reboot flow
> requires a **full power cycle of the SAME image** (a fresh boot, not a warm
> `Machine.reset()`), faithful to real hardware. The exact `pm_DevConfig`
> (slot,chan,dev) triple was not decoded (CPU-domain-dependent monitor read);
> the load-bearing proof is the observed round-trip.

## Error handling

- Unknown/unimplemented escape codes: logged via the house bounded-log
  pattern (cap + drop counter), rendered as no-ops — never crash or abort a
  page.
- Malformed/truncated jobs: the idle window flushes whatever pages exist;
  a job with zero complete pages emits the partial page rather than nothing.
- Print-panel cancel: job discarded silently.
- SCC writes outside the modeled register subset: logged bounded, inert —
  same convention as every device stub before it.

## Testing

- **SCC unit tests** from the derived driver contract (register sequences
  the OS actually performs, cited; transmit-ready behavior; the ROM-probe
  regression stays green — POST/menu FNV anchors unmoved).
- **Interpreter golden tests**: synthetic escape-code streams → raster
  hashes (all-text page, graphics page, mixed, density changes, unknown-code
  resilience). No Apple data needed — streams are synthesized.
- **Integration checkpoint** (env-gated like K/L/M): boot the installed
  Office System, script Preferences printer config + a LisaWrite print via
  `click`/`type`, assert pages produced and pin the raster (FNV) of a
  deterministic printed page.
- Full prior-pin matrix as always; TomHarte untouched by construction
  (no CPU/Machine-loop changes expected; if the SCC needs Machine event
  scheduling, existing seams suffice).

## Constraints (inherited house rules)

Evidence-gated constants cited file:line (OS serial + `ciprint` sources;
ImageWriter/C.Itoh references as cross-check); both-docs rule +
strike-not-erase; TDD; no Apple-derived data committed (printed-page
artifacts of Apple content stay outside the repo; synthetic test pages are
fine); every prior pin green or stop-the-line; canonical-image copy
discipline for integration tests.

## Explicitly out of scope

Receive-side serial (LisaTerminal/LisaBug console — the SCC built here is
their foundation, but they're separate future work); daisy wheel and Canon
inkjet devices (the PrinterPort seam accommodates them later); real serial
hardware passthrough; expansion-slot parallel cards.
