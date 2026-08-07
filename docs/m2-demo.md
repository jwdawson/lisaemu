# M2 demo — floppy boot into the OS loader

M2's exit criterion: with a real Apple Lisa OS floppy image inserted, the Rev H
boot ROM (driven through its own startup menu) reads the boot block off the
disk, executes it, and the **Lisa OS loader runs from RAM and makes documented
progress** — relocating itself, reading the LFS off the floppy, and reaching
its first `trap #6` MMU-programming call. ~~its Lisa Pascal segment-call runtime
(the M3 boundary).~~ *(M3 Task 1 correction: that `trap #6` is the OS's
MMU-programming trap `do_an_mmu`, not a Pascal segment-call runtime, and it was
NOT an M3 boundary — it was an emulation divergence (a missing 12-bit MMU
page-wrap), since diagnosed and fixed. See rom-trace-notes.md "Gate diagnosis
(M3 Task 1)".)*

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

stop line (was mislabeled "M3 boundary"; DIAGNOSED as an emulation bug, M3 Task 1):
  trap #6 = do_an_mmu:           vec98(TRAP#6)=$A84000 (installed BY DESIGN — do_an_mmu relocated into seg 84)
                                 trap #6 -> PC=$A84000; our MMU decode sent it to phys $200800 (past 2MB) not $800
                                 -> fetched FF garbage -> bombed back to PROM menu.  FIXED: 12-bit page-wrap in MMU.translate
  interrupts:                    SR=$2704 throughout (IPL mask 7 — loader polls, never unmasks)
  screen:                        framebuffer unchanged (78181 px — loader draws nothing pre-gate)
  halted:                        false (a live progression, not a fault)
```

~~The `trap #6` gate is Lisa Pascal's inter-segment call runtime (`#$a84000` is
a segment-base placeholder baked into the on-disk loader). Resolving it needs
the Pascal segment-loader/relocation runtime — an M3 CPU-runtime requirement,
not a new device.~~ **M3 Task 1 correction:** `trap #6` is the OS's
MMU-programming trap (`do_an_mmu`); `$A84000` is the *deliberate* relocated
address of that handler (`initmmutil`, LDASM:174-252), not a placeholder. The
stop was an **emulation divergence** — our `MMU.translate` omitted the
hardware's 12-bit page-add wrap, so `$A84000` decoded to phys `$200800` (past
2 MB) instead of `$800`. Fixed in `LisaCore/MMU.swift`; the gate now falls. See
`docs/rom-trace-notes.md` "Gate diagnosis (M3 Task 1)" and hardware-notes.md §1.

## Artifacts

No screenshot is committed. The loader produces no new drawing before its stop
line, so there is no distinct "loader screen"; the on-screen content during the
loader run is the boot menu / device-list window from step 1, which
`lisadbg … sca` (or `sc <path>.png`) renders. Any PNG belongs outside the repo
(e.g. `~/Development/LisaEmu-artifacts/`) and is never committed — it renders
Apple's ROM-drawn UI.

Task 7's manual checkpoint (`--insert-disk … --auto-screenshot
~/Development/LisaEmu-artifacts/m2-live-loader.png`, no menu click scripted)
captures exactly this: the boot-menu screen, disk inserted. Stated honestly,
not as a bug -- `--insert-disk` only attaches the image; it does not also
drive the STARTUP FROM click sequence, and the loader itself (once driven)
draws nothing new anyway. See task-7-report.md (local SDD artifact, not committed) for the captured PNG's
dimensions/content confirmation.

## 4. In the app — insert, boot, and watch it live (M2 Task 7)

The steps above drive the emulator headlessly (`lisadbg`/`swift test`). The
same journey is reachable interactively in `LisaApp`, the SwiftUI window shell
(`docs/superpowers/plans/2026-08-05-m1c-app-shell.md`):

```
xcodegen generate --spec LisaApp/project.yml
xcodebuild -project LisaApp/LisaApp.xcodeproj -scheme LisaApp build
open -a LisaApp/LisaApp.xcodeproj  # or run the built .app directly
```

1. **Insert Disk 1** — File > Insert Disk… (**⌘I**), an `NSOpenPanel`
   filtered to `.dc42` files, and pick `OS31_Install_1.dc42`; or just drag the
   `.dc42` file onto the window. Either path calls
   `EmulationController.insertFloppy(url:)`, which loads the image on the
   emulation thread and attaches it via `Machine.bus.floppy.insert(_:)` — a
   load failure (bad path, malformed image) surfaces as a dismissible
   "Could Not Insert Disk" alert, never a crash. The status strip's new disk
   indicator (a small dot + "DISK" label, bottom-right) lights up once
   attached. A tagless DC42 container (`tagLen == 0` — common for wild
   Mac-disk DC42s, exactly what drag-and-drop invites) is accepted, not
   rejected: `DC42Image` synthesizes zero tags, so it inserts and reads
   cleanly and the Lisa-side boot rejects it gracefully instead of crashing
   the emulator.
2. **Click STARTUP FROM…**, then a device item in the list that opens — the
   same two clicks `ROMFloppyBootTests`/`EmulationControllerFloppyIntegrationTests`
   script automatically. Mouse/keyboard reach the Lisa through the existing
   M1c input path (`InputCapture`/`COPS.postMouse`/`postKey`); no new input
   plumbing was needed for this.
3. **What you'll see**: the Sony loader reads block 0, the boot block JMPs
   into RAM, and the OS loader relocates itself and reads ~24 blocks off the
   floppy (the disk indicator's dot flashes green each time
   `FloppyController` finishes a command — `EmuStatus.diskActivity`) — but
   **the screen itself does not change**. Per step 3 above, the loader draws
   nothing before its stop line; the boot menu/device-list window stays on
   screen throughout. The visible confirmation that real progress happened is
   the disk-activity flash, not new pixels.
4. **Where it stops, and why** *(M3 Task 1: diagnosed as an emulation bug — see
   the corrected account below; the struck text is the original, now-refuted
   framing, kept per the both-docs rule):*

   ~~the loader reaches its Lisa Pascal `trap #6` inter-segment call gate
   (`$A84000`, an unrelocated segment-base placeholder) and halts forward
   progress there — no new peripheral would get it further; whatever unblocks
   it is M3-scoped work, not more floppy/device modeling.~~

   ~~That said, the recorded facts (vector `$98` overwritten with the
   unrelocated `$A84000` placeholder, domain-0 segment 84 mapped with
   `SORG=$FE4` → phys `$1FC800`, `$A84000` translating to phys `$200800` —
   just past this environment's 2 MB RAM end, and the placeholder bytes
   baked into DC42 block 1 offset 478) support two different explanations,
   not one settled conclusion: **(a)** the Pascal segment-loader/relocation
   runtime genuinely hasn't executed yet at this point — real hardware stops
   here too, and M3 implements that runtime; or **(b)** this is an
   emulation divergence (MMU SORG/limit decode, OQ1's still-open
   inactive-domain semantics, or a RAM-size-dependent path in the loader's
   own relocation math) — real hardware runs this loader PAST this gate
   using only 68000 + MMU + disk. **M3's first task is to discriminate the
   two** — cheapest probe: re-run the same trace with a 1 MB RAM
   configuration and see whether the stop point changes. See
   `docs/rom-trace-notes.md` "OS loader (Task 6)" → "Two open hypotheses for
   the stop" for the full citations.~~

   **Corrected (M3 Task 1 — hypothesis (b) confirmed):** that `trap #6` is the
   OS's **MMU-programming trap** `do_an_mmu`, not a Pascal segment-call gate;
   vector `$98 = $A84000` is the *deliberate* relocated home of `do_an_mmu`
   (`initmmutil`, LDASM:174-252), not an "unrelocated placeholder"; and the
   stop was an **emulation divergence** — our `MMU.translate` omitted the
   hardware's 12-bit page-add wrap, so seg-84 origin page `$FE4` (a *negative*
   page, −28) plus offset `$4000` decoded to phys `$200800` (past 2 MB) instead
   of wrapping to `$800`. Fixed in `LisaCore/MMU.swift`; the gate now falls and
   the boot advances to a new, later stop (Task 2's frontier). Full evidence
   chain: `docs/rom-trace-notes.md` "Gate diagnosis (M3 Task 1)" and
   hardware-notes.md §1.
5. **Reset survives the inserted disk**: Machine > Reset (⌘R) warm-resets the
   CPU/ROM but the floppy stays inserted (Task 2's by-construction guarantee,
   proven end-to-end at the controller level by
   `EmulationControllerFloppyTests.insertedMediaSurvivesReset`) — real
   hardware's RESTART button doesn't eject media either.
6. **Debug launch argument**: `--insert-disk <path>`, alongside
   `--auto-screenshot <path>`, inserts a floppy at launch without a human
   driving the open panel or drag-and-drop — used for the manual
   verification checkpoint (task-7-report.md).

### Conscious deferral: no Power menu

M1c first deferred "power on/off via COPS" to a later task; this task
(M2 Task 7, the app-integration task where it was next scheduled) defers it
again, deliberately — `LisaCore.COPS.powerCommandLog` already exists (it
captures the OS-driven soft-power-off command byte sequence), but a Power
menu item needs somewhere to actually GO (suspend the emulation thread, show
a "powered off" UI state, wire a wake path) that doesn't exist until M3's
soft-power/Widget work. This task lands the OTHER still-open M1c item
instead: the status-strip disk-activity indicator. See
`LisaApp/Sources/LisaApp.swift`'s doc comment at the `CommandMenu("Machine")`
declaration for the same note in code.
