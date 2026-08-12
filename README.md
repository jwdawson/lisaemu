# LisaEmu

A from-scratch **Apple Lisa 2/10 emulator** written in Swift for macOS — built to deeply
understand the Lisa hardware and the Lisa OS source code released by Apple and the
Computer History Museum in 2023.

**Current status:** the real Rev H boot ROM completes its power-on self-test and boots
the Lisa Office System 3.1 the whole way to a **working machine you can use** — the full
daily loop runs end to end. The Office System installs from its floppies onto a blank
Widget hard-disk image, boots clean off that hard disk to the **Office System desktop**,
and there responds to a **live mouse, keyboard, and clock**: real Filer work (open the
disk, tear off and keyboard-rename a folder), a LisaWrite tool installed from its diskette
and **typed into**, and a **soft-power shutdown** through the OS's own path (which leaves
the next boot free of the dirty-volume dialog). The clock is the emulated COPS real-time
clock, faithful to the Lisa's 4-bit year field — it rolls every 16 years, so a 2026 host
clock is displayed by the OS as 1994.

## Milestones

| Milestone | Result |
|---|---|
| M0 — Scaffold | Musashi 68000 core wrapped as a Swift package; 807,147 TomHarte conformance vectors passing (0 failing) |
| M1a — MMU | Hardware SORG/SLIM MMU, real bus errors, I/O dispatch; ROM runs its self-test |
| M1b — Self-test | The real boot ROM completes POST and draws the boot menu |
| M1c — Live app | Interactive SwiftUI window: host keyboard/mouse drive the ROM live |
| M2 — Floppy boot | The OS 3.1 install disk boots; the OS loader runs off the real disk image |
| M3 — OS executes | Three MMU-semantics fixes; the loaded OS image executes its own kernel code |
| M4 — OS alive | Live interrupts, OS scheduler, floppy write-through, real-68000 fault frames; **boots to the Office System installer** |
| M5 — Widget HD | Widget/ProFile hard-disk HLE; the Office System installs onto a blank Widget image and **boots off the hard disk to the desktop**, mouse live |
| M6 — Real machine | The full daily loop: RTC (real clock), OS-driven soft-power shutdown, Filer work + LisaWrite typed into — **mouse, keyboard, and clock all live** |
| M7 — next | Timed reboot-alarm wake; per-app symbol relocation; deeper app coverage (LisaCalc/Draw, printing) |

Each milestone has a demo document under [`docs/`](docs/) (`m1b-demo.md` … `m6-demo.md`)
with reproduction steps, and the project keeps two citation-backed engineering records:
[`docs/hardware-notes.md`](docs/hardware-notes.md) (every register, address, and constant,
with sources) and [`docs/rom-trace-notes.md`](docs/rom-trace-notes.md) (the boot-trace
journey, checkpoint by checkpoint, including every refuted hypothesis — struck through,
never erased).

## Architecture

- **`LisaCore`** — pure Swift emulation package, no UI dependencies.
  - `CMusashi` — the [Musashi](https://github.com/kstenerud/Musashi) 68000 core, vendored
    as a C target. Local patches (address-error emulation, real 68000 group-0 bus-error
    frames, jump-gate fault frames the Lisa OS's syscall engine requires) are applied by
    the anchored, fail-loud [`Scripts/vendor-musashi.sh`](Scripts/vendor-musashi.sh).
  - `Machine` / `Bus` / `MMU` — single master clock, cycle-stamped event queue, and the
    Lisa's segmented MMU (128 segments × 4 domains) in the bus path from day one.
  - Devices — two register-accurate 6522 VIAs, COPS keyboard/mouse/clock/soft-power
    controller (HLE, host-time RTC), Sony 400K floppy controller (HLE, DC42 images,
    session-scoped write-through), Widget/ProFile hard-disk controller (HLE, persistent
    image), video timing with vertical-retrace interrupts.
- **`LisaShell`** — emulation-thread harness: drift-corrected 5 MHz governor, frame
  publication, input mailbox.
- **`LisaApp`** — SwiftUI macOS app (Xcode project generated with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen)): live framebuffer, pointer capture,
  drag-and-drop disk insertion.
- **`lisadbg`** — command-line debugger: trace, disassemble, memory/MMU inspection,
  screenshots, scripted `bootdisk` boot harness, and symbol overlay loaded at runtime
  from the Lisa OS Linkmaps.

## Building and running

Requirements: macOS 14+, Swift 6 toolchain, XcodeGen (for the app).

```sh
# Core package + debugger
swift build -c release

# Command-line boot to the installer (ROMs/images not included — see below)
swift run -c release lisadbg --rom ~/Development/LisaROMs \
    --disk ~/Development/LisaImages/OS31_Install_1.dc42
# then at the prompt:
#   bootdisk        — scripted menu click; boots the OS
#   sc              — screenshot the framebuffer

# The SwiftUI app
cd LisaApp && xcodegen generate --spec project.yml && open LisaApp.xcodeproj
```

### External assets (required, not included)

This repository contains **no Apple-derived data** — no ROMs, no disk images, no OS
source, no symbol tables. You need, from
[bitsavers](https://www.bitsavers.org/bits/Apple/Lisa/):

- Rev H boot ROM images (`341-0175-H` high / `341-0176-H` low)
- Lisa Office System 3.1 install disk images (DC42; convert flux formats offline)

The Lisa OS source tree (Apple/CHM 2023 release, academic license) is used as a
read-only debugging oracle and for the runtime symbol overlay; it is referenced by
local path only and never bundled.

## Testing

```sh
swift test                      # 252 tests; suites needing real ROMs/disks/linkmaps skip

# Full matrix with real assets:
LISAEMU_ROM_DIR=~/Development/LisaROMs \
LISAEMU_DISK_DIR=~/Development/LisaImages \
LISAEMU_LINKMAP_DIR="<path to Linkmaps 3.0>" \
swift test -c release

# CPU conformance (TomHarte/ProcessorTests, ~1M vectors):
LISAEMU_TH_DIR=<path to 68000/v1 JSONs> swift test -c release --filter TomHarteTests
```

The integration suites pin the boot bit-exactly: boot-menu framebuffer hash, POST
markers, blocks read off the disk, interrupt delivery, and the installer-screen
framebuffer hash.

## License

The emulator's own code is [MIT licensed](LICENSE). Apple's ROMs, disk images, and the
Lisa OS source remain Apple's; obtain them separately for personal study.

## Acknowledgments

- [Musashi](https://github.com/kstenerud/Musashi) by Karl Stenerud — the 68000 core
- [TomHarte/ProcessorTests](https://github.com/TomHarte/ProcessorTests) — 68000 conformance vectors
- The Computer History Museum and Apple for the 2023 Lisa source release
- [bitsavers.org](https://www.bitsavers.org) for preserving the ROMs, disks, and manuals
- LisaEm and MAME, whose Lisa emulations served as cross-check oracles
