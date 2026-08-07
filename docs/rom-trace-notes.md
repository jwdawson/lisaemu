# Rev H Boot ROM — Execution Trace Notes (M1a exit criterion / M1b requirements)

This document records the observed behavior of the real Apple Lisa Rev H boot
ROM (`341-0175-H.BIN` / `341-0176-H.BIN`, interleaved per `ROMImage`) running
under the M1a emulator, and derives the requirements M1b must satisfy. Every
claim is reproducible with `swift run lisadbg --rom $HOME/Development/LisaROMs`
using the `t` (per-instruction trace) and `g` (run-N-cycles, dump SLIM/SORG +
I/O deltas) commands added in Task 7, and is exercised by
`Tests/LisaCoreTests/ROMBootTests.swift` (env-gated on `LISAEMU_ROM_DIR`).

Address/constant citations are to `docs/hardware-notes.md` unless noted.

## Summary

Under the current (M1a) model the ROM executes ~75,000 instructions of its
power-on sequence: it validates its own checksum, runs a full MMU register
self-test across all 128 segments and all 4 domains (4132 SLIM/SORG port
writes), programs the real domain-0 segment map, and drops setup mode
(`clr.b $fce012` at `$FE0440`). Its **next instruction fetch faults**, because
that fetch is now MMU-translated through segment 127 (prom), whose access
nibble `$F` the M1a `MMU.translate` does not decode. Exception stacking faults
again → double bus fault → HALT. This is the clean M1a→M1b boundary: **the ROM
runs; translated-mode access to prom/io special space is the first thing M1b
must add.**

The ROM never reaches VIA/COPS/status/board-ID device init under the current
model — it halts upstream of all of it.

## Reset vectors

Interleaved image, big-endian, vector 0 = SSP, vector 4 = PC:

- **SSP = `$00000480`** (initial supervisor stack, low RAM)
- **PC  = `$00FE00F6`** → masks to `$FE00F6`, inside the ROM window
  `$FE0000-$FE3FFF`.

(Confirmed post-reset by `ROMBootTests.resetVectorsMatchDocumentedValues`;
lane order verified in Task 6 / `ROMImage`.)

## First instructions — warm-vs-cold boot decision

```
FE00F6: move.w  $fc8000.l, D0     ; read SLIM[seg126] (iospace) via port $8000
FE00FC: andi.w  #$fff, D0
FE0100: cmpi.w  #$901, D0         ; already initialized? (iospace SLIM == $901)
FE0104: bne     $fe0152           ; COLD boot (our case: reg reads 0) -> full init
FE0106: andi.w  #$fff, $fc8008.l   ; seg126 SORG re-check (mask in place) ...
FE010E: bne     $fe0152           ; ... nonzero SORG -> also COLD path
   ; --- warm path (skipped on cold boot) explicitly programs the real map: ---
FE0110: move.w  #$700, $8000.l     ; seg0   SLIM = $700  (readWrite, 256 pages)
FE0118: move.w  #$901, $fc8000.l   ; seg126 SLIM = $901  (iospace, nibble $9)
FE0120: move.w  #$f00, $fe8000.l   ; seg127 SLIM = $F00  (prom,    nibble $F)
FE0128: clr.w   $fe8008.l          ; seg127 SORG = 0
```

`$fc8000`/`$fe8000` are the SLIM ports of segments 126/127 (`SLIM = $8000 +
seg*$20000`); `$8000` is seg0 SLIM; `$fe8008` is seg127 SORG. The warm path at
`$FE0110-$FE0128` is the **primary-source ground truth** for the real hardware
special-segment SLIM values (see "MMU programming" below).

## ROM checksum self-test

```
FE0194: clr.l   D0
FE0196: lea     (-$198,PC), A0       ; A0 = $FE0000 (ROM base)
FE019A: lea     ($3e62,PC), A1       ; A1 = $FE3FFE (last ROM word)
FE019E: add.w   (A0)+, D0            ; sum each ROM word ...
FE01A0: rol.w   #1, D0               ; ... with a rotate between adds
FE01A2: cmpa.l  A0, A1
FE01A4: bne     $fe019e              ; loop over $FE0000..$FE3FFE (8192 words)
FE01A6: add.w   (A0)+, D0            ; + final checksum word at $FE3FFE
FE01A8: bne     $fe00c8              ; nonzero => checksum FAIL -> error path
```

The real ROM checksums to zero (our image is genuine); the `bne` at `$FE01A8`
is **not** taken, and execution proceeds to the MMU self-test dispatcher at
`$FE01B0+` (uses A4/A6 as return links via `bra`/`jmp (A6)`). This is the first
~40,000 instructions and touches **no** IODispatcher-visible I/O — only
SLIM/SORG ports (logged in `Bus.mmuPortLog`, not `ioTrace`) and RAM.

## MMU programming (which segments, decoded values, which domain, setup timing)

### Register self-test

The MMU test inner loop (`$FE0286-$FE029A`) walks bit patterns
(`$55A`,`$AA5`,`$B5A`,…) through every SLIM/SORG register, reading each back
and `eor`-verifying (`FE0288: eor.w D0,D1` / `FE028E: bne $fe02b0` error
branch). It covers **all 128 segments in all 4 domains** — a total of
**4132 SLIM/SORG port writes** (deterministic; asserted in
`ROMBootTests.romTouchesIOAndProgramsMMU`). The first port write is
`domain 0, seg 0, SLIM = $55A`.

**Setup mode is ON for the entire self-test** (translation off; SLIM/SORG
ports reachable at flat `$xx8000/$xx8008`). Setup is dropped exactly once, at
the very end (`$FE0440`, below).

### Domain choreography and the context latches

`bus.domain` is driven only by the context latches `$FCE008/A` (bit1 off/on)
and `$FCE00C/E` (bit2 off/on). Across the whole boot the ROM touches these
exactly 8 times (the only IODispatcher-visible I/O besides the final
setup-off), producing the domain sequence

```
$FCE00A ON  -> 1     $FCE00A ON  -> 1
$FCE00E ON  -> 3     $FCE00E ON  -> 3
$FCE008 OFF -> 2     $FCE008 OFF -> 2
$FCE00C OFF -> 0     $FCE00C OFF -> 0
                     $FCE012     -> setup OFF
```

Domain 0 is programmed **first** (while it is the current/active domain, before
any context toggle); the ROM then selects domains 1/3/2 in turn and programs a
full 128-segment pass into each, then a second pass clears domains 1/3/2 back
to absent. **The active domain at setup-drop is 0.**

### Final domain-0 map at setup-drop (the map translation will run under)

| Seg      | Name    | SLIM  | Decoded                          | SORG |
|----------|---------|-------|----------------------------------|------|
| 0–15     | RAM     | `$700`| readWrite, 256 pages             | 0    |
| 16–125   | —       | `$C00`| absent                           | 0    |
| 126      | iospace | `$900`/`$901` | access nibble **`$9`**    | 0    |
| 127      | prom    | `$F00`| access nibble **`$F`**           | 0    |

Segments 0–15 with SORG 0 identity-map the low 2 MB of logical space to the
2 MB of physical RAM (readWrite). Segments 126/127 are **special hardwired
decodes** selected by access nibble, not origin-relative (SORG = 0).

## Where it first reads VIA / COPS / status — and what it waits for

**It does not.** Before the halt, the only IODispatcher-visible accesses are
the 8 domain-context-latch reads and the final setup-off write. There are **no**
reads of the board ID (`$FCC031`), VIA1 (`$FCD801`), VIA2/COPS (`$FCDC01`),
status register (`$FCF800/1`), or video latch (`$FCE800`). All device
initialization lies **beyond** the setup-drop boundary and is therefore an M1b
concern; the trace cannot yet observe what the ROM waits on.

## Where execution stalls / faults (PC + disassembly)

```
FE0440: clr.b   $fce012.l   ; SETUP OFF -> translation active (io 00E012 W)
FE0446: clr.l   D0          ; next fetch: MMU-translated as segment 127 (prom)
```

At `$FE0446` the CPU fetches its next instruction through the now-active MMU.
PC `$FE0446` is in segment 127, whose SLIM is `$F00` (access nibble `$F`).
`MMU.translate` decodes only nibbles `$5/$6/$7/$8` (and treats `$C` +
everything else as absent), so nibble `$F` → `.fault(.invalidSegment)`. The
resulting bus error's exception stacking then faults again (low-RAM vector
fetch / stack), which `Bus` detects as a double bus fault and force-HALTs the
core (`forceHaltHandler`). Post-halt PC is garbage (`$27180004`) and Musashi's
cycle counter saturates (`26654648`); the meaningful diagnostic is the
faulting fetch address `$FE0446` and the undecoded prom nibble `$F`.

(`ROMBootTests.romReachesSetupDropBoundaryThenHalts` asserts `setupMode==false`,
`domain==0`, `halted==true` at 2 M cycles.)

## Beyond the M1a boundary (Trace checkpoint A)

Now that M1b Task 1 dissolved the setup-drop halt (`MMU.translate` decodes the
ROM's special nibbles `$9`/`$F`), execution runs on past `$FE0446`. This
section records where it goes, everything it touches, and what it finally
stalls on. Reproduce with `swift run -c release lisadbg --rom
$HOME/Development/LisaROMs`, then `g <cycles>` (cumulative). All observations
below are at the current M1b stub set (VIA read-back stubs at bases
`$D801`/`$DC01`; COPS absent; status byte 0; `$C031 == 0x00`; unknown IOSpace
and special `$4000+` → `0xFF`).

### PC frontier over time (deterministic under Musashi)

| Cycles | PC        | What it is doing                                            |
|--------|-----------|------------------------------------------------------------|
| setup-drop | `$FE0440` | `clr.b $fce012` (mmuPortWrites=4132)                    |
| 2 M    | `$FE0F00` | `move.l D1,(A0)+` — a low-RAM fill loop (A0→`$1FE61C`, top of 2 MB); mmuPortWrites=4384 (252 more MMU writes happened just past the boundary) |
| 5 M    | `$FE35FE` | `dbra D2,$fe35f2` — a delay/scan loop in the `$FE35xx` block |
| ~5.5 M | `$FE08B0` | enters the VIA2 register self-test **retry loop** (below)  |
| 10–60 M| `$FE08B4`/`$FE08BE` | **stuck** — infinite retry of that self-test    |

Still `setup=OFF`, `domain=0`, `halted=false` throughout. This is a **live
busy-loop, not a halt**: the CPU never faults, it just never satisfies a device
presence test. (The `ioTrace` cap of 4096 entries saturates by ~5.5-6 M cycles
— i.e. right as the retry loop begins hammering `$DD8D`/`$DD8F` — so `g`'s
per-slice I/O dump goes empty for every later slice: an artifact of the trace
buffer filling, not of the CPU going quiet; the PC samples confirm it is still
spinning.)

### The hard stall — VIA2 register self-test (`$FE07B8`, target `$FCDD81`)

The stall is a read/write **memory-presence test** on two VIA2 registers,
driven from the retry loop at `$FE08B0`:

```
FE08B0: lea     ($546,PC), A3        ; A3 = $FE0DF8 (a bus-error handler)
FE08B4: move.l  A3, $8.w             ; install it at BUSERRV ($8) — probe guard
FE08B8: movea.l #$fcdd8d, A0         ; A0 = VIA2 reg (base $DD81 + $C = T1LL2)
FE08BE: moveq   #$2, D0              ; A1 = A0 + 2 = $FCDD8F (T1LH2)
FE08C0: lea     ($6,PC), A6          ; return link
FE08C4: bra     $fe07b8              ; run the R/W test
FE08C8: beq     $fe08d6              ; pass? (D0 == 0)
FE08CA: bset    #$a, D7              ; else mark failure bit
FE08CE: tst.l   D7
FE08D0: bmi     $fe08b0              ; D7 sign set (bit31) -> retry forever
```

`$FE07B8` clears both cells, writes `$FF`, and reads each back expecting the
written value, 256 times (`dbra D3`). Each mismatch does `addq #1,D0`; a nonzero
`D0` on return = fail. Under the current stub `$FCDD8D`/`$FCDD8F` are **unknown
IOSpace** (they fall outside the modeled VIA2 window `$DC01…$DC1F`), so reads
return `0xFF` and writes are dropped — the very first `clr.b`/read-back-`0`
mismatches, `D0` comes back nonzero every pass, and `D7` (already `$80000C00`
from earlier accumulated status) keeps `bmi` taken. **Infinite retry.**

Empirically confirmed: temporarily pointing the VIA read-back stub at the ROM's
actual bases (`$D901`/`$DD81`) so those cells hold what is written lets the test
pass — the ROM immediately advances past `$FE08B0` to a later phase (`$FE099A`).
That patch was reverted; **making VIA2 a real read/write register file is Task 3
(VIA core), not this task.**

### Device base addresses — ROM ground truth (refines hardware-notes §3)

Disassembling the accessors gives the boot ROM's own base/stride for each
6522, which **differ from `hardware-notes.md §3` as it then read** (`$D801`/`$DC01`; §3 has since been corrected to the ROM-observed bases):

- **VIA1 = `$FCD901`, stride ×8.** Used at `$FE0802`, `$FE0B6A`, `$FE1138`,
  `$FE1E14`. Register decode confirmed: `(A0)`=PORTB1, `$08`=PORTA1,
  `$10`=DDRB1, `$18`=DDRA1, `$30`=T1LL1 (`$FCD931`), `$38`=T1LH1 (`$FCD939`).
  The post-boundary `$D931`/`$D939` writes seen at 2 M are the Timer-1 latch
  loads (`hardware-notes.md §3` "VIA1 Timer1 reload").
- **VIA2 = `$FCDD81`, stride ×2.** Used at `$FE0494`, `$FE0920`, `$FE0B06`,
  `$FE11D0`, and many more. Decode confirmed from `$FE0B0C-1E`: `$04`=DDRB2,
  `(A0)`=PORTB2, `$16`=ACR2; the self-test targets `$0C`=T1LL2 (`$FCDD8D`) /
  `$0E`=T1LH2 (`$FCDD8F`).

**Task 3 must decode VIA1 at `$D901` and VIA2 at `$DD81`** (the ROM is primary
source), OR model the partial chip-select decode that makes both the `$D8xx`
and `$D9xx` (resp. `$DCxx`/`$DDxx`) aliases hit the same chip. The current
stub's `$D801`/`$DC01` window is never touched by the ROM.

### Annotated post-boundary I/O inventory

Every distinct IOSpace offset touched from setup-drop to the stall:

| Offset      | Access                                   | Device / meaning                                   |
|-------------|------------------------------------------|----------------------------------------------------|
| `$E010`/`$E012` | R/W strobe (×~126 pairs)             | setup latch on/off — `do_an_mmu` brackets each late MMU write in setupon/off (accounts for the 252 extra writes) |
| `$E008/A/C/E`   | R strobe                             | domain context latches (a few more toggles)        |
| `$E800`     | W (`$AF`,`$2F`,`$3F`, page values)       | video page latch (`hardware-notes §2`)             |
| `$E018`/`$E01A` | tst.w / clr.w                        | VertReset / VRIRENB (`hardware-notes §2`)          |
| `$E01C`/`$E01E` | tst.b bare strobe (`$FE00E2`, `$FE0D6E`, …) | **NEW, not in hardware-notes** — data-less video strobes (companions to `$E018/A`); Task 5 |
| `$F801`     | `btst #1` (`$FE00D0`, `$FE0F68`)         | status register (`hardware-notes §5`); Task 5      |
| `$C031`     | `tst.b` / `btst #5` / `move.b`           | board ID (see below)                               |
| `$D241`     | W seq `$02,$00,$09,$C0,$05,$82`, R       | unidentified I/O controller (see below)            |
| `$D901…$D939`   | W (DDR/port/timer)                   | **VIA1** (base `$D901`)                            |
| `$DD8D`/`$DD8F` | R/W self-test (thousands)            | **VIA2** (base `$DD81`) — the stall target         |

No special-space `$4000+` (SNUM at `$FE8000`/segment-127-upper) access occurs
before the stall — the ROM only reads in-ROM bytes (`$FE3FFD` version byte at
`$FE08DC`) via the `$0000-$3FFF` special window. SNUM remains unreached.

### `$C031` board ID — read, and `0x00` does NOT divert POST

`$C031` is now read (three sites: `$FE0B24`, `$FE0B2C`, `$FE119A`). The gating
branch:

```
FE0B24: tst.b   $fcc031.l      ; N = bit7 (Pepsi-or-later, hardware-notes §3)
FE0B2A: bpl     $fe0b3c        ; bit7 == 0 -> skip the Pepsi adjustment  [OUR PATH]
FE0B2C: btst    #$5, $fcc031.l ; (Pepsi only) bit5 = LisaLite
FE0B34: bne     $fe0b3c
FE0B36: move.b  D0,D3 / lsr.b #2,D3 / add.b D3,D0   ; Pepsi DAC/contrast tweak
FE0B3C: move.b  D0, ($10,A0)   ; -> VIA2 T2CL2
```

With `$C031 == 0x00`, bit7 is clear, `bpl` at `$FE0B2A` **is taken**: the ROM
takes the **pre-Pepsi path**, skipping the Pepsi-only DAC adjustment. This is a
benign, sane branch — `0x00` does not send POST into any error. The alternate
value `$80` (bit7=Pepsi) would instead run the `lsr/add` contrast tweak — also
benign, not an error. **No stub change is warranted: the `0x00` default is
correct and is the simplest documented board (pre-Pepsi, VIA1 T1 reload
`$CA/$27`).** This closes OQ3 below.

### `$D241` — unidentified controller, passes the stub (not blocking)

`$FCD241` is probed at `$FE10D0`: a short command sequence is written from a
table (`move.b (A2)+,(A0)`), and on failure the ROM loads boot **error code
`$37`/`$38`** (`$FE10F6`/`$FE10FA`). The 2 M-trace write pattern
(`$02,$00,$09,$C0,$05,$82` — a register-pointer/value cadence, `$09→$C0`
resembling a Z8530 WR9 reset) makes it a **candidate RS-232 SCC** (`RSBASE`,
flagged "not chased" in `hardware-notes.md` Known Gaps). It is **not** part of
the Task 3-5 set and, importantly, **passes with the current `0xFF` stub** — the
ROM reaches the VIA2 stall downstream of it — so it needs no immediate action;
recorded here as a future serial-device requirement.

### Wait-target table — requirements handed to Tasks 3–5

| Target            | What the ROM needs                                            | Task |
|-------------------|--------------------------------------------------------------|------|
| VIA2 `$DD81` (stride 2), esp. `$DD8D`/`$DD8F` (T1 latches) | real 6522 registers that read back written values (DDR/latch/port). **This is the current hard stall.** | **Task 3** |
| VIA1 `$D901` (stride 8): DDRB1/PORTB1/DDRA1/PORTA1/T1LL1/T1LH1 | real 6522 register file; timer-1 latch loads | **Task 3** |
| COPS / VIA2 Port A+B (`$DD81`=CRDY/PORTB2, `$DD83`/`$DD87`=DDRA2/`$DD9F`=IORA2) | **DONE (Task 4)** — real HLE `COPS` endpoint; see "COPS" section below | ~~Task 4~~ |
| `$F801` status register bit 2 (`btst #2`, vsync)          | **DONE (Task 5)** — real `VideoTiming`; see "Trace checkpoint B" below | ~~Task 5~~ |
| `$E018/$E01A` video strobes (VertReset/VRIRDIS, VRIRENB)  | **DONE (Task 5)** — arm/clear semantics validated against ROM's own access order; see "Trace checkpoint B" | ~~Task 5~~ |
| `$E01C/$E01E` video strobes                               | **DIAGNOSED, no model change (Task 5)** — bare bracketing strobes around a RAM-sizing/checksum routine, result never branched on; see "Trace checkpoint B" | ~~Task 5~~ |
| `$F801` status register bit 1 (`btst #1`)                 | still undetermined — Task 6 found all 3 statically-cited gating sites (`$FE00D0`/`$FE0F14`/`$FE0F72`) are either dead code or unconfirmed live-reached through 30M cycles; see "Bus-error frame spike" below | later task |
| `$FE2DBE` unconditional "next COPS input byte" wait        | **RESOLVED (Task 7)** — NOT a POST blocker: it is the boot MENU's "await next COPS input event" (mouse/keypress) idle loop. POST is complete and the startup menu is drawn by the time the ROM sits here; with no user input it correctly waits forever. See "POST completion (Task 7)" below. | ~~later task~~ |
| `$D241` controller (error `$37/$38`)                      | candidate SCC; passes 0xFF stub, defer       | later serial task |
| `$C031` board ID                                          | none — `0x00` (pre-Pepsi) already correct    | — |

## COPS (Task 4)

Full trace, TDD evidence, and design rationale: task-4-report.md. This
section records only the ROM-observed protocol facts (the wait-target
table row above points here); it does not attempt the Task 5 "checkpoint B"
broad re-sweep of the whole post-boundary territory.

### The presence-probe stall clears — and CRDY is on PORT B, not Port A

The `$FE0920-$FE09B2` stall the Task 2/3 wait-target table left for this
task (`btst D4,(A1)`, `A1=$FCDD81`, `D4=6`) is a poll of **PORTB2 bit 6**,
not Port A — see hardware-notes.md §4 for the full correction (the
OS-source listing's "CRDY = Port A bit 6" claim is refuted). Adding a real
`COPS` HLE endpoint behind VIA2 (command handshake + input FIFO, wired to
`via2.portAInput`/`portBInput`/`onPortAAccess`) clears this stall entirely:
the ROM's presence probe (4 commands: `$00,$70,$50,$60`, none in the
OS-derived command table — hardware-notes.md §4) succeeds, the driver-init
sequence (`ACR2=$01, PCR2|=$09, IER2=$7F, IFR2=$7F` — already documented by
Task 3) completes, and the ROM proceeds into a long pre-Pepsi contrast-DAC
calibration delay loop (`$FE0AE2`, a `subq.l`/`bne` spin burning ~3-9M
cycles depending on which of three delay constants is selected — unrelated
to COPS, board-revision contrast/DAC bit-banging per hardware-notes.md §2's
"Board-revision-dependent write paths").

### The reset packet is a fixed 7 bytes — not sub-code-conditional

The ROM's reset-dispatch handler (`$FE2D82`-`$FE2D9E`) stores the received
State-4 sub-code into `$480` and then UNCONDITIONALLY reads 5 more bytes
(`$FE2D9E-$FE2DBA`, into `$481-$485`), regardless of the sub-code's value —
see hardware-notes.md §4's added trace note. `COPS`'s power-on stream models
this as `$80, <keyboard ID>, 0,0,0,0,0` (5 zero placeholder bytes — the
COUNT is trace-validated, the VALUE is not).

### New frontier: an unconditional wait for the next COPS byte (`$FE2DBE`)

After the full power-on packet is consumed, the ROM reaches a NEW, stable
stall by ~18M cycles at `$FE2DCE` (`beq $fe2dc6`, inside
`$FE2DBE-$FE2DD6`): an unconditional (no-timeout) poll of VIA2 IFR2 bit 1,
waiting for another COPS input byte. Call chain: `$FE2624` (sets flag bit 5
of low-RAM cell `$2A2`) → `$FE2C46` (tests bit 3 of the same cell) →
`$FE2D38` → `$FE2DBE`. This reads as a later, on-going "wait for next COPS
event" primitive (distinct from the bounded-timeout receive routine at
`$FE0A7E`-`$FE0AA8` used during power-on/clock-byte reception), not part of
the documented reset-packet protocol — task-4-report.md has the full
disassembly and register-dump evidence. `COPS` has nothing further queued
to deliver at this point, so the ROM legitimately waits forever; this is the
new frontier left for a later task (task-4-report.md's "New ROM frontier"
and `ROMBootTests.romClearsCOPSPresencePollAndStallsAwaitingNextInputByte`).

### The IFR2 desync (found and fixed under trace)

Confirmed live via a `lisadbg m fcdd80 20` register dump at an early attempt
of this same stall: VIA2 PORTA2 (`peek(1)`) read back `$80` (COPS's pending
power-on reset byte, still undelivered) while IFR2 (`peek(13)`) read `$00`
(the "byte ready" flag already clear) — a permanent desync. Root cause: the
ROM's own VIA2 driver-init does a blanket `IFR2 = $7F` ("clear all") shortly
after `COPS`'s power-on interrupt has already raised IFR2 bit 1, days (in
cycle terms) before the ROM gets around to actually reading Port A. That
write reaches `VIA6522` directly and has no way to notify `COPS`, so
`COPS`'s internal "byte pending" state and the VIA's actual flag drift out
of sync, and the ROM's later no-timeout poll (`$FE2DC6-$FE2DCE`) hangs
forever. Fixed with a self-reasserting "data ready" timer (`COPS
.armReassertTimer`, task-4-report.md has the design rationale) that keeps
re-raising the flag on a fixed cadence for as long as a byte remains
genuinely undelivered — modeling how a real level-sensitive peripheral
signal would behave, since a one-shot pulse cannot survive a premature
external flag clear it has no visibility into.

## Trace checkpoint B (Task 5)

With `VideoTiming` live (vsync every 83,333 cycles, `$F801` bit 2, `$E018`
disarm+clear / `$E01A` arm), this section re-traces the post-COPS-handshake
territory the task brief asked checkpoint B to cover: does the `$FE2DBE`
frontier resolve, is the `$E018`/`$E01A` polarity right, what are
`$E01C`/`$E01E`, and does the ROM ever reach the SNUM region. Reproduced with
`swift run -c release lisadbg --rom $HOME/Development/LisaROMs`, `g
<cycles>`, and a throwaway `@testable import LisaCore` scratch test (deleted
before commit) that single-stepped through the transition and printed
`Machine`/`VideoTiming` state — not committed, but every finding below is
independently reproducible from the `lisadbg` commands shown.

### The `$FE2DBE` frontier is UNCHANGED — confirmed NOT vsync-related

Resampled at 20M, 25M, 30M, 35M, 40M, 50M, 70M, 120M, and 220M cycles (`g`):
PC never leaves `$FE2DBE-$FE2DD6` (the same unconditional `IFR2` bit-1 poll
task-4-report.md documented), and `Machine.halted` stays `false` throughout.
Two independent reasons this task's video timing cannot resolve it, both
confirmed live:

1. **The CPU's own SR interrupt mask is 7 throughout this whole region**
   (`SR=$2704`/`$2700`/`$2710`/... — bits 10-8 always `111`), sampled from
   well before $FE0BA2's vsync self-test through the $FE2DBE stall itself.
   Mask 7 blocks levels 1-6 unconditionally, so even a continuously-asserted
   level-1 vsync IRQ (`Machine.vsyncPending == true`, confirmed below) cannot
   preempt this loop — the ROM runs this entire stretch of POST with
   interrupts globally disabled.
2. **Independent of masking, `$FE2DBE`'s poll only reads VIA2 `IFR2` bit
   1** (`move.b ($1a,A0),D0` / `btst #1,D0`, `A0=$FCDD81`) — a different
   register, different device, and different interrupt level (2) than vsync
   (level 1, `$F801`/VIA1's shared line). There is no code path by which a
   vsync tick could set that bit.

So the answer to the brief's core checkpoint-B question is definitive: **the
`$FE2DBE` wait does not resolve via a vsync-timed COPS byte** — it is exactly
what task-4-report.md already characterized it as, an unconditional wait for
a *new, unsolicited* COPS input byte that this model's `COPS` has nothing
queued to deliver. No further evidence surfaced pointing to a specific
COPS message (clock reply, keyboard ID, or otherwise) that would satisfy
it — the call chain (`$FE2624` sets low-RAM flag `$2A2` bit 5 → `$FE2C46`
tests it → `$FE2D38` → `$FE2DBE`) reads as a generic "wait for the next
COPS event" primitive, not a specific reply this task's COPS model is
positioned to synthesize without inventing un-evidenced protocol content.
**Left open, precisely as before — this is beyond Task 5's video/COPS scope
as currently understood; resolving it needs either a real unsolicited event
(a later task's keyboard/mouse harness) or further disassembly of what
`$2A2` bit 5's setter (`$FE2624`) is actually gating on.**

### `$E018`/`$E01A` arm/reset polarity — validated by the ROM's own access order, model's default outcome confirmed harmless

The ROM's own vsync/vertical-retrace self-test lives at `$FE0BA2-$FE0DE4`,
reached from the pre-Pepsi contrast-DAC delay loop via
`$FE0AEA`→`$FE0B96`→...→`$FE0BA2` (confirmed live: a single-stepped trace
from 10M cycles hits `$FE0BA2` at cycle 11,880,588, ~1.88M cycles — about 22
vsync periods — after the 10M sample, well inside the documented 3-9M-cycle
contrast-DAC delay window):

```
FE0BA2: movea.l #$fce018, A3      ; A3 = VertReset/VRIRDIS
FE0BA8: movea.l #$fce01a, A4      ; A4 = VRIRENB
FE0BAE: movea.l #$fcf801, A5      ; A5 = status register
FE0BB4: move.w  #$df4, D0         ; timeout count (0xDF4 = 3572)
FE0BB8: moveq   #$2, D2           ; bit 2 (vsync pending)
FE0BBA: tst.w   (A3)              ; $E018 -- ANY access, ROM does this FIRST
FE0BBC: tst.w   (A4)              ; $E01A -- ANY access, SECOND
FE0BBE: btst    D2, (A5)          ; test $F801 bit 2
FE0BC0: beq     $fe0bc8
FE0BC2: dbra    D0, $fe0bbe
FE0BC6: bra     $fe0bd4
FE0BC8: tst.w   (A3)              ; $E018 again
FE0BCA: tst.w   (A4)              ; $E01A again
FE0BCC: btst    D2, (A5)
FE0BCE: beq     $fe0bd4           ; -> fail-mark path (bset #2,D7), non-fatal
FE0BD0: tst.w   (A3)              ; $E018 once more
FE0BD2: bra     $fe0be0           ; success path
FE0BD4: bset    #$2, D7           ; record failure flag (does NOT retry/abort)
FE0BD8: tst.l   D7
FE0BDA: bmi     $fe0ba2           ; only retries if D7's sign bit (unrelated,
                                   ; accumulated earlier) is set
FE0BDC: bra     $fe139a           ; otherwise falls through -- POST continues
```

The ROM's own access order is exactly `$E018` (clear/disarm) THEN `$E01A`
(arm) — matching this model's `VideoTiming.handleVertResetAccess` /
`handleVertEnableAccess` naming and the VRIRDIS/VRIRENB (DISable/ENable)
labels in `hardware-notes.md` §2, which this model follows over the same
section's more ambiguous "write re-arms/clears" phrasing (see
`VideoTiming.swift`'s type doc comment). A single-stepped trace of the actual
run (`armed` transitions `false`→`true` at cycle 11,880,652, immediately
after the `$E01A` access at `$FE0BBC`, exactly as the model predicts) confirms
the wiring reacts correctly to both registers in the ROM's real order.

**The self-test's own outcome is a soft, non-fatal failure under this
model — and, from the timing alone, would very likely be a soft failure on
real hardware too.** The full poll window from `$E018` (clear) to the final
`btst` is roughly 130 cycles in the observed run — several orders of
magnitude short of one 83,333-cycle vsync period — so `$F801` bit 2 has no
realistic chance of having flipped again by the time the routine samples it,
whichever of the two check sites (`$FE0BBE`/`$FE0BCC`) actually executes.
The observed run takes the immediate-fail branch both times (`beq` taken at
`$FE0BC0` and `$FE0BCE`), landing on `$FE0BD4` (`bset #2,D7`, a diagnostic
flag — not a `btst #2,D7` site was found anywhere else in the ROM, so this
flag's downstream consequence, if any, is not chased here) and then falling
straight through to `$FE0BDC`/`$FE139A` — POST continues normally. No infinite
retry occurred in the traced run (the `bmi $fe0ba2` retry only fires if
D7's *sign* bit, set by an unrelated earlier diagnostic, happens to be set;
in the traced run it was not). **No model change is needed or evidenced**:
the routine tolerates this outcome by design, and the frontier is reached
identically whether this self-test's own bit-2 sample happens to land inside
or outside a live vsync window.

### `$E01C`/`$E01E` diagnosed: bare bracketing strobes around a RAM-sizing/checksum routine, result discarded

Both addresses appear repeatedly, always as a `tst.b`/`tst.b` pair (or a lone
`tst.b $fce01c` at a few sites), bracketing the RAM-size/checksum probe at
`$FE0D68-$FE0FCC` (which computes RAM size via `$2A4`/`$fcf000`, installs an
NMI handler at `$7C`, and probes memory presence) — e.g.:

```
FE0D6E: tst.b   $fce01c.l
...
FE0D96: tst.b   $fce01e.l
...
FE0DB4: tst.b   $fce01c.l
...
FE0F52: tst.b   $fce01c.l
FE0F58: tst.b   $fce01e.l
```

In every occurrence the very next instructions never test the Z/N flags a
`tst.b` of these addresses would set — they instead branch on unrelated
computed values (`D2`, `D4`, a checksum comparison) already in registers.
This is the same "bare strobe, result unused" shape `hardware-notes.md`'s
Setup/Domain-context latches document for `$E010/$E012`/`$E008-$E00E`, so
these read as two more address-decoded latches in that family — but WHICH
latches, and what they actually do on real hardware, is not determinable
from this evidence (no cited hardware-notes entry, and the ROM never
observably depends on their value). **Evidence-gated per the brief: no
behavior is modeled beyond the existing "unknown I/O offset, 0xFF stub,
logged" default** — and this default is confirmed sufficient: the ROM
reaches the (unchanged) `$FE2DBE` frontier regardless, having touched
`$E01C`/`$E01E` dozens of times along the way with no ill effect.

### `$F801` bit 1 — new context, still undetermined, unrelated to vsync

`hardware-notes.md` §5 already flagged bit 1's meaning as undetermined. This
task found the actual usage site: `$FE0F46-$FE0F72`, inside the same
RAM-sizing/checksum routine referenced above. `$FE0F46` installs a handler
at low-core `$7C` (the NMI vector, `hardware-notes.md` §7) whose body
(`$FE0F72`) does `bsr $fe0f68` (`btst #$1,$fcf801` / `rts`) then branches on
the result. This reads as an NMI-or-bus-error-driven memory-presence probe
(consistent with `hardware-notes.md`'s "Known Gaps: Parity/bus-error status
register bit layout not located"), not anything vsync-related — bit 1 and
bit 2 are evidently independent status-register sources. This model already
treats undriven status bits as always-0 (`IODispatcher.statusByte` defaults
to 0, OR'd only with `videoTiming.pending` for bit 2), which is a safe
default here too: the RAM-sizing routine completes and the frontier is
reached regardless. Precisely pinning bit 1's real semantics is left for a
later task (Task 6, board-ID/bus-error territory, is the natural home).

### SNUM ($FE8000+, special-space `$4000+`) — still unreached, now confirmed across the ENTIRE ROM image

Task 2's "Beyond the M1a boundary" section confirmed no special-space
`$4000+` access occurs before the (then-current) stall. This task re-checked
more strongly: a full linear disassembly of the entire 16KB ROM image
(`d fe0000 9000` under `lisadbg`, confirmed to cover exactly `$FE0000
-$FE3FFE` — the disassembly desyncs into garbage past `$FE3FFE`, the
documented ROM end / version-word address) contains exactly two absolute
references in the `$FE4000+` range anywhere in the ROM's code: `$fe8000.l`
and `$fe8008.l` — both are the segment-127 SLIM/SORG MMU ports (used
repeatedly through the setup-mode MMU-programming code at `$FE0120-$FE0420`,
already documented under "MMU programming" above), not a SNUM data read.
**No instruction anywhere in the ROM references the SNUM range.** This is a
stronger statement than Task 2's ("before the stall") since it covers the
whole image, not just the pre-frontier portion — SNUM access, if the ROM
ever performs one, is either data-driven (a computed/indexed address this
static disassembly can't discover) or simply not exercised by this boot
ROM's revision at all.

## Answers to the Task 5 open questions

### OQ1 — Does the ROM program SLIM/SORG targeting the CURRENT domain (our model), or does the hardware "inactive domain" semantic matter?

> **STATUS UPDATE (M3 Task 2, sweep-noted M3 Task 3): now ANSWERED.** The
> "remains OPEN"/"UNVALIDATED and open" conclusion below was correct for its
> time (M1b -- the boot trace genuinely couldn't discriminate the two models
> yet) but is now STALE: the Checkpoint-D domain-1 crossover (the OS
> loader's `do_an_mmu` switching live context mid-handler) finally forced
> the discriminating case this section predicted M1b would need, and
> `initmmutil`/`do_an_mmu`'s own source settles it in favor of the
> CURRENT (active) domain -- see "OQ1 status" (near the end of this
> document) for the full resolution and citations. The paragraphs below are
> preserved as the historical M1b record (both-docs rule), not the current
> answer.

**Undetermined by the boot trace — remains OPEN for M1b (historical, see the
status update above).** The current-domain
model is *consistent with* everything the boot ROM does, but the boot path
**cannot discriminate** current- from inactive-domain routing, so this is not
evidence that the model is correct.

Why the self-test can't decide it: the MMU register test writes a pattern and
immediately reads it back to `eor`-verify (`$FE0290` write / `$FE0286`,
`$FE0288` read). But in `Bus.slimSorgPortAccess` **both** the write and the
read-back index the *same* `domain`, so the test is read/write-symmetric — it
would pass identically under a symmetric inactive-domain hardware model (write
to inactive X, read back from inactive X). No context-latch toggle occurs
*inside* the write→verify loop, so nothing observes which physical domain was
actually hit. And the single translated instruction fetch before HALT
(`$FE0446`) faults on the segment-127 nibble-`$F` decode regardless of which
domain holds the map — so it, too, tells us nothing about routing.

Therefore: our current-domain implementation is retained because it is
consistent with all observed M1a boot behavior, but the `hardware-notes.md`
"Setup Latch" claim that setup-mode writes program the **inactive** domain
stays **UNVALIDATED and open**. The discriminating experiment is a live OS
domain-switch (program the soon-to-be-active domain while executing in another,
then swap and observe), which M1b must run once translated execution works.

### OQ2 — How does the ROM reach ROM+special space in translated mode? Exact SLIM/SORG for segments 125/126/127.

Definitively answered, and it **refutes the ledger's hypothesis** that
prommmu (127) uses access `$8` routed via `.io`:

- **seg 127 (prom):** SLIM = **`$F00`** (access nibble **`$F`**), SORG = 0.
  Programmed explicitly at `$FE0120` (`move.w #$f00,$fe8000`) and matched by the
  reset warm-boot check at `$FE015E` (`cmpi.w #$f00`).
- **seg 126 (iospace):** SLIM = **`$901`** (warm path) / `$900` (self-test tail),
  access nibble **`$9`**, SORG = 0. Programmed at `$FE0118`
  (`move.w #$901,$fc8000`), checked at `$FE0100` (`cmpi.w #$901`).
- **seg 125 (screen):** left absent (`$C00`) in domain 0 at setup-drop; the ROM
  sets it up later (post-boundary, unobserved).

**M1b requirement:** `MMU.translate` must decode the special access nibbles
`$F` (prom) and `$9` (iospace) — NOT the OS-era `$8` (`mmuio`) assumed at M1a —
as *hardwired* special-space decodes independent of SORG: nibble `$F` on
segment 127 serves ROM bytes for `$FE0000-$FE3FFF`; nibble `$9` on segment 126
routes to the IODispatcher (`$FC0000` I/O space). Until then, translated-mode
fetches from prom fault. (These nibbles are the ROM's own convention, which
predates the OS `do_an_mmu` `$5/$6/$7/$8/$C` set documented in
`hardware-notes.md §1`; `hardware-notes.md` should be extended with `$9`/`$F`.)

### OQ3 — Board-ID `$C031` = `0x00`: does it send the ROM down a sane path?

**Resolved by Trace checkpoint A** (see "Beyond the M1a boundary" above). The
board ID is not read before the setup-drop halt, but past the boundary it *is*
read (`$FE0B24`/`$FE0B2C`/`$FE119A`). The gating branch `tst.b $fcc031;
bpl $fe0b3c` takes the **pre-Pepsi path** on `0x00` (bit7 clear) — it skips a
Pepsi-only contrast/DAC adjustment and otherwise proceeds normally. `0x00` does
**not** divert POST into any error, and the alternate `$80` path is equally
benign. **The `0x00` default is correct and needs no change** (it selects the
simplest documented board, pre-Pepsi, VIA1 T1 reload `$CA/$27`).

## Bus-error frame spike + board-ID/memory-sizing validation (M1b Task 6)

M0/M1a parked a known Musashi defect: `m68ki_exception_bus_error()`
(`Sources/CMusashi/m68kcpu.h`) pushes the 68010-only 29-word format-8 frame
(`m68ki_stack_frame_1000`) with the FAULT ADDRESS field hardcoded to 0,
instead of the real 68000 7-word group-0 frame (`m68ki_stack_frame_buserr`,
which the vendored core's *address-error* path already uses correctly) with
`m68ki_aerr_address`/`m68ki_aerr_write_mode` populated from the fault. This
task's brief: does the ROM ever take a *recoverable* bus error (a handler
that RTEs back) on the path to the current frontier, or will POST's memory
test need one? Method: instrument, run to and past the frontier, then
disassemble every place the ROM installs vector `$8` (bus error) to see how
it actually uses it.

### Live instrumentation: zero bus-error pulses through the frontier

`Bus.busErrorPulseCount` (new, bounded diagnostic counter alongside
`mmuPortWrites`/`lastFault`) increments once per real (non-peek,
non-double-fault) `busErrorHandler` invocation — i.e. once per genuine
Musashi bus-error exception the CPU actually takes. Wired into `lisadbg`'s
`t`/`g` status lines and asserted by
`ROMBootTests.romTakesNoBusErrorThroughTheFrontier`. Running the full boot
10M cycles past the `$FE2DBE` frontier (30M total, `lisadbg g 30000000`):

```
setup=OFF domain=0 mmuPortWrites=4384 busErrorPulses=0 halted=false
PC=00FE2DCE
```

**Zero bus errors, the entire way.** Every access the ROM makes on this path
either lands in mapped RAM/ROM, a modeled IOSpace register, or an
`IODispatcher`/`specialAccess` "unknown, stub `0xFF`" fallback — none of
which raise a real `.fault` in `Bus.access`/`MMU.translate`. The only way to
reach `.fault` today is an absent segment (nibble `$C`, domain-0 segments
16-125) or a write to a read-only segment; the ROM's boot-path device probes
never touch those.

### Static evidence: the ROM's own bus-error idiom never RTEs

A full linear disassembly of the ROM image (`lisadbg d fe0000 9000`, same
method Task 5 used for the SNUM sweep) finds **22 sites that touch vector
`$8`** — **20 writes** (`move.l A3,$8.w` or equivalent: 18 fresh installs
plus 2 restores of a previously-saved handler) and **2 reads**
(`movea.l $8.w,A5` at `$FE1318`/`$FE2160`, saving the current handler before
a temporary install — see the MOVEP-probe idiom below). Across the *entire*
16KB image there are only **2** `rte` instructions total:

- `$FE00F4` — inside a block (`$FE00CA-$FE00F4`) that is not a branch target
  anywhere in the ROM (confirmed by grepping every `$FE00C*`/`$FE00CA`
  reference); it sits between the checksum-failure infinite loop
  (`$FE00C8: bra $fe00c8`) and the real reset entry (`$FE00F6`, the
  documented PC-vector target). Dead disassembly, not reachable code.
- `$FE0DF6` (`moveq #$1,D2 / rte`) — reached via `movea.l A2,$7c.w` /
  `move.l A3,$7c.w` at `$FE0D5C-$FE0D64` (offset **`$7c`**, the **NMI**
  vector, not `$8`). This is a genuinely RTE-terminated handler, but it is
  Musashi's `m68ki_exception_interrupt` path (autovectored level-7
  interrupt), a completely different C function from
  `m68ki_exception_bus_error` — the frame-format bug does not apply to it.

So **none** of the ROM's 20 real bus-error (`$8`) handler installs/restores
ever execute `rte`. This is a static claim about the *content* of every
installed handler body (each was disassembled and read in full), independent
of whether every guarded probe is itself confirmed live-reached — the VIA2
self-test guard (`$FE08B4`, below) and the `$D241` probe guard (`$FE100C`,
below) both sit on code already independently confirmed live by earlier
tasks (Task 3's VIA2-stall trace; Task 2's original `ioTrace` observation of
`$D241` traffic), so those two are solid on both counts. Representative
disassembly of three of them:

```
; VIA2 T1-latch self-test guard (installed $FE08B4, target from $FE08B0)
FE0DF8: moveq   #$32, D0        ; error code
FE0DFA: bset    #$a, D7         ; mark failure bit
FE0DFE: bra     $fe0918         ; -> shared "mark + continue POST" dispatcher

; $D241 (candidate SCC) presence probe guard (installed $FE100C)
FE10EE: cmpa.l  #$fcd241, A0
FE10F4: bne     $fe10fa
FE10F6: moveq   #$38, D0
FE10F8: bra     $fe10fc
FE10FA: moveq   #$37, D0        ; boot error code $37/$38
FE10FC: tst.l   D7
FE10FE: bpl     $fe1108
FE1100: movea.w #$480, A7       ; reset SP, retry from the top
FE1104: bra     $fe1008
FE1108: bra     $fe0918         ; -> same shared dispatcher

; the shared dispatcher itself
FE0918: bset    #$12, D7
FE091C: bra     $fe0758
```

Both funnel into `$FE0918`, a shared "record a failure bit in D7, then
`bra`" continuation — never a return into the faulting instruction stream.
Neither reads any field of the pushed exception frame (D0's error code comes
from a register comparison against the probed address already in A0, not
from the stack), so the frame's fault-address bug is invisible to them
regardless of correctness.

A second idiom, used by the I/O-board `MOVEP` presence probes
(`$FE1306-$FE137E`, `$FE2160-$FE21A6`), sidesteps the frame shape even more
directly: it saves `A7` into `A6` *before* the guarded probes, installs a
trivial one-instruction handler that just falls through into the next real
instruction on a fault (no `rte`, no stack adjustment), and unconditionally
restores `A7 := A6` once all probes finish — discarding whatever the CPU
pushed for any fault that occurred in between, wholesale, regardless of its
length. Musashi's buggy 29-word frame vs. the correct 7-word frame changes
only how much transient stack headroom this consumes between probes, not
correctness.

**Even the ROM's own default/baked-in bus-error handler doesn't RTE.**
Before any POST code installs a handler, vector `$8` (and vector `$C`,
address error — both share the same target) reads through the
`$0000-$3FFF` ROM mirror (`setupMode == true`) to `$FE0030`
(`m fe0000 20`: bytes 8-11 = `00 FE 00 30`):

```
FE0030: movea.w #$480, A7      ; reset SP to the boot value
FE0034: clr.l   D7             ; clear the cumulative-failure register
FE0036: bra     $fe0194        ; -> restart the checksum self-test
```

A full POST restart, not a resume.

**Conclusion:** this ROM's bus-error idiom is structurally "abandon the
faulting context, mark/record, continue POST elsewhere" — never
"trap-and-resume via RTE." The frame layout/fault-address bug this task was
scoped to evaluate has **no observable effect on any bus-error usage this
ROM makes**, confirmed both empirically (zero pulses through the live
frontier) and statically (every reachable installed handler, plus the
default handler, discards the frame rather than consuming it).

### Memory sizing: statically present, live reachability NOT confirmed (fix round 1 correction)

**This section originally asserted the RAM-sizing routine as live boot
fact from static disassembly alone; code review caught that the reachability
claim was never actually checked. Corrected below with the live evidence —
the DECISION is unaffected (see "DECISION" below for why).**

The RAM-sizing/checksum routine (`$FE0D68-$FE0FCC`, already located by Task
5 as the `$E01C`/`$E01E`/`$F801`-bit-1 usage site) is statically present in
the ROM image and reads **`$FCF000`** at three static call sites into a
shared subroutine (`FE0FF0-FE0FFE`, called via `bsr` from `$FE0F2A`,
`$FE0F78`, and `$FE0714`), plus two more direct reads outside that
subroutine (`$FE00DA`, `$FE0DAE`):

```
FE0FF0: clr.l   D1
FE0FF2: move.w  $fcf000.l, D1   ; hardware "installed RAM" ID register
FE0FF8: move.w  D1, $1aa.w      ; stash the raw value
FE0FFC: lsl.l   #5, D1          ; magnitude/granularity decode
FE0FFE: rts
```

**Live reachability check (unbounded, instruction-granular — not subject to
the `ioTrace`/`mmuPortLog` bounded-cap caveat that made earlier tasks'
"absence from the trace" arguments weaker evidence):** a `@testable import
LisaCore` scratch harness single-stepped **every** instruction from reset to
30M cycles (14M cycles past the `$FE2DBE` frontier — 3,091,264 total steps)
and recorded PC hits against a broad watch set spanning this routine's two
NMI-guarded entry points (`$FE0D5C`, `$FE0F46`), its body (`$FE0D68`,
`$FE0E02`), the `$FCF000` subroutine and all 3 of its callers (`$FE0F2A`,
`$FE0F78`, `$FE0714`), its post-sizing continuation (`$FE1000`), and the
shared bit-1-error landing target (`$FE0704`/`$FE0730`/`$FE0764`). The
harness was validated against 4 independently-known-live sanity PCs
(`$FE0446` hit at cycle 580,344; `$FE0BA2` at 11,876,766; `$FE2DBE` at
16,181,126; `$FE2DCE` — the frontier poll — hit 431,839 times from
16,181,172 onward), all matching prior tasks' documented cycle counts. Every
one of the RAM-sizing-routine addresses: **zero hits.**

So: **this routine is statically present in the ROM but empirically NOT
executed on the traced boot path through 30M cycles.** The earlier claim
that "$FCF000 is read directly for POST-level memory sizing" describes ROM
code that exists, not a confirmed live event — precisely the OQ1 pattern
("statically present, live reachability unconfirmed"; treat as plausible,
not proven). This task does not distinguish between the honest
possibilities: the routine could be dead code for this ROM revision/board
configuration, reachable only via a genuine NMI (level 7) this model never
generates, or reachable only from a call site past the current `$FE2DBE`
frontier. What *is* still true regardless: its only fault-shaped defensive
mechanism is the **NMI** vector (`$7c`), not the CPU bus-error vector `$8`
this task is about, so even if it were reached, it would exercise a
different Musashi code path, unaffected by the format-8 bug.
`$FCF000`'s exact encoding remains undetermined (evidence-gated, same as
`$D241`/`$E01C`/`$E01E`).

### `$F801` bit 1 — all three cited gating sites unconfirmed live (fix round 1 correction)

**This section originally claimed all three sites were "reconfirmed safe"
live boot behavior. Code review caught that `$FE00D0` sits in dead
disassembly, and the live-reachability check above shows the other two are
also unconfirmed — corrected here.**

Three call sites gate on it statically: `$FE00D0`, `$FE0F14` (entering the
RAM-sizing routine), and inside the NMI handler installed at `$FE0F46`
(`$FE0F72-$FE0F74`) — all `btst #$1,$fcf801` / `bne $fe0704` (an error/skip
branch). Of these:

- `$FE00D0` sits inside the `$FE00CA-$FE00F4` block, which is **not a
  branch target anywhere in the ROM** (confirmed by grepping every
  `$FE00C*` reference in the full disassembly) — dead disassembly, not
  reachable code, regardless of cycle count.
- `$FE0F14` and `$FE0F72` belong to the RAM-sizing routine just shown above
  to be unreached through 30M cycles (both were in the watched PC set;
  both scored zero hits).

So **none of the three originally-cited `$F801` bit 1 gating sites are
confirmed live-reached** on this boot path. Bit 1's real semantics, and
whether this model's default (clear) has any live consequence before the
frontier, remain **undetermined** — this reverts to (and is consistent
with) `hardware-notes.md`'s original framing. The "reconfirmed safe"
language previously here is retracted.

### DECISION: defer the Musashi bus-error-frame fix to M2

Per the plan's decision framework: **no recoverable bus error is observed
or needed through the `$FE2DBE` frontier.** This rests on two pieces of
evidence, both solid and **independent of the memory-sizing reachability
question above**:

1. `Bus.busErrorPulseCount == 0` live through 30M cycles (14M past the
   frontier) — an unbounded, direct measurement of every real Musashi
   bus-error exception the CPU actually took. Not subject to any
   bounded-log-cap caveat.
2. The ROM's own bus-error idiom, checked statically across all 20 real
   vector-`$8` handler installs/restores plus the ROM-baked default
   handler, never depends on RTE-based resumption or on the pushed frame's
   content — this is a claim about what each installed handler's code
   *does*, independent of whether every guarded probe is itself reached.

Together these mean: zero bus errors actually occurred, **and** even a
hypothetical future one (on a probe not yet reached) would not be
observably affected by the current frame bug, because nothing this ROM
installs at vector `$8` ever consumes the frame. The memory-sizing
routine's reachability is a separate, still-open question (see above) that
does not change this: it is not a source of bus errors either way (its
defensive path is NMI, a different Musashi exception entirely, not vector
`$8`), so its uncertain status cannot flip the decision. **M2 owns the real
68000 group-0 frame fix** (swap to `m68ki_stack_frame_buserr`, plumb
address/isWrite into `m68ki_aerr_address`/`m68ki_aerr_write_mode`) whenever
a future task's trace actually needs it; this spike found no such need
before Task 7's POST-menu frontier.

## Instrumentation added (Task 7, diagnostics only)

- `Bus.mmuPortLog` — bounded (8192) log of completed SLIM/SORG port writes
  `(domain, segment, isSorg, value, cycles)`, alongside the existing
  `mmuPortWrites` counter. Logged on the low-byte lane (full 16-bit value
  present). `mmuPortLogDropped` counts overflow.
- `lisadbg`: `t` now prints SLIM/SORG writes (decoded) interleaved with I/O and
  a `setup=/domain=/mmuPortWrites=` status line; new `g [cycles]` command runs
  quietly then dumps the SLIM/SORG + I/O deltas and final state. `Monitor`
  gained a `.go(Int)` command.

No device behavior was changed: no stub return value was altered, because the
trace shows the ROM halts before reaching any stub-served register.

## Instrumentation added (M1b Task 6, diagnostics only)

- `Bus.busErrorPulseCount` — bounded counter, incremented once per real
  (non-peek, non-double-fault) `busErrorHandler` invocation, i.e. once per
  genuine Musashi bus-error exception the CPU actually takes. See "Bus-error
  frame spike" above.
- `lisadbg`: the `t`/`g` status lines gained `busErrorPulses=`.

No device behavior was changed here either: the ROM never reaches the
`.fault` branch of `Bus.access` on the traced path, so this counter stays 0
and no stub was touched.

## POST completion (Task 7) — the ROM reaches the boot menu

**M1b exit criterion met.** The `$FE2DBE` frontier that Tasks 4–6 left open
turned out not to be a POST blocker at all: it is the drawn boot MENU's
"await the next COPS input event" idle loop. Reproduce with `swift run -c
release lisadbg --rom $HOME/Development/LisaROMs`, then `g 25000000` and
`sca` (or `sc <path>.png`).

### What `$FE2DBE` actually is (the consumer, disassembled)

`$FE2DBE` is a blocking "receive one COPS byte" subroutine:

```
FE2DBE: move.l  A0, -(A7)
FE2DC0: movea.l #$fcdd81, A0     ; VIA2 base
FE2DC6: move.b  ($1a,A0), D0     ; read IFR2
FE2DCA: btst    #$1, D0          ; COPS "byte pending"?
FE2DCE: beq     $fe2dc6          ; NO TIMEOUT — spin until a byte arrives
FE2DD0: move.b  ($2,A0), D0      ; read PORTA2 reg 1 (handshake) -> consume; D0 = byte
FE2DD4: movea.l (A7)+, A0
FE2DD6: rts                      ; returns the received byte in D0
```

Its caller `$FE2D38` is the COPS input-packet state machine (State 0
dispatch): `$00` -> mouse packet (`$FE2D48`, read dx/dy into `$48a`/`$48b`),
`$80` -> reset dispatch (`$FE2D5C`), else -> keycode. The reset dispatch
`$FE2D5C` is where the keyboard-ID-vs-clock-start asymmetry lives (see
hardware-notes.md §4's Task 7 correction): `$00-$DF` -> `$FE2D7C` (store ID
at `$1b2`, loop back, NO trailing bytes), `$E0-$EF` -> `$FE2D82` (store at
`$480`, read 5 more into `$481-$485`), `$FB` -> power button, `$FE-$FF` ->
COPS-failure error codes `$34`/`$35`.

`$FE2D38` is called from the mouse-cursor / menu-interaction loop
`$FE2C46` (reached from `$FE2624`, which first `bset`s bit 5 of the
low-RAM flag cell `$2A2`). That loop is unmistakably the interactive UI
driver:

- `$FE300E`/`$FE2EC2` render the mouse cursor — cursor bitmap at `$4a2`,
  hot-spot/position words at `$490`-`$498`, clipped against screen bounds
  `$2d0` (720) × `$16c` (364).
- `$FE2E46` hit-tests the cursor position against a rectangle table at
  `$53a` (first word = entry count; a live dump at the stall shows 3
  entries — the three menu buttons).

With flag bit 5 set, unrecognized received bytes just loop back and fetch
another packet — i.e. the loop idles here until the user moves the mouse or
presses a key. There is no user, so `$FE2DBE` waits forever. **This is the
correct terminal behavior for a menu, not a hang.**

### The screen: the classic Lisa startup menu + a no-boot-device error

The 720×364 framebuffer at the stall (rendered via `lisadbg sc`) shows:

- Three menu buttons in a bordered box: **`[⌘1] RESTART`**, **`[⌘2]
  CONTINUE`**, **`[⌘3] STARTUP FROM…`**.
- A mouse-cursor arrow.
- An **`H`** ROM-revision marker (top-right).
- A crossed-out **ProFile** hard-disk icon labelled **`42`** (a
  no-boot-device / device-error indicator) — expected, since no
  floppy/hard-disk hardware is modeled.

This is BOTH accepted M1b success states at once: the startup/boot-device
UI *and* a no-boot-device error indicator. (Screenshot reproduce steps:
docs/m1b-demo.md. The PNG is kept OUT of the repo — it renders Apple's
ROM-drawn UI.)

### Timing / stability (cycle budget for the test)

Single-process sampling (deterministic under Musashi):

| Cycles | PC        | black px | State                                           |
|--------|-----------|----------|-------------------------------------------------|
| ≤15 M  | `$FE0AE2`/`$FE0B4A` | ~48% (desktop-gray dither) | contrast-DAC delay / video setup |
| 16 M   | `$FE32xx` | transitional | menu being drawn                            |
| 18 M   | `$FE2DBE-$FE2DD6` | 78,100 / 262,080 (29.80%) | menu fully drawn, input-idle loop entered |
| 25–60 M| `$FE2DBE-$FE2DD6` | 78,100 (bit-identical) | stable — framebuffer FNV unchanged |

The menu is fully drawn and the idle loop entered by ~18 M cycles; the
framebuffer is then bit-stable (identical 64-bit FNV-1a fingerprint
`0xd09234d25516d0b8`) through at least 60 M cycles. The content is
independent of the host wall clock (the menu shows no time-of-day —
verified reproducible across processes at different times), so the exact
hash is a legitimate deterministic anchor. `ROMBootTests
.romCompletesPOSTAndReachesBootMenu` samples at 25 M and asserts the
POST-complete markers, the input-loop PC range, `blackPixels == 78100`, the
robust `>1%` weaker invariant, and the exact FNV anchor.

### COPS power-on stream — the only device change this task made

The `$FE2DBE` wait is reached (and the identical menu drawn) with the
current command-handshake path regardless of the power-on input stream —
including with NO power-on stream at all (empirically verified: same
framebuffer hash). So the input FIFO stream is fidelity-only, not
load-bearing for the boot path. Task 4's 5 trailing `$00` placeholder bytes
were both (a) unnecessary and (b) a latent hazard — `$00` is the State-0
mouse-packet marker, so queuing them risks phantom mouse packets. Task 7
changes `COPS`'s power-on stream to the faithful 2-byte keyboard-present
announcement `$80, <keyboard ID>` (matching the state machine's keyboard-ID
reset = exactly 2 bytes) and drops the trailing `$00`s. Removing them
reaches the byte-identical menu (same 29.80% / same FNV). No other device
behavior or stub value was changed.

### Wait-target table — FINAL

Every row the trace opened is now resolved or explicitly deferred with
evidence:

| Target            | Status                                                        |
|-------------------|---------------------------------------------------------------|
| VIA2 `$DD81` / VIA1 `$D901` register files | DONE (Task 3)                        |
| COPS / VIA2 Port A+B handshake             | DONE (Task 4)                        |
| `$F801` bit 2 (vsync) + `$E018`/`$E01A`    | DONE (Task 5)                        |
| `$E01C`/`$E01E` strobes                    | diagnosed inert, no model change (Task 5) |
| `$F801` bit 1                              | statically present, live-reach unconfirmed; default (clear) reaches the menu (Task 6) |
| Musashi 68010 bus-error frame              | deferred to M2 with two evidence pillars (Task 6) |
| **`$FE2DBE` "next COPS byte" wait**        | **RESOLVED (Task 7): the boot-menu input-idle loop; POST is complete** |
| `$D241` controller (`$37/$38`)             | candidate SCC; passes `0xFF` stub, not on the boot path — later serial task |
| `$C031` board ID                           | none — `0x00` (pre-Pepsi) correct    |
| SNUM (`$FE8000+` special `$4000+`)         | never referenced by any ROM instruction (Task 5, whole-image sweep) |

**No stall on the path to the menu requires a new subsystem.** The
remaining open items (`$F801` bit 1 semantics, the `$D241` SCC, the M2
bus-error frame) are all off the boot-to-menu path and correctly deferred.

## Floppy boot (checkpoint C) — the ROM reads block 0 and runs it (M2 Task 5)

With `FloppyController` live (`$C000-$C7FF` shared-RAM window, `$C015=1`,
DISKIN reflecting insertion, DC42-served reads, VIA2 PB4 + own level-1
completion) and a disk inserted (`swift run -c release lisadbg --rom
$HOME/Development/LisaROMs --disk $HOME/Development/LisaImages/OS31_Install_1.dc42`),
this section records how the Rev H boot ROM actually reaches, drives, and
returns from its floppy read routine, and settles hardware-notes.md §9's two
ambiguities from the disassembly. All findings are reproducible from
`lisadbg` (`g`, `d`, `m`) and are pinned by `ROMFloppyBootTests` (env-gated on
`LISAEMU_ROM_DIR` + `LISAEMU_DISK_DIR`).

### The ROM does NOT auto-boot — and an inserted disk does NOT change the menu

An unbounded single-step reachability trace (reset → 30 M cycles) with the disk
inserted hits **none** of the boot-dispatch PCs (`$FE16E2` FIND_BOOT,
`$FE1706`/`$FE1714` device probes, `$FE1BCC` Sony loader, `$FE1D76` read
routine). The only boot-flow PC reached is `$FE2624` (the menu setup, at
~16.2 M), and the ROM parks in the same `$FE2DBE-$FE2DD6` "await next COPS input
byte" idle loop Task 7 documented. The power-on framebuffer with a disk inserted
is **byte-identical** to the no-disk boot-menu anchor — same FNV-1a
`0xd09234d25516d0b8`, same 78,100 set pixels, same crossed-out ProFile "42"
icon. So `$1B3`/bootdev auto-boot does **not** fire on this ROM/board with no
persistent parameter memory: the menu anchor is UNMOVED by an inserted disk
(`ROMFloppyBootTests.diskInsertedAtPowerOnReachesTheIdenticalMenuAnchor`; the
no-disk `ROMBootTests` anchors are untouched by this task).

### Triggering the boot: a two-level menu selection

A floppy boot is reached only through the menu. The `$53a` hit-test table at
the idle loop holds the three menu buttons (`$F4` RESTART, `$F1` CONTINUE, `$F2`
STARTUP FROM, rects at x∈[416,496]). Injecting mouse motion + a click (via
`COPS.postMouse`/`postKey $06`, the M1c input channel) onto **STARTUP FROM**
(`$F2`) opens a device-list window (the hit-test table becomes two items,
`$F4 [16,16,160,50]` / `$F1 [16,50,160,84]`). Clicking a device item runs the
Sony loader `$FE1BCC` → twig_entry (`$FE0094` → `$FE1D76`).

### The read routine (`$FE1D76`) — go-bytes, cells, handshake

```
FE1D76: ori #$700,SR              ; mask interrupts for the transfer
FE1D80: bsr $FE1E96               ; drain any stale completion (clristat if PB4 set)
FE1D84: movep.l D1,($4,A0)        ; stage DRIV/HEAD/SEC/TRAK cells ($05/$07/$09/$0B), stride-2
FE1D88: move.b D0,($C,A0)         ; drive-speed cell ($0D)
FE1D8C: clr.b  ($2,A0)            ; DISKPARM ($03) = 0 = readdisk sub-command
FE1D90: move.b #$81,(A0)          ; DISKCMD ($01) = excmd  -> FloppyController.performExCmd
FE1D94: bsr $FE1E3E               ; WAIT COMPLETION -- $FE1E3E: move.l D2,D3 (timeout counter
                                   ;   setup) / $FE1E40: movea.l #$fcdd81,A3 / $FE1E46: btst
                                   ;   #$4,(A3) / $FE1E4A: bne $fe1e54 (VIA2 PB4 SET; loops via
                                   ;   $FE1E4C: subq.l #1,D3 / $FE1E4E: bne $fe1e46 on timeout).
                                   ;   M3 Task 3 precision fix: the poll instruction itself is
                                   ;   $FE1E46, not the $FE1E3E subroutine entry point (8 bytes
                                   ;   earlier) -- see hardware-notes.md §9's mirrored note.
FE1D9A: move.b ($10,A0),D0        ; read DISKERR ($11)
FE1D9E: move.b #$CC,($2,A0)       ; DISKPARM = $CC
FE1DA4: move.b #$85,(A0)          ; DISKCMD = clristat
FE1DA8: bsr $FE1E04               ; WAIT READY: DISKCMD==0, gated on VIA1 $FCD901 PB6
FE1DAC: tst.b D0 / bne error      ; DISKERR must be 0
FE1DB0: lea ($3E8,A0),A4 ; movep  ; copy 12 tag bytes (odd lane $3E9,$3EB,…,$3FF)
FE1DC6: lea ($400,A0),A4 ; movep  ; copy 512 data bytes (odd lane $401,$403,…,$7FF)
```

with `A0 = $FCC001` throughout. The command cells (`$01/$03/$05/…`) are the odd
byte of each 68000 word — the 6504's 8-bit shared RAM — and `FloppyController`'s
`Cell` offsets already matched them. Simple/probe commands elsewhere on the boot
path use go-bytes `$86` enabstat, `$87` clrmask, `$88`→DISKPARM, `$85` clristat,
and `$81` excmd with non-read sub-commands.

### AMBIGUITY (a) SETTLED — buffer base `$400`, odd-lane stride-2

`$FE1DC6: lea ($400,A0),A4` (A0=`$FCC001`) + `$FE1DCE: movep.l ($0,A4),D3`
prove the data buffer BASE is **`$400`** (not the `$600` the SONYASM
"DISKDATA+1024" reading implied), read with `movep.l` (stride 2) from the odd
lane — so the 512 bytes live at window offsets `$401,$403,…,$7FF`, and the tag
at `$3E9,…,$3FF` (`$FE1DB0`). `FloppyController` had been storing both buffers
**contiguously** (`$400+i`), which this task's live trace exposed: the ROM read
misaligned data, the loader's signature check failed, and it fell back to the
menu (`blocksRead=3, lastError=9`, no RAM execution). **Fix (one constant's
worth, per the §9 design):** `performRead` now writes `window[diskData+1+2*i]` /
`window[diskHdr+1+2*i]`. After the fix the ROM reads block 0 in a single pass
(`blocksRead=1, lastError=0`) and boots.

### AMBIGUITY (b) SETTLED — `$FCD901` (VIA1) bit 6, no wiring needed

The ready/handshake wait `$FE1E04` polls **VIA1 PORT B bit 6 at `$FCD901`**
(`movea.l #$fcd901,A3` / `andi.b #$bf,($10,A3)` making PB6 an input /
`btst #$6,(A3)`), NOT `$FCD801`. `$FCD901` is our ROM-established VIA1 base
(§3), so the disk_control idle bit is literally a VIA1 port-B input line —
resolving the OS-source `$D901`/`$D801` contradiction in favor of `$D901`. **No
new wiring was required:** VIA1's `portBInput` defaults to `0xFF` (unconnected
input floating high), so PB6 already reads 1 = idle/ready, exactly what the
handshake needs. The completion wait (`bsr $FE1E3E`, polling at `$FE1E46` --
M3 Task 3 precision fix: the poll instruction is 8 bytes past the
subroutine's `$FE1E3E` entry, see "The read routine" above) likewise
confirms the completion-line polarity: it spins until VIA2 PORTB2 bit 4 is
SET, matching
`FloppyController`'s idle=0/asserted=1 choice.

### The boot block: load address `$020000`, first instruction `4E FA` (JMP)

After a clean block-0 read the loader verifies the boot-block signature
(`$FE1EF2: cmpi.w #-$5556,D0` i.e. `$AAAA`, read from block offset 4), runs a
contrast-DAC delay, and **JMPs into the loaded block at `$020000`** (cycle
~33.1 M in the traced run). The block's first bytes are
`4E FA 00 0E …` = `JMP (d16,PC)`, with the `$AAAA` signature at `$020004`.
`ROMFloppyBootTests.menuSelectionReadsBlockZeroAndExecutesTheBootBlock` pins
`blocksRead≥1`, `lastError==0`, `PC==$020000`, the `4E FA` opcode, and the
`$AAAA` signature. **This is checkpoint C's stop line — the loader's journey
beyond boot-block entry is Task 6.**

## OS loader (Task 6) — the loader runs from RAM, reads the LFS, and reaches ~~its Pascal segment gate~~ the `do_an_mmu` trap gate (diagnosed M3 Task 1)

**M2 exit criterion met.** Picking up from checkpoint C (boot block executing
at `$020000`), this section follows the boot block into the OS loader and
records how far it gets, matched to the original loader sources
(`Lisa_Source/LISA_OS/OS/source-ldmicro.text.unix.txt` = the "ldsony"
loader-loader; `source-ldlfs.text.unix.txt` = the compiled Pascal loader;
`source-LDEQU.TEXT.unix.txt` = the low-core hand-off cell equates).
Reproduce via `ROMFloppyBootTests.osLoaderExecutesFromRAMAndReachesPascalSegmentGate`
(env-gated on `LISAEMU_ROM_DIR` + `LISAEMU_DISK_DIR`); every observation below
came from a `@testable import LisaCore` scratch harness that single-stepped the
same menu-driven boot and dumped PC / floppy stats / low-core cells / MMU-port
log (deleted before commit, but each finding is reproducible from that test's
assertions).

### The boot block is the "ldsony" loader-loader (source-ldmicro)

The block-0 code at `$020000` is `LDRLDR` (`.proc LDRLDR`, source-ldmicro:5).
Its first instruction `4E FA 00 0E` = `jmp over_ldr_data` skips the 8-byte
loader-data area (`boot_id`/`ldr_version` + reserved words, source-ldmicro:62-74;
this is why the `$AAAA` = `boot_id` signature sits at `$020004`), then:

1. **Relocates itself to the RAM midpoint.** `move.l prom_realsize,d0 / lsr.l
   #1,d0` (source-ldmicro:77-78): `prom_realsize` (cell `$2A8`, LDEQU:66) was
   populated by the PROM to `$200000` (2 MB), so `ldbase = $100000`. The stub
   copies itself there and `jmp`s into the relocated copy (`ldbaseptr` cell
   `$21C` = `$100000` afterwards; LDEQU:35). **Confirmed live:** control enters
   the relocated loader at `$100042` ~5.8 K cycles after `$020000`.
2. **Reads its remaining code blocks + the LFS MDDF off the floppy.** `main_loop`
   (source-ldmicro:128-134) calls `ldr_read_block` (→ `drv_enable` → `twig_entry`
   `$FE0094`, the shared RWTS) until `codesize` is exhausted. Every read is
   `excmd`/`readdisk` (go-byte `$81`, DISKPARM 0), bracketed by `clristat`
   (`$85`) — the same go-byte choreography checkpoint C documented. `blocksRead`
   climbs deterministically **1 → 24**: 23 loader code blocks (linear blocks
   1-22 read as trak0 sec1-11 / trak1 sec0-10, then the Pascal side) **plus
   block 28** — the MDDF. Block 28 is `ld_fs_block0`, the MDDF address the boot
   block's own `fs_block0` field named (see step 3); it maps (CONVERT,
   source-ldmicro:436-531) to trak2/sec4, and `FloppyController.blockNumber`
   returns DC42 block 28, whose data the HLE serves **byte-for-byte identical to
   the raw image** (`00 11 9c f9 …` = `fsversion` 17 + `volname` "Office System
   1 3.0"). Every read `lastError == 0`.
3. **Writes the loader hand-off cells** (source-ldmicro:121-125, LDEQU:29-40):
   `dev_type` (`$22E`) = **2** = `dev_sony`; `ld_fs_block0` (`$210`) = **`$1C`**
   (MDDF block); `log_volume` (`$212`) = **1** (drive). `start_pascal`
   (source-ldmicro:327-340) then pushes the Pascal entry frame and `jmp`s into
   the compiled loader (`source-ldlfs`), which runs as position-relative code
   using **A5 as the Pascal globals base** (e.g. `move.l (A7)+,(-$b0,A5)` at
   `$100FE0`) — confirming translated execution reached the real Pascal loader,
   not just the asm stub.

### The stop line — ~~a Lisa Pascal `trap #6` segment-call gate (M3 boundary)~~ an MMU page-wrap divergence (DIAGNOSED + FIXED, M3 Task 1)

> **M3 Task 1 update (both-docs rule, strike-through-not-erase):** the
> reproducible FACT pattern below stands unchanged, but its causal
> interpretation was WRONG. `trap #6` is not a "Pascal segment-call gate" — it
> is the OS's **MMU-programming trap** (`do_an_mmu`; hardware-notes.md §1,
> LDASM:174-446). Vector `$98 = $A84000` is installed **by design**
> (`initmmutil` relocates `do_an_mmu` into segment 84 and points the vector at
> it), not as an "unrelocated placeholder." And the stop was an **emulation
> divergence**, not a runtime boundary: our MMU physical decode failed to wrap
> the 12-bit page arithmetic, sending virtual `$A84000` to phys `$200800`
> (past 2 MB) instead of the intended `$800`. Fixed. Full evidence chain in
> "Gate diagnosis (M3 Task 1)" below; read that section as the authoritative
> conclusion and the text immediately following as the (partly superseded)
> original observation.

The compiled Pascal loader reaches an **inter-segment call gate** and stops
making forward progress there. The gate (at `$1003F8`-`$10041E` in the relocated
image) is a classic Lisa Pascal segmented-code thunk:

```
1003F8: lea    ($26,PC),A1        ; A1 = return point
1003FC: lea    ($fe,PC),A2
100400: suba.l A1,A2              ; A2 = offset within the target segment
100402: movea.l #$a84000,A1       ; A1 = HARDCODED segment base  <-- placeholder
100408: adda.l A1,A2              ; A2 = $A84000 + offset  (target routine)
...
100418: trap   #$6                ; dispatch the call via the TRAP #6 vector
```

The immediate `#$a84000` is **baked into the on-disk loader** (the bytes
`22 7C 00 A8 40 00` appear at DC42 block 1 offset 478, and the value `00 A8 40
00` occurs 9× across the image) — it is Lisa Pascal's placeholder base for a
code **segment 84** (`$A80000 = 84 × $20000`) that the loader is meant to
resolve/relocate at runtime. Two things then happen that our environment cannot
carry through:

- **The loader overwrites the PROM's TRAP #6 vector.** At `$020000` entry,
  vector `$98` (TRAP #6 = vector 38) holds `$FE1D14` (a valid PROM handler in
  ROM). By the time the gate is reached the Pascal-loader startup has replaced
  it with the **unrelocated** `$A84000` placeholder. So `trap #6` vectors the
  CPU to `$A84000`.
- **`$A84000` has no code.** The loader *did* map a live MMU segment for its
  Pascal code — the only two SLIM/SORG writes on the whole loader path are
  `dom0 seg84 SORG=$FE4` / `SLIM=$7DB` (readWrite, origin phys `$1FC800`),
  i.e. it mapped logical segment 84 to the top of physical RAM. But logical
  `$A84000` (segment-84 offset `$4000`) then translates to phys `$200800` —
  **just past our 2 MB** — and, regardless, the loader loaded its code to
  `$100000`, not to segment 84's physical window, so the `$A84000`-based
  references were never fixed up to the real load base. The CPU fetches garbage
  at `$A84000`, wanders, and the loader's fault path ejects (`shutdown`:
  `unclamp`/`clristat`/`clrmask $88`, source-ldmicro:184-203) and re-enters
  `prom_monitor` (source-ldmicro:141-150) — i.e. it bombs back to the boot menu.

**This TRAP-based segment loader is where forward progress stops in this
environment — no new peripheral is required to get here, and none would get
the loader past `trap #6` as this environment currently behaves.** Resolving
it needs Pascal segment-loader/relocation runtime work in some form. Per the
task brief's "stop at the documented boundary" rule, Task 6 stops here with
the evidence above rather than scope-creeping into that runtime — but see
the discrimination note directly below before treating that runtime work as
the ONLY thing standing between here and further progress.

### Two open hypotheses for the stop — not yet a settled conclusion

Everything recorded above (the block-0/loader-progression anchors, the
`trap #6` dispatch at `$100418`, vector `$98` holding the PROM's real handler
at `$020000` entry and the unrelocated `$A84000` placeholder by the time the
gate is reached, domain-0 segment-84 mapped with `SORG=$FE4`/`SLIM=$7DB`
(origin phys `$1FC800`), logical `$A84000` translating to phys `$200800`, and
the `22 7C 00 A8 40 00` placeholder bytes baked into DC42 block 1 offset 478)
is a solid, reproducible FACT pattern. What is NOT yet settled is the causal
conclusion drawn from it — WHY forward progress stops here, in THIS
environment. Two hypotheses both fit every anchor above:

- **(a) Genuine runtime boundary.** The Pascal segment-loader/relocation code
  that resolves `trap #6` and fixes up the `$A84000` placeholder to the
  loader's real `$100000` load base simply has not run yet at this point in
  the sequence — on real Lisa hardware as much as here — and implementing
  that machinery is exactly M3's scoped requirements work, independent of
  anything this emulator gets wrong.
- **(b) An emulation divergence masquerading as a runtime boundary.** Real
  Lisa hardware might run this identical on-disk loader PAST this identical
  gate using nothing more than a 68000 + MMU + disk. If so, something in this
  environment's 68000/MMU modeling diverges from real silicon at or before
  the gate. The anchors above point at three candidates: a subtly wrong MMU
  SORG/limit decode for the seg-84 mapping (exactly the kind of error that
  would make `$A84000` land at phys `$200800`, just past this environment's
  2 MB RAM end, instead of somewhere the loader actually populated); OQ1's
  still-undischarged inactive-domain semantics (this IS the first live,
  post-POST SLIM/SORG programming of a fresh segment by running OS code, per
  the sanity sweep below — the first place OQ1 could actually bite); or some
  other RAM-size-dependent path in the loader's own relocation math
  (`ldbase = prom_realsize/2`, i.e. `$100000` only because this environment
  always runs the hardware-max 2 MB configuration).

**M3's first task is to discriminate (a) from (b), not to assume (a).** The
cheapest available probe: re-run this exact loader trace with a 1 MB RAM
configuration instead of 2 MB (`ldbase` becomes `$80000`, not `$100000`). A
genuine runtime boundary (a) predicts the SAME `trap #6`-at-`$A84000` stop
regardless of RAM size; the RAM-size-dependent strand of (b) predicts a
DIFFERENT stop point or failure mode. Only after that probe should M3 commit
its scope to segment-loader-runtime implementation as the confirmed correct
next investment, rather than as the untested default assumption it is today.

> **RESOLVED (M3 Task 1): hypothesis (b) — emulation divergence — confirmed.**
> Not the RAM-size strand, not OQ1: a **12-bit MMU page-wrap** our decode
> omitted. See "Gate diagnosis (M3 Task 1)" immediately below.

### Gate diagnosis (M3 Task 1)

**Root cause — a missing 12-bit physical-page wrap in `MMU.translate`.** The
loader's `trap #6` is the OS **MMU-programming trap** `do_an_mmu`
(hardware-notes.md §1; `source-LDASM.TEXT.unix.txt:305-446`), *not* a Pascal
segment-call/lazy-load trap. There is **no fault-driven segment loader** in the
loader sources (`ldlfs`/`ldmicro`/`LDASM` install only trap #6 → `do_an_mmu`
and a transient trap #8 stack-switch; loads are eager `READ_PAGE`/`READ_BLOCK`,
ldlfs:138-159). So the ledger's "lazy fault-load, our frame delivery diverges"
hypothesis is **refuted by source**; the M2 group-0 frame work is not
load-bearing here.

`initmmutil` (`LDASM:174-252`) sets this up deliberately:

1. `move.l #mmusegorg+bit_14,trap6` (L177-179): vector `$98` :=
   `84*$20000 + $4000 = $A84000`. **`$A84000` is the intended final virtual
   address of `do_an_mmu`, not an "unrelocated placeholder."**
2. It maps segment 84 (`mmucodemmu`) to a *negative* origin page:
   `SORG = ((utiladr + prom_byte0) >> 9) − 32` (L208-213), `SLIM = $DB + $700`
   (`mmuseglen`, readWrite). Live-observed: `utiladr = $800`, `prom_byte0 = 0`
   ⇒ `SORG = 4 − 32 = −28`, stored as the 12-bit value **`$FE4`**; `SLIM =
   $7DB` — **byte-for-byte the values M2 recorded.**
3. It copies `do_an_mmu` into that window at virtual `$A84000` (L234-242).

On real hardware virtual `$A84000` (segment-84 page 32) decodes to physical
page `(SORG + 32) mod 4096 = (−28 + 32) = 4` → phys **`$800`** = `utiladr`,
exactly where the handler was copied. The wrap is intrinsic: SORG is a 12-bit
register (hardware-notes.md §1 "AND.W #$0FFF"), page size 512 ⇒ a **21-bit /
2 MB** physical space; `(SORG + pageWithinSegment)` truncates to 12 bits.

**Our `MMU.translate` computed `(sorg<<9) + offset` without the truncation**,
so `$A84000` → `$FE4<<9 + $4000 = $200800` — 2 KB **past** the 2 MB RAM top.
`Bus.ramAccess` returns `$FF` for out-of-range physical (no fault), so `trap
#6` dispatched the CPU to `$A84000` → phys `$200800` → it fetched `FF FF…`
garbage, wandered, and bombed back to `prom_monitor` (the recorded menu
bounce). This is a pure 68000/MMU-modeling divergence — **hypothesis (b)** —
reachable with nothing but a 68000 + MMU + disk.

**Discriminators, as run:**

- **(i) 1 MB probe.** `utiladr` is a *fixed low address* (`$800`), not
  RAM-size-relative, so the gate is RAM-size-**independent** — (a)'s RAM-strand
  is dead either way. (Aside: at `ramSize=$100000` the ROM POST correctly
  writes `prom_realsize=$100000` but our menu-driven boot never reaches the
  loader — a *separate* 1 MB POST-path divergence at `$FE099C`, parked for a
  later milestone; it does not bear on this gate.)
- **(ii) source-ldlfs/ldmicro/LDASM contract.** As above: `trap #6` =
  `do_an_mmu`; vector `$98 = $A84000` by design; no lazy-load handler.
- **(iii) MMU decode of `SORG=$FE4`/`SLIM=$7DB`.** `SLIM` nibble 7 = readWrite,
  limit byte `$DB` ⇒ 37 pages, so page 32 (offset `$4000`) is *within* limit —
  it does **not** fault at the limit check. The only decode question is the
  physical formula, and that is exactly where the wrap was missing.

**Fix (`Sources/LisaCore/MMU.swift`):** mask the memory/stack physical result
to 21 bits — `((sorg<<9) &+ offset) & 0x1F_FFFF` — implementing the hardware's
12-bit page-add wrap. Regression-pinned by `MMUTests.physicalPageAddWrapsAt12Bits`
(the exact `SORG=$FE4`/offset `$4000` → `$800` case, plus a top-of-range wrap
invariant; verified RED without the mask). Sub-2 MB translations are unchanged,
so all prior MMU/Bus/boot assertions still hold.

**Gate outcome — it falls.** With the wrap, virtual `$A84000` → phys `$800`
(in RAM), and at the gate the CPU now **executes the real `do_an_mmu`** code
(`$A84000, $A84004, …$A8406E`) instead of `$FF` garbage. Task 1 characterised
the next stop as a `$FE0030` bounce and left it undiagnosed for Task 2.
**M3 Task 2 diagnosed and moved it:** the `$FE0030` landing was NOT a
`do_an_mmu` return — it was `do_an_mmu` derailing when it toggles SETUP *on*
inside its own loop (a *second* emulation divergence, the setup-latch one). See
"Checkpoint D (M3 Task 2)" below, which supersedes this paragraph's "new stop"
as the authoritative account.

### Sanity-negative sweep (device / interrupt / MMU / screen)

The brief asked to watch for new device expectations, interrupt-mask changes,
MMU reprogramming, and screen drawing on the loader path. Findings, all live:

- **No new device.** Every floppy access is the checkpoint-C go-byte protocol
  (`$85`/`$86`/`$87`/`$81`+readdisk, plus `unclamp` in the eject path). No SCC,
  Widget, or clock probe occurs before the `trap #6` stop. The loader's
  `shutdown` issues `unclamp` (sub-command 2), which the read-only HLE answers
  with `notIssued` (DISKERR 9) — **cosmetically harmless**: `shutdown`
  (source-ldmicro:196-197) waits on the VIA2-PB4 completion line and never reads
  DISKERR, so the eject/teardown completes regardless (see hardware-notes.md §9).
- **Interrupts stay masked at 7.** SR is `$2704` throughout (supervisor, IPL
  mask 7): the loader's read routine masks with `ori #$700,SR` and never drops
  below 7 on this path, so the level-1 floppy line is polled (VIA2 PB4 /
  VIA1 PB6), never delivered as a real IRQ. No unmasking observed.
- **MMU: exactly one new segment, in domain 0, setup-bracketed — OQ1 still
  NOT discriminated.** The loader's only MMU writes are the two seg-84 SLIM/SORG
  above, programmed in the **active domain 0** with setup momentarily on
  (the `do_an_mmu` bracket), then off. It does **not** switch domains and does
  **not** program an *inactive* domain, so this path still cannot tell the
  current-domain model from the hardware inactive-domain semantics (OQ1 remains
  open, as in Trace checkpoint B). **New OQ1 data point though:** this is the
  first observed *post-POST, live* SLIM/SORG programming of a fresh segment by
  running OS code — future work that gets past `trap #6` (into the Pascal
  segment loader, which maps many segments) is the natural place OQ1 will
  finally be forced. **(M3 Task 3 sweep note: this prediction came true --
  see "Checkpoint D" and "OQ1 status" below, where the domain-1 crossover
  forces exactly this and OQ1 is answered.)**
- **The loader draws nothing pre-gate.** The framebuffer set-pixel count is
  identical (`78181`) at `$020000` entry and at the `trap #6` gate — the boot
  UI (menu + opened device-list window) stays on screen unchanged; the loader
  produces no new drawing before it stops. (After the bomb, `prom_monitor`
  redraws — a different, post-stop state, not asserted.)

### What `ROMFloppyBootTests.osLoaderExecutesFromRAMAndReachesPascalSegmentGate` pins

Robust invariants + exact deterministic anchors: `ldbaseptr($21C)==$100000`,
`prom_realsize($2A8)==$200000`, `blocksRead>=20` **and** `==24`, `lastError==0`,
`dev_type($22E)==2`, `ld_fs_block0($210)==$1C`, `log_volume($212)==1`, vector
`$98==$A84000` (PROM handler overwritten), `mmuPortWrites>4384` (seg-84
programmed live), framebuffer still populated (`>70000` px), and `!halted`
(a live progression, not a fault).

## Checkpoint D (M3 Task 2) — beyond the fallen gate: the loader's MMU build and the domain-1 crossover

With the M3 Task 1 page-wrap fix in place, `trap #6` dispatches the CPU to the
real `do_an_mmu` at logical `$A84000` (phys `$800`). Task 2 traced what happens
next, from the `bootIntoLoader` bench (parks at `$A84000`), single-stepping.

### The `$FE0030` stop was a *second* emulation divergence — the setup latch

`do_an_mmu` (LDASM:305-446) is a **loop** that programs one MMU segment per
iteration. Each iteration does `setupoff → (interrupt window) → setupon`, then
reads the SMT entry and writes the SLIM/SORG ports (LDASM:387-425). The handler
lives in seg-84 (logical `$A84xxx` → phys `$800`) and it toggles **SETUP on
inside that loop while continuing to fetch its own code and read the SMT from
that same seg-84 window.**

Our emulator modelled `setupMode ⇒ flat physical addressing` (the POST-era
model). So the *instant* `do_an_mmu` executed `move.b d1,setupon` (`$A84068`),
the next instruction fetch at logical `$A8406E` was treated as flat physical
`$A8406E` — 2 KB past the 2 MB RAM top — returning `$FFFF` garbage. Executing
that garbage took an exception whose vector (`$8`/`$C`, the ROM's default
bus/address-error handler) lands at **`$FE0030`**: `movea.w #$480,A7` (reset SP)
→ `bra $FE0194` (restart the ROM checksum self-test) → the menu. That IS the
"`$FE0030` → `$FE019E` spin → menu bounce" Task 1 saw. **It is not a
`do_an_mmu` return and not a fault-driven load — it is `do_an_mmu` pulling its
own rug out**, because our SETUP model diverged from hardware.

**Evidence (single-step, deterministic):** at `$A84068` `setupMode` flips
`false→true`; the very next step has `PC=$A8406E`, `setup=true`, the fetched
opcode is `$FFFF` ("dc.w $ffff"), and the step after lands at `$FE0030`.
`busErrorPulseCount` stays **0** throughout — this was never a bus error, it was
executing `$FF` filler.

### The fix — SETUP does not disturb live translation

hardware-notes.md §1 "Setup Latch" already records the hardware rule: *while
SETUP is on, SORG/SLIM register writes are redirected, **without disturbing live
translation.*** The setup-toggling code idiom confirms it — `initmmutil` copies
itself to low `$7800` ("*work area where setup can be turned on safely*",
LDASM:165) and `libhw`'s `ReadMagic`/`WriteMagic` run from a fixed low
`MMURoutine`; `do_an_mmu` runs from seg-84 (phys `$800`). All of these keep
executing across their own `setupon`, which is only possible if translation
stays live.

`Sources/LisaCore/Bus.swift` (setup-mode branch): before falling back to flat
physical, attempt `mmu.translate`; use it **only when it resolves to a present
memory segment**. Unprogrammed segments decode to `.fault` (default SLIM nibble
0 → invalidSegment), so every POST setup-mode access — which runs before any
segment is programmed — still falls through to flat exactly as before; only code
running from an already-mapped segment (the loader's `do_an_mmu`) changes. All
172 pre-existing assertions stay green (release + debug); the seg-84 SLIM/SORG
*register* writes were, and remain, intercepted separately by
`slimSorgPortAccess`.

### What the fix reveals — the loader's full domain-0 MMU build

`do_an_mmu` now executes cleanly and `rte`s to the loader's `prog_mmu` return
site **`$10041A`** (the trap frame's stacked PC), `busErrorPulseCount==0`. The
loader then drives `do_an_mmu` (via `prog_mmu`, LDASM:257-275) **once per
segment**, walking segment indices up through `$7F` — **126 completed domain-0
programmings** (calls #1–#126, all `d2=0`), programming ~all 128 of domain 0's
segments, then the faulting domain-1 pivot (call #127). `mmuPortWrites` climbs
`4386 → 4638` (= 126 × 2). Landmarks watched: `blocksRead` stays 24
(no new LFS reads on this stretch — the loader is mapping, not loading),
framebuffer unchanged (`78181` px, no draw), **SR never drops below `$2700`**
(interrupts stay masked at 7 — still no live IRQ delivery), no COPS `$02` clock
read, and **zero floppy writes** (`writeAttempts==0`).

### The new frontier — the domain-1 crossover (OQ1's forcing point, at last)

Calls **#1–#126** are all `d2=0` (target **domain 0**), each programming one
segment (SORG+SLIM = 2 writes) — **126 completed domain-0 programmings, 252
writes** (`mmuPortWrites` `4386 → 4638`). **Call #127** is the pivot: `d0=0 d1=1
d2=1 d3=0` — program **domain 1, segment 0**. `do_an_mmu` "establishes the
requested context" first (executable ctbit switch, LDASM:364-376): it writes
`ctbit1on` (`$A8402E`), switching the **live** context to domain 1, and keeps
executing its own seg-84 code there. But domain 1 is **empty** — the
loader has only just begun building it (this very call is domain 1's *first*
segment) — so the in-handler instruction fetch finds seg-84 unmapped in domain
1; the CPU tries to take the fault, the exception-vector read (`$0C-$0F`, logical
`$0F`) *also* finds domain-1 seg-0 unmapped, and it **double-faults to a halt**.

> **Status update (M3 Task 4):** This multi-domain halt was the Checkpoint-D frontier until the supervisor-domain-0 resolution (see "Kernel push (M3 Task 4)" below). The crossover now survives and reaches the loaded OS code.

This is a genuine **multi-domain-bootstrap boundary**, and it is exactly the
long-carried **OQ1** forcing point ("the Pascal segment loader mapping many
segments … if it switches domains, capture EVERYTHING"). The evidence pins the
shape precisely:

- `do_an_mmu` programs the **currently-active (just-switched-to) domain**, not
  an "inactive" one — it establishes the target domain via `ctbit`, *then*
  `setupon` + writes. This is now **source-established**, not merely a live data
  point: `initmmutil` (LDASM:215-224) sets domain 0 *live* via `ctbit1off/
  ctbit2off` and *then* `setupon`-programs `mmucodemmu`; `do_an_mmu`
  (LDASM:364-376 + 387-425) does the identical establish-then-program pattern.
  If `setupon` targeted the *inactive* domain, `mmucodemmu` would never land in
  the running domain and no Lisa would boot — so **OQ1's active/inactive
  question is ANSWERED: SORG/SLIM writes program the CURRENT (active) domain.**
- For `do_an_mmu` to run at all after switching domains, its own segment
  (`mmucodemmu`, seg-84) — and the vector/stack/SMT segments it touches — must
  be reachable in the target domain **the moment it switches**. `initmmutil`
  programmed seg-84 in **domain 0 only** (LDASM:214-225). So real hardware must
  make these essential segments **global across domains** (or the context latch
  has semantics our per-domain-independent model does not capture).
- **Confirmatory experiment (read-only, not shipped):** mirroring domain-0's
  seg-84 registers into domains 1-3 lets `do_an_mmu` advance only **2 more
  instructions** (`$A84034→$A8403A`) before faulting again on the same
  domain-1-empty vector read. So seg-84-global alone is insufficient — domain 1
  needs its whole essential segment set. Resolving this needs the real Lisa
  per-domain-vs-global segment semantics, which no surfaced primary source
  documents; forcing a fix here would bake in **uncited** hardware behavior.
  **Parked as the Checkpoint-D frontier / OQ1 (still open, but now FORCED and
  characterised with live evidence, not merely predicted).**

> **Status update (M3 Task 4):** This open question was resolved by the supervisor-domain-0 mechanism below. The Checkpoint-D halt no longer occurs; the frontier has moved to the OS's own COPS driver (see "Kernel push (M3 Task 4)" below).

### OQ1 status

**ANSWERED (active/current domain), with a precisely-renamed successor open
question.** OQ1 as originally posed — "does the ROM/OS program SLIM/SORG
targeting the CURRENT domain (our model), or does an 'inactive domain' semantic
matter?" — is now **resolved in favour of the current (active) domain**, and
**source-established**, not just live-inferred: `initmmutil` (LDASM:215-224) and
`do_an_mmu` (LDASM:364-376, 387-425) both establish the target domain *live* via
`ctbit` and *then* `setupon`-program it; the "inactive domain" reading would make
`mmucodemmu` land in a non-running domain and no Lisa would boot. Our
current-domain `MMU.translate`/`slimSorgPortAccess` model matches. (See the
hardware-notes.md §1 "Setup Latch" strike-through: the original M1a "inactive
domain" transcription is refuted — it most likely conflated *registers staged
until setup-off* with *a different domain*.)

> **Status update (M3 Task 4):** OQ1′ (the multi-domain segment presence question) remains open for future investigation. The supervisor-domain-0 resolution (see "Kernel push (M3 Task 4)" below) unblocked the immediate Checkpoint-D halt, moving the frontier forward to the OS's own COPS driver.

**Renamed successor open question (OQ1′ — the Checkpoint-D crossover):**
*per-domain vs. global segment presence.* Checkpoint D is the first path that
switches the live context to a non-zero domain mid-handler, and it needs
`mmucodemmu` (seg-84) — and the vector/stack/SMT segments `do_an_mmu` touches —
present in domain 1 the instant it switches, yet `initmmutil` programmed seg-84
in domain 0 only. What remains undetermined: whether that cross-domain presence
is a hardware-global register file (some segment indices shared across all
domains) or an OS step not yet traced. The seg-84-global-alone experiment (above)
shows it is not a one-register answer. This is the subject of a dedicated
multi-domain MMU task, gated on finding the hardware citation.

### What the M3 Task 2 tests pin (`ROMFloppyBootTests`)

- `doAnMmuExecutesAtItsWrappedHomeAndReturnsToLoader` — the **boot-level guard
  for the fallen gate** (reviewer's ask): from the `$A84000` park, stepping
  through `do_an_mmu` re-enters the loader at **`$10041A`** with
  `busErrorPulseCount==0`, `!halted`, `mmuPortWrites>4386`. Without either the
  M3 Task 1 wrap fix or the Task 2 setup-latch fix this derails to `$FE0030`.
- `loaderBuildsDomain0MMUThenHaltsAtTheDomain1Crossover` — the **Checkpoint-D
  frontier anchor** (SUPERSEDED by M3 Task 4, which resolved OQ1′ so the
  crossover no longer halts; the test was re-anchored to the new furthest
  state — see "Kernel push" below): `≥120` `do_an_mmu` (`trap #6`) calls,
  `mmuPortWrites` climbs past the gate value, the boot **crosses into domain
  1** (OQ1), then **halts** at the multi-domain boundary, `writeAttempts==0`.

## Kernel push (M3 Task 4) — OQ1′ resolved; the loader loads the OS image; the OS's own COPS driver

### OQ1′ answered — supervisor-mode translation uses the OS domain (0)

OQ1′ asked: on real hardware, when `do_an_mmu` switches the live context into
the *empty* domain 1 mid-handler (setup off) and keeps fetching its own seg-84
code, what makes that code reachable? The three candidates were (a) a
SETUP-mode global bypass, (b) the loader pre-programming domain 1 before the
pivot, (c) some segments being hardware-global. **Deterministic single-step to
the fault instant + the OS source refute (a) and (b) and establish the real
mechanism:**

- **Trace (single-step to the pivot).** The last successful fetch is `$A8402E`
  (`move.b d1,ctbit1on`, domain 0, **`setup=OFF`**); the very next fetch
  `$A84034` is in domain 1 and faults. So the context switch is **outside** the
  `setupon` window — **candidate (a) refuted** (setup is off at the switch, in
  both the trace and the source: `do_an_mmu` does `setupon` only later, at
  LDASM:394, inside its loop). And **zero** non-domain-0 SLIM/SORG writes have
  occurred at that instant — domain 1 is provably empty — so **candidate (b) is
  refuted**: nothing pre-programs domain 1.
- **Source (the OS's universal pattern).** `SET_DOMAIN` (starasm1:232-258,
  header "*Can only be called from the supervisor stack*") writes the `ctbit`
  latch to the target domain and then `jmp (a0)` straight back to the caller —
  it *requires* the caller's code to stay mapped across the switch. `do_an_mmu`
  (LDASM:364-425) does the identical establish-then-keep-running dance with
  setup off. Neither can work if the context latch gated supervisor fetches.
  Even the domain-*construction* routines (`MAP_SPACE`/`MAP_DOMAIN`,
  MMPRIM:491-624) run through `do_an_mmu`, switching to the target domain
  *before* programming it — a chicken-and-egg that only closes if supervisor
  code is domain-independent.
- **The model.** Domain 0 is the **OS/system domain** (`initmmutil` LDASM:215
  "establish domain 0, the OS domain"); **domains 1-3 are per-user-process**,
  LRU-assigned from the DCT (`SYSGLOBAL:60/137` `domainRange`/`domvalue`
  "*user's domain on sys call entry*"; SCHED `Set_Address_Space`/`SelectDomain`
  212-453; EXCEPASM's "system code" vs "user domain", 108-178). The context
  (`ctbit`) latch selects the translation map for user-mode accesses;
  **supervisor-mode code EXECUTION translates through domain 0** — the only
  reading under which every domain-switching OS routine keeps running.
  Implemented as `Bus.translationDomain` (`supervisor ? 0 : latched domain`);
  SLIM/SORG *register* programming is a separate mechanism and still targets
  the raw latched domain, so the loader still builds domains 1-3 for later
  user-mode execution. Refutes the M3 Task 2 "per-domain vs global" framing:
  it is neither — it is **supervisor-vs-user**. (hardware-notes.md §1 "Domain
  Context Latches" updated in lockstep.)

- **Scope of the proof / the successor question (OQ1″).** This rule is
  **inferred from OS behavior + source, not a datasheet**, and what the boot
  path actually *proves* is **supervisor code EXECUTION across a latch switch**
  (min SR `$2700`, no user processes yet — no supervisor DATA access to a user
  domain is ever exercised). `Bus.translationDomain` models the rule as
  unconditional (`supervisor ⇒ domain 0`), which may **refine** once processes
  run: EXCEPASM saves `domvalue` ("*user's domain on sys call entry*") so the
  OS can act on the user's domain on syscall entry, hinting the kernel may
  read/write user buffers in domain N while supervisor (LDSN mechanism, or a
  data-reference mode that DOES follow the latch). **OQ1″ (open, flagged for
  the first user-process milestone, M4/M5):** *does supervisor DATA access to a
  user domain follow the context latch?* No traced path exercises it; revisit
  `translationDomain` then. (See the open-questions table below.)

### What the fix reveals — the loader loads the OS image; the OS's COPS driver

With OQ1′ resolved the domain-1 pivot **survives** (`do_an_mmu` establishes
domain 1, programs it, restores domain 0, `rte`s — `busErrorPulseCount==0`, no
halt). The loader then builds domain 1's whole register file (an
`MAP_SPACE`-style clear-to-`mmuabsent` pass — `SLIM=$C00`/`SORG=$000` per
segment — then the mapped entries; `mmuPortWrites` `4638 → 5414`), completes,
and **reads the OS image off the floppy**: `blocksRead` climbs **24 → 75**
(51 OS-image blocks), every read via the PROM twig read routine `$FE1E4C`,
`lastError==0`. Control then enters **loaded OS code at `$520000`**.

The boot stops in the OS's own **COPS command-send driver** (`$520824`). It is
the very protocol the ROM uses (COPS.swift type doc "command-send protocol",
hardware-notes.md §4): stage the command byte to **IORA2 register 15** (the
*no-handshake* ORA alias, `$FCDD9F`), then drive it by flipping **DDRA2**
(`$FCDD87`) to `$FF` (`move.b D3,(A1)` at `$520894`, `D3=$FFFF`), polling
**CRDY** (VIA2 PORTB bit 6, `$FCDD81`) throughout. The routine is sending
`$7C` ("enable mouse interrupts", §4). It **spins** at `$520842-$52084E`
because our simplified COPS model drops CRDY on *every* register-15 write
(`COPS.handlePortAAccess` → `handleCommandWrite`, no index guard on writes),
and this driver re-writes register 15 on every poll iteration — so CRDY, which
the loop waits to read *high*, never recovers. On real hardware a register-15
write is *no-handshake*: it stages the byte without strobing the COPS, so CRDY
is untouched and the loop falls straight through to the DDRA2 drive (which is
the real "send"). The ROM path tolerates the shortcut because it writes
register 15 exactly once; this OS driver does not.

### The M3 Task 4 STOP — a genuinely-new subsystem boundary (M4)

This is the OS's **first non-ROM COPS use**, and closing it faithfully means
modeling the **DDRA2-gated COPS handshake** (register-15 stages, no CRDY
change; the `DDRA2 $00→$FF` transition drops CRDY; the ack raises it) and
re-validating the pinned ROM COPS path (menu FNV fingerprint, the POST presence
probe, `COPSTests`, M1c input) — the ROM currently *relies* on the reg-15-drops-
CRDY shortcut, so this is a rework, not a one-liner. Parked as an **M4
requirement** (COPS-driver fidelity / interrupt-driven COPS), alongside the
already-recorded observation that interrupts stay masked at 7 the entire path
(`minSR=$2700` — the COPS/floppy IRQ is never delivered) and no floppy WRITE
ever occurs (`writeAttempts==0`). Framebuffer unchanged (menu still present,
`78181` px) — the loader/OS draw nothing before this boundary.

### What the M3 Task 4 tests pin (`ROMFloppyBootTests` / `BusTests`)

- `BusTests.supervisorTranslationUsesOSDomainZeroRegardlessOfContextLatch` —
  the OQ1′ mechanism as a unit: with the latch on (empty) domain 1, a
  **supervisor** access resolves through domain 0 (succeeds); a **user** access
  follows the latch into domain 1 (faults).
- `domain1CrossoverSurvivesLoaderLoadsOSImageAndReachesTheCOPSDriver` (re-anchor
  of the Task 2 frontier test) — the crossover **survives** (`!halted`,
  `busErrorPulseCount==0`), `do_an_mmu` returns to domain 0, `≥120` trap-#6
  calls, `mmuPortWrites` climbs past 4638, `blocksRead==75`, `lastError==0`,
  the PC reaches the OS COPS driver `$520800-$5208FF`, `writeAttempts==0`.

**Reproduction.** ~~This frontier is reachable **only through the
integration test** — `lisadbg` cannot get here on its own: it has no
menu-harness (the cursor-walk + click that selects a boot device), so it
cannot drive the ROM past the boot menu into the loader. `bootIntoLoader`
(the `ROMFloppyBootTests` harness) is the sole reproduction vehicle for the
`$520000` state.~~ **Superseded (M4 Task 2):** `lisadbg` now has its own
menu-boot harness (the `bootdisk` command, `Sources/lisadbg/main.swift`,
porting this exact cursor-walk + click mechanism) and reaches this state —
and well past it — on its own; the integration test is no longer the sole
reproduction vehicle. See `task-2-report.md` for a live transcript reaching
`$520712`+ (the current, Task-1-advanced frontier) standalone.

## M3 Task 3 — deferrals re-recorded to M4 (parked-debt bundle)

Two subsystems the M3 plan document's Global Constraints named as
"consciously deferred to M4 unless evidence forces them" (Widget + Power
menu) are re-recorded here, explicitly, as this milestone's ledger asked:
nothing observed on the boot-to-menu path, the floppy-boot path
(checkpoint C), or the OS-loader path through the current Checkpoint-D
frontier (`do_an_mmu`'s domain-0 MMU build and the domain-1 crossover halt)
has forced either into scope.

| Deferred item | Evidence it wasn't forced | Where the hook already exists |
|---|---|---|
| **Widget hard-disk HLE** | `dev_type` (`$22E`) only ever observed `= 2` (`dev_sony`) on every traced boot (checkpoint C, Task 6's loader progression, Checkpoint D) — `dev_widget = 3` (docs/hardware-notes.md §9 "Boot Path") is never selected because no traced path chooses a Widget boot device. | None yet — no peripheral beyond the internal Sony/Twiggy floppy (`FloppyController`) exists in this emulator. |
| **ProFile HLE** | Same low-core cell: `dev_type` never observed `= 1` (`dev_prof`) on any traced path. `docs/hardware-notes.md` §9's "ProFile interleave table" is transcribed as research only, never exercised. | None yet. |
| **Soft power / Power menu** | No traced boot path (menu idle-wait, floppy boot, the OS loader through Checkpoint D) has been observed to issue a Power Command byte (`$20`/`$21`/`$23`/`$25`/`$2C`/`$2D`, docs/hardware-notes.md §7). | `COPS.powerCommandLog` (`Sources/LisaCore/COPS.swift`) already recognizes and logs every Power Command byte, regression-pinned by `COPSTests.powerCommandsAreLogged` — no shutdown/reboot/alarm semantics are modeled behind the log, by design, until M4 evidence demands them. |
| **OS COPS command-send driver** (M3 Task 4 STOP) | The boot now reaches the OS's own COPS driver at `$520824` (sends `$7C`) and spins: our simplified COPS model drops CRDY on *every* register-15 write, but this driver re-writes register 15 each poll iteration (real hw: register 15 is *no-handshake* — stages without strobing the COPS; the `DDRA2 $00→$FF` transition is the real send). See "Kernel push (M3 Task 4)". | `Sources/LisaCore/COPS.swift` (`handleCommandWrite`) — needs a **DDRA2-gated CRDY handshake** + re-validation of the pinned ROM COPS path (menu FNV, POST presence probe, `COPSTests`, M1c input) before it can advance. |
| **OQ1″ — supervisor DATA access to a user domain** (open) | `Bus.translationDomain` models `supervisor ⇒ domain 0` as unconditional, but only supervisor *execution* is proven (§1). EXCEPASM saves `domvalue` so the OS can act on the user's domain on syscall entry — the kernel may read/write user buffers in domain N while supervisor once processes run. No traced path exercises it. | `Sources/LisaCore/Bus.swift` `translationDomain` — revisit at the first user-process milestone (M4/M5). |

Wired the same way the plan's own precedent already established
(`docs/hardware-notes.md` §7 "Soft Power Control" carries the mirrored
note): these are conscious M4 deferrals, not gaps discovered by this
sweep — re-recording them here just makes the M3 ledger's own claim
("Widget + Power menu remain consciously deferred to M4 unless evidence
forces them") checkable against live evidence, in the same place the rest
of this document tracks what's forced vs. deferred.

## M3 final-state summary (Task 5, milestone close)

M3 opened with the boot stalled at what M2 mislabeled a Pascal segment-call
gate; it closes with the OS's own code running from `$520000`, having read
itself off the floppy and built out its own MMU domain-0 map. Three real
emulation divergences were found and fixed along the way (M3 Task 1's 12-bit
MMU page-add wrap, M3 Task 2's setup-latch live-translation fix, M3 Task 4's
supervisor-always-domain-0 translation rule); each was root-caused against
the Lisa OS assembly source before being patched, not guessed at. The
milestone's current stop — the OS's own COPS command-send driver spinning on
a handshake line our simplified COPS model doesn't drive the way this driver
expects — is a **genuinely new subsystem boundary**, not a fourth emulation
bug: it is the first time any traced boot path has exercised OS-originated
(as opposed to ROM-originated) COPS traffic. Full narrative: `docs/m3-demo.md`
(plain-language walkthrough), "Checkpoint D" and "Kernel push (M3 Task 4)"
above (evidence + citations).

### Open-question statuses at milestone close

| ID | Question | Status |
|---|---|---|
| **OQ1** | Does SLIM/SORG register programming target the CURRENT (active) domain, or an "inactive domain" per the original M1a hardware-notes transcription? | **ANSWERED** (M3 Task 2) — the CURRENT (active) domain, source-established (`initmmutil`/`do_an_mmu` both establish-then-program). The "inactive domain" reading is refuted; hardware-notes.md §1 carries the strike-through. See "OQ1 status" above. |
| **OQ1′** | Checkpoint D's domain-1 crossover: how does `do_an_mmu`'s own code stay reachable the instant it switches the live context into an empty domain? | **RESOLVED** (M3 Task 4) — supervisor-mode code EXECUTION always translates through domain 0, regardless of the context latch; the latch only gates user-mode accesses. Implemented as `Bus.translationDomain`. Supersedes the Task 2 "per-domain vs. global segment presence" framing — it is neither, it is supervisor-vs-user. See "Kernel push (M3 Task 4)" above. |
| **OQ1″** | Does supervisor **DATA** access (not code execution) to a user domain follow the context latch, or also force domain 0? | **OPEN**, registered M3 Task 4 review. No traced path exercises supervisor data access to a non-zero domain yet (min SR stays `$2700`, no user processes run in M3). Flagged for the first user-process milestone (M4/M5); revisit `Bus.translationDomain` then. |
| **OQ2** | How does the ROM reach ROM/special space (segments 125-127) in translated mode — exact SLIM/SORG values? | **ANSWERED** (M1b Task 5) — seg 127 (prom) SLIM `$F00`/nibble `$F`; seg 126 (iospace) SLIM `$901`/nibble `$9`; seg 125 (screen) left absent at setup-drop. See "Answers to the Task 5 open questions" above. Unrelated to M3's MMU work; listed here only for a complete OQ roster at milestone close. |
| **OQ3** | Does board-ID `$C031 == 0x00` send POST down a sane (non-error) path? | **ANSWERED** (M1b Task 5) — yes, the pre-Pepsi path, benign. See "Answers to the Task 5 open questions" above; unrelated to M3, listed for completeness. |

The M3 Task 3 deferrals table above (Widget HD, ProFile, soft power/Power
menu, the OS COPS driver, and OQ1″) is this document's live record of what
M3 consciously left for M4; nothing in that table was silently dropped.

## Checkpoint E (M4 Task 3) — THE UNMASKING: live interrupts and the OS comes alive

M4 Task 1 opened the OS↔COPS handshake; M4 Task 2 gave `lisadbg` a `bootdisk`
harness. This checkpoint follows the OS from the un-frozen COPS driver through
`DriverInit`/`INITSYS` to **the first live interrupt delivery in the emulator's
history**, and finds the OS running its scheduler in user mode. One real
emulation divergence was found and fixed (an inverted `$F801` bit-2 polarity
that stormed the OS's level-1 interrupt handler), root-caused against the OS
assembly source before being patched.

### What the OS does after the COPS driver (LIBHW-DRIVERS `DriverInit`)

The loaded OS at `$520000` runs `DriverInit` (LIBHW-DRIVERS:493) then `INITSYS`.
`DriverInit` programs the hardware the way the source prescribes and our model
answers:

- **VIA1 T1 = the millisecond tick.** `DriverInit` picks the T1 reload from the
  board ID (LIBHW-DRIVERS:578-588): pre-Pepsi `$27CA`, post-Pepsi `$637B`.
  `DiskROMId` bit 7 selects; our board reports pre-Pepsi (`$C031==0`, OQ3), so
  the OS writes **`LCounterInit=$CA` / `HCounterInit=$27`** (the pre-Pepsi
  values) — confirmed live. It sets `ACR1=$48`, enables T1 via `IER1=$C0`, and
  installs `Level1` at vector `$0064`.
- **Level-2 COPS.** `DDRA2=$00` (port A input), `PCR2=$C9`, `ACR2=$01`,
  `IER2=$82` (enable COPS), then `COPSCMD` sends **`$7C`** ("enable mouse
  interrupts", the very command M4 Task 1's handshake fix let complete), and
  installs `Level2` at vector `$0068`.

### The divergence — `$F801` bit-2 vsync polarity was inverted (interrupt storm)

The instant the OS lowers SR below `$2700`, its `Level1` handler
(`$5208A6`, LIBHW-DRIVERS:895) runs. Its first act:

```
Level1  MOVEM.L A0/D0,-(SP)
        BTST    #2,StatusRegister+1   ; $FCF801 bit 2 — vertical retrace?
        BNE.S   @0                    ; "branch if NOT vertical retrace"
        JSR     VertRetrace           ; else service + ack it
```

`BNE` taken means bit 2 ≠ 0 ⇒ *not* retrace; so **bit 2 == 0 is the OS's
"retrace pending" encoding** (active-LOW), and only then does it call
`VertRetrace`, whose tail writes `$E018` (VertReset) to acknowledge. Our model
exposed the bit **active-HIGH** (`pending ? 0x04 : 0`), so the handler read
bit2=1 as "no retrace", never called `VertRetrace`, never acked — while
`Machine.vsyncPending` (a real level-1 source) stayed asserted. The moment SR
dropped, the CPU took a level-1 interrupt, `Level1` found "nothing to do",
`rte`'d, and **immediately re-entered** because the vsync line was still high:
a permanent interrupt storm, PC pinned in the `$5208xx` handler, no main-code
progress. (Traced live: `vsyncPending=true`, `F801=$04`, the handler cleanly
`rte`-ing and re-entering `$5208A6` every iteration.)

**Fix** (`IODispatcher.currentValue`, `case 0xF801`): expose bit 2 active-low —
`(statusByte & ~0x04) | (pending ? 0 : 0x04)`. Now a pending retrace reads
bit2=0, `Level1` calls `VertRetrace`, `$E018` clears `vsyncPending`, and the
level-1 line drops. This is *more* faithful to the ROM too: the ROM's own
vsync self-test (`$FE0BA2`, "Trace checkpoint B" above) clears via `$E018` then
waits for bit 2 to read 0 as "the next retrace arrived" — active-low. The ROM
tolerated the old polarity only because that self-test is soft-fail either way;
**every ROM anchor (menu FNV `0xd09234d25516d0b8`/78,100 px, POST, floppy boot
through the COPS driver) is unmoved by the fix**, confirmed by the full suite.
hardware-notes.md §2/§5 carry the corrected polarity (strike-not-erase).

### The first live interrupts — verified against the OS's handlers

With the storm gone, SR unmasks at `$5208A6` (`$2700 → $2100`) and the
emulator delivers its first interrupts, straight into the OS's own handlers:

- **Level 2 (COPS/VIA2)** first: vectored to **`Level2` @ `$520A52`** (SR
  `$2004 → $2200`). The initial COPS packets (the `$7C` ack / power-on stream)
  are consumed here.
- **Level 1 (VIA1 T1 ms-tick / vertical retrace)**: vectored to **`Level1` @
  `$5208A6`** (SR `→ $21xx`), servicing `VertRetrace` (`ScrnFrames`,
  cursor tracking) and `Timer1` each tick.

Both autovectors match the addresses `DriverInit` installs at `$0064`/`$0068`.
The M1b-era "interrupt-delivered floppy completion never exercised" item is now
partially retired: `Level1` polls the Twiggy/disk completion lines (`VIA2 PB4`,
`VIA1 IFR`) on every tick under live interrupts — though no disk *completion*
interrupt fires at this checkpoint (the OS issues no new disk command here).

### Where it rests — the OS scheduler idles in a user-mode event-wait (the STOP)

Freed from the storm, the OS runs its scheduler across **eleven loaded code
segments** (`$22/$24/$26/$28/$2E/$3C/$3E/$46/$48/$4C/$CC xxxx`) and drops to
**user mode (SR `$0000`)** — its first processes are running. It then settles
into a steady **user-mode event-wait loop** at `$4C0276`:

```
$4C0276 movea.l ($a,A6),A0
$4C027A move.l  (A0),-(A7)
$4C027C pea     (-$2a,A6)
$4C0280 jsr     ($7d4,A5)     ; getter -> $2E2BE4: reads a field, returns
$4C0284 cmpi.b  #$2,(-$2a,A6) ; wait for an in-RAM state byte to become 2
$4C028A bne     $4c0276
```

This loop touches **no hardware** — it polls an in-RAM state field for the
value `2`; the only live I/O in the whole resting steady-state is the ms-tick
`Level1` handler. Over ~1.77 billion cycles (~350 s emulated) nothing changes:
`blocksRead` stays 323, `writeAttempts` 0, `mmuPortWrites` ~5508, the screen
frozen at 78,181 px (the ROM boot screen plus the OS's hourglass/busy cursor —
the OS's `VertRetrace` cursor code is now live). Injected mouse motion does not
move the cursor here, so this is not the interactive desktop idle: the OS is
**blocked in its scheduler waiting for an in-memory event to be posted** that
never is in our model.

**The STOP (a documented boundary, not a bug):** the OS is alive — scheduler
running, both interrupt levels delivering to its own handlers, first processes
in user mode — and idles awaiting an unposted event. Identifying which
process/event the wait polls (and satisfying it, toward the Office System
desktop) is **M4 Task 4**. Whether that event is a scheduler/exception post, an
alarm, or a device-completion the boot volume needs (Widget probe) is the next
frontier.

### OQ statuses at Checkpoint E

- **OQ1″ (supervisor DATA access to a user domain): still OPEN, not yet
  forced.** User processes run (SR `$0000`) but `Bus.domain` stays **0**
  throughout — no supervisor access to a non-zero domain has occurred yet.
  `Bus.translationDomain` is untouched. Revisit when a process runs in domain
  1+ and the kernel copies its buffers (M4 Task 4 / M5).
- **Floppy writes: still none observed** (`writeAttempts==0` everywhere through
  Checkpoint E). Session write-through stays armed but unbuilt, exactly as the
  plan's contingency prescribes — nothing to implement until the OS writes.
- **COPS `$02` clock read:** not observed at this checkpoint; the OS's COPS
  traffic here is the `$7C` mouse-int enable and the level-2 packet stream.

### What the Checkpoint E test pins (`ROMFloppyBootTests`)

`checkpointE_unmaskingAndFirstLiveInterrupts` — from the loaded OS code:
`minSR < $2700` (the unmasking, in fact to `$0000`), the `Level1` (`$5208A6`)
AND `Level2` (`$520A52`) handlers both entered (first live level-1 + level-2
delivery), user mode reached, the `$4C0270` event-wait loop reached, `!halted`,
`busErrorPulseCount==0`, `writeAttempts==0`, `blocksRead==323`. Robust
invariants alongside the exact deterministic handler/loop anchors.


## Checkpoint F (M4 Task 4) — the init-time driver I/O-completion poll (CORRECTED)

Checkpoint E left the OS idle in a poll at `$4C0270`, waiting for an in-RAM byte
to become `2`. M4 Task 4 dissected that wait. **The first-round diagnosis below
was WRONG and is struck; the corrected diagnosis, proven against the OS source
(source-DRIVERDEFS/asynctr/clock/SOURCE-STARTUP), follows.**

> ~~**(Struck — M4 Task 4 review.)** The polled cell is an "event object" and
> the OS "blocks on an event that another process or a device would post";
> hypothesis-4 "no second process" was read as confirmation of a
> co-process/"multiprocess event-dispatch" boundary; the leading trigger was
> guessed to be "a periodic COPS/RTC status interrupt our HLE doesn't emit."~~
> Every one of those claims is refuted below. The empirical traces that fed
> them (getter `$2E2BE4` reads obj+`$14`; the sole writer `$2E2BFC` sets it to
> `2`; input does not post it; the OS Timer Manager is healthy; A5 never
> changes; nothing else runs) are all correct — only their *interpretation* was
> wrong.

### What the poll actually is: a driver-request-block completion wait

The polled object is a **driver I/O request block** (`reqblk`,
source-DRIVERDEFS:182-204). Field offsets confirmed live: obj+`$4` =
`pcb_chain.kind` = `reqblk_type(1)` (proves the record type); the polled cell
obj+`$14` is `reqstatus.reqsrv_f`, enum `(active,in_service,complete)=0/1/2` —
so the awaited value **`2` means `complete`**. The getter `$2E2BE4` returns that
field; the loop spins until it is `complete`.

The sole writer `$2E2BFC` is **`unblk_req`** (source-asynctr:209-245), matched
instruction-for-instruction: `cmpi.b #$2,(A4)` = "if reqsrv_f <> complete";
`move.b #$2,(A4)` = "reqsrv_f := complete"; the `[$15]:=[$16] xor 1` "toggle"
(mis-read at first round as a blink pair) is literally
`reqsuccess_f := not reqabt_f`; `tst.l (A3)` = "if pcb_chain.headr <> nil"; the
`($c54,A5)` call = `ALARMRELATIVE(unblk_alarm,0)`. `unblk_req`/IODONE is called
from **device-completion handlers** (floppy, ProFile, serial, console) and from
the 10 ms clock ISR `CLK_Q_MGR` (source-clock:447). The poster is an
**ISR/driver completion**, not a co-process.

### The boot phase: single-process STARTUP, before multiprocessing

Per SOURCE-STARTUP:2174-2184, `INITSYS` runs `BOOT_IO_INIT` (= Checkpoint E's
unmasking, "Init all devices, runs FS_INIT") → `SYS_PROC_INIT` (creates the
system processes) → … → `ENTER_SCHEDULER`. Our observed "A5 never changes, no
context switch" is **not** a co-process boundary — it means the boot is still in
the **single outer STARTUP process, inside `BOOT_IO_INIT`, before
`SYS_PROC_INIT` has created any other process.** At this phase a wait can only
be satisfied by an ISR/driver completion.

### The request, identified: an FS-mount READ to the OS's own Sony driver

The reqblk fields (live): `operatn` (obj+`$18`) = `1` = **read**; `cfigptr`
(obj+`$1A`) → a `devrec` at `$CC5CE0` whose driver `entry_pt` is a jump table
into segments `$46/$48/$4A`; `req_extent` (obj+`$1E`) → a `disk_extend` reading
**block `41`** = the volume's `fs_strt_blok` (`ext_diskconfig.fs_strt_blok`,
`num_bloks=$694`=1684). Devices `"#14#1"`/`"#14#2"` share this driver. The
driver code references **`$FCC000`/`$FCC180`** (the floppy shared-RAM window +
parameter memory), so this **is the OS's own Sony floppy driver** for the two
drive slots — issuing the boot-volume MDDF/catalog read that FS_INIT needs to
mount the boot volume. (It is NOT an unimplemented device, and NOT the boot
Sony we already serve via the ROM routine — see next.)

### Why it never completes — the precise, corrected frontier

Counting across the whole boot-to-rest:

- **`unblk_req` (`$2E2BFC`) executes 0 times** — no reqblk is ever completed.
- **The OS Sony driver's hardware layer never runs** — its command-issue
  (`$46027A`: `move.b #$88,($3,A2)` to `$FCC003`) and command-wait
  (`$460160`: poll `$FCC001` + `$FCD801` bit 6) execute **0 times**. The request
  is never dispatched to hardware (no `$FCC000` access occurs after the last
  read).
- **Every working read (248, blocks 75→323) used the *synchronous* ROM read
  routine `$FE1E0E`** (`movea.l #$fcc001,A0`) — the loader-style path. The
  boot loads itself synchronously via the ROM; the **first time it issues an
  *async* `reqblk` read (the FS mount), it hangs.**

The reviewer's suspect (a) — "the ms-tick never reaches `CLK_Q_MGR`'s
alarm-expiry path" — is **refuted**: the alarm mechanism is alive and firing.
The alarm-callback table `$CC0090[]` holds kernel alarms `$521360` and
`$52123E`, both of which **fire** (9× / 10× over 40 M cycles) driven by the ms
tick → Timer Manager. But the **Sony driver's own servicing alarms**
(`$4612EC`, `$4611A0`, also registered in `$CC0090[]`) are **registered but
never armed** (their `$CC0026` active bit stays clear), so the driver is never
kicked to service the queued request. The gap is therefore **not** the clock
ISR and **not** an unimplemented device: it is that the enqueued async disk
request is **never dispatched to the Sony driver** (its servicing alarm is never
armed) at this pre-multiprocessing stage, so no completion ISR ever calls
`unblk_req`.

**Corrected boundary (M5 frontier):** the OS's **async driver request-dispatch
path** for the boot-volume FS-mount read does not function under our emulation
during single-process `BOOT_IO_INIT` — the Sony driver's servicing alarm is
never armed, the read is never issued to `$FCC000`, and `reqsrv_f` stays
`active` forever. The synchronous ROM-routine read path works (248 reads); the
async OS-driver path does not. Identifying *why* the driver's alarm is not armed
when `DEV_IO` enqueues the request (a driver-model / request-dispatch divergence
— e.g., a device/parameter-memory state the driver checks before arming, or the
`(-$55c,A5)` "skip-wait" mode flag the loop tests at `$4C0270` that is `0` here)
is the M5 fix target. No evidence-gated device/core fix was reached this task:
the two first-round-plausible fixes (clock-ISR alarm expiry; an unimplemented
device) are both refuted, and fabricating completion would be faking progress.

### OQ / writes / screen at Checkpoint F (unchanged, re-confirmed)

- **OQ1″: still OPEN.** Single-process STARTUP, supervisor stays domain 0;
  A5/context never change; no supervisor DATA access to a non-zero domain.
- **Floppy writes: still NONE** (`writeAttempts == 0`).
- **COPS `$02` clock: not read** (`clockSetNibbles == []`). (Not implicated —
  the wait is a disk-driver completion, not a COPS event.)
- **Screen: one frozen rest screen** — the ROM "STARTUP FROM" window + the OS
  busy/hourglass cursor (`~/Development/LisaEmu-artifacts/m4-checkpoint-f-rest.png`,
  identical to `m4-checkpoint-e.png`, 78,181 set px). Unchanged by input.

### What the Checkpoint F test pins (`ROMFloppyBootTests`)

`checkpointF_blockedOnDriverIOCompletion` — reaches the `$4C0276` init-time
I/O-completion poll and pins the corrected diagnosis: the getter reads the
reqblk's `reqstatus` field (obj+`$14`), the setter `$2E2BFC` (`unblk_req`) writes
`complete`=2; the reqblk is derived at runtime and confirmed (`kind=reqblk_type`
at +`$4`, `operatn=read`). Over an 8 M-instruction window it asserts the
mechanism: `unblk_req` (`$2E2BFC`) never runs, the OS Sony driver's hardware
command-issue (`$46027A`) never runs, the state stays `active` (≠ complete), A5
never changes (single-process STARTUP), while the machine is provably alive —
`Level1` (`$5208A6`) fires and the Timer Manager accumulator `$CC001E` advances
— with no halt, no bus error, `writeAttempts == 0`, `blocksRead == 323`.
