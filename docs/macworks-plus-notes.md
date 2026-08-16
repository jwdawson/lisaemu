# MacWorks Plus — discovery notes, and how it was solved

**Date:** 2026-08-13 (live boot) / 2026-08-15 (this write-up) /
**2026-08-15 RESOLVED pass (PR #7)**
**Status:** ~~evidence-gated discovery~~ → **SOLVED.** MacWorks Plus boots to
the Macintosh Finder, and with a MacWorks-formatted Widget attached it boots
**System 6 to a full Mac desktop**.
**Purpose:** originally a cold-start brief for continuing the hunt; now also
the record of how it ended. Every claim was observed under `lisadbg` or read
off the DC42 headers. Do not treat Wikipedia / LisaEm folklore as load-bearing.

**How to read this file.** The 2026-08-13 discovery text is preserved as
written, with overturned claims ~~struck~~ and a dated correction beside them
(house strike-not-erase rule). Section 0 (constraints) and section 2 (image
inventory) stood up unchanged. Sections 1, 3, 4.3 and 6 contain the claims
that did not.

This is **not** "emulate a Macintosh." MacWorks Plus is Lisa guest software.
The Lisa-side half already ran. ~~The remaining wall is the **Mac-side disk
driver** after the patched 128K ROM takes over.~~ **(2026-08-15 correction:
the wall was never the Mac-side driver stack. It was four things on the LISA
side that the Lisa OS's own habits had left unconstrained — see §1′.)**

---

## 0. Constraints (do not violate)

Project rules (`CONTRIBUTING.md`, `README.md`):

- **No Apple-derived data in the repo.** No ROM bytes, no `.dc42` contents, no
  Widget that the OS has written, no screenshots of Apple/Sun UI. Screenshots
  from this investigation lived in `/tmp` and `~/Development/LisaEmu-artifacts/`
  — do not commit them.
- **Evidence-gated device changes.** A floppy/VIA/SCC change needs a citation
  (OS source line, ROM disassembly, or a live `lisadbg` trace). "It would make
  MacWorks happier" is not a justification.
- **Both-docs rule** if you *do* change hardware: `docs/hardware-notes.md` for
  constants, this file (or `docs/rom-trace-notes.md`) for the journey.
  Strike-through, never erase.
- Target machine is still a **Lisa 2/10** (Sony 400K + Widget). MacWorks is a
  guest, not a new machine type.
- Do **not** build a Macintosh IWM / Mac VIA / Mac SCC chipset unless a live
  trace shows an *unpatched* IWM path at `$DFExxx`. The working hypothesis is
  that MacWorks' patches should talk to Lisa I/O at `$FCxxxx`.
  **✅ 2026-08-15: this constraint held, and the hypothesis was right.** No
  Mac chipset was built. Every fix was a Lisa-side cell at `$FCxxxx`. The one
  Mac-hardware access that does occur (`$580000`, the Plus's SCSI base) is a
  boot-device scan that is supposed to fail on a Lisa — §4.3′.

External assets (not in the repo):

| What | Where |
|---|---|
| Rev H ROM pair | `~/Development/LisaROMs` (`341-0175-H.BIN` / `341-0176-H.BIN`) |
| MacWorks images | `~/Development/LisaImages/MacWorksPlus/` |
| Built debugger | `LisaEmu/.build/release/lisadbg` (or `swift run -c release lisadbg`) |
| Bitsavers source | https://www.bitsavers.org/bits/Apple/Lisa/macworksPlus/ |

---

## 1. One-paragraph verdict (2026-08-13, superseded — see §1′)

`lisadbg --disk macworksplus_1.1_boot_1989_400k.dc42` + `bootdisk` reaches the
**MacWorks Plus 1.0.18 splash** (Sun logo, floppy+`?`). The Lisa bootloader
reads **310 blocks** via the existing Sony HLE (`$FCC000`), programs the MMU,
and jumps into a patched Mac Plus ROM at **`$400000`**. A-traps fire. The
splash loop then tries to `_Read` a Macintosh boot volume (`'LK'` = `$4C4B` at
the buffer in A6) using ~~**`$A815`** (`_SCSIDispatch`) — **not** the Lisa Sony
go-byte protocol~~ **(struck 2026-08-15: `$A815` IS reached and IS the Mac Plus
SCSI Manager, but it is a RED HERRING — a Lisa has no SCSI, so that scan is
SUPPOSED to fail. MacWorks drives the Lisa Sony go-byte protocol perfectly
well; see §4.3′.)**. After that jump, `blocksRead` freezes at 310. ~~Inserting a
genuine `'LK'` installer via the media-change path does **not** produce another
floppy read.~~ **(struck: it does, once DISKIN reads `$FF`.)** ~~That is the
wall.~~

## 1′. What it actually was (2026-08-15, PR #7)

**Four Lisa-side gaps, none of them in the Mac driver stack.** Each is a cell
or convention the Lisa OS never constrained, which is exactly why six
milestones of Office-System work never exposed them — and why a second,
independent guest found them all in an afternoon.

1. **DISKIN (`$FCC041`) present-value must be `$FF`, not `1`.** The Lisa OS
   only ever tests `<> 0` (ISDISKIN SONYASM:437-441, hdinit
   SONY.TEXT:629-636), so the `1` this emulator had written since M2 was an
   unconstrained choice, never evidence. MacWorks' patched `.Sony` reads it
   ABSOLUTELY: at **`$41B892`** it compares the byte at `$FCC041` against
   `$FF` and, on any other value, loads `-65` (`offLinErr`) and returns it.
   With `1` in the cell every Mac-side
   `_Read` was refused, the drive queue element's `diskInPlace` (`$1DE3`) was
   never written at all (watched with `gw` across 600M cycles spanning an
   eject and an insert), and the splash loop had nothing to mount. `$FF`
   satisfies BOTH drivers. **This one byte is the whole of §1's "wall".**
2. **800K double-sided block order is INTERLEAVED BY TRACK** — track 0 side 0,
   track 0 side 1, track 1 side 0 — not all of side 0 then all of side 1,
   which is what the M2-era `side == 1 ? block + 800` assumed (no traced path
   had ever read side 1). MacWorks read (t0, s0, sec 0/2/4) then
   (t0, **side 1**, sec 4): block 16 interleaved, block 804 under the old
   form. Every read returned DISKERR 0, so the guest got plausible GARBAGE
   rather than an error and ejected the diskette as unreadable.
3. **`$FCC015` (`adr_intdisk`) derived from media** instead of a static `1`
   (0 = Twiggy, 1 = single-sided Sony, 2 = double-sided, STARTUP:1747-1748),
   closing the M3 Task 3 inconsistency where DISKFLG and `$C015` could
   contradict each other.
4. **Shared-RAM cell `$0D` is a host-set busy flag the controller must
   clear.** Absent from SONYASM's equates (which jump `$0B` → `$0F`) and
   never touched by any Lisa OS path. MacWorks uses it as a second handshake
   beside DISKCMD when booting System 6 off the hard disk: after staging
   DISKPARM = 0 and DISKDRIV = 2, **`$4242B8`** sets cell `$0D` to `$FF`,
   **`$4242BC`** writes go-byte **`$84`** (also undocumented), and
   **`$4242C2`** spins on cell `$0D` until the controller zeroes it — then
   reads DISKERR and stores it into the drive queue element's `dQFlags`.
   Symptom:
   the Finder draws its menu bar and hangs with the watch cursor, no desktop,
   ~40,000 reads of `$FCC00D` per 2M cycles.

**Reached:** Mac Finder off the 400K installer; the 800K installer mounting
("MW+ INSTALLER, 768K in disk"); MW Install formatting a blank Widget and
installing to it; and System 6 booting from that Widget to a desktop with the
`MW+HardDisk` volume icon. Artifacts outside the repo in
`~/Development/LisaEmu-artifacts/` (`mwp-*.png`).

**Not needed, contrary to expectations:** no SCSI, no IWM, no Mac VIA/SCC, no
VIA2 shift register (§6 P2's predicted sound wall never blocked the desktop),
and no Widget `Formatcmd`/multi-block (§6 P3) — MW Install formats the disk
with ordinary single-block writes.

---

## 2. Image inventory (`~/Development/LisaImages/MacWorksPlus/`)

Inspected 2026-08-13 by reading DC42 headers + the first data-plane blocks
(84-byte header, data length at offset 64, tags at 68).

| File | Blocks | FS | Block 0 | Role |
|---|---|---|---|---|
| `macworksplus_1.1_boot_1989_400k.dc42` | 800 (400K) | Lisa bootloader | `$46FC2700` (`MOVE.W #$2700,SR`) then `LEA` `$FCC000` | **Lisa-side boot disk.** Start with this. Not a Mac volume. |
| `macworksplus_boot_1.1H_cp2.dc42` | 800 | Lisa bootloader | same `$46FC2700` | Alternate 1.1H boot. Same class. |
| `macworksplus_1.0.2_install_198809_400k.dc42` | 800 | MFS | `'LK'` + System/Finder name | **First retry disk after the driver works.** 400K, matches current `$C015=1`. Volume name `MW+ Installer`. |
| `macworksplus_1.0.1_install_198808_800k.dc42` | 1600 (800K) | HFS (`BD` at block 2) | `'LK'` + System/Finder | Same installer, double-sided. **Needs `$C015` as 800K Sony.** Volume name `MW+ INSTALLER`. |
| `macworksplus_sysdisk_b_.dc42` | 800 | MFS-ish (Finder/APPL strings) | **all zeros** | Not blessed. Do not use as a System disk. Volume name `System B`. |

Bitsavers also has (not necessarily downloaded):

- `macworksplus_boot_1.1H.dc42`, `macworksplus_boot_1988_400k.dc42` — more boot disks
- `macworksplus_install.dc42`, `macworksplus_install_198808_800k_2.dc42` — more 800K installers
- `macworksplus_1.0.18_upd_400k.dc42` — updater, not a boot disk

**How to use them on real hardware / LisaEm (for orientation only):**

1. Lisa ROM menu → Startup From… the **boot** disk.
2. Splash → boot floppy ejects → `?` floppy.
3. Insert a **Mac** System / installer disk (`'LK'`).
4. Happy Mac → Finder (or the installer app).

HD install is a later step (800K installer → Widget). SCSI is MacWorks **Plus II**,
not Plus 1.0.x.

---

## 3. Live boot (repro)

```sh
cd ~/Development/LisaEmu

# Lisa-side boot to splash (~80s)
printf 'bootdisk 80000000\nsc /tmp/mwplus-splash.png\n' | \
  .build/release/lisadbg --rom ~/Development/LisaROMs \
    --disk ~/Development/LisaImages/MacWorksPlus/macworksplus_1.1_boot_1989_400k.dc42

# After splash: swap the 400K installer (does NOT currently get read)
printf 'bootdisk 80000000\neject\ninsert %s\ng 200000000\nsc /tmp/mwplus-after-insert.png\n' \
  ~/Development/LisaImages/MacWorksPlus/macworksplus_1.0.2_install_198809_400k.dc42 | \
  .build/release/lisadbg --rom ~/Development/LisaROMs \
    --disk ~/Development/LisaImages/MacWorksPlus/macworksplus_1.1_boot_1989_400k.dc42
```

`bootdisk` (`Sources/lisadbg/main.swift`) waits out POST, clicks
STARTUP FROM… `(420, 182)`, then the top device item `(88, 33)`.
Do **not** attach a Widget for this experiment.

### Observed timeline

| cycles (approx) | PC | `blocksRead` | Meaning |
|---|---|---|---|
| 0 | `$FE00F6` | 0 | Rev H reset |
| 18M | `$FE2DC6` | 0 | POST done, menu idle (same as LOS) |
| 24.5M | `$FE314A` | 0 | device item clicked |
| 34.5M | `$020D56` (`XFERLEFT+4`) | 58 | Lisa loader in RAM |
| 44.5M | `$4086C6` | **310** | inside Mac ROM / glue |
| ≥54.5M | **`$400720`** / `$400722` | **310 and frozen** | splash delay loop, forever |

Status at the splash (one representative dump, `bootdisk 80000000`):

```
PC=400722 SR=2000 cycles=104450082
D0=000380C6 D4=8800001D D5=000000A8 D6=00001DE6 D7=00400FFA
A0=001FC512 A5=000FFD90 A6=00100000 A7=000FFC00
disk=IN blocksRead=310 halted=false
mmuPortWrites=4640  busErrorPulses=0  powerCmds=[$25]
```

- `SR=$2000` — supervisor, IPL 0 (IRQs unmasked). Mac ROM is live.
- `A6=$100000` — read buffer the `'LK'` compare uses.
- `D4` high byte `$88` — same nibble as the board-ID `$C031=$88` stub.
- `disk=IN` after hundreds of millions of cycles — **unclamp was never
  successfully issued** (or never issued). A real MacWorks boot floppy ejects.
- Framebuffer: grey desktop, floppy icon with `?`, Sun Remarketing box
  "MacWorks Plus! 1.0.18 / Lisa Interface by Charles Lukaszewski".

After `eject` + `insert` of the 400K `'LK'` installer + `g 200000000`:

- lisadbg reports the media-change path (`bot_in` attention raised).
- `blocksRead` still **310**.
- PC still `$400720`.
- D2 changed `3 → $FFFF`, A0 changed `$001FC512 → $00400000`. Animation
  continues; no Sony `readdisk`.

**2026-08-15 correction — this observation is real but its cause is not what
it looks like.** The insert IS serviced: MacWorks reads DISKERR, reads
DISKSTAT (`$90` = `bot_int|bot_in`), issues `clristat` (`$85`), polls DISKCMD
78 times until the HLE clears it, then reads DISKIN 31 times. The handshake
works end to end. It then does nothing, because DISKIN answered `1` and its
`.Sony` requires `$FF` (§1′). With `$FF` the same sequence mounts the volume
(`blocksRead` 310 → 485, `$100000` = `4C 4B`) and reaches the Finder.

**Methodological note worth keeping regardless.** This repro (and the P0 probe
that copied it) puts `eject` and `insert` in adjacent `lisadbg` commands, which
execute **zero CPU cycles between them** — DISKIN goes 1 → 0 → 1 with no
instruction run, while the guest polls it at roughly 1 Hz emulated. A guest
that detected insertion on a 0 → 1 edge could never have seen the 0. That was
not the bug here (settling 25M cycles between each step changed nothing), but
it is a real hazard in any scripted media-change test: **settle between the
eject and the insert.**

---

## 4. Guest code anchors (splash / disk)

All of this is in the **guest** MacWorks image, mapped at `$400000`. It is
not Lisa OS and will not match Linkmap symbols.

> **Redacted 2026-08-15.** The transcribed instruction listings that were here
> are Apple/Sun-derived guest code, which §0's "no Apple-derived data in the
> repo" rule covers. Each is replaced by its address range and a description
> of what the code does — every address, every constant we depend on, and
> every conclusion is preserved, so the anchors remain usable for
> re-derivation with `lisadbg`'s `d` command. Nothing that follows requires
> the literal opcodes.

### 4.1 Delay / animation (where `bootdisk` lands)

**`$40071C`-`$400732` (redacted listing).** A counted delay: D0 is loaded
with `$00040000` and decremented to zero at `$400720`/`$400722` — the PC
sample `bootdisk` almost always lands on. `$400724`-`$400728` then advance an
animation counter pair (D4 up, D5 down); when D5 expires, `$40072A`-`$400730`
reload a pointer from `$400FFA` into A0/D7. `$400732` branches back to the
outer wait loop at `$400628`.

`$400628` is the outer splash/wait loop. D5 is an animation countdown
(observed `$A8` → `$7F` over ~200M cycles), not a hang in a single delay.

### 4.2 Volume check (the `'LK'` test)

**`$400690`-`$4006B6` (redacted listing).** `$400690` is the `_Read`
A-trap (`$A002`); `$400692` branches to `$4006BC` when it fails. On success
`$400694` compares the first word of the buffer addressed by A6 against
`$4C4B` (`'LK'`, the Macintosh boot-block signature) and `$400698` branches
to `$4006C8` on a mismatch. `$40069A` is a further A-trap (`$A852`),
`$4006A4` jumps to `$400F28`, and `$4006B6` is the jump to `$425D2A` that
would leave the splash for good.

`$400644` tests the drive-queue head in D6 and, when it is zero, skips
straight to the scan routine at `$4006E4` — an empty drive list.

### 4.3 Drive scan → `$A815` (~~the wall~~ — a red herring, see §4.3′)

**`$407D40`-`$407D5A` (redacted listing).** `$407D40` tests the low-memory
byte at `$B22` and skips the entire scan (to `$407D60`) when it is zero.
Otherwise it saves D0-D7/A0-A6, sets D5 = 6, and loops: for each D5 from 6
down to 0 it tests the corresponding bit in the low-memory word at `$B2E` and,
when clear, calls the per-device routine at `$407D62`.

Actual I/O (`$407dcc`) does **not** touch `$FCC000`:

**`$407DCC`-`$407E10` (redacted listing).** It builds a parameter block at
low-memory `$9FA`, storing opcode `8` followed by fields taken from D3/D2,
then issues `$A815` three times with selectors `1`, `2` and `3` pushed on the
stack, testing the returned word after each and branching to the failure path
at `$407E4E`. No access to `$FCC000` anywhere in this routine.

`$A815` = Toolbox trap 0x15 with the 128K-ROM "new trap" bit — **`_SCSIDispatch`**
in a Mac Plus ROM. Selectors 1 / 2 / 3 are on the stack. If the handler
returns an error, `_Read` never hits Sony HLE and `blocksRead` stays at 310.
That matches the insert experiment.

**Working hypothesis (unconfirmed — next session must confirm by tracing
the `$A815` vector):** after ROM takeover, disk I/O goes through the Mac
driver stack (SCSI Manager and/or a patched `.Sony`). Either

1. MacWorks patched `_SCSIDispatch` / `.Sony` to talk to Lisa `$FCC000` and
   that handler is failing because some Lisa signal we stub (VIA1 disk-enable,
   `$C015`, `read_bf`, completion polarity) is wrong, **or**
2. the vanilla Mac Plus IWM/SCSI path is still installed and is poking
   `$DFExxx` / SCSI space we do not model, failing fast.

Do not implement SCSI or IWM until a `t`/`d` of the `$A815` target decides
which one it is.

### 4.3′ Resolved (2026-08-15) — hypothesis 2, and it does not matter

The A-line vector at `$28` holds **`$401F52`**, a Toolbox dispatcher that
indexes the table at `$C00.w`. Selector 1 lands at `$41712C` → `$417294` →
`$4172BC`:

**`$41729E`-`$4172C6` (redacted listing).** A3 and A4 are loaded with
`$580000` and `$580001` — the Mac Plus NCR 5380 SCSI base and its write
alias. The routine writes `$80` through A4, writes `$01` at offset `$20` from
it, then tests bit 6 of the register at offset `$10` from A3 and branches on
the result.

`$580000`/`$580001` is the **Mac Plus NCR 5380 SCSI base** — hypothesis 2,
confirmed. **It is a red herring.** A Lisa has no SCSI, so this scan is
*supposed* to fail; it is the ROM's normal boot-device sweep falling through.
No bus errors are raised (those addresses are absorbed silently). The advice
above stands and was followed: **SCSI and IWM were never implemented, and
nothing needed them.**

The genuinely useful part of §4.2/§4.3 turned out to be the `_Read` path, not
the `$A815` one: `$400690`'s `_Read` IS dispatched (`$A002` → `$401F52` → OS
trap table at `$400.w` → `$4023BE` → `$4021A8` unit-table lookup, a textbook
Device Manager dispatch with A1 = the drive queue element), and it returns
`-65 offLinErr` because of DISKIN. `$400644`'s `tst.l D6 / beq` never took the
empty-drive-list branch: the queue was always populated (`qHead = qTail =
$1DE6`, `dQDrive = 1`, `dQRefNum = $FFFB` = `.Sony`, `UTableBase = $17C2`,
`UnitNtryCnt = 48`).

### 4.4 Speaker (VIA2 SR) — not today's hang, will be the next one

**`$40073C`-`$40077A` (redacted listing).** A0 is loaded with `$FCDD81`
(VIA2, Rev H base, stride 2). The code clears the top ACR bits at offset
`$16` and then sets bit 4 there — shift-out under phi2 — writes a byte to T2CL
at offset `$10`, and writes `$0F` to SR at offset `$14`. It then spins a
`dbra` software delay of `$0C1C` iterations, restores ACR, and returns
through A6. **The delay is unconditional: nothing in this path waits on the
SR interrupt flag.**

`VIA6522` SR (index 10) is a **plain store**. No shift, no IFR bit 2.
Splash survives because this path uses `dbra`, not the SR flag. Mac System
beeps / Sound Manager **will** wait on that flag. Do not "fix" Finder
freezes after the first beep by touching floppy.

**2026-08-15 update — still true, still unimplemented, and it did NOT block
the desktop.** System 6 boots from the Widget to a full Finder desktop with
the SR left as a plain store. The advice in the last sentence was sound but
was very nearly self-fulfilling: the Finder-freeze-with-watch-cursor that DID
occur was a floppy-window cell after all (`$0D`, §1′), just not one of the
signals listed here. Diagnose by profiling which address is being hammered
(`iot clear` then `g`), not by reasoning from the symptom.

---

## 5. What the emulator already did (do not re-do)

These are **done**, witnessed by the splash:

| Subsystem | Evidence |
|---|---|
| Rev H POST + boot menu | same `$FE2DCA` idle as LOS |
| Sony HLE `readdisk` + tags + 400K zone map | 310 successful reads |
| MMU remapping by guest | PC in `$400000–$41FFFF`, no bus errors |
| Video + vsync | recognisable 720×364 MacWorks frame |
| VIA timers + IRQ encoder | `SR=$2000`, animation loop advances |
| A-line dispatch | `$A002` / `$A815` / `$A852` execute |
| COPS / 2 MB RAM / Widget-not-required | floppy-only path got here |

Lisa Office System milestones (M0–M7) are the foundation. MacWorks is not a
new CPU/MMU project.

---

## 6. Remaining work (priority order)

> **2026-08-15 STATUS (PR #7): P0 DONE, P1 DONE, P3 DONE, P2 not needed yet,
> P4 DONE.** The per-item corrections are inline below; the surviving roster
> is in §9. Read §1′ first — the diagnosis in P0 below is aimed at the wrong
> layer (it assumes the fault is in the Mac driver stack; it was four Lisa-side
> cells).

### P0 — make one Mac-side block read succeed ✅ DONE

This is the whole next milestone. Success criterion:

> After the splash, with the 400K installer inserted (or already in the
> drive — try both), `blocksRead` increases **or** a traced `$A815`/`_Read`
> handler is seen issuing a Sony `readdisk` / equivalent, and `$100000`
> (A6) contains `'LK'`.

How to get there:

1. At the splash, dump the A-line vector for `$A815` and `$A002`
   (Mac 128K ROM trap dispatcher → destination). `d` that target.
2. Single-step or burst-trace one `$407df2` call. Record every
   `$FCxxxx` / `$DFxxxx` / VIA access.
3. Classify: Lisa Sony, Lisa VIA disk-enable, IWM, SCSI, or "driver
   never entered the drive queue."
4. Only then change HLE. Candidates, in the order the trace should
   confirm or kill:

   - **VIA1 port bits** (contrast DAC / disk-enable,
     `hardware-notes.md` §3). Currently a register file with no floppy
     side effects. LOS barely uses them; a Mac `.Sony` init might.
   - Sony subcommands still returning `ErrorCode.notIssued` (9):
     `format=3`, `verify=4`, `formattrk=5`, `verifytrk=6`,
     `read_bf=7`, `write_bf=8`
     (`FloppyController.SubCommand`, `performExCmd` default).
   - `DISKSTAT` / VIA2-PB4 completion vs. what this driver polls
     (`hardware-notes.md` §9). LOS is happy; MacWorks may not be.
   - `$b22` / `$b2e` low-memory flags — if `$b22==0` the scan at
     `$407d40` is a no-op. Find who sets them.
   - IWM at `$DFExxx` — **only if the trace lands there.**

Do **not** start with `$C015` or Widget. The 400K `'LK'` disk is already
the right media.

### P1 — 800K double-sided Sony ✅ DONE

**Both halves landed, and the second one was not on this list.** `$C015` is
now derived from the inserted media (`FloppyController.intDiskId`) — but that
alone still ejected the 800K installer, because the double-sided BLOCK ORDER
was also wrong (§1′ item 2). Only after the interleave fix does the volume
mount. The original note follows.

#### P1 as originally written

`$C015` is hardcoded to `1` (single-sided). `DISKFLG` already follows
`blockCount > 800`. That combination cannot exist on real hardware
(`hardware-notes.md` §9, M3 Task 3 note; `FloppyController.insert`
doc comment). Needed for the 800K installer and any real System 6 disk.

### P2 — VIA2 shift register (sound handshake) — NOT needed for the desktop

Still unimplemented; System 6 reaches its Finder desktop anyway. Keep it on
the roster for when something actually waits on IFR bit 2 (see §4.4′). The
original note follows.

SR interrupts (IFR bit 2) + ACR shift modes. Required before a booted
Mac System beeps. See §4.4.

### P3 — Widget as a Mac volume ✅ DONE, and cheaper than feared

MW Install formats a blank Widget and installs to it using **ordinary
single-block writes** — no `Formatcmd` ($02), no multi-block ($26), so
`WidgetDrive`'s single-block T_Seagate contract was already sufficient. The
`$0D` handshake (§1′ item 4) was the only thing missing, and it is a floppy
cell, not a Widget one. A `blank` Widget was used exactly as advised; the
user's `OS31-installed.widget` was never touched. The original note follows.

`WidgetDrive` rejects multi-block (`$26`) and format (`m5-demo.md`,
`WidgetDrive.swift`). LOS install never needed them. A MacWorks HD
install / format might. A LOS `.widget` is a Lisa volume — use a
**blank** Widget + the 800K installer, not `OS31-installed.widget`.
"Share with MacWorks" is a partition layout, not a new controller.
SCSI stays out of scope (Plus II).

### P4 — input through MacWorks' translator ✅ DONE

COPS keycodes and mouse deltas do become Mac Toolbox events. Two harness
changes were needed and are now in `lisadbg` (§7′): the steering has to read
the **Mac's** cursor, and a Mac samples the mouse button at VBL so a
double-click needs longer button phases than the Lisa's event-queue driver.
The original note follows.

COPS already delivers Lisa keycodes + mouse deltas. After Finder,
confirm they become Mac Toolbox events. VBL is already ~60 Hz.

### Explicitly not the work

- Macintosh IWM/VIA/SCC as a second machine (unless P0 trace demands IWM)
- SCC receive, contrast DAC, serial-number PROM, host audio
- Building a Mac from scratch
- Committing images, ROM fragments, or splash screenshots

---

## 7. Code map (where to look, where to change)

| Path | Why |
|---|---|
| `Sources/LisaCore/FloppyController.swift` | Sony HLE. `SubCommand`, `Cell`, `insert`/`eject`, `$C015` note |
| `Sources/LisaCore/VIA6522.swift` | SR is a plain store (index 10). CA1/CA2 unmodeled |
| `Sources/LisaCore/IODispatcher.swift` | `$C015`, VIA1/VIA2 decode, unknown-I/O `0xFF` |
| `Sources/LisaCore/WidgetDrive.swift` | rejects format + multi-block |
| `Sources/LisaCore/MMU.swift` | already sufficient (Mac ROM runs) |
| `Sources/lisadbg/main.swift` | `bootdisk`, `insert`, `eject`, `d`/`m`/`t`/`g`/`sc` |
| `docs/hardware-notes.md` §3 VIA, §9 floppy, §10 Widget | cited constants |
| `docs/m2-demo.md` / `m5-demo.md` | LOS floppy / Widget baseline |

`lisadbg` at the splash:

```
d 400628 40
d 407d40 20
d 407dcc 30
m fcc000 48          ; Sony window: DISKCMD=$01 DISKPARM=$03 DISKERR=$11 DISKSTAT=$5F
m 0000b22 2
m 0000b2e 2
m 100000 8           ; A6 buffer — want 4c 4b after a good _Read
```

`diskStatus` only prints `disk=IN/OUT blocksRead=N`. It does **not** print
`lastError` / `commandsProcessed`. Peek `$FCC011` (DISKERR) and `$FCC05F`
(DISKSTAT) instead, or add a debug print — do not expand scope until P0
is classified.

### 7′. Tooling added while solving this (2026-08-15, PR #7)

None of the four fixes was findable with the debugger as it stood. In order of
how much each one paid for itself:

| Command | What it answers |
|---|---|
| `gu <hexaddr> [cycles]` | Run until PC = addr. `g` can only stop on a cycle count and `t` cannot be walked through the splash's `$40000`-iteration delay loop, so there was no way to stop on the one instruction that mattered. Reports `reachedPC` / `budgetExhausted` / `halted` / `poweredOff`. |
| `gw <hexaddr> [cycles]` | Run until a byte CHANGES. "Does anything ever write this flag?" has no answer a breakpoint can give — this is what proved `diskInPlace` was never written across 600M cycles. Peek-sampled, so watching an I/O address cannot toggle a latch. |
| `iot clear` / `iot limit <n>` | The `ioTrace` cap is a **TOTAL, not a rolling window**: it fills during POST, after which `g`'s "I/O touches this slice" list prints empty — which reads as "the guest touched no I/O" when it means "the log filled up". Clear it right before the slice you care about. |
| `widget log` | `WidgetDrive`'s `log` closure is not wired up by `lisadbg`, so rejections and retry loops were invisible. Run-length summarized. |
| `guest mac` / `guest lisa` | Which guest's cursor the click/moveto/press/drag steering reads back. Under `mac` it reads the Macintosh `Mouse` global (`$830`, a Point — **v/y first, then h/x**) and MEASURES the delta signs rather than assuming them. |

**The profiling idiom that found `$0D`** — when a guest hangs, ask which
address it is hammering before theorising about which subsystem is at fault:

```
iot limit 40000
iot clear
g 2000000
```

then sort the `io` lines by frequency. 39,945 reads of one cell named the bug
in a single run.

### 7″. Harness gotchas (learned the hard way)

- **You cannot boot the Widget directly.** The Lisa ROM rejects a
  Mac-formatted disk with **`23 ERROR`**. The MacWorks boot floppy
  (`macworksplus_boot_1.1H_cp2.dc42`) must load the Mac ROM first; it then
  finds and boots the attached Widget by itself.
- **`bootdisk` picks the wrong device when a Widget is attached.** Its
  hardcoded `(88, 33)` is STARTUP FROM **row 1 = the Widget**; row 2 (`88,
  68`) is the floppy. The rows are the ports, and both appear whether or not
  media is present. Drive it explicitly: `click 420 182` then `click 88 68`.
- **Settle between `eject` and `insert`** (§3′) — adjacent lisadbg commands
  run zero cycles between them.
- **A boot WRITES to the image.** Every run here used copies; the user's
  `MacWorks-Widget.widget` and `OS31-installed.widget` were verified
  byte-unchanged.

## 8. Suggested first session (P0 only) — ~~pending~~ COMPLETED 2026-08-15

*(Kept as written. Step 3's instruction to trace `$A815` was followed and the
answer was "hypothesis 2, and it does not matter" — §4.3′. Step 5's "smallest
HLE change that makes `_Read` return `'LK'`" turned out to be a single byte:
DISKIN `$FF`. The success criterion in P0 — `'LK'` at `$100000` — was met, and
then some.)*

1. Reproduce §3. Confirm splash + `blocksRead=310`.
2. Do **not** write floppy/VIA code yet.
3. At the splash, resolve `$A815` and `_Read` to a PC. Disassemble until
   the first device access. Write the destination address + the first
   `$FC`/`$DF`/VIA touch into this file (append, strike if you refute §4.3).
4. Classify the path (Lisa Sony / VIA disk-enable / IWM / SCSI / no
   drive-queue).
5. Only then make the smallest HLE change that makes `_Read` return
   `'LK'` from `macworksplus_1.0.2_install_198809_400k.dc42`.
6. Stop at `'LK'` seen or at a new cited wall. Do not chase 800K, sound,
   or Widget in the same change.

Success screenshot (outside the repo): splash replaced by Happy Mac or
the MW+ Installer. Failure that still counts as progress: a cited
`$A815` target and one classified I/O access.

---

## 9. Surviving roster

- **MacWorks Plus II 2.5.0 — VIA2 CA1 (§10).** The one item here with a
  known root cause, a bounded scope and an acceptance test.

- **VIA2 shift register / SR interrupts** (§6 P2) — for whatever first waits
  on IFR bit 2. Nothing has yet.
- **`clampcmd` (sub-command 9)** — MacWorks issues this Twiggy-only command in
  the hard-disk configuration. Answering it as a success no-op was tried and
  REVERTED: DISKERR went 9 → 0 as intended and changed nothing observable, and
  no source states what real Sony firmware returns for a Twiggy-only
  sub-command. Documented on `FloppyController.SubCommand.clampcmd`.
- **`$0D` clear timing** — currently fires when the go-byte is consumed, which
  for `excmd` PRECEDES the data-completion interrupt. If a guest is ever seen
  waiting on `$0D` for an excmd's DATA rather than its ack, move the clear to
  `raiseCompletionLineAfterDelay`.
- **A scripted end-to-end MacWorks regression test.** Everything above is
  reproducible by hand but nothing pins it. The `$FF` DISKIN value, the 800K
  interleave and the `$0D` clear each have a unit-level pin; the boot itself
  does not.
- **Go-byte `$84`** is answered as a generic unrecognized-go-byte ack. What it
  actually commands is unknown; MacWorks only uses its DISKERR result.

---

---

## 10. MacWorks Plus II 2.5.0 — diagnosed 2026-08-15, NOT fixed (next milestone)

> **SUPERSEDED 2026-08-15 by §10′.** The root cause recorded below — "CA1 is
> unmodeled, so the flag never sets" — is **refuted**. The emulator already
> raises IFR2 bit 1 on COPS byte-ready. Read §10′ first; the symptom
> observations here are all still accurate, only the diagnosis is not.

~~**Status:** root-caused, bounded, and deliberately not started. It needs one
emulator capability the Lisa OS never forced us to build, and adding that
capability is milestone-sized.~~

### Images

`~/Development/LisaImages/MacWorksPlusII/` — both well-formed DC42:

| File | Blocks | Notes |
|---|---|---|
| `MW+II 2.5.0 BOOT disk.dc42` | 800 (400K) | Lisa boot block (`46FC2700`), DC42 name is literally `-not a Macintosh disk-` |
| `MW+II Install V2.5.0.dc42` | 1600 (800K) | `'LK'` Mac volume, "MW+II Install v2.5.0" |

### Symptom and root cause

Boot it and you get a garbage band across the top of the screen and nothing
else. Reproduced headlessly: `PC = $023742` in the Lisa-side loader,
`SR = $2704` (IPL 7), `blocksRead` frozen at 21. Profiling the slice
(`iot clear` then `g 2000000`) gives one address, 40,000 times: `$FCDD9B` =
**VIA2 IFR**.

The loop (addresses only; guest code is not transcribed here — §4's
redaction note applies):

- `$023736` loads a 2047-iteration timeout counter
- `$02373A` tests **IFR2 bit 1 = CA1**
- `$023742` `dbne`s back until CA1 sets or the count expires
- `$023748` on success reads **PORTA2 reg 1 (`$FCDD83`)** — the COPS data
  port, and the read that clears CA1 on real hardware

It **never polls CRDY** ~~: zero accesses to `$FCDD81` in the entire boot~~,
unlike the Rev H ROM and the Lisa OS. ~~So MacWorks Plus II drives the COPS
purely through the CA1 handshake, times out, and an outer loop retries
forever.~~

**Corrected 2026-08-15 (§10′):** "zero accesses to `$FCDD81`" is wrong as
stated — a pre-spin trace records **3,476** reads of it. They are not CRDY
polls: `$FCDD81` is PORTB2, and `IODispatcher` puts the **floppy completion
line** on bit 4 (DDRB2 = `$AF` leaves only bits 4 and 6 as inputs), so the
guest is polling the disk handshake and CRDY on bit 6 merely rides along in
the same byte. The substance survives — MacWorks Plus II never polls CRDY
*as CRDY* — but the address is touched constantly.

~~This is the fifth instance of one pattern — DISKIN, the 800K interleave,
cell `$0D`, `clampcmd`, now CA1: **a signal the Lisa OS's own habits left
unconstrained, which a second guest depends on.**~~ Not an instance of that
pattern at all — see §10′.

### ~~Why it is a milestone and not a patch~~ (REFUTED — see §10′)

The Lisa OS **already enables CA1** — see hardware-notes.md "VIA2 CA1" for
the traced evidence (IER2 `$82` six times, PCR2 positive-edge, 93 reads of
the CA1-clearing handshake port per boot). So this is genuine hardware
fidelity, not a MacWorks-specific hack — but it also means the risk is live:

- CA1 interrupts are enabled on a **level-2** line during every normal boot.
- ~~Asserting IFR bit 1 starts dispatching an OS interrupt path that has
  **never executed** in this emulator.~~ **False** — the COPS HLE raises
  IFR2 bit 1 on every key and every mouse packet, so that path has run
  continuously since M4.
- ~~That path races the existing COPS model, whose delivery is gated on read
  counts — a concrete double-consume hazard for keyboard and mouse bytes.~~
  **False** — `COPS` already owns both the raise and the clear; there is no
  second writer to race.
- ~~Every checkpoint FNV, menu anchor, input pin and print test is exposed.~~
  Not by this; nothing in the emulator needs to change for the flag to set.

~~Comparable in shape to M4's COPS handshake rework, which the ledger calls
"the frontier gate".~~

### ~~Scope sketch~~ (obsolete — see §10′)

1. Model CA1 in `VIA6522`: edge selection from PCR bit 0, IFR bit 1, clear
   on a register-1 (handshake) PORTA read, IER gating for the IRQ line.
   `setInterruptFlag(_:)` and the `onPortAAccess` hook already exist.
2. Decide what asserts it — COPS byte-ready is the evident answer — and
   reconcile with the CRDY/read-count gate so a byte cannot be consumed
   twice.
3. Re-validate the full env-gated suite: checkpoint FNVs, menu anchors,
   COPSTests, the M1c input pins, ROMPrinterTests.
4. CA2 is unmodeled too; decide whether it is in scope or explicitly parked.

### Acceptance test

MacWorks Plus II 2.5.0 boots past `$023742` and reaches its splash — with
every existing Lisa OS anchor unchanged. That is a clean pass/fail, which is
what makes this a good milestone rather than an open-ended one.

### Repro

```
cp "$HOME/Development/LisaImages/MacWorksPlusII/MW+II 2.5.0 BOOT disk.dc42" /tmp/mw2boot.dc42
printf 'bootdisk 80000000\nd 23730 20\niot limit 40000\niot clear\ng 2000000\n' | \
  .build/release/lisadbg --rom ~/Development/LisaROMs --disk /tmp/mw2boot.dc42
```

## 10′. What it actually is (2026-08-15, M9 opening probe) — a keyboard prompt

§10's symptom observations are all reproducible. Its *diagnosis* is not. Two
independent lines of evidence — one live trace, one static read of the boot
image — say MacWorks Plus II is not blocked on an unmodeled hardware signal.

### The flag was never the problem

`VIA6522` has no CA1 edge logic, but the COPS HLE supplies the externally
observable half of CA1 and always has: `IODispatcher` wires COPS's
`raiseInterrupt`/`clearInterrupt` onto `VIA6522.setInterruptFlag(0x02)` /
`clearInterruptFlag(0x02)`; `COPS.scheduleDeliveryIfIdle` raises IFR2 bit 1
when a byte becomes ready, `COPS.handleByteConsumed` clears it on a
register-1 handshake read, and `COPS.armReassertTimer` re-raises it if
software blanket-clears IFR. **IFR2 bit 1 sets on every keystroke and every
mouse packet in this emulator**, and has since M4. See the correction block
in hardware-notes.md "VIA2 CA1".

### The loop is a receive helper, and it is bounded

The boot image contains the traced code, and the instruction offsets pin the
mapping exactly (file offset `0x2FF2` ↔ memory `$023736`; the `btst` at +4
and the `dbne` at +12 match the recorded PCs byte-for-byte).

`$023736` is a **"receive one COPS byte, or give up"** subroutine: load a
2047-try budget, poll IFR2 bit 1, and on success read PORTA2 reg 1 — then
`rts` **on both paths**, returning `D0.w = $FFFF` when it times out. Nothing
here loops forever.

Its caller at `$02370C` is a COPS input-stream drain implementing the §4
Input Packet State Machine: `$00` → mouse packet (2 more bytes), `< $80` →
keycode, `$80` → reset code (sub-code, and if `$E0-$EF`, 5 clock bytes).

### The callers are user prompts

Four call sites reach the drain. Each loops `DBPL` around it — retrying only
while the helper *times out*, exiting the instant any byte arrives:

| Site | Retry budget | Waits for | Keycaps |
|---|---|---|---|
| `$022F1E` | drain-until-quiet | — | startup COPS flush |
| `$02315C` | `#$0087` = 135 (~14M cyc) | `$5C`/`$DC`, `$06`/`$86` | **Space**, **mouse button** |
| `$023220` | — | `$86`, `$A0`, `$D8`, `$C4` | — |
| `$023CD4` | `#$0FD6` = 4054 (~414M cyc) | `$E7`, `$EF` | **Y**, **N** |

Keycap `$5C` = Space (`Sources/LisaShell/KeyMap.swift:96`), `$06` = mouse
button (M1c), `$67` = Y and `$6F` = N (`KeyMap.swift:64,53`); bit 7 set is
key-down. Site `$02315C` is exactly the 2.5.3 build's own string
`HOLD DOWN SPACE BAR OR MOUSE BUTTON / TO ADJUST STARTUP CONFIGURATION`;
site `$023CD4` is a yes/no prompt that reprints and re-waits on any other
key.

**So the machine is sitting at a prompt waiting for a keypress.** The 40,000
reads of `$FCDD9B` per 2M cycles are the sound of an unanswered prompt, not
a failing handshake. `SR = $2704` (IPL 7) at the spin confirms the loop is
purely polled — no interrupt could be delivered there even with CA1 fully
modeled.

The prompt routine also does `jsr $00FE00B8` — a call into the **Lisa boot
ROM** — on each pass, which is a candidate for the garbage band across the
top of the screen and is independent of anything COPS-related.

### 2.5.3 behaves identically — don't chase a newer build

The MacWorks Plus II 2.5.3 installer's data fork is the booter blob itself,
and a spliced 2.5.3 boot disk boots and parks the same way (same
single-address profile, 40,000 reads of `$FCDD9B`). The receive helper is
byte-identical between 2.5.0 and 2.5.3, with the same four call sites and
the same `#$0087` / `#$0FD6` budgets.

### Symbol-overlay warning

`lisadbg`'s Linkmap overlay labels MacWorks guest code with **LisaGraph**
symbols — `CKY2RGRS` (`$023644`), `DRAW1BAR` (`$023CE6`), `BGSTRIPB`
(`$023F76`) are all from `linkmap-lisagraph.TEXT.unix.txt`, colliding with
MacWorks' `$02xxxx` load addresses. They are meaningless here; `DRAW1BAR`
and `BGSTRIPB` are bar-*chart* routines, not evidence about the screen. This
is `LinkmapSymbols.swift:52`'s "all 22 maps are app maps" hazard in the wild.

### CONFIRMED LIVE 2026-08-15 — one keystroke boots it

Run: reach the wait loop, run **60M further cycles with no input**, then a
single `type y`, then run on.

| | no key, +60M cyc | after `type y` |
|---|---|---|
| PC | `$02373A` (still in the poll) | **`$423A9E`** |
| `blocksRead` | 21 | 279+ |
| `mmuPortWrites` | 4384 | 4608 |
| disk | IN | **OUT** (guest ejects it itself) |
| COPS | — | `powerCmds=[$25]` accepted |

Sixty million cycles is more than four times site `$02315C`'s ~14M budget,
so that site is ruled out: the boot parks at **`$023CD4`, the Y/N prompt**
(4054 retries ≈ 414M cycles — which is why 80M-cycle repro runs looked like
an infinite hang). A single keystroke releases it; MacWorks Plus II then
loads ~258 more blocks, programs the MMU, ejects the Lisa boot floppy on its
own, drives the COPS successfully, and **reaches `$423A9E` — inside the
patched Mac ROM at `$400000`**, the same takeover MacWorks Plus 1.1 does.

**So there is no emulator-capability gap, and nothing about CA1 needs
building.** MW+II 2.5.0 boots on the existing hardware model.

```
printf 'iot limit 10\nbootdisk 1000\ngu 23736 60000000\ng 60000000\nr\ntype y\ng 300000000\nr\n' | \
  .build/release/lisadbg --rom ~/Development/LisaROMs --disk <copy of the 2.5.0 boot disk>
```

### What actually remains open

1. **The display is wrong.** The "garbage band" is not a legible prompt: it
   renders as structured but misaligned character cells across the top rows,
   growing as the boot proceeds. Suspect a framebuffer base/stride
   disagreement between what MW+II programs and what scanout reads — this is
   the real bug, and it is why the prompt was never readable.
2. **A Mac volume is wanted next** — the guest ejected the boot floppy, so
   the `'LK'` 800K installer (`MW+II Install V2.5.0.dc42`) is the next thing
   to feed it.
3. `$FE00B8` (the boot-ROM call the prompt routine makes each pass) is still
   uncharacterized, and may or may not relate to item 1.
4. Whether the prompt needs answering on real hardware at all, or whether
   PRAM startup settings normally satisfy it (the 2.5.3 build's strings
   mention `USING STARTUP SETTINGS STORED IN PRAM`, and `PFG` clips).

## 10″. The display bug — one latch lane (2026-08-16, FIXED)

§10′ left "the display is wrong" as the only real defect. It was a
**one-lane video-latch decode bug**, and MacWorks Plus II now reaches its
splash screen.

### Symptom

Everything MW+II drew was invisible; the screen showed a growing band of
structured noise. Pulling the framebuffer back out of a `sc` screenshot (the
PNG is 1bpp 720×364 = the 32,760 raw bytes verbatim) and autocorrelating it
gave a dominant period of **4 bytes**, not any row stride — plus byte groups
like `ff bf ee d7 / ee d5 / ee d3` (a table stepping by −2) and `55555555` /
`aaaaaaaa` memory-test patterns. That is not a screen at all: we were
scanning out **physical page 0**, which MW+II uses for data.

### Cause

`Bus.framebufferSnapshot()` reads RAM at `videoPageLatch << 15`, and
`IODispatcher` latched only on an exact write to offset `$E800`. MacWorks
Plus II sets the screen with a **word** write:

```
io 00E800 W 00  [video page latch]
io 00E801 W 3E
```

so the real page (`$3E` → `$1F0000`, top of RAM) landed on the odd byte and
was dropped; we kept the `$00`. The Rev H ROM and the Lisa OS both write the
latch as a `MOVE.B` to the even address, which is why six milestones of
Office System work never exposed it — the same "unconstrained by the Lisa
OS's habits" shape as DISKIN, the 800K interleave, cell `$0D` and `clampcmd`.
(So §10's "fifth instance of one pattern" claim was right about the pattern —
just wrong about which signal.)

### Fix

`IODispatcher.applyNonLatchWrite`: `case 0xE800, 0xE801`. `Bus` decomposes a
word write into even-then-odd byte writes, so last-write-wins takes the low
byte for a word write and leaves the ROM/OS byte path bit-identical. Write
side only — no guest has been seen reading `$FCE801`. Full citation block on
the case; hardware fact recorded in hardware-notes.md §2 "VideoLatch".
Pinned by `IODispatcherTests.videoPageLatchTakesTheLowByteOfAWordWrite` and
`...ByteWriteToEvenAddressIsUnchanged`.

### Result

`MacWorks Plus II 2.5.0` splash renders correctly — logo, the 1994 Query
Engineering / Dafax / Sun Remarketing / Apple copyright block, version
`II2.5.0`, the floppy-`?` icon and the mouse cursor. Artifact (outside the
repo): `~/Development/LisaEmu-artifacts/mw2-fixed.png`.

Repro, end to end from cold:

```
iot limit 10
bootdisk 1000
gu 23736 60000000     # the Y/N startup prompt (§10′)
type y
g 300000000           # -> $423Axx, inside the patched Mac ROM
insert <MW+II Install V2.5.0.dc42 copy>
g 400000000           # blocksRead 340 -- volume mounted
sc <artifacts>/mw2-fixed.png
```

### Still open

The splash shows the floppy-`?` icon, i.e. it is still asking for a
*bootable* Mac volume — the 800K disk is the installer, and per §1′/§6 the
MacWorks route is to install onto a Widget rather than boot the installer.
Driving MW+II's installer to build a bootable volume is the next step, and
is now unblocked because the screen is readable.
