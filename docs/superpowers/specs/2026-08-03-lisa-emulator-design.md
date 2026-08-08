# LisaEmu — Apple Lisa 2/10 Emulator Design

**Date:** 2026-08-03
**Status:** Approved design, pre-implementation
**Author:** jdawson + Claude

## Purpose and goals

A from-scratch Apple Lisa emulator built primarily for **learning** — to deeply
understand the Lisa hardware and the Lisa OS 3.1 source code released by Apple/CHM
(local copy at `~/Development/Lisa_Source`). Existing emulators (LisaEm, MAME,
IDLE) are references and cross-check oracles, not competitors.

**North star:** boot from power-on through the real Rev H boot ROM and Lisa OS 3.1
to the Office System desktop, with working mouse, keyboard, and clock.

**Secondary product:** a debugger that makes the Lisa OS source *legible while
running* — MMU domain inspection and symbol overlay from the shipped Linkmaps.

## Decisions (fixed)

| Decision | Choice |
|---|---|
| Target machine | Lisa 2/10 (Sony 400K floppy + internal Widget HD) first |
| Language / platform | Swift, native macOS app |
| 68000 core | Wrap Musashi (C) via an SPM C target; Swift core possible later behind the same interface |
| Peripheral sub-CPUs (COPS421, 6504 floppy, Widget controller) | **Staged hybrid**: behavioral (HLE) implementations first behind stable `Device` interfaces; low-level (LLE) replacements as later projects |
| Disk image formats | DC42 and raw sector images (with tags) natively; flux formats (A2R) converted offline with Applesauce tooling |
| Project location | `~/Development/LisaEmu`, its own git repo, separate from the licensed source dump |

## External prerequisites (not in this repo, not redistributable)

From `https://www.bitsavers.org/bits/Apple/Lisa/`:

- `firmware/REV_H_BOOT_SOURCE_1/2.IMAGE` — Rev H boot ROM (+ its source listing, used as a debugging oracle)
- `firmware/342-0172A_IO_28L22_U48.BIN` — I/O board ROM
- `firmware/COP421-HZT_LisaIO.zip` — COPS ROM dump (only needed for the future LLE COPS stage)
- `office_3.x/Lisa_Office_System_3.1.7z` — OS 3.1 install disks (convert to DC42 if flux-format)
- `workshop_3.0/` — Workshop toolchain (stretch milestone)

The Lisa Hardware Reference Manual (bitsavers PDFs) is the authority for exact
register addresses, bit layouts, and video timing. **This spec commits to
structure, not to numeric constants from memory** — all constants get sourced
from the manual or the boot ROM listing during implementation.

License note: the OS source tree is under Apple's academic license (no
redistribution); ROMs/disk images are personal-study material. The emulator's own
code is ours, but we never bundle ROMs, images, or Apple source with it.

## §1 Architecture

Two layers:

- **`LisaCore`** — pure Swift package, no UI dependencies.
  - `CMusashi` — C target wrapping Musashi; small shim routes Musashi's memory
    callbacks into the bus.
  - `Machine` — owns everything; single-threaded core loop driven by one master
    clock (CPU cycles @ 5 MHz). Runs CPU until the next scheduled event, then
    dispatches from a cycle-stamped event queue (vsync, VIA timers, device
    completion interrupts). No per-device threads; determinism over parallelism.
  - `Bus` — memory map. Every access: Musashi callback → MMU translate (logical →
    physical + access check, per current domain) → RAM / ROM / framebuffer /
    device dispatch.
  - `Device` protocol — `read(addr)`, `write(addr, value)`, `tick(event)`, reset,
    IRQ plumbing, and snapshotable state. The HLE↔LLE swap seam.
- **`LisaApp`** — SwiftUI macOS app. Framebuffer view (vImage 1-bit expansion
  into a CGImage, aspect-corrected; Metal only if profiling ever demands it),
  keyboard/mouse capture → COPS events, menus for
  power/reset/disk images. Emulation runs on its own thread; UI↔core
  communication via input-event queue in, frames + status out.

## §2 MMU and memory map

The MMU is built first and sits in the bus path from day one.

- 24-bit logical space ÷ **128 segments × 128 KB** (matches `maxmmusize = 131072`
  in the OS memory manager). Top 7 address bits select the segment register pair.
- **4 domains** (register sets). OS = domain 0; users = 1–3. Domain selected by
  the two context bits the OS writes at `$FCE008–$FCE00E`
  (`Lisa_Source/LISA_OS/OS/source-starasm1.text.unix.txt:234-256`).
- Per segment: **SOR** (origin) + **SLR** (limit + access type): read/write RAM,
  read-only, **stack** (grows down, limit-checked — backs the OS `ds_stack`
  segments), memory-mapped I/O, invalid.
- Violations assert **bus error** → `m68k_pulse_bus_error`. This path is
  first-class: the OS uses faults for protection and swap-in.
- **Setup mode** at reset: translation bypassed, boot ROM visible at address 0
  for reset vectors; ROM programs MMU then leaves setup mode. Modeled as a bus
  flag.
- Swift shape: `struct MMU` with 4 × 128 segment registers and a pure
  `translate(logical, domain, isSupervisor, isWrite) -> PhysicalAccess | Fault`.
  No caching until profiling demands it.
- Physical targets: RAM (≤ 2 MB; parity modeled always-good initially), 16 KB
  boot ROM, framebuffer (ordinary RAM, base set by video address latch, 32 KB
  for 720×364×1bpp), I/O space (devices below + MMU/system control registers).

## §3 Devices

- **Video** — passive scanout + **vertical-retrace interrupt** (~60 Hz; exact
  timing from the manual). Vsync event: raise IRQ, snapshot framebuffer to UI.
- **2 × 6522 VIA** — full register-accurate implementation (timers, IFR/IER,
  ports, shift register). Cheap "LLE" — it is a chip, not a CPU — and both COPS
  and Widget/parallel hang off VIAs.
- **COPS (HLE)** — byte-protocol endpoint behind its VIA: keyboard make/break
  codes, mouse deltas, RTC (host-time backed), power/reset events. LLE-from-ROM
  is a future stage.
- **Floppy controller (HLE)** — models the 6504's observable behavior: commands
  via shared RAM (per the 68000-side protocol in `source-twiggy`/`SOURCE-SONY`:
  clamp/format/eject, per-drive status bits, completion interrupts), plausible
  completion delays (OS timeouts), serves 512-byte sectors **+ tag bytes** from
  DC42/raw images. Tags are mandatory: Lisa FS block labels (Scavenger fodder)
  live there.
- **Widget HD (HLE)** — ProFile-family block protocol (read/write/spare, status
  bytes) over a 10 MB image file. Boot volume for OS 3.1; retry/status semantics
  exercised by `source-PROFILE` logic.
- **SCC (Z8530)** — register-level stub first (satisfy ROM/OS probes); later
  bridged to host PTYs (LisaTerminal, LisaBug serial console).
- **System glue** — interrupt priority encoder to 68000 levels, parity-error
  latch (inert initially), power/config latches, **serial-number PROM**
  (synthesized valid serial; OS reads machine ID — FS stores it for theft
  protection).

## §4 App shell and debugger

**Shell (thin):** one window — framebuffer, status strip (power, disk activity,
speed), menus (power on/off via COPS, reset, insert/eject floppy, choose Widget
image). Speed toggle (real-time vs unthrottled). Drag-and-drop disk images.
Deferred: sound, full-screen, config UI.

**Debugger (bring-up tool from day one),** separate window:

- CPU + disassembly (Musashi dasm): pause, step, step-over, run-to, breakpoints.
- Memory viewer: physical or per-domain logical views.
- MMU inspector: live 4 × 128 decoded segment table, current domain highlighted.
- **Symbols: load `Lisa_Source/LISA_OS/Linkmaps 3.0` maps** → names in
  disassembly, break on `SCHEDULER.SelectProcess` by name. *(Project-history
  note, M4 Task 2: the loader + `d`/`t`/status/`sym` annotation are built
  (`LinkmapSymbols.swift`, `lisadbg`'s `sym`/`symbase` commands) — the
  "break on `SCHEDULER.SelectProcess` by name" half is not (no breakpoint
  command exists yet in `lisadbg`), and the available Linkmaps only cover
  Office System applications, never the OS kernel, so kernel-space names
  like `SCHEDULER.SelectProcess` have no data to resolve against yet
  regardless — see `task-2-report.md`.)*
- I/O trace: filterable device register + interrupt log.
- **Whole-machine snapshot save/restore** (forces clean device state ownership;
  turns 90-second boots into instant repro).

Not building: scripting, remote debug protocol, rewind.

## §5 Testing and milestones

Oracles per layer:

- **CPU/shim:** TomHarte/ProcessorTests 68000 JSON vectors run through the full
  Musashi + shim + bus stack.
- **MMU:** exhaustive unit tests (translation, limits, stack grow-down, domain
  isolation, setup mode, supervisor checks).
- **VIA:** datasheet-driven unit tests.
- **HLE devices:** protocol tests (command in shared RAM → sectors + tags +
  completion IRQ; Widget status/retry sequences).
- **Integration:** boot ROM POST (failure codes map to the ROM source listing);
  OS `SYSTEM_ERROR` codes map to the OS source. Cross-check LisaEm/MAME when
  stuck.
- **Regression:** headless boot from snapshot + framebuffer-hash checkpoints.

Milestones (each a demo):

1. **M0 Scaffold** — SPM builds; Musashi runs test code from emulated RAM;
   debugger shows disasm + registers.
2. **M1 Self-test** — real boot ROM passes POST, draws boot menu (MMU, video,
   VIAs, COPS basics, vsync). Most unknowns die here.
3. **M2 Floppy boot** — install disk loads; kernel starts (watch with symbols).
   *(Project-history note, 2026-08-06: this line's two clauses landed as two
   separate milestones in the actual build order. "Install disk loads" ✓ —
   closed by the project's own M2 (`docs/m2-demo.md`): the loader runs from
   RAM and reads the LFS off the floppy. "Kernel starts" — closed by the
   project's own M3 (`docs/m3-demo.md`), honestly stated: the loaded OS
   image EXECUTES its own initialization code [MMU domain-0/1 bootstrap,
   127 `trap #6` calls, then reading and entering the OS image itself at
   `$520000`], and is currently blocked at the OS's own COPS-driver
   handshake — a new subsystem boundary, not a bug, deferred to the
   project's M4. ~~Symbol-overlay debugging (the "watch with symbols" half
   of this line) is unimplemented; the debugger's Linkmap-symbol feature
   per §4 has not been built yet.~~ **Superseded (M4 Task 2, 2026-08-06):**
   built — `lisadbg` loads `Lisa_Source/LISA_OS/Linkmaps 3.0` (or
   `LISAEMU_LINKMAP_DIR`) and annotates `d`/`t`/status output and a `sym`
   lookup command with resolved `UNIT.PROC+0xNN` symbols
   (`LinkmapSymbols.swift`). Honest finding: the "watch with symbols" line
   assumed the Linkmaps would cover the OS kernel being traced; they
   don't — all 22 files in both Linkmaps directories are Office System
   application/library maps (Filer, LisaWrite, sys1lib, ...), so kernel
   addresses like the `$520000+` frontier currently resolve to nothing. The
   overlay is real and works (verified against a real, cited symbol), it
   just has no data for the address range M3/M4's trace needs yet — see
   `task-2-report.md`.)*
   *(Project-history note, 2026-08-07: the "kernel starts" clause is now closed
   far beyond "starts". The project's own M4 (`docs/m4-demo.md`) carried the
   loaded OS from M3's COPS-handshake stop all the way to the **Lisa 7/7 Office
   System 3.0 installer dialog live on screen** — the OS takes live interrupts
   into its own `Level1`/`Level2` handlers, runs its multi-domain scheduler,
   reaches user mode, and draws the installer UI. It idles there awaiting mouse
   input; an Install attempt correctly reports "can't find a suitable disk"
   because no hard disk is modeled yet [deferred to the project's M5 = Widget/
   ProFile HLE]. See `docs/rom-trace-notes.md` "Checkpoint E/F/G" and
   `task-4-report.md`.)*
4. **M3 Widget** — install OS 3.1 onto Widget image in-emulator; boot from HD.
   *(Project-history note, 2026-08-06: not yet reached by the project's own
   milestone numbering — see the M2/M3 note above for how this spec's
   numbering diverged from the actual build order.)*
   *(Project-history note, 2026-08-08: **ACHIEVED** by the project's own M5
   (`docs/m5-demo.md`). Both clauses landed: the real Office System installer,
   driven in-emulator, **installs OS 3.1 onto a blank Widget image** — the
   Widget/ProFile hard-disk HLE answers `PROF_INIT`, the 19456-block disk is
   initialized, and five install floppies copy across five live media swaps to
   the installer's own "software has been installed" completion (leaving a
   bootable 10 MB image at `~/Development/LisaImages/OS31-installed.widget`); and
   that installed image **boots from the HD** — the boot ROM's own `prof_entry`
   parallel-port routine reads block 0 off the Widget and the OS loader + OS come
   up entirely off the disk. See `docs/rom-trace-notes.md` "Checkpoint H/I/J/K"
   and `task-2/3/4-report.md`. The single-block `T_Seagate` protocol is what the
   install and boot exercise; the multi-block/`T_Widget` path [§10.6] is
   unimplemented by design.)*
5. **M4 Desktop ⭐** — mouse/keyboard/clock live; Office System desktop.
   *(Project-history note, 2026-08-07: substantially reached, one honest step
   short of the desktop itself. The project's own M4 (`docs/m4-demo.md`)
   delivered live interrupts (mouse/COPS level 2, ms-tick/vsync level 1 into the
   OS's own handlers) and the running multi-domain scheduler, and drove the boot
   to the **Office System 3.0 installer UI on screen** (screenshot
   `~/Development/LisaEmu-artifacts/m4-checkpoint-g-installer-ui.png`). The
   **Office System desktop** proper is the POST-install boot, which is still
   ahead: it needs a hard disk to install onto first — the installer reports
   "can't find a suitable disk" because none is modeled. So the desktop ⭐ waits
   on the project's M5 (Widget/ProFile HLE), after which installing the OS and
   booting from HD yields the desktop. Also carried to M5: driving the installer
   UI (mouse input at its event-wait), the soft-power/Power menu, `$C015` vs.
   800K double-sided, and the parked 1 MB-POST divergence `$FE099C`.)*
   *(Project-history note, 2026-08-08: the **desktop ⭐ is reached** by the
   project's own M5 (`docs/m5-demo.md`). Booting the M5-installed Office System
   off the Widget (see the M3-Widget note above) carries all the way to the
   **Office System desktop** — menu bar **Desk / File/Print / Edit /
   Housekeeping** and icons **Preferences · Wastebasket · Clipboard · Internal
   Hard Disk** — with **mouse and keyboard live**: a first-boot modal is
   dismissed by an on-screen click (a modal answered by a mouse event), and the
   OS cursor is steered live via the COPS input channel. The screenshot is
   `~/Development/LisaEmu-artifacts/m5-boot-06-desktop.png`; pinned behaviourally
   by `ROMWidgetBootTests.checkpointK`. **One clause of this line's "clock live"
   remains honestly unmet:** no RTC (COPS real-time clock) is modeled, so the
   Office System draws a "clock/calendar is not set" note on each boot — the
   "working clock" is the natural M6 headline, not an M5 boot blocker. See
   `docs/rom-trace-notes.md` "Checkpoint K" and `task-4-report.md`.)*
6. **Stretch (any order)** — SCC→PTY + LisaBug console; boot Workshop 3.0 and
   rebuild the OS source in-emulator; LLE COPS; LLE 6504 floppy; Lisa 1/Twiggy.
