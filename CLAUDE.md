# CLAUDE.md

LisaEmu is a from-scratch Apple Lisa 2/10 emulator in Swift (a learning
project). The north star — boot the real Rev H ROM off a Widget image to the
Office System desktop with working input, clock, persistence, and printing —
is **met**; work proceeds in milestones (see the README table; next is M8).
Design spec: `docs/superpowers/specs/2026-08-03-lisa-emulator-design.md`.

## Layout

- SPM package: `LisaCore` (machine/bus/devices), `CMusashi` (vendored C 68000),
  `LisaShell` (Foundation-only host layer: EmulationController, printer
  pipeline), `lisadbg` (headless debugger/driver).
- `LisaApp/` — SwiftUI macOS app via XcodeGen (`LisaApp/project.yml`; the
  `.xcodeproj` is gitignored — regenerate it, never commit it).

## Build & test

```sh
swift build
swift test                  # no-env: ROM/image-gated suites auto-skip; fast, always run this
xcodegen generate --spec LisaApp/project.yml
xcodebuild -project LisaApp/LisaApp.xcodeproj -scheme LisaApp test
```

Full-env runs (release, one process at a time; ROMPrinterTests alone ~60s):

```sh
LISAEMU_ROM_DIR=~/Development/LisaROMs \
LISAEMU_WIDGET_DIR=~/Development/LisaImages \
  swift test -c release
LISAEMU_TH_DIR=<tomharte-dir> swift test -c release   # expected EXACTLY 807147 passed / 0 failed / 192913 known-failure skips
```

## Assets — never commit, handle with care

- ROMs: `~/Development/LisaROMs`. Disk images: `~/Development/LisaImages`.
  **Neither may ever enter the repo or its history** (licensed material; an
  M5 near-miss forced a squash-merge — keep binaries out of branches too).
- `OS31-installed.widget` is both the canonical bootable image **and the
  user's living daily-driver disk** (their documents and config live on it).
  **A boot WRITES to the image — always copy it and boot the copy.** Never
  "clean up" or regenerate it.
- Screenshots/renders/captures go to `~/Development/LisaEmu-artifacts/`,
  outside the repo.

## Vendored Musashi

Never hand-edit `Sources/CMusashi`. All changes are patches applied by
`Scripts/vendor-musashi.sh` so they survive re-vendoring.

## Documentation map & conventions

- `docs/hardware-notes.md` — citation-backed hardware truth. Every constant
  cites the evidence (OS source `file:line`, ROM trace, or live capture);
  claims without evidence don't go in.
- `docs/rom-trace-notes.md` — boot-trace checkpoints; regression anchors are
  FNV hashes + pixel counts pinned by env-gated tests.
- `docs/mX-demo.md` — per-milestone walkthroughs (m7-demo has printer
  troubleshooting).
- **Strike-not-erase**: overturned claims stay visible as `~~struck~~` text
  with a dated correction next to them, in docs and reports alike. Specs are
  annotated, not rewritten.
- Bounded diagnostic logs (capped arrays + drop counters) are the house
  pattern for device-level "unexpected byte" telemetry.

## Workflow

- Milestone branches + PR; **the user reviews and merges on GitHub** (squash
  preferred). Don't merge or push to main without being asked (docs-only
  hygiene commits to main are OK).
- **The user runs live-app/manual emulator tests themselves** — prepare the
  code, say it's ready, and let them run it and paste results. Quick builds
  and the no-env `swift test` are fine to run directly. Avoid token-heavy
  agent fan-outs; this project is run lean.
- Session/resume state lives in the SDD ledgers
  (`.superpowers/sdd/<date-milestone>/progress.md`, gitignored) and in
  Claude's persistent memory — not in this file.

## Debug facilities

- `lisadbg --rom <dir> [--widget/--disk <img>] [--printer-dir <d>]
  [--printer-raw <f>]`; prompt commands include `g`, `gu <addr>` (run until
  PC = breakpoint), `gw <addr>` (run until a byte changes), `iot clear`/`iot
  limit <n>` (the ioTrace cap is a TOTAL, not a window — it fills during
  POST, so clear it before a slice whose I/O you need to see), `guest
  mac|lisa` (which guest's cursor the click/drag steering reads back —
  MacWorks keeps its mouse in Mac low memory, not the Lisa OS's cells),
  `sc`/`sca`, `click`, `dclick`,
  `press/release/moveto/drag`, `type`, `insert/eject`, `printer`, `reset`,
  `power`.
- Every closed print job auto-dumps raw wire bytes + page rasters +
  unknown-escape log to `~/Library/Application Support/LisaEmu/PrintDebug/`
  (`PrintDebugDump`; override dir with `LISAEMU_PRINT_DEBUG_DIR`). Check
  there first for any print misbehavior — and if a print looks garbled,
  suspect a **stale app build** before the emulator.
