# M3 demo — the kernel starts (and where it stops)

M3's task list (the spec's "kernel starts, watch with symbols" line) asked: past
M2's floppy-boot exit criterion (loader running from RAM, reaching its first
`trap #6`), does the OS actually **start executing**? The honest answer this
milestone landed on: **yes** — the loaded OS image runs its own initialization
code — but two real emulation bugs stood between M2's stop line and that
result, and a third, genuinely new boundary (not a bug) now blocks it. This
document is the plain-language walkthrough; full evidence and citations live in
`docs/rom-trace-notes.md` ("Checkpoint D", "Kernel push (M3 Task 4)") and
`docs/hardware-notes.md` §1.

## What now happens on boot

Starting from M2's stop (the OS loader parked at its `trap #6` MMU-programming
call, `do_an_mmu`, at logical `$A84000`):

1. `do_an_mmu` **executes correctly** and returns to the loader (`$10041A`).
   It is called **127 times**, building out the OS's domain-0 (system) MMU
   segment table — 126 domain-0 segments, then a pivot call that switches the
   live MMU context into domain 1 mid-handler.
2. That domain-1 pivot **survives** — `do_an_mmu` keeps executing its own code
   across the context switch, programs domain 1, switches back to domain 0,
   and returns normally.
3. The loader finishes building the domain-1 register file, then **reads the
   OS image off the floppy**: `blocksRead` climbs from 24 (M2's stop) to
   **75** (51 more blocks), via the same PROM read routine M2 used, with no
   read errors.
4. Control **enters the loaded OS code itself**, at logical address
   **`$520000`** — this is genuinely new code that only exists because the
   floppy read in step 3 just placed it in RAM; nothing about it comes from
   the boot ROM.
5. The OS runs its **own COPS driver** (not the ROM's) to send a "enable
   mouse interrupts" command to the keyboard/mouse controller chip — and
   **spins forever** polling a handshake line our COPS model doesn't drive
   the same way this driver expects. That is where M3 stops.

Throughout all of this, interrupts stay masked (`SR=$2700`, IPL 7 — the boot
path never unmasks IRQs), no floppy **write** ever happens (this is all
reads), and the on-screen framebuffer never changes: the boot menu drawn at
POST is still the only thing on the glass the whole way through, because
nothing in the loader or the OS's COPS driver draws to the screen before the
COPS handshake gate.

## How far it gets, concretely

- **75 floppy blocks read** (vs. 24 at the M2 stop) — the OS image itself.
- **OS code executing at `$520000`**, specifically its COPS command-send
  driver at `$520824`, sending command byte `$7C`.
- **127 `trap #6` (`do_an_mmu`) calls completed**, building domain 0 (the
  system's own MMU map, ~128 segments) and starting domain 1.
- **Zero bus errors, zero halts** the entire way — this is a live progression
  to a spin-wait, not a crash.
- **The stop is the OS's own COPS handshake**, at the boundary where our
  simplified controller-chip model and the OS driver's polling protocol
  disagree — explained below.

### In `lisadbg`

~~There is no menu-navigation harness in `lisadbg` (no cursor-walk + click),
so it cannot drive the ROM past the boot menu on its own — the same
limitation M2 already documented. `lisadbg --rom … --disk …` plus `g`/`sca`
still shows exactly the M2 picture: POST completes, the disk is inserted,
the menu is drawn, `blocksRead=0` because nothing has clicked "STARTUP
FROM…" yet. **The $520000 frontier this document describes is reachable
only through the integration test harness below** — see "Reproduce" for the
actual repro vehicle, and `docs/rom-trace-notes.md`'s "Kernel push (M3 Task
4)" section's "Reproduction" paragraph for the fuller citation.~~
**Superseded (M4 Task 2):** `lisadbg` now has a `bootdisk` command (ported
from this same cursor-walk + click mechanism) that drives the ROM past the
menu, into the loader, and into the loaded OS image entirely on its own —
`lisadbg --rom … --disk … ` then typing `bootdisk` reaches (and currently
runs well past) the `$520000` frontier with no integration test involved.
`d`/`t`/status output also gets a Linkmap-symbol overlay (`sym`/`symbase`
commands; `LISAEMU_LINKMAP_DIR` or the default `Lisa_Source` path) — though
see `task-2-report.md` for the honest coverage finding: the available
Linkmaps only cover Office System applications, not the OS kernel this
frontier lives in, so kernel-space addresses currently show no annotation.

## The three MMU discoveries, in plain language

Three real divergences between this emulator's MMU model and the actual Lisa
hardware were found and fixed this milestone. All three were bugs in *our*
model, not gaps in the real Lisa's design — each was confirmed against the
Lisa OS's own assembly source before being fixed.

1. **The 12-bit page-add wrap (M3 Task 1).** The MMU computes a physical
   address by adding a segment's origin page to a logical offset. On real
   hardware that add wraps around within 12 bits (so a "negative" origin
   page correctly wraps back into range). Our translator didn't apply that
   wrap, so a segment deliberately placed at a negative origin (a real,
   intentional trick the OS uses to relocate its MMU-programming code)
   decoded to an address past the end of RAM instead of wrapping back to the
   correct low address. Fetching garbage there sent the emulator back to the
   boot menu, which looked like a hard stop but was really this one
   arithmetic bug. Fixed by masking the physical result to 21 bits.

2. **The setup-latch fix (M3 Task 2).** "Setup mode" is a hardware flip-flop
   that redirects MMU register writes to a staging area instead of the live
   translation tables. Our model additionally treated setup mode as "turn
   off address translation entirely, use flat physical addresses" — which is
   true during power-on (before anything is mapped) but **not** true once
   code is running from a mapped segment, as the OS's own MMU-programming
   handler does. The OS routine toggles setup mode on and off *while still
   executing its own code through the MMU* — something only possible if
   translation stays live. Our flat-fallback model broke that assumption and
   sent the fetch into unmapped garbage. Fixed: setup mode only falls back
   to flat addressing when the *current* segment isn't actually mapped yet
   (i.e., during real POST), not for already-mapped code.

3. **Supervisor execution ignores the domain-context latch (M3 Task 4,
   "OQ1′").** The Lisa MMU has 4 register sets ("domains") — domain 0 is the
   OS's own map; domains 1-3 belong to user processes. A 2-bit latch selects
   which domain is "current." The OS switches that latch as part of routine
   process bookkeeping, including *while it is executing its own kernel
   code* mid-handler, into a domain that is still completely empty. Real
   hardware clearly survives this (otherwise no Lisa would ever boot), and
   tracing plus the OS's own source confirms why: **supervisor-mode code
   execution always translates through domain 0, regardless of what the
   latch says** — the latch only matters for user-mode accesses. Our
   original model let the latch gate *all* accesses, supervisor included, so
   the kernel's own code vanished out from under it the instant it switched
   domains, and the double-fault took the emulator down. Fixed by having the
   bus pick domain 0 for supervisor accesses unconditionally, while leaving
   the raw MMU-register-programming path (which still needs to write real
   per-domain register values) untouched.

Each fix is a single, precisely-scoped change confirmed against the OS
assembly source before being made — see `docs/rom-trace-notes.md` for the
disassembly, single-step traces, and source citations behind each one.

## Reproduce

Prerequisites, same as M2: the Rev H ROM pair and `OS31_Install_1.dc42` (or
another OS 3.1 install-disk image), e.g. under `~/Development/LisaROMs` and
`~/Development/LisaImages`.

**The integration test is the only way to reach the M3 frontier** (see
"In `lisadbg`" above for why):

```
LISAEMU_ROM_DIR=$HOME/Development/LisaROMs \
LISAEMU_DISK_DIR=$HOME/Development/LisaImages \
  swift test -c release --filter ROMFloppyBootTests
```

The relevant assertion is
`ROMFloppyBootTests.domain1CrossoverSurvivesLoaderLoadsOSImageAndReachesTheCOPSDriver`:
it drives the menu click sequence, boots the floppy, single-steps through the
domain-1 crossover, and asserts `blocksRead==75`, no halt, no bus error, and
the PC inside `$520800-$5208FF` (the COPS driver). `BusTests.
supervisorTranslationUsesOSDomainZeroRegardlessOfContextLatch` pins the OQ1′
mechanism in isolation (a latched, empty domain 1; supervisor access resolves
via domain 0, user access faults).

## In the app

The same `--insert-disk`/`--auto-screenshot` launch arguments from M2 still
work exactly the same way (`docs/m2-demo.md` §4 has the full walkthrough —
inserting via ⌘I / drag-and-drop, clicking "STARTUP FROM…", the disk-activity
indicator flashing as blocks are read). Nothing about the app's UI changed
this milestone. The integration test is the automated reproduction vehicle for
the M3 frontier; in the app itself, you reach it by clicking through the boot
menu (File > Insert Disk, then click the on-screen STARTUP FROM button, then
click a device). When you do, the real boot sequence drives: the ROM's Sony
loader reads block 0, the OS loader runs from RAM, and the disk indicator
flashes repeatedly (~51 more blocks read) as the loader fills the OS image
into memory. Then control enters the loaded OS code itself at `$520000`, and
the OS's own COPS driver sends a command to the keyboard controller — and
spins there forever, unresponsive, the status bar showing "running" (not a
hang, not a crash; the OS is at `$520842-$52084E` in its own COPS driver,
waiting for a handshake our simplified model doesn't provide the same way).
The screen stays frozen on the boot menu the entire time — nothing in the
loader or the OS's COPS driver draws before hitting that gate, so there are
no new pixels to see. This frozen state is the M3/M4 documented boundary, not
a bug; closing it for M4 means modeling the real COPS handshake more
faithfully and re-checking the ROM's own usage stays identical.

The screenshot captured for this milestone (`~/Development/LisaEmu-artifacts/m3-boot-progress.png`, captured via):

```
LisaApp.app/Contents/MacOS/LisaApp \
  --insert-disk "$HOME/Development/LisaImages/OS31_Install_1.dc42" \
  --auto-screenshot "$HOME/Development/LisaEmu-artifacts/m3-boot-progress.png"
```

**shows the plain boot menu — the same picture M2's checkpoint screenshot
showed.** This is stated honestly, not as a bug: the app only inserts the
disk at launch, and the loader/OS code this milestone traces all runs without
producing a single new pixel. Not committed (it renders Apple's ROM-drawn
UI, same rule as M2's artifact).

## M4 teaser: the OS's own COPS handshake

The stop this milestone reaches is not an emulation bug — it's a genuinely
new subsystem the boot has never touched before. Everything up through M3 used
the boot ROM's *own* COPS driver, which our simplified model happens to match
closely enough (it only ever writes one particular register once per command).
The loaded OS has its **own, different** COPS driver, and it uses the
handshake more thoroughly: it stages a command byte, then toggles a data
direction register to actually "send" it, polling a ready line the whole time.
Our model's simplification (dropping the ready signal on every command-byte
write) works fine for the ROM's usage pattern and breaks this driver's, which
re-writes the command byte on every poll iteration. Closing this gate for M4
means modeling the real handshake more faithfully — gated on the data
direction register transition, not on every register write — and then
re-checking that the ROM's own COPS usage (which this milestone's fixes never
touched) still works identically afterward. See `docs/rom-trace-notes.md`
"Kernel push (M3 Task 4)" → "The M3 Task 4 STOP" for the full protocol
disassembly.
