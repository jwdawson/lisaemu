# M2 demo — floppy boot into the OS loader

M2's exit criterion: with a real Apple Lisa OS floppy image inserted, the Rev H
boot ROM (driven through its own startup menu) reads the boot block off the
disk, executes it, and the **Lisa OS loader runs from RAM and makes documented
progress** — relocating itself, reading the LFS off the floppy, and reaching
its Lisa Pascal segment-call runtime (the M3 boundary).

Full narrative + citations: `docs/rom-trace-notes.md` "OS loader (Task 6)" and
"Floppy boot (checkpoint C)"; the floppy interface itself is
`docs/hardware-notes.md` §9.

## Prerequisites

- The interleaved Rev H ROM in a directory (`341-0175-H.BIN` / `341-0176-H.BIN`),
  e.g. `~/Development/LisaROMs`.
- A DC42 OS floppy image named `OS31_Install_1.dc42`, e.g. in
  `~/Development/LisaImages`.

## 1. lisadbg one-liner — boot to the menu with a disk inserted

The Rev H ROM does **not** auto-boot from an inserted floppy: it completes POST
and parks in its boot-menu input-idle loop, byte-identical to a no-disk boot.
This is reproducible standalone (no menu interaction needed):

```
printf 'g 25000000\nsca\nq\n' | \
  swift run -c release lisadbg --rom $HOME/Development/LisaROMs \
    --disk $HOME/Development/LisaImages/OS31_Install_1.dc42
```

Expected tail:

```
PC=00FE00F6 SR=2704 cycles=0
      setup=OFF domain=0 mmuPortWrites=4384 busErrorPulses=0 halted=false disk=IN blocksRead=0
PC=00FE2DCA SR=2704 cycles=25000006
```

`PC=$FE2DCA` is the `$FE2DBE`-`$FE2DD6` "await next COPS input byte" menu idle
loop; `blocksRead=0` confirms no auto-boot. `sca` renders the drawn boot menu
(three buttons + the crossed-out ProFile "42" no-boot-device icon). Selecting a
device to actually boot the floppy requires mouse/keyboard input, which the
emulator delivers through `COPS.postMouse`/`postKey` — driven by the test below.

## 2. The test — boot the floppy and follow the OS loader

```
LISAEMU_ROM_DIR=$HOME/Development/LisaROMs \
LISAEMU_DISK_DIR=$HOME/Development/LisaImages \
  swift test -c release --filter ROMFloppyBootTests
```

Three env-gated tests run:

- `diskInsertedAtPowerOnReachesTheIdenticalMenuAnchor` — an inserted disk does
  not change the boot menu (same FNV framebuffer fingerprint, `blocksRead==0`).
- `menuSelectionReadsBlockZeroAndExecutesTheBootBlock` — clicking
  "STARTUP FROM…" then a device item runs the Sony loader → twig_entry RWTS,
  which reads block 0 and JMPs into the boot block at `$020000` (checkpoint C).
- `osLoaderExecutesFromRAMAndReachesPascalSegmentGate` — **the M2 exit
  criterion** (below).

## 3. Loader milestone — status transcript

The loader draws nothing new to the framebuffer (the boot UI stays on screen),
so the milestone is captured as a status transcript rather than a screenshot.
Markers observed at the point of maximal, stable progress (deterministic under
Musashi), asserted by `osLoaderExecutesFromRAMAndReachesPascalSegmentGate`:

```
at boot-block entry ($020000):   prom_realsize($2A8)=$200000   vec98(TRAP#6)=$FE1D14 (PROM handler)
                                 dev_type($22E)=0   ldbaseptr($21C)=0   blocksRead=1

loader progression:
  relocated to RAM midpoint:     ldbaseptr($21C)=$100000   (= prom_realsize/2)
  read LFS off floppy:           blocksRead=24   lastError=0   (23 code blocks + block 28 = MDDF)
  MDDF (block 28) served:        00 11 9c f9 ...  = fsversion 17, volname "Office System 1 3.0"
                                 (byte-identical to the raw DC42 image)
  loader hand-off cells:         dev_type($22E)=2 (dev_sony)   ld_fs_block0($210)=$1C   log_volume($212)=1
  mapped Pascal code segment:    MMU dom0 seg84 SORG=$FE4 SLIM=$7DB (readWrite)   mmuPortWrites 4384->4386
  entered compiled Pascal loader: A5-relative globals code running at $100000+

stop line (M3 boundary):
  Pascal trap #6 segment gate:   vec98(TRAP#6)=$A84000 (loader overwrote PROM's; unrelocated placeholder)
                                 trap #6 at $100418 -> PC=$A84000 (unmapped) -> bombs back to PROM menu
  interrupts:                    SR=$2704 throughout (IPL mask 7 — loader polls, never unmasks)
  screen:                        framebuffer unchanged (78181 px — loader draws nothing pre-gate)
  halted:                        false (a live progression, not a fault)
```

The `trap #6` gate is Lisa Pascal's inter-segment call runtime (`#$a84000` is a
segment-base placeholder baked into the on-disk loader). Resolving it needs the
Pascal segment-loader/relocation runtime — an M3 CPU-runtime requirement, not a
new device. See `docs/rom-trace-notes.md` "OS loader (Task 6)".

## Artifacts

No screenshot is committed. The loader produces no new drawing before its stop
line, so there is no distinct "loader screen"; the on-screen content during the
loader run is the boot menu / device-list window from step 1, which
`lisadbg … sca` (or `sc <path>.png`) renders. Any PNG belongs outside the repo
(e.g. `~/Development/LisaEmu-artifacts/`) and is never committed — it renders
Apple's ROM-drawn UI.
