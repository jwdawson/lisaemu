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
presence test. (The `ioTrace` cap of 4096 entries fills by ~30 M, so `g`'s
per-slice I/O dump goes empty after that — an artifact of the trace buffer, not
of the CPU going quiet; the PC samples confirm it is still spinning.)

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
| `$F801` status register (`btst #1`)                       | real status bits (bit1, plus bit2 vsync)     | Task 5 |
| `$E018/$E01A/$E01C/$E01E` video strobes                   | vsync/vertical-retrace strobe + interrupt semantics; `$E01C/$E01E` are newly observed | Task 5 |
| `$D241` controller (error `$37/$38`)                      | candidate SCC; passes 0xFF stub, defer       | later serial task |
| `$C031` board ID                                          | none — `0x00` (pre-Pepsi) already correct    | — |

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
