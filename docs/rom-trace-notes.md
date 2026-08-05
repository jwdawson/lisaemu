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
6522, which **differ from `hardware-notes.md §3`** (`$D801`/`$DC01`):

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
| `$F801` status register bit 1 (`btst #1`)                 | still undetermined — new context found (NMI/bus-error RAM-probe, not vsync); see "Trace checkpoint B" | later task |
| `$FE2DBE` unconditional "next COPS input byte" wait        | genuine open frontier — confirmed NOT vsync-related (SR interrupt mask blocks all levels here regardless); needs either a real unsolicited COPS event or further call-chain tracing to determine what, if anything, the ROM expects | later task |
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

**Undetermined by the boot trace — remains OPEN for M1b.** The current-domain
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
