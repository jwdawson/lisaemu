# Apple Lisa Hardware Constants Reference

This document consolidates hardware constants mined from the Apple Lisa OS source tree. All values are cited to their original locations in `Lisa_Source/LISA_OS/`. This is a reference document for hardware-related development and validation; treat all values as absolute and keep citations current as validation anchors.

Note: `LIBHW/` and `LIBS/LIBHW/` are byte-identical; citations use `LIBHW/`.

## 1. Memory Management Unit (MMU)

### Base Addresses

- **I/O Space MMU:** `$FC0000` (OS/source-PASCALDEFS.TEXT.unix.txt:47; also OS/source-SERNUM.TEXT.unix.txt:15)
- **Real Memory MMU:** `$AA0000` (OS/source-PASCALDEFS.TEXT.unix.txt:54)

### MMU Addressing Model

- **MMU_BASE Calculation:** `MMU_BASE(mmu) = mmu * $20000` (128KB per MMU segment)
  - Source: OS/source-MMPRIM.TEXT.unix.txt:773-797
  - Self-consistent mapping: IOSPACEMMU=126 → $FC0000; SCREENMMU=125 → $FA0000; PROM_MMU=127 → $FE0000; REALMMU(85) → $AA0000

### Register Index Assignments (128 total, numbmmus=128)

- Assigned per domain per OS/source-PASCALDEFS.TEXT.unix.txt:62-71, OS/source-MMPRIM.TEXT.unix.txt:60-94:
  - monvarmmu=0
  - lisabugmmu=16
  - kernelmmu=17
  - codespacemmu=1
  - mmucodemmu=84
  - realmemmmu=85 (start of 16 MMUs mapping real memory, logrealmem=$AA0000)
  - superstkmmu=101
  - sysglobmmu=102
  - syslocmmu=103
  - minsysldsnmmu=104..106
  - ldsn1mmu=107
  - ldsn2mmu=108
  - ldsn7mmu=113
  - stackmmu=123
  - shrsegmmu=124
  - screenmmu=125
  - iospacemmu=126
  - prommmu=127

### Access-Type Codes

Source: OS/source-MMPRIM.TEXT.unix.txt:97-101, OS/source-PASCALDEFS.TEXT.unix.txt:78-79
- mmureadonly = $5
- mmustack = $6
- mmureadwrite = $7
- mmuio = $8
- mmuabsent = $C

Additionally observed programmed by the Rev H boot ROM (see
rom-trace-notes.md); not present in the OS source's constant set --
decode semantics to be implemented in M1b:
- $9 = iospace (seg126 SLIM=$901, programmed at $FE0118)
- $F = prom/special (seg127 SLIM=$F00, programmed at $FE0120)

### Software Segment Map Table (SMT) Entry

Source: OS/source-MMPRIM.TEXT.unix.txt:268-274, OS/source-LDASM.TEXT.unix.txt:139
- Structure: packed record with origin (int2, pages), access (int1), limit (0..255 pages)
- Table size: array[0..511] of SMT entry = 512 total entries (128 MMUs × 4 domains)
- Entry size: 512 bytes/domain

### Hardware Register Layout (SOR/SLIM)

Derived from `do_an_mmu` (OS/source-LDASM.TEXT.unix.txt:305-446) and ReadMMU/WriteMMU (LIBHW/libhw-MACHINE.TEXT.unix.txt:611-685).

**Register Width:** Both registers are 12-bit (AND.W #$0FFF — libhw-MACHINE:636-637, 660-661)

**Origin Register (SORG):**
- Bits 11-0: page number of segment origin
- Page size: 512 bytes (mempgsize=512)

**Limit/Access Register (SLIM):**
- Bits 11-8: access nibble (pre-shifted values confirmed: mmustack equ $600, mmureadwrite equ $700 — LDASM:129-130)
- Bits 7-0: length in pages; two's complement for non-stack (neg.b d3 — LDASM:414)
- Stack special: length = (value-1) with origin adjusted +length-$100 first (LDASM:403-412)

**Physical Address Relocation:**
- For memory access types ($5/$6/$7, access ≤ mmunotmem $700): prom_byte0 (physical byte 0 offset) is added to origin before programming (LDASM:417-420)
- I/O and absent types skip relocation

**Physical Address Width — 12-bit page-add WRAP (21-bit / 2 MB space):**
The physical page number the MMU forms is `(SORG + pageWithinSegment)`
**truncated to SORG's 12-bit width**, i.e. it wraps modulo 4096 pages. With a
512-byte page that is a **21-bit (2 MB) physical space**: `physical =
(((SORG & $FFF) << 9) + offsetWithinSegment) & $1FFFFF`. This is not cosmetic —
the loader relies on it. `initmmutil` (LDASM:174-252, "MMU Programming (TRAP #6)"
below) programs `mmucodemmu` (seg 84) with a **negative** origin page
`SORG = ((utiladr + prom_byte0) >> 9) − 32`; for the live-observed
`utiladr=$800, prom_byte0=0` that is page `−28`, stored as the 12-bit value
`$FE4`. It points TRAP #6's vector at `mmusegorg+bit_14 = $A84000` and expects
virtual `$A84000` (seg-84 page 32) to decode back to physical `$800`:
`(−28 + 32) mod 4096 = 4` → `$800`. Without the wrap the same access lands at
`$FE4<<9 + $4000 = $200800`, past 2 MB. Implemented in `LisaCore/MMU.swift`
(`& 0x1F_FFFF` on the memory/stack result); diagnosed and fixed in M3 Task 1
(rom-trace-notes.md "Gate diagnosis (M3 Task 1)").

### Register Port Addressing

Source: OS/source-LDASM.TEXT.unix.txt:139-179, 380-425
- SLIM address: `$8000`
- SORG address: `$8008` (8 bytes higher, e.g., move d2,8(a2) — LDASM:425)
- Per-MMU SLIM address: `slim + mmu_index * $20000`
- Bit shift: mmu_to_base = 17

### Setup Latch

Source: LIBHW/libhw-DRIVERS.TEXT.unix.txt:139-140, LDASM:154-155
- SetUpSet: IOSpace + $E010
- SetUpReset: IOSpace + $E012
- Behavior: ANY access (read or write, e.g., TST.B) toggles the flip-flop; data is irrelevant (libhw-MACHINE:641-645, 681-685)
- While SETUP is on, SORG/SLIM writes program ~~the inactive domain's registers~~ **the CURRENT (active) domain's registers** without disturbing live translation
  - **~~inactive domain~~ REFUTED (M3 Task 2, strike-through-not-erase):** the "inactive domain" half is contradicted by the very source that sets this behavior up. `initmmutil` (LDASM:215-224) establishes domain 0 *live* via `ctbit1off/ctbit2off` and *then* `move.b d0,setupon` + programs `mmucodemmu`; `do_an_mmu` (LDASM:364-376 establish, 387-425 program) does the identical establish-then-`setupon`-then-program pattern. If `setupon` targeted the *inactive* domain, `mmucodemmu` would land in a non-running domain and no Lisa would boot. The original M1a transcription most likely conflated "registers staged until setup-off" with "a different domain." OQ1's active-vs-inactive question is now **ANSWERED: current (active) domain** — source-established, matching our current-domain `MMU.translate`/`slimSorgPortAccess` model (rom-trace-notes.md "Checkpoint D (M3 Task 2)" / "OQ1 status"). The "without disturbing live translation" half stands, now doubly proven (see the M3 Task 2 note below).
- Sequence (per do_an_mmu): toggle setupoff → interrupt-window → setupon per write (LDASM:387-394)
- **"Without disturbing live translation" is load-bearing (M3 Task 2):** SETUP
  redirects the SORG/SLIM *register* ports, but general instruction/data
  translation stays active. `do_an_mmu` (LDASM:305-446) proves it — the handler
  runs from seg-84 (logical `$A84xxx` → phys `$800`) and toggles SETUP *on
  inside its own loop* while it keeps fetching its code and reading the SMT from
  that seg-84 window; it could not if SETUP forced flat addressing. Likewise
  `initmmutil` copies itself to low `$7800` ("work area where setup can be
  turned on safely", LDASM:165) and `libhw`'s Read/WriteMagic run from a fixed
  low `MMURoutine` (libhw-MACHINE:611-685) — all setup-on code sits at a
  low-physical / already-mapped home. Emulator: `Bus.access`'s setup-mode branch
  models POST as flat (segments unprogrammed → `.fault` → flat), but now also
  applies `mmu.translate` to a **present** memory segment before the flat
  fallback, so `do_an_mmu` executes at its wrapped home (rom-trace-notes.md
  "Checkpoint D (M3 Task 2)").

### Domain Context Latches

Source: OS/source-starasm1.text.unix.txt:232-258 (SET_DOMAIN), LDASM:145-151
- ctbit1on = $FCE00A
- ctbit1off = $FCE008
- ctbit2on = $FCE00E
- ctbit2off = $FCE00C
- Behavior: Access-triggered like SetUp; 2 bits encode domains 0..3
- **Domain 0 is the OS/system domain; domains 1-3 are per-user-process
  (M3 Task 4, OQ1′).** `initmmutil` (LDASM:215) "establish domain 0, the OS
  domain"; domains 1-3 are LRU-assigned to user processes from the DCT
  (`SYSGLOBAL:60/137` `domainRange`/`domvalue` "user's domain on sys call
  entry"; SCHED `Set_Address_Space`/`SelectDomain` 212-453; EXCEPASM
  "system code" vs "user domain", 108-178).
- **Supervisor-mode code EXECUTION translates through domain 0 regardless of
  the context latch (proven); the latch selects the map for user-mode
  accesses** (M3 Task 4, OQ1′). NOTE: this is **inferred from OS behavior +
  source, not a datasheet**, and what is *proven* is specifically **supervisor
  code execution across a latch switch** — the only thing the boot path
  exercises (min SR `$2700`, no user processes yet, so no supervisor DATA
  access to a user domain occurs). The proof: `SET_DOMAIN` (starasm1:232-258,
  "*can only be called from the supervisor stack*") flips the latch then
  `jmp (a0)` back to the caller, and `do_an_mmu` (LDASM:364-425) flips the
  latch **with setup OFF** then keeps fetching its own seg-84 code and reading
  the SMT — both would fault on the first post-switch fetch if the latch gated
  supervisor translation, and no Lisa would boot. Even the domain-construction
  routines (`MAP_SPACE`/`MAP_DOMAIN`, MMPRIM:491-624) switch to the target
  domain *before* programming it. Deterministic single-step confirms the pivot
  fetch `$A84034` occurs in the freshly-latched, empty domain 1 with
  `setup=OFF` and nothing written to domain 1 (rom-trace-notes.md "Kernel push
  (M3 Task 4)"). Implemented as `LisaCore/Bus.swift`'s `translationDomain`
  (`supervisor ? 0 : latched domain`); SLIM/SORG *register* programming
  (`slimSorgPortAccess`) still targets the raw latched domain, so the loader
  builds domains 1-3 for later user-mode execution. (This SUPERSEDES the M3
  Task 2 "per-domain vs global segment presence" framing of OQ1′: it is
  neither — it is supervisor-vs-user.)
- **OPEN (OQ1″) — supervisor DATA access to a user domain.** The rule above is
  modeled as unconditional (`supervisor ⇒ domain 0`), but only supervisor
  *execution* is proven. EXCEPASM saves `domvalue` ("*user's domain on sys
  call entry*", SYSGLOBAL:137) precisely so the OS can act on the user's domain
  once processes run — hinting the kernel may read/write user buffers in
  domain N while supervisor (LDSN mechanism, or a mode where data references
  DO follow the latch). No traced path exercises this yet. **Flagged for the
  first user-process milestone (M4/M5)**; revisit `translationDomain` then.

### Reset Line (Warm Reset)

M2 Task 2 modeling note, not a primary-source citation (no OS-source
listing describing the 68000 RESET line's effect on these specific
latches/registers has surfaced): the SETUP flip-flop's own documented
power-on default is "on" (translation off, flat `$FCxxxx` I/O addressing --
see "Setup Latch" above), and a hardware reset re-establishes that same
default state, re-asserting SETUP and clearing both domain-context latch
bits (`domain` back to 0) -- this is the natural reading of "reset returns
the machine to its power-on state" applied to latches whose power-on state
is independently documented above, not a separately-sourced fact about the
RESET line itself.
- The SORG/SLIM MMU segment registers are modeled as SURVIVING a warm
  reset (RAM-like storage, not re-zeroed) -- a deliberate simplification,
  not a hardware citation either way. With SETUP re-asserted, the CPU's
  vector fetch and everything else in `$0000-$3FFF` goes through the flat
  ROM-mirror path (see "ROM Range" under Memory Map) regardless of what
  those registers still contain, so their survival is unobservable at
  reset time either way -- see `LisaCore/Machine.swift`'s `reset()` doc
  comment.
- Both VIA6522 chips are reset per the 6522/65C22 datasheet's documented
  RES behavior (see "VIA 6522 Chips" below) -- `LisaCore/VIA6522.swift`'s
  `reset()` doc comment has the full citation and the one documented
  simplification (this model additionally disarms in-flight timers, where
  some datasheets describe T1/T2 counter/latch content as unaffected by
  RES).

### Physical Byte 0 Relocation Cell

- Address: prom_byte0 = $2A4 (OS/source-LDEQU.TEXT.unix.txt:65)
- Alias: MemoryBase = $2A4 (libhw-DRIVERS:131)
- Usage: Low-core cell containing physical byte 0 relocation added to segment origins

### MMU Programming (TRAP #6)

Source: starasm1:186-214 (trap dispatch); implementation do_an_mmu LDASM:257-450
- Trap vector: trap6 = 152 (LDASM:172)
- Pascal entry points (MMPRIM:352-363, 800-824):
  - MAP_SEGMENT
  - MAP_DOMAIN
  - SET_DOMAIN
  - LDSN_TO_MMU

## 2. Video System

### Latches

- **VideoLatch:** IOSpace + $E800 = $FCE800 (libhw-DRIVERS:140-142)
  - Value: (ScrnPhys + MemoryBase) >> 15
  - Alignment: 32KB-aligned physical page
  - Source: SetScreenKeybd, libhw-MACHINE:138-149
  - **Both bytes of the word latch (M9 finding, 2026-08-16).** The register
    captures whichever data lane the CPU drives, so `$FCE801` sets it just as
    `$FCE800` does. Evidence: the Rev H ROM writes it at 5 sites, every one a
    `MOVE.B` to the EVEN address (`13FC`/`13C0`/`13C6` + `00FCE800`), and the
    whole ROM image contains **zero** references to `$FCE801`; the Lisa OS
    likewise uses `MOVE.B D1,VideoLatch` (libhw-MACHINE:147). A 68000 `MOVE.B`
    to an even address drives D15-D8. **MacWorks Plus II writes the same
    register as a WORD (`$003E`)**, putting the page on D7-D0 — the odd byte.
    Both work on real hardware, so the latch cannot be tied to a single lane.
    Modeled in `IODispatcher.applyNonLatchWrite` as "either address latches";
    since `Bus` decomposes a word write into even-then-odd byte writes,
    last-write-wins yields the low byte for a word write and leaves the
    ROM/OS byte path bit-identical. Found because MacWorks Plus II latched
    `$00` and scanned out physical page 0 — its own data tables and `$55`/`$AA`
    memory-test patterns — instead of its screen.

- **ContrastLatch:** IOSpace + $D01C = $FCD01C (libhw-DRIVERS:136)
  - Range: 0 (max contrast) – 255 (min)
  - Initialization: $80; dim mode: $B0
  - Board-revision-dependent write paths: libhw-MACHINE:65-78, 227-260

### Display Specifications

Source: libhw-MACHINE:97-99, 38-41
- **Resolution:** 720 × 364 pixels
- **Framebuffer:** 32,760 bytes
- **Refresh rate:** ~60 Hz

**M1b Task 5 modeling note (not a cited hardware fact):** bit order within
each framebuffer byte is assumed MSB-first, row-major (bit 7 = leftmost
pixel of each 8-pixel group, 90 bytes/row × 364 rows = 32,760) — the
conventional 1bpp bitmap convention and consistent with 720/8 = 90 dividing
evenly, but not independently confirmed against OS source or a real
screen dump. `Bus.framebufferSnapshot()`/`lisadbg`'s `sc`/`sca` commands
follow this assumption; revisit if a later task finds contradicting
evidence (e.g. once the OS actually draws something recognizable).

### Low-Core Screen Cells

Source: libhw-DRIVERS:127-131
- AltScrnAddr = $110
- ScrnAddr = $160
- AltScrnPhys = $170
- ScrnPhys = $174

### Vertical Retrace

Source: libhw-DRIVERS:936-962; independent confirmation OS/source-SERNUM.TEXT.unix.txt:16-20

**Registers:**
- VertReset: IOSpace + $E018 (write re-arms/clears pending)
- StatusRegister: IOSpace + $F800 (16-bit); low byte at $FCF801
- ~~StatusRegister bit 2: vertical retrace pending~~ **(polarity corrected M4
  Task 3 — see below)** StatusRegister bit 2 is **ACTIVE-LOW**: `0` == retrace
  pending, `1` == not pending.
- VRIRENB (V-Retrace Interrupt Enable): $E01A + IOMMU
- VRIRDIS (V-Retrace Interrupt Disable): $E018 + IOMMU

**M4 Task 3 polarity correction (`$F801` bit 2 is active-LOW).** The OS source
settles the bit-2 sense the ROM self-test could not (its poll window is far
shorter than a vsync period, soft-fail either way). LIBHW-DRIVERS `Level1`
(:895) and `Poll` (:801) both do `BTST #2,StatusRegister+1 / BNE (skip
VertRetrace)` with the comment *"branch if NOT vertical retrace"* — so bit 2
**== 0** is "retrace pending" (service it), bit 2 **== 1** is "not pending".
`VideoTiming.pending` is still the internal boolean; `IODispatcher.currentValue`
now exposes it inverted at `$F801` (`pending ? 0 : 0x04`). The earlier
active-high exposure stormed the OS's level-1 handler at the unmasking (it read
bit2=1 as "no retrace", never acked via `VertRetrace`'s `$E018` write, and
`Machine.vsyncPending` held level 1 asserted forever). See
docs/rom-trace-notes.md "Checkpoint E". No ROM anchor moved.

**M1b Task 5 ground truth / polarity resolution:** this section's own two
phrasings are in tension ("VertReset... write re-arms/clears pending" vs.
"VRIRDIS" = DISable) — the Rev H boot ROM's own vsync self-test
(`$FE0BA2-$FE0DE4`, disassembled live under trace, docs/rom-trace-notes.md
"Trace checkpoint B") resolves it: the ROM's OWN access order is `$E018`
(ANY access) THEN `$E01A` (ANY access) before polling bit 2 — i.e. clear/
disarm first, then arm, matching the VRIRDIS/VRIRENB (DISable/ENable)
labels, not a "re-arms" reading of $E018. M1b's `VideoTiming` implements
$E018 = disarm the interrupt + clear the pending status bit; $E01A = arm
(and assert immediately if bit 2 is already pending). The ROM's own
self-test tolerates either outcome of its bit-2 poll (a non-fatal
diagnostic flag on failure, not a retry-forever or abort) because its
poll window (~130 cycles, observed) is far shorter than one ~83,333-cycle
(5 MHz / 60 Hz) vsync period — so this ROM code does not, by itself,
discriminate the polarity choice; the VRIRDIS/VRIRENB naming plus the
ROM's own access order are the basis for this model's semantics.

**$E01C/$E01E — diagnosed, not modeled (Task 5):** bare `tst.b` strobes
(data irrelevant, like the Setup/Domain-context latches above) bracketing
a RAM-sizing/checksum routine (`$FE0D68-$FE0FCC`); the ROM never branches
on the result. Purpose undetermined (no hardware-notes source located);
docs/rom-trace-notes.md "Trace checkpoint B" has the full citation. Model:
falls through to the existing generic "unknown I/O offset" stub, confirmed
sufficient (the ROM proceeds past every occurrence regardless).

**StatusRegister bit 1 — new context, still undetermined (M1b Task 6):**
tested inside an NMI-vector-installing RAM/bus-error presence probe
(`$FE0F46-$FE0F72`, installs a handler at low-core `$7C`) within the same
RAM-sizing routine — likely related to the "Known Gaps" parity/bus-error
status noted below, not vsync. M1b Task 6 disassembled all three statically
gating sites (`$FE00D0`, `$FE0F14`, and inside the NMI handler at `$FE0F72`)
but an unbounded live single-step trace (every instruction, reset through
30M cycles — 14M past the `$FE2DBE` frontier) found `$FE00D0` sits in
unreachable dead disassembly and the other two score zero PC hits — none of
the three are confirmed live-reached. Real semantics, and whether this
model's default (bit clear) has any live consequence at all before the
frontier, remain fully undetermined; see docs/rom-trace-notes.md "Bus-error
frame spike (M1b Task 6)" for the full trace (an earlier draft of this note
claimed "reconfirmed safe" from static analysis alone — retracted after the
live check).

**Interrupt:** Level 1 (autovector $64) — libhw-DRIVERS:895-898

### Serial Number

- **Address:** SNUM = $FE8000 (special I/O segment 127)
- **Format:** Bitstream readable
- **Synchronization:** Vsync-synchronized
- **Source:** OS/source-SERNUM.TEXT.unix.txt:17

## 3. VIA 6522 Chips

### Base Addresses

**Rev H boot ROM ground truth (primary source — use these):**

The Rev H boot ROM was traced under the emulator (docs/rom-trace-notes.md
"Beyond the M1a boundary (Trace checkpoint A)"), and the register base each
VIA is actually programmed at was read straight off the disassembly of the
accessing code:

- **VIA1:** IOSpace + **$D901**, stride ×8. Base loads at `$FE0802`
  (`movea.l #$fcd901,A0`), `$FE0B6A`, `$FE1138`, `$FE1E14`; register decode
  confirmed there (e.g. `($10,A0)`=DDRB1, `($18,A0)`=DDRA1, `($08,A0)`=PORTA1,
  T1 latch loads `$FCD931`/`$FCD939` = T1LL1/T1LH1).
- **VIA2:** IOSpace + **$DD81**, stride ×2. Base loads at `$FE0494`
  (`movea.l #$fcdd81,A0`), `$FE0920`, `$FE0B06`, `$FE11D0`, …; register decode
  confirmed at `$FE0B0C-1E` (`($04,A0)`=DDRB2, `(A0)`=PORTB2, `($16,A0)`=ACR2;
  the boot self-test targets `$FCDD8D`/`$FCDD8F` = T1LL2/T1LH2).

**M1b Task 3 (VIA core) must implement the ROM-observed bases $D901/$DD81** (or
model the partial chip-select decode that makes the historical aliases below
alias onto the same chips) — the ROM never touches $D801/$DC01.

**Historical OS-source equates (libhw-DRIVERS:137-138), REFUTED for the Rev H
2/10 boot path** — kept for provenance only:

- ~~VIA1: IOSpace + $D801 (hard disk / parallel VIA; alternate decode: $D101)~~
- ~~VIA2: IOSpace + $DC01 (keyboard / COPS VIA; alternate decode: $D181)~~

The prior "Use $D801/$DC01 (Lisa 2/10-era decodes)" note was an OS-source
assumption; the ROM trace (primary source) shows the Rev H boot code uses
$D901/$DD81, so per the both-docs ROM-wins rule the ROM values above take
precedence. (The register *offset* tables and stride below are unchanged and
were independently re-confirmed by the same trace.)

### VIA1 Register Offsets

Stride: ×8 bytes (libhw-DRIVERS:148-163)

| Register | Offset |
|----------|--------|
| PORTB1   | $00    |
| PORTA1   | $08    |
| DDRB1    | $10    |
| DDRA1    | $18    |
| T1CL1    | $20    |
| T1CH1    | $28    |
| T1LL1    | $30    |
| T1LH1    | $38    |
| T2CL1    | $40    |
| T2CH1    | $48    |
| SR1      | $50    |
| ACR1     | $58    |
| PCR1     | $60    |
| IFR1     | $68    |
| IER1     | $70    |
| IORA1    | $78    |

### VIA2 Register Offsets

Stride: ×2 bytes (libhw-DRIVERS:165-182)

Note: Stride differs from VIA1—a common emulation gotcha.

| Register | Offset |
|----------|--------|
| PORTB2   | 0      |
| PORTA2   | 2      |
| DDRB2    | 4      |
| DDRA2    | 6      |
| T1CL2    | 8      |
| T1CH2    | 10     |
| T1LL2    | 12     |
| T1LH2    | 14     |
| T2CL2    | 16     |
| T2CH2    | 18     |
| SR2      | 20     |
| ACR2     | 22     |
| PCR2     | 24     |
| IFR2     | 26     |
| IER2     | 28     |
| IORA2    | 30     |

### VIA2 CA1 — the COPS receive handshake (M8 finding, PARTLY UNMODELED)

> **CORRECTION 2026-08-15 (M9 opening probe).** This section originally
> claimed the CA1 flag "never sets" and that raising it would light up an
> untested interrupt path. **Both are wrong**, and the "who needs it" claim
> below is wrong too. What is genuinely unmodeled is narrower than it reads:
> `VIA6522` has no CA1/CA2 *edge* logic (PCR edge select, auto-clear of IFR
> bit 1 on a register-1 read) **inside the chip core** — but the COPS HLE
> already performs the externally observable half of it. `IODispatcher.swift`
> wires `COPS`'s `raiseInterrupt`/`clearInterrupt` onto
> `VIA6522.setInterruptFlag(0x02)` / `clearInterruptFlag(0x02)`, and
> `COPS.scheduleDeliveryIfIdle` raises IFR2 bit 1 the moment a byte is ready
> while `COPS.handleByteConsumed` clears it on a genuine handshake read. So
> **IFR2 bit 1 is asserted and cleared on the real byte-ready/handshake
> conditions today**, and `VIA6522.peek(13)` returns it regardless of IER.
> The gap that remains matters only to a guest that drives CA1 for something
> *other* than COPS byte-ready, or that depends on PCR edge polarity.

**`VIA6522` models neither CA1 nor CA2.** The Rev H boot ROM does not need
them: it polls CRDY (PORTB2 bit 6) exclusively, which is what this emulator
grew up satisfying. The Lisa OS, however, **enables CA1 and expects the
handshake** — live trace of a full Office System boot off a Widget
(`lisadbg`, `iot limit 600000`, 164k VIA2 accesses):

| Access | Count | Meaning |
|---|---|---|
| `$FCDD9D` (IER2) W `$82` | 6 | bit 7 = *set*, bit 1 = **enable CA1 interrupts** |
| `$FCDD9D` (IER2) W `$7F` | 2 | clear all sources |
| `$FCDD99` (PCR2) W `$09` / `$C9` | 3 | CA1 = **positive edge** (PCR bit 0) |
| `$FCDD83` (PORTA2 reg 1) R | **93** | the HANDSHAKE port — a real 6522 clears the CA1 flag on this read |

PORTA2 carries COPS command/reply DATA (see "COPS" above), so CA1 is the
COPS byte-ready strobe and the OS's driver is written for interrupt-driven
receive. The emulator reaches the desktop with working keyboard and mouse
regardless, because the COPS HLE satisfies the polled path — the CA1 ISR has
simply never executed here.

~~**Consequence for anyone implementing it:** CA1 interrupts are *already
enabled* on a level-2 line during a normal boot. Asserting IFR bit 1 will
start dispatching an OS interrupt path that has never run in this emulator,
against a COPS model whose delivery is gated on read counts — a concrete
double-consume hazard, and a risk to every checkpoint FNV, menu anchor and
input pin. Treat it as a milestone, not a patch.~~

**CORRECTED 2026-08-15.** IFR2 bit 1 is not a dormant path: the COPS HLE
raises it on **every keyboard byte and every mouse packet**, so the level-2
line it feeds has been exercised continuously since M4. There is no
"never-run interrupt path" to light up, and no new double-consume hazard —
`COPS` already owns both the raise and the clear, and has since M4's
read-count gate landed.

~~**Who needs it:** MacWorks Plus II 2.5.0, which uses CA1 *exclusively* —
its loader polls IFR2 bit 1 with a 2047-try timeout and then reads PORTA2
reg 1, and never touches CRDY at all. Without CA1 it times out forever.~~

**CORRECTED 2026-08-15 — MacWorks Plus II does not need this.** Its loader
does poll IFR2 bit 1 on a 2047-try budget and read PORTA2 on success, but
that routine is a bounded "receive one COPS byte, or time out" helper that
**returns either way**; its callers are keyboard prompts waiting for the
user (Space/mouse-button, then Y/N). It stalls because nobody presses a key,
not because the flag cannot set — and it polls at IPL 7, where no interrupt
could be delivered even if CA1 were fully modeled. See
docs/macworks-plus-notes.md §10.

### VIA1 Function

Source: libhw-DRIVERS:578-588, 595-596

- **Timer1:** System millisecond tick
  - Pre-Pepsi reload: $CA/$27 ($27CA = 10186)
  - Post-Pepsi reload: $7B/$63 ($637B = 25467)
- **Ports:** Drive contrast DAC and disk-enable signals
- **Shift Register:** Used for alarm interrupts
- **Interrupt Level:** 1 (IRQ)

#### VIA phi2 clock = CPU/4 (Pepsi) — the keyboard-auto-repeat / millisecond-clock rate

The 6522 phi2 is **divided down from the CPU clock**, and the T1 reload
values above pin the divisor exactly. The OS loads VIA1 T1 so one underflow
period equals **20 ms of real time** (its `Timer1` handler adds 20 to the
`TimerTicks` millisecond clock per T1 IRQ — libhw-DRIVERS:974/987), and
libhw-DRIVERS:574-576 states the Pepsi board needs "a larger number ... since
the clock is running faster":

- **Pre-Pepsi:** 10186 VIA-clocks = 20 ms ⇒ phi2 = 509.3 kHz = **CPU/10**
  (the classic 6800-family E-clock; CPU = 20.371 MHz / 4 = 5.093 MHz).
- **Post-Pepsi (this emulator's board):** 25467 VIA-clocks = 20 ms ⇒ phi2 =
  1.273 MHz = **CPU/4** (= master 20.371 MHz / 16). The ratio 25467/10186 =
  2.5 = 10/4 confirms the divisor went from /10 to /4.

On real hardware `/4` is EXACT: master 20.371 MHz / 16 = 1.2732 MHz phi2,
and 25467 / 1.2732 MHz = 20.002 ms. Emulation: `Machine.tickVIAsAndUpdateIRQ`
feeds both VIAs `cycles/4` (`Machine.viaClockDivisor`, remainder carried), so
25467 counts take 25467×4 = 101,868 CPU cycles. At our 5.0 MHz nominal CPU
clock that is 20.37 ms vs the intended 20.00 ms — ~1.9% slow, purely the
emulator's pre-existing nominal-clock approximation (we run 5.0 MHz, not the
real 5.093 MHz), the exact same rounding `VideoTiming.cyclesPerVsync` = 83,333
already carries (= exactly 60.0 Hz at 5.0 MHz vs ~60.1 Hz real). It does not
affect the auto-repeat fix: the ~102 ms-vs-400 ms threshold separation is
~4×, dwarfing 1.9%. **Bug history (keyboard-duplication fix):** the VIAs were
previously ticked at CPU/1, so T1 fired every ~5.09 ms and `TimerTicks` ran
~3.93× too fast. The keyboard driver's auto-repeat `RepeatInitial` = 400 ms
delay (libhw-DRIVERS:543) then elapsed after only ~102 ms of real key-hold —
inside a normal human keypress — so the OS emitted a spurious typematic repeat
that **duplicated every typed key** at the desktop. lisadbg's `type` held keys
only ~30 ms (≪ the 102 ms threshold), which is why headless typing looked
clean while the live app duplicated. Regression pinned by
`VIAClockDivisorTests`.

### VIA2 Function

- **Port A:** COPS handshake bus
- **Port B bit 1:** Volume control (libhw-MACHINE:508-528)
- **Shift Register (ACR2/SR2):** Drives speaker output (libhw-MACHINE:559-570)
- **IFR2 bit 1:** COPS interrupt pending
- **Interrupt Level:** 2 (IRQ)

### Driver Initialization Sequence

Source: libhw-DRIVERS:592-620

**VIA1:**
- ACR1 = $48
- TST SR1
- T1CL1 = LCounterInit
- T1CH1 = HCounterInit
- IER1 = $C0

**VIA2:**
- DDRA2 = $00
- DDRB2 = (mask $0E; preserve bits 5 and 7)
- PCR2 = $C9
- ACR2 = $01
- IER2 = $82

### Reset (RES) Behavior

Per the commonly-documented 6522/65C22 datasheet RES pin behavior: clears
DDRA/DDRB/ORA/ORB/ACR/PCR/IER/IFR to 0 (all peripheral pins become inputs,
both timers forced to one-shot mode with handshaking disabled, every
interrupt source masked). See "Reset Line (Warm Reset)" above for the
cross-reference to the MMU/setup-latch side of a Lisa hardware reset, and
`LisaCore/VIA6522.swift`'s `reset()` doc comment for the one documented
simplification this model makes (disarming in-flight timers, where some
datasheet variants describe T1/T2 counter/latch content as unaffected by
RES).

## 4. COPS (via VIA2 Port A for data; Port B for the CRDY handshake)

### CRDY lives on PORTB2 bit 6 — REFUTES the OS-source claim below

**M1b Task 4 ground truth (primary source — use this):** the Rev H boot
ROM's own COPS command-send routine (`$FE0956`-`$FE09C0`, disassembled live
under trace — see docs/rom-trace-notes.md "COPS" section and
task-4-report.md for the full transcript) polls CRDY exclusively via `btst
#6,(A1)` with `A1 = $FCDD81` — VIA2 base + offset **0**, i.e. **PORTB2**, not
PORTA2 (`$FCDD81 + 2 = $FCDD83`). Independently confirmed by a direct
register dump at the ROM's COPS-poll stall (`m fcdd80 20` under `lisadbg`):
`DDRB2 = $0E` (only bits 1/2/3 are outputs — bit 6 is an input, consistent
with CRDY being COPS-driven) while `DDRA2 = $00` (Port A still fully input,
before the routine's own `DDRA2 = $FF` step even runs). Command/reply DATA
is on Port A exactly as documented below; only the handshake bit's PORT was
wrong.

**Historical OS-source claim (libhw-DRIVERS:822-887), REFUTED for the Rev H
boot path** — kept for provenance only:

- ~~Poll CRDY (Port A bit 6, aka VIA2 base + bit 6)~~

Per the both-docs ROM-wins rule, PORTB2 bit 6 is the corrected reading; the
flow steps below are otherwise unchanged (and re-confirmed by the same
trace, including the byte-order refinement noted in step 1).

### Command Protocol

Source: libhw-DRIVERS:822-887, corrected/refined by the M1b Task 4 ROM trace.

**Flow (ROM's `$FE0956` "SendCOPSCommand", corrected step order):**
1. Write command byte to IORA2 (register 15, the no-handshake ORA alias, offset `$1E`) — while DDRA2 is still `$00` (input): this STAGES the byte without yet driving Port A's pins (real 6522 DDR-gates-OR-to-pins behavior).
2. Poll CRDY (**PORTB2** bit 6) until it reads 0 ("ready → not-ready").
3. A short delay, then poll CRDY == 0 again (observed as a near-instant second check in practice).
4. Set DDRA2 = $FF (output) — Port A now actually drives the staged byte. This is the real "send" (not a separate step 6 — the ROM does not re-write the data byte here).
5. Poll CRDY until it reads 1 again ("not-ready → ready" — COPS acknowledging).
6. A further short delay, then set DDRA2 = $00 (input).
7. `IER2 |= $82` (register 14, set-mode, bit 1) — enables VIA2's "COPS interrupt pending" source (§3's IFR2 bit 1) for whatever input follows.

Step numbering above is the ROM's actual order (DDRA2 → output happens
AFTER, not before, the "wait for not-ready" poll) — the original OS-source
listing's step numbering implied output-then-poll; the ROM trace is the
primary source for the corrected order.

**M4 boundary — the OS's own COPS command-send driver (M3 Task 4 STOP;
CLOSED by M4 Task 1, model below).** Once M3 Task 4 resolved OQ1′ (§1 Domain
Context Latches), the boot loads the OS image and reaches loaded OS code at
`$520000` running the identical command-send protocol from RAM — an OS
driver (`$520824`, `COPSCMD`, LIBHW-DRIVERS:829-887) sending `$7C` ("enable
mouse interrupts"). It **stages** to IORA2 register 15 (`$FCDD9F`,
no-handshake) and then **drives** via DDRA2 (`$FCDD87` ← `$FF`), exactly as
steps 1-4 above. The emulator STALLED here (M3 Task 4 — pre-M4 state, kept
for provenance): `LisaCore/COPS.swift`'s simplified model dropped CRDY on
*every* register-15 write (it had no per-index guard on writes), but this
driver re-writes register 15 on **every poll iteration**, so CRDY — which
the loop reads *high* to proceed — never recovered. The ROM path survived
the shortcut only because it writes register 15 exactly once.

~~Closing this needs a **DDRA2-gated CRDY handshake** (register-15 write =
no CRDY change; the `DDRA2 $00→$FF` transition = the real send that drops
CRDY; the ack raises it)~~ — **REFUTED by M4 Task 1's disassembly evidence**
(both the live `$520824` OS binary and the ROM's own `$FE0956`, task-1-report.md):
in BOTH senders, Phase A/loop-1's CRDY poll for the drop runs, and succeeds,
*entirely before* the DDRA2 flip ever executes (OS: Phase A/B, `$520842`-
`$520892`, all precede Phase C's DDRA2 write at `$520894`; ROM: steps 2-3
precede step 4's DDRA2 write at `$FE0994`). So the DDRA2 transition CANNOT be
what drops CRDY for either sender — **the register-15 write is the drop's
real trigger**, matching the pre-M4 model's mechanism, not contradicting it.

**M4 Task 1 model (implemented):** the write still drops CRDY, but the
*visibility* of that drop is gated by READ COUNT, not cycle count
(`COPS.swift`'s `suppressCRDYDropForNextRead`): the FIRST `portBInput` read
after a fresh (ready→not-ready) transition-triggering write still reports
ready; every read after that reports the real dropped state. This lets the
OS's Phase A (`$520842`-`$52084E`: write, then IMMEDIATELY test, zero
intervening instructions) see "still ready" and fall through on the common
(idle-COPS) path, while Phase B's very next check (`$520850`, the SECOND
read since the same write) deterministically sees the real drop — closing
the M3 Task 4 stall without ever needing the ROM to change how it drives
DDRA2 at all. A cycle-scheduled short delay was tried first and rejected: it
broke under `Machine.run(until:)`'s burst execution (`Bus`'s injected
`scheduleEvent` computes a scheduled event's due cycle from `Machine.cycles`,
which only updates once an entire CPU burst completes — up to
`Machine.irqPollQuantum`, 1024 cycles, stale relative to a write that
happens mid-burst), regressing `ROMFloppyBootTests` back into the same
looks-instant-drop failure mode this task exists to fix. The read-count gate
needs no cycle scheduling for the drop's visibility at all, so it is exact
under any execution granularity. Re-validated: menu FNV/px, POST presence
probe, `COPSTests`, M1c input backstop, and the M2/M3 boot anchors
(`blocksRead` 75, `$520000` entry) all unchanged (task-1-report.md). DDRA2
itself remains unmodeled by `COPS` (no bit-level Port A bus simulation).

**Frontier check (M4 Task 1):** with the fix, `$7C`'s handshake completes and
the CRDY spin breaks. `COPSCMD` is called via `jsr` from `$52070E`, so its
`rts` (`$5208A4`) returns to `$520712` — the very next instruction in its
CALLER, driver-init — which immediately installs the level-2 (COPS)
autovector handler (`lea ($33C,PC),A1; move.l A1,$68.w`) and continues
driver-init (clearing OS globals, walking a 16-entry device table at
`$2B0.w` via `jsr $520A74` per entry, etc.). **Not** the `Level1`-shaped
code visible at `$5208A6`+ immediately after `COPSCMD` in binary layout —
that address is simply the next routine in the image, never reached from
this call site; it would only run later via an actual interrupt, and
interrupts are still masked at this point. Task 3 should start tracing from
`$520712`.

Companion observations at the (now-passed) M3 Task 4 boundary: interrupts
stay masked at 7 the whole path up to that point (`minSR=$2700` — the
COPS/floppy IRQ is never delivered), and no floppy WRITE ever occurs
(`writeAttempts==0`). See rom-trace-notes.md "Kernel push (M3 Task 4)" and
"Checkpoint E" (M4 Task 1/3).

### Command Bytes

All citations from libhw-TIMERS, libhw-MACHINE, or libhw-DRIVERS:

| Byte  | Function                            | Source                      |
|-------|-------------------------------------|-----------------------------|
| $02   | Read clock                          | libhw-TIMERS:620            |
| $2C   | Disable clock/timer, prep set-clock | TIMERS:656                  |
| $10   | Write clock nibble (or'd with data) | TIMERS:666, MACHINE:468     |
| $25   | Enable clock, disable timer         | TIMERS:673                  |
| $20   | Power off (timer off, clock off)    | MACHINE:425                 |
| $21   | Power off (timer off, clock on)     | MACHINE:427                 |
| $2D   | Disable timer enable, set clock for reboot alarm | MACHINE:462     |
| $23   | Power off, reboot later             | MACHINE:473                 |
| $7C   | Enable mouse interrupts (16ms)      | libhw-DRIVERS:616           |

**M1b Task 4 trace note:** the boot ROM's own POST presence probe
(`$FE093E-$FE0954`) sends `$00`, `$70`, `$50`, `$60` in sequence — none of
which are in this OS-derived table. These read as boot-ROM-only
diagnostic/self-test opcodes with no documented meaning; the ROM only
requires the CRDY handshake to complete for each, not any particular
COPS-side effect.

### Input Packet State Machine

Source: libhw-DRIVERS:1074-1252 (COPS/COPSX handlers)

**State 0 (idle):**
- $00 → mouse packet (enter state 1)
- $80 → reset code follows (enter state 4)
- Else → keycode (bit 7 = down/up flag; bits 6-0 = keycap)

**State 1:** Receive dx → advance to state 2

**State 2:** Receive dy → emit MouseMovement, return to state 0

**State 3:** Receive 5 clock bytes (after $E0-$EF seen in state 4) → update ClockHigh/ClockLow (byte layout: see "Read-Clock ($02) Reply Format" below)

**State 4 (reset dispatch):**
- $00-$DF: keyboard ID
- $E0-$EF: clock start (year nibble = low 4 bits)
- $F0-$FA: reserved
- $FB: power button (synthesized as key $08 down/up) -- CONFIRMED correct by
  M6 Task 1 (DRIVERS:1196/1230 sets `D0=$08`; `KeyPushed` KEYBD:755/758 emits
  down `$80` + up `$00`; pseudo-key table KEYBD:732 `08 -- Power Button`). COPS
  puts `$80,$FB` on the wire; the OS makes the `$08` -- see §7 "Power Button ->
  shutdown chain" for the full button->PowerDown->COPS-power-off path.
- $FD: keyboard unplugged
- $FE-$FF: COPS failure (bit 0: 0 = I/O COPS, 1 = keyboard COPS)

**M1b Task 4 trace note (RETRACTED by Task 7 — see correction below):** Task
4 read the reset-dispatch handler as unconditionally receiving 5 more bytes
after ANY State-4 sub-code, and its COPS model appended 5 zero placeholder
trailing bytes to the power-on stream.

**M1b Task 7 correction — the 5-byte payload is CLOCK-START-only, matching
the state machine:** re-disassembling the reset dispatch (`$FE2D5C`) shows
the sub-code branches are NOT symmetric. The keyboard-ID branch (`$00-$DF`
-> `$FE2D7C`) stores the ID at `$1b2` and loops straight back to the
packet-start (`bra $fe2d38`) — it reads NO trailing bytes. Only the
clock-start branch (`$E0-$EF` -> `$FE2D82`) stores the sub-code at `$480`
and falls into the 5-iteration receive loop (`$FE2D9E-$FE2DBA`, into
`$481-$485`). So a keyboard-ID reset packet is exactly 2 bytes (`$80` +
ID); the 5 data bytes belong to State 3, reached only via the State-4
clock-start sub-code, exactly as the state machine above already says. Task
4's "fixed 7 bytes regardless of sub-code" reading was a misattribution
(the extra bytes it saw consumed were its own placeholder `$00`s being
re-parsed as State-0 mouse-packet markers). Task 7's COPS model sends the
faithful 2-byte `$80, <keyboard ID>` announcement and drops the 5 trailing
`$00`s; the ROM reaches the byte-identical boot menu either way (the
power-on stream is not load-bearing for the boot path — see
docs/rom-trace-notes.md "POST completion (Task 7)").

### Read-Clock ($02) Reply Format and Set-Clock Sequence (M6 Task 2)

Sources: libhw-TIMERS:600-609 (clock/calendar packing), :619-641 (`Clock`,
the `$02` read), :652-680 (`SetClock`, the set sequence), :695-766
(`ClockToDate`, the consumer); libhw-DRIVERS:1161-1219 (`COPS3`/`COPS4`, the
parser); :505-506 (uninitialized init); libhw-MACHINE:419-480 (power-off /
reboot-alarm clock semantics).

**~~M1b-era placeholder (STRUCK):~~** ~~the `$02` reply was `$80, $E0,
<4-byte big-endian host Unix time>, $00` — a best-effort guess, no
byte-level format claimed.~~ SUPERSEDED: the OS parses those raw seconds as
BCD and gets an invalid day/hour, which is why the Office System showed its
"clock not set" Note (M6 Task 2 live proof, task-2-report.md). The real
format is derived below from the OS's own parser — the OS side is the
contract, every byte cited.

> **Hedge (Task 2, honest):** the causal chain "invalid parsed date → the Note
> draws" is **empirically dispositive** (the Note is present with the old
> placeholder reply and gone with the parser-derived reply, otherwise identical)
> but not fully source-cited: `ClockToDate` (TIMERS:695-766) does not itself reject
> an invalid BCD date — it only special-cases the `0FFF…` uninitialized sentinel
> (DRIVERS:505-506). The exact Office System / Desktop Manager validity check that
> raises the alert is **un-cited** because that source is not in the tree (only the
> Filer and libhw are). We claim the byte-level `$02` contract (cited below), not
> the dialog's internal trigger.

**Clock/calendar packing (TIMERS:600-606).** Six nib-packed bytes:

```
byte0     byte1     byte2     byte3     byte4     byte5
0000yyyy  dddddddd  ddddhhhh  hhhhmmmm  mmmmssss  sssstttt
```

- `yyyy` — year, BINARY, `1980 = 0`; 4 bits, rolls over every 16 years
  (TIMERS:596). `ClockToDate` maps `n -> 1980+n`, range 1980..1995
  (TIMERS:687,711-713).
- `dddddddddddd` — day-of-year `1..366`, 3 BCD nibbles (hundreds, tens, ones).
- `hhhhhhhh`/`mmmmmmmm`/`ssssssss` — hour/minute/second, 2 BCD nibbles each.
- `tttt` — tenths of a second, 1 BCD nibble.
- Top nibble `0000` of byte0 is the ALARM field (SetClock zeros it,
  TIMERS:655); it is dropped in the read reply's selector high nibble.
- "Not set since battery loss" sentinel: `0FFF FFFFFFFF` (TIMERS:608-609),
  the value `ClockToDate` treats as uninitialized (DRIVERS:505-506).

**The `$02` reply stream (parser-derived, DRIVERS:1077-1219).** `Clock`
(TIMERS:619) sends `$02` then spins reading Port A into the `COPS` interrupt
parser until `ClockReady`. COPS must reply with this 7-byte input stream:

| Byte  | Value            | Parser action (DRIVERS)                                   |
|-------|------------------|----------------------------------------------------------|
| 1     | `$80`            | State 0 -> State 4 ("reset code follows", COPS0 @5:1092)  |
| 2     | `$E0 \| yyyy`    | State 4 clock-start: `ClockReady=0, ClockBytes=5, ClockHigh=year nibble`, -> State 3 (COPS4 @2:1212) |
| 3     | byte1 `dddddddd` | State 3, ClockBytes==5: `ClockHigh=(ClockHigh<<8)\|b` (:1167) |
| 4     | byte2            | State 3: `ClockLow=(ClockLow<<8)\|b` (:1173)              |
| 5     | byte3            | State 3: ditto                                            |
| 6     | byte4            | State 3: ditto                                            |
| 7     | byte5            | State 3, ClockBytes->0: `ClockReady=1`, -> State 0 (:1181)|

Result: `ClockHigh = 0000yyyy dddddddd`, `ClockLow = ddddhhhh hhhhmmmm
mmmmssss sssstttt` — exactly the packing above. So the reply PAYLOAD (after
the `$80` frame) is `[$E0|yearNibble, byte1..byte5]`, 6 bytes. This is what
`COPS.clockReplyBytes(from:)` builds from host time and what
`notSetClockReply = [$EF,$FF,$FF,$FF,$FF,$FF]` builds for the off state.

**Host-year windowing.** Host year `Y` maps by the same 16-year rollover the
silicon uses: `yearNibble = (Y - 1980) & $0F`. E.g. 2026 -> nibble 14 ->
displayed 1994; 2023 -> nibble 11 -> displayed 1991. Faithful to the 4-bit
field and keeps the desktop showing an in-window date. Time-of-day/day-of-
year are preserved exactly. Decoded in a FIXED UTC Gregorian calendar so the
byte sequence is a pure function of the injected `Date` (deterministic
tests).

**Set-clock sequence `$2C -> $10xN -> $25` (TIMERS:652-680).** `SetClock`:
1. `$2C` — disable clock/timer, prep set (TIMERS:656).
2. 16x `$10|nibble` (TIMERS:659-671): two 8-iteration loops send, MSN-first,
   the high clock LONGWORD's 8 nibbles (`0,0,0,0,0,year,dayHi,dayMid` — the
   5 leading zeros are the `AND #$0FFF` zero-fill of the 16-bit high word
   promoted to a longword) then the low longword's 8
   (`dayLo,hourHi,hourLo,minHi,minLo,secHi,secLo,tenths`).
3. `$25` — enable clock, disable timer (TIMERS:673): commit.

So COPS drops the 5 leading fill nibbles and repacks the last 11 into the
6-byte reply payload — the exact inverse of the read parse. A committed set
value is returned by every subsequent `$02` until cleared. (Modeled in
`COPS.finishSetSequence`.)

**Power-off clock semantics (MACHINE:419-480).** `PowerDown` reads the clock
and picks the power-off byte by whether it is running (MACHINE:423-427):
- `$21` — power off, clock ON (clock was running): clock PRESERVED.
- `$20` — power off, clock OFF (clock read as `$0FFF`): clock CLEARED; next
  `$02` returns the not-set sentinel. The OS only sends `$20` when it already
  saw the clock unset, so this is a faithful mirror.
- `$23` — power off, reboot later (PowerCycle, MACHINE:473): clock ON,
  PRESERVED; pairs with `$2D` + 5 alarm nibbles (MACHINE:462-471).

**DEFERRED to M7 — the `$23`/`$2D` timed reboot WAKE.** `PowerCycle`
(MACHINE:447-480) powers off and re-powers after N seconds, but ONLY if the
clock is already set (MACHINE:451-456 falls back to a plain `PowerDown`
otherwise). Now that our `$02` reads as set, that path is reachable, but
modeling the physical wake needs a host-time alarm that RE-POWERS the Machine
(Task 1's `powerState` in reverse) — out of Task 2's read/set/keep scope. The
alarm nibbles are captured in `COPS.clockSetNibbles` for provenance; delivery
source expectation is MACHINE:447-480. (Mirrors Task 1's `$23`/`$2D` deferral
note in §7.)

## 5. Interrupts

### 68000 group-0 bus-error frames — the OS's recoverable-fault engine (M4 Task 4 round 4)

The Lisa OS's bus-error handler `BUS_ERR` (SOURCE-EXCEPASM:434-505) is a
RECOVERY engine, not just an error trap: user-space code reaches swapped-out
code segments and OS entry points through `$A0xxxxxx`-tagged jump-table
gates whose fetch deliberately faults; `BUS_ERR` decodes the group-0
frame's **instruction register** (frame+6, its `B1`/`B2` equates) and
**fault address** (frame+2, `BADADDR`), then backs the frame **PC** up by
an instruction-specific constant so the jump RE-RUNS after `CODE_CHK`/the
memory manager swaps the target segment in:

| frame IR | form | PC fix | side-effect expectation |
|----------|------|--------|--------------------------|
| `$4EB9` | JSR (xxx).L | PC−6 | return NOT yet pushed (re-run pushes once) |
| `$4EA8`+reg | JSR d16(An) | PC−4 | return NOT yet pushed |
| `$4E90`+reg | JSR (An) | PC−2 | return NOT yet pushed |
| `$4EF9` / `$4ED0`+reg | JMP.L / JMP (An) | PC−2 | none |
| `$4E75` | RTS | PC−2 | pop COMMITTED — handler un-pops (USP−4) |
| `$4E73` | RTE | PC := BADADDR | pops committed |
| `$4A`xx | TST (stack probe / `gentrap`'s `TST.W stkspace(A7)`) | PC−2 | stack growth via `Check_Stack` |
| `$2211` | MOVE.L (A1),D1 | — | intrinsic-library data fault |

Those constants encode real 68000 microcode order: a jump's **target
prefetch happens inside the jump instruction**, before a JSR writes its
return address and after an RTS pops it, and the pushed frame PC is the
jump-site-relative value above (mid-instruction data faults push
`instruction start + 2`). Stock Musashi diverges (it completes the jump
and faults at the next loop-top opcode fetch with PC = target+2), which
made every OS gate re-run push a SECOND return address — corrupting
syscall parameter frames (observed live as fatal OS error 10201
`e_hardsyscode`, source-EXCEPRIM:70). The vendored core is patched to push
real-68000 frames for these cases (`m68ki_exception_bus_error`,
Sources/CMusashi/m68kcpu.h; re-applied by Scripts/vendor-musashi.sh;
pinned by Tests/LisaCoreTests/BusErrorFrameTests.swift). The frame's
fault-address field carries the full unmasked 32-bit target for
fetch faults — the `$A0` tag bits survive there (and in registers) even
though the 24-bit address bus strips them before memory decode, which is
exactly how the OS's gate scheme works on real hardware. See
docs/rom-trace-notes.md "Checkpoint G (round 4)".

### Autovector Addresses

Source: OS/SOURCE-INITRAP.TEXT.unix.txt:11-37

| Vector | Address | Name      |
|--------|---------|-----------|
| $8     | -       | BUSERRV   |
| $C     | -       | ADDRERV   |
| $10    | -       | ILLINSV   |
| $14    | -       | TRAPDV    |
| $18    | -       | TRAPCV    |
| $1C    | -       | TRAPOV    |
| $20    | -       | PRIVIOV   |
| $28    | -       | LINE10V   |
| $2C    | -       | LINE11V   |
| $60    | -       | SPURINV   |
| $64    | -       | INT1V     |
| $68    | -       | INT2V     |
| $6C    | -       | INT3V     |
| $70    | -       | INT4V     |
| $74    | -       | INT5V     |
| $78    | -       | INT6V     |
| $80-$9C | -     | TRAP0V-TRAP7V |
| $B8    | -       | trapEv    |

### Interrupt Levels

Source: libhw-DRIVERS (various), OS/source-mover.text.unix.txt, OS/source-INITRAP.TEXT.unix.txt

- **Level 1:** VIA1 (autovector $64)
  - Sources: VIA1 timer, vertical retrace, parallel port, Twiggy
  - Handler: libhw-DRIVERS:895-927
  - Installation: libhw-DRIVERS:599-601

- **Level 2:** VIA2/COPS (autovector $68)
  - Handler: libhw-DRIVERS:1056-1066
  - Installation: libhw-DRIVERS:606-620

- **Level 3:** Expansion slot 2 (OS/source-mover.text.unix.txt:791-813, INITRAP:127-128)

- **Level 4:** Expansion slot 1

- **Level 5:** Expansion slot 0

- **Level 6:** RS-232 SCC (mover:822-849, INITRAP:136-137)
  - **M7 Task 4 (WIRED):** the SCC now asserts CPU Level 6 when a channel has a
    pending, enabled Tx-empty interrupt (`SCC8530.irqAsserted`, OR'd into
    `Machine.tickVIAsAndUpdateIRQ`). This is REQUIRED for printing: the OS's
    `XMIT` ISR (§11.4 step 5) sends the first byte polled, then drives every
    subsequent byte off the Level-6 Tx-empty interrupt — without it a live
    print emits exactly ONE byte and stalls (observed). Task 2's "SCC not wired
    to the CPU IRQ" note is superseded here — and to the project's honesty bar,
    it was **wrong in reasoning, harmless in effect at boot**: its stated
    rationale ("the polled fast path never blocks, so the driver drains its
    buffer synchronously and never waits on a Level-6 interrupt") is **refuted**
    by rsASM:96-152 — the driver polls only byte 1 (`RSOUT`/`BYTEO`); bytes
    2..N ride the `XMIT` ISR (`WR0=$29` :98, `WR1=0` :100-101, `WR0=$38` :103,
    `JSR RSOUT` :129-133, exit re-arms `WR1=$17` via `#$0617`→`RESTORE`
    :150-152). It happened to be boot-harmless *only* because channel B is never
    armed at boot (no `dinit`, so Level 6 never asserts — the FNV checkpoints
    confirm boot is byte-identical). Autovectored (`$78`), like every other Lisa
    interrupt.

- **Level 7:** NMI (INIT_NMI_TRAPV, INITRAP:43,73)
  - Debugger break-in via low-core $7C — LDASM:68-106

### Mask Constants

Source: OS/source-DRIVERDEFS.TEXT.unix.txt:29-38

- allints = $700
- rsints = $600
- slotints = $500
- copsints = $200
- vertints/twigints/winints/clokints = $100

### Installation Note

Level 1/Level 2 vectors are installed by LIBHW DriverInit, not INIT_TRAPV (which is commented out at INITRAP:117-125).

## 6. Memory Map

### High-Level Regions

Source: libhw-DRIVERS:134; starasm1:262-304

- **IOSpace:** $FC0000
- **Special I/O (PROM, mmu127):** $FE0000
- **Screen Space (mmu125):** $FA0000
- **Real-Memory Window (mmu85-100):** $AA0000

### ROM/Message Space

Source: starasm1:262-304

- **Message Display:** $FE0088 (prom_message)
- **Value Display:** $FE00B0 (prom_value)
- **ROM Version Word:** $FE3FFC (prom_sn)
- **ROM Range:** $FE0000-$FE3FFF

### System Buffers and Cells

Source: libhw-DRIVERS:133; PASCALDEFS:27-28; STARTUP:198, 324, 342-343, 1278-1396

- **MMU Routine Temp Buffer:** $F4000
- **Trap 5 Vector:** $94
- **Physical Byte 0 (Memory Base):** $2A4
- **Keyboard Queue:** $2B0
- **SGLOBAL/B_SYSGLOBAL:** $200
- **Loader Link:** $204
- **C Domain Pointer:** $208
- **Boot Device Address:** $1B3

### Hardware Configuration Registers

Source: libhw-DRIVERS:135; libhw-DRIVERS:574-588

**Disk ROM ID (DiskROMId):** IOSpace + $C031 = $FCC031

| Bit | Meaning              | Source             |
|-----|----------------------|--------------------|
| 7   | Pepsi-or-later board | VIA1 T1 reload diff |
| 5   | LisaLite variant     | -                  |

Effect: Post-Pepsi boards use VIA1 T1 reloads $7B/$63 instead of $CA/$27 (libhw-DRIVERS:574-588).

### Status Register

- **16-bit Address:** IOSpace + $F800 = $FCF800
- **Low Byte:** $FCF801
- **Bit 2 (low byte):** Vertical sync pending — **ACTIVE-LOW** (0 == pending,
  1 == not pending; corrected M4 Task 3 from OS source, see "Vertical Retrace"
  above and docs/rom-trace-notes.md "Checkpoint E").

### RAM Sizing

Source: STARTUP:326, 344-346, 389-396

- Loader determines physical RAM size (l_physicalmem/membase/memleng via $2A4)
- Mapped into MMUs 85-100 (16 × 128KB = 2MB maximum)

**Boot ROM POST-level sizing (M1b Task 6, distinct from the OS loader above)
— statically present, live reachability NOT confirmed:** the Rev H boot
ROM's RAM-sizing/checksum routine (`$FE0D68-$FE0FCC`,
docs/rom-trace-notes.md "Bus-error frame spike") reads a hardware ID
register at **`$FCF000`** at 3 static call sites (`$FE0F2A`, `$FE0F78`,
`$FE0714`, all via a shared `move.w $fcf000.l,D1` subroutine at `$FE0FF0`)
plus 2 more direct reads (`$FE00DA`, `$FE0DAE`) — NOT by probing for a bus
error at the top of RAM. Its only fault-shaped defensive mechanism is the
**NMI** vector (`$7C`), not the CPU bus-error vector — see "NMI and
Debugger Break-In" below. An unbounded live single-step trace (every
instruction, reset through 30M cycles) found **zero** hits on this entire
routine (entry points, body, and all 3 `$FCF000`-subroutine callers alike)
— it is statically present in the ROM image but not confirmed to execute
on the traced boot path; dead-code-for-this-configuration, NMI-only-reached,
and reached-only-past-the-frontier are all open possibilities. `$FCF000`'s
exact bit encoding is undetermined (evidence-gated, unstubbed — `0xFF`
bytes) regardless. See docs/rom-trace-notes.md "Bus-error frame spike" for
the full reachability evidence.

### I/O Board IDs

Source: SOURCE-CD:49-53

- iob_lisa = 0
- iob_pepsi = 1
- iob_sony = 2
- iob_twiggy = -1

## 7. Boot ROM and Power Management

### ROM Facilities

Source: starasm1:262-304

- **DISP_MESSAGE:** prom_message at $FE0088
- **Value Display:** prom_value at $FE00B0
- **ROM Version Word:** $FE3FFC

### Boot Device

Source: STARTUP:198, 1278-1396

- **Address:** adr_bootdev = $1B3
- **Set by:** Boot ROM

### Soft Power Control

Source: libhw-MACHINE:413-481

**Overview:** All soft power is mediated by the COPS chip via command interface.

**Power / clock commands** (only `$20`/`$21`/`$23` actually power the machine
OFF; the rest are clock/timer control that the shutdown routines send
alongside):
- `$20`: Power off, timer off, clock off (MACHINE:425 -- PowerDown, clock invalid)
- `$21`: Power off, timer off, clock on (MACHINE:427 -- PowerDown, clock running)
- `$23`: Power off, reboot later (MACHINE:473 -- PowerCycle, after the alarm nibbles)
- `$2D`: Disable timer, set clock for the reboot alarm (MACHINE:462 -- PowerCycle)
- ~~`$25`: power off / "Enable clock, disable timer"~~ **`$25` is NOT a
  power-off command** (M6 Task 1 correction, cited): a grep of LIBHW finds
  `$25` only at TIMERS:673 (`MOVE.W #$25,D0 ; enable clock, disable timer`, a
  clock-control command in the calendar code) and DRIVERS:1058 (`MOVE.W
  #$2500,SR`, an unrelated status-register write). Neither PowerDown nor
  PowerCycle sends `$25`. The earlier listing of `$25` among the shutdown
  commands is struck. (`$2C` "disable clock, prep set-clock" is likewise
  clock-control, TIMERS:656, not power-off.)

**Shutdown Sequence (M6 Task 1 -- full chain, cited to LIBHW `/LIBS/LIBHW/`,
byte-identical to `/LIBHW/`):**
- `PowerDown` (MACHINE:419-436, OS trap slot 38 per DRIVERS:397): dim contrast
  to 255 (`SetContrast`, MACHINE:420-421) -> read the hardware clock (`Clock`,
  MACHINE:422) -> compare against the `$0FFF` "not validly running" sentinel
  (MACHINE:423) -> send `$20` if invalid (MACHINE:425) or `$21` if the clock is
  running (MACHINE:427) -> `JSR COPSCMD` (MACHINE:429) -> busy-coast + retry.
- `PowerCycle` (MACHINE:447-474, trap slot 40, power-off-with-timed-reboot):
  dim -> read clock -> `$2D` (MACHINE:462) -> loop sending five alarm nibbles
  each OR'd with `$0010` "write clock" via `COPSCMD` (MACHINE:464-471) ->
  `$23` "power off, reboot later" (MACHINE:473) -> `COPSCMD` (MACHINE:474). The
  wake-at-alarm half is NOT modeled here (no RTC alarm -- M6 Task 2 territory);
  `$23` still powers OFF like `$20`/`$21`.
- The COPS-command-send primitive is `COPSCMD` (DRIVERS:829); the emulator's
  COPS HLE drives its exact CRDY handshake (see §4 "M4 Task 1").

**Power Button -> shutdown chain (M6 Task 1, cited):**
- COPS puts `$80` then `$FB` on its input stream (a State-4 reset-dispatch
  packet, §4). The OS's COPS input handler (DRIVERS:1190 `COPS4`, `$FB` branch
  at DRIVERS:1196) synthesizes pseudo-keycap `$08` (`MOVE.W #$08,D0` at
  DRIVERS:1230) and calls `KeyPushed` (DRIVERS:1231). **The M1b-era "synthesized
  as key `$08` down/up" note is CONFIRMED correct** (not struck): `KeyPushed`
  (KEYBD:741-761) genuinely emits BOTH a down (`$80`, KEYBD:755) and an up
  (`$00`, KEYBD:758) transition, and the pseudo-key table KEYBD:728-738 line 732
  reads `08 -- Power Button`. Emulator fidelity note: `COPS.pressPowerButton()`
  sends the faithful `$80,$FB` (what real COPS puts on the wire), NOT a
  synthesized `$08` -- the OS makes the `$08` itself, exactly as on hardware.
- The `$08` event goes onto the ordinary keyboard event queue (via `Key`/
  `Enqueue`, KEYBD:955-1130). There is NO kernel special-case for keycap `$08`;
  userland decides to shut down: the Shell's `PowerOff` (nwshell:2143-2162,
  menu key `'o'/'O'` at nwshell:2232) sets `term_event[1] := 4` and terminates,
  the Root scheduler (PMSPROCS:315-344) maps event `4` to `kill_power` and
  calls `FS_ShutDown`, which flushes/unmounts every volume (fsinit:1216) and
  ends at `GiveUpGhost` (fsinit:1066) -> `powerdown` (fsinit:1115), i.e. the
  `PowerDown` trap above. (The graphical Office System's Desktop Manager isn't
  in this source tree, but uses the same `term_event[1]=4`/`kill_power` path --
  and empirically DOES honor the power button at the desktop; see below.)

**Emulator status (M6 Task 1 -- IMPLEMENTED; supersedes the M3-Task-3
deferral below).** Soft power is now real behavior:
`COPS.pressPowerButton()` injects `$80,$FB`; decoding a power-OFF command
(`$20`/`$21`/`$23`) fires `COPS.onPowerOff` -> `Bus.powerOffHandler` ->
`Machine.powerState = .off`, a clean stop distinct from a double-fault
`halted` (`run(until:)`/`step()` short-circuit; `reset()` powers back on). The
Power button is reachable from `lisadbg` (`power`), `EmulationController`
(`.powerButton` mailbox + `EmuStatus.poweredOff`), and LisaApp (Machine >
Power, ⌘⌥P). **LIVE PROOF (Checkpoint L, rom-trace-notes.md):** at the Office
System desktop, pressing the button ran the OS's own shutdown, which issued
COPS `$21` and stopped the machine (`power=OFF`, `halted=false`); rebooting the
same Widget image then showed NO dirty-volume dialog (the clean shutdown wrote
the volume back not-in-use). One observed subtlety: the button is honored only
at the live desktop, NOT at the modal dirty-volume dialog (the dialog's own
event loop swallows the keycap) -- so the LIVE PROOF/Checkpoint L press the
button after reaching the desktop. `powerCommandLog` still logs every
power/clock command byte for provenance (`$20`/`$21`/`$23`/`$25`/`$2C`/`$2D`),
regression-pinned by `COPSTests`.

~~**Emulator status (M3 Task 3 -- re-recorded deferral, consciously, to M4):**
soft power / the Power menu are NOT implemented as behavior -- `COPS`
recognizes and LOGS every power command byte above into `COPS.powerCommandLog`,
but no shutdown/reboot/clock-for-alarm semantics are modeled.~~ SUPERSEDED by
M6 Task 1 above (strike-not-erase): the log-only model is replaced by a real
power-off transition; the reboot-later ALARM half of `$23`/`$2D` remains
deferred (M6 Task 2, RTC).

### NMI and Debugger Break-In

Source: LDASM:68-106

- **NMI Vector:** Low-core $7C
- **Trigger:** Debugger break-in signal

## 8. Keyboard and Mouse Input

Source: LIBHW-DRIVERS.TEXT.unix.txt (COPS state machine), libhw-KEYBD.TEXT.unix.txt
(event/state logic, ShiftTable, EventTable), libhw-LEGENDS.TEXT.unix.txt
(keycap→ASCII tables, keycode matrix, keyboard IDs), libhw-MOUSE.TEXT.unix.txt.
All citations below are relative to `LISA_OS/LIBHW/` (mined for M1c Task 2;
see `.superpowers/sdd/2026-08-05-m1c-app-shell/research-input-codes.md` for
the full research pass this section transcribes).

### Keycap Code Matrix (Final US, 76 keys)

Source: LEGENDS:618-656 (keycode matrix), LEGENDS:125-133 (primary ASCII
legends), KEYBD:719-761 (pseudo-keys).

`keycode = (col<<4)|row`. Bit 7 of the COPS byte is the down (`$80`) / up
(`$00`) flag; the low 7 bits below are the keycap value itself.

- `$01` Disk1Inserted, `$02` Disk1Button, `$03` Disk2Inserted, `$04`
  Disk2Button, `$05` ParallelPort, **`$06` MOUSE BUTTON**, **`$07` MOUSE
  PLUG**, `$08` PowerButton (pseudo-key injected via KeyPushed; `$0B`-`$0E`
  Sony-inserted variants) — KEYBD:719-761
- **Keypad (`$20`-`$2F`):** `$20` Clear, `$21` `-`, `$22` Left (shift = `+`),
  `$23` Right (`*`), `$24` `7`, `$25` `8`, `$26` `9`, `$27` Up (`/`), `$28`
  `4`, `$29` `5`, `$2A` `6`, `$2B` Down (`,`), `$2C` `.`, `$2D` `2`, `$2E`
  `3`, `$2F` Enter (numeric)
- **Main block (`$40`-`$7F`)**, keycode → legend (primary ASCII, from
  LEGENDS:125-133):

  | Code | Legend | Code | Legend | Code | Legend | Code | Legend |
  |------|--------|------|--------|------|--------|------|--------|
  | $40  | `-_`   | $41  | `=+`   | $42  | `\|`   | $43  | (unused, US) |
  | $44  | `p`    | $45  | Backspace (`$08`) | $46 | AlphaEnter (`$03`) | $48 | Return (`$0D`) |
  | $49  | pad 0  | $4C  | `/?`   | $4D  | pad 1  | $4E  | R-Option |
  | $50  | `9(`   | $51  | `0)`   | $52  | `u`    | $53  | `i`    |
  | $54  | `j`    | $55  | `k`    | $56  | `[{`   | $57  | `]}`   |
  | $58  | `m`    | $59  | `l`    | $5A  | `;:`   | $5B  | `'"`   |
  | $5C  | Space  | $5D  | `,<`   | $5E  | `.>`   | $5F  | `o`    |
  | $60  | `e`    | $61  | `6^`   | $62  | `7&`   | $63  | `8*`   |
  | $64  | `5%`   | $65  | `r`    | $66  | `t`    | $67  | `y`    |
  | $68  | `` ` ~ `` | $69 | `f`  | $6A  | `g`    | $6B  | `h`    |
  | $6C  | `v`    | $6D  | `c`    | $6E  | `b`    | $6F  | `n`    |
  | $70  | `a`    | $71  | `2@`   | $72  | `3#`   | $73  | `4$`   |
  | $74  | `1!`   | $75  | `q`    | $76  | `s`    | $77  | `w`    |
  | $78  | Tab (`$09`) | $79 | `z` | $7A  | `x`    | $7B  | `d`    |
  | $7C  | L-Option | $7D | CapsLock | $7E | Shift  | $7F  | Command |

  `$47`, `$4A`, `$4B`, `$4F` do not appear in the mined matrix — a gap in
  the source table, not a documented "unused" marker like `$43`.

### Modifiers

Source: ShiftTable, KEYBD:88-97; EventTable `$78`-`$7F` row = `$F0`
(modifiers never generate OS events on their own — KEYBD:65, 85, 298-301).

- Shift = `$7E` (either physical shift key)
- L-Option = `$7C`, R-Option = `$4E` (the Old-US keyboard sends `$68`
  instead, remapped in software — DRIVERS:1101-1117)
- Command/Apple = `$7F`
- CapsLock = `$7D` (**latching** — the OS tracks lock state itself)
- MouseButton = `$06` (ShiftState bit 4)

All of the above arrive as ordinary keycap down/up bytes over the keyboard
stream; the OS combines them into shift state itself — the COPS protocol
has no separate "modifier state" message. Emulator behavior: forward
independent down/up edges for each physical key; mapping both host Option
keys to `$7C` is acceptable (the OS ORs left/right into a single bit
anyway).

### Mouse

Source: DRIVERS:1089-1158, MOUSE:241,247 (sign-extension), KEYBD:95,
301-305, 1062-1070 (button routing), MOUSE:50-83 and DRIVERS:616 (update
cadence), DRIVERS:109-110 (screen bounds), MOUSE:87-170 (OS-side scaling).

- **Delta packet:** `$00`, `dx` (signed byte), `dy` (signed byte) — 3 bytes
  total.
- **Button:** keycap `$06` in the KEYBOARD stream (down = `$86`, up = `$06`)
  — NOT part of the delta packet. Plug-in = `$87`, unplug = `$07`.
- **Update cadence:** COPS command `$78|((ms+2)/4 clamped 0-7)`; boot
  default `$7C` = 16 ms.
- **Screen bounds:** MaxX = 719, MaxY = 363. OS-side scaling modes exist;
  the emulator sends raw deltas only.

### Keyboard ID

Source: LEGENDS:583-596, 660-859; masking at DRIVERS:1106-1108, KEYBD:1256.

- **Byte format:** bits 7-6 = manufacturer (`00` TKC, `10` Keytronics),
  bits 5-0 = layout/legends code. Software masks the received ID with
  `$3F` before comparing it, so the manufacturer bits are effectively
  don't-care.
- **US = `$3F`** (Final US, 76-key — the matrix above). **Old US = `$0F`**
  (73-key; also the OS's synthesized fallback if no ID arrives by
  DriverInit end — DRIVERS:642-649). European layouts occupy `$24`-`$2E`.
  Simplest correct full ID byte: **`$3F`**.
- **CAVEAT (could-not-find):** no factory log confirms real hardware's
  manufacturer bits; `$3F`/`$7F`/`$BF`/`$FF` are all equivalent under the
  `$3F` mask, so `$3F` (manufacturer bits `00`) is the simplest choice, not
  a uniquely confirmed one.
- **M1c Task 2 correction:** M1b's `COPS.placeholderKeyboardID` used `$2F`
  as an unresearched stand-in value. `$2F` is **not** the Final-US ID — per
  the byte-format rule above (mask `$3F`), US is `$3F`; `$2F` is actually a
  **UK** layout code. `Sources/LisaCore/COPS.swift`'s constant is corrected
  to `$3F` in lockstep with this section (both-docs rule); see that file's
  doc comment for the COPS-side citation and `docs/rom-trace-notes.md`
  "POST completion (Task 7)" / the keyboard-ID-reset discussion for why the
  power-on packet's *shape* (2 bytes: `$80` + ID) was already correct and
  only the ID *value* changes here.

### Special (Power Button, Unplug, Failure)

Source: DRIVERS:1227-1232 (power button), state machine reset-dispatch
(hardware-notes.md §4 "Input Packet State Machine").

- **Power button:** COPS sends `$FB` in the reset-dispatch stream;
  software synthesizes pseudo-keycap `$08` down+up (DRIVERS:1227-1232).
- **Keyboard unplugged:** `$FD` — clears KeyBitmap except mask `$E0`
  (parallel-port and mouse bits persist).
- **COPS failure:** `$FE`/`$FF` (bit 0 semantics per §4,
  LIBHW-DRIVERS.TEXT:1244-1252: 0 = I/O COPS, 1 = keyboard COPS).
- **Dead-key diacriticals:** Option-layer pseudo-ASCII `$10`-`$14`
  (KEYBD:101-151) — found in the source, but entirely OS-side processing
  of ordinary keycap events; no emulator-side work is implied.

### Auto-Repeat (Software, Not COPS)

Source: RepeatCheck, KEYBD:600-714; defaults DRIVERS:543-544.

Auto-repeat is entirely a SOFTWARE feature of the OS's keyboard driver
(`RepeatCheck`), not something COPS or the keyboard hardware generates.
Defaults are 400 ms initial delay / 100 ms subsequent repeat per the CODE
at DRIVERS:543-544 (a doc comment nearby says 150 ms; the code is the
source of truth and wins per the both-docs rule). **The emulator never
synthesizes repeat keycap events** — only real host key-repeat (if the
host OS delivers it) or the app layer's own timer would do so, and this
model does neither at the COPS/KeyMap layer.

### Not Found

- Portuguese/APL/Canadian/Dvorak transformation tables were proposed in
  the OS source but never implemented — they fall through to FinalUS.
- The full COPS command opcode table beyond `$78`-`$7F` (mouse-enable) and
  `$58`-`$6F` (NMI-key ranges) lives in COPS firmware, not this source
  tree.

## 9. Floppy Controller Interface (Sony 400K)

Source: mined from `Lisa_Source/LISA_OS/` (M2 Task 1 pre-implementation
research, `.superpowers/sdd/2026-08-05-m2-floppy-boot/research-floppy-interface.md`).
Key files: `OS/SOURCE-SONY.TEXT.unix.txt` (Pascal driver, Rich Castro),
`OS/SOURCE-SONYASM.TEXT.unix.txt` (68000 asm), `OS/source-twiggy.text.unix.txt`,
`OS/source-mover.text.unix.txt` (equates + interrupt dispatch),
`OS/source-ldmicro.text.unix.txt` ("ldsony" boot loader-loader),
`OS/source-LDTWIG.TEXT.unix.txt`, `OS/source-LDEQU.TEXT.unix.txt`,
`OS/SOURCE-STARTUP.TEXT.unix.txt`, `LIBHW/LIBHW-DRIVERS.TEXT.unix.txt`.

> **Numbering note:** the M2 plan document labeled this section "§7", written
> before this doc's own §7 ("Boot ROM and Power Management", added in M1b)
> existed. Renumbering §7/§8 here would break the many existing citations to
> them elsewhere in this codebase (Bus.swift, Machine.swift, ROMBootTests,
> rom-trace-notes.md, etc.), so this content is filed as a new §9 instead of
> overwriting/renumbering. Flagged here rather than silently deviating.

### Shared-RAM Window (68000 ↔ 6504)

- **Internal Sony/Twiggy base:** `$FCC000` (IOMMU+`$C000`) — SONY.TEXT:602-605
  (`hwbase := iospacemmu*$20000 + $0C000` when iochannel<0); `TWIGBAS .EQU
  IOMMU+$0C000` (mover:17); `dskbase equ $fcc000` (ldmicro:37,42; LDTWIG:45,50).
- **External slot Sony base:** `$FC0000 + $4000*slot + $2000` (SONY.TEXT:602-605).
- **Cell layout** (offsets from base; Sony names from SONYASM:11-33, Twiggy
  from mover:12-42):
  - `$01` DISKCMD (go-byte; write triggers 6504)
  - `$03` DISKPARM (sub-command)
  - `$05` DISKDRIV (0=top/`$80`=bottom)
  - `$07` DISKHEAD (side 0-1)
  - `$09` DISKSEC
  - `$0B` DISKTRAK
  - `$0F` DISKCNFM (format confirm)
  - `$11` DISKERR (nonzero=error)
  - `$13` DISKFLG (single/double-sided flag)
  - `$19` DISKSKING (`$FF` while seeking)
  - `$41` DISKIN (~~nonzero=disk present; Sony~~ **M8 correction: the
    value is `$FF` when present, not merely "nonzero" -- see the DISKIN
    entry below**)
  - `$5F` DISKSTAT (interrupt/status)
  - `$95` DISKCS (checksum err count; mover says `TWIGCS=$BB`!)
  - `$B9` DISKB2
  - `$FB` CMDINDEX (+0/+2/+A = prev cmd/parm/trak save)
  - `$180` PMEMAD (64-byte parameter memory mirror)
  - `$3E8` DISKHDR (12-byte packed tag)
  - `$400` DISKDATA (512-byte sector buffer)

**AMBIGUITY (a) — SETTLED (Task 5, boot-ROM disassembly + live trace).** The
buffer base is **`$400`**, ~~not `$600`~~ (the SONYASM:221-231 "DISKDATA+1024"
reading was a red herring). The Rev H boot ROM's own read routine (twig_entry
`$FE1D76`) reads the data buffer at `$FE1DC6: lea ($400,A0),A4` with
`A0 = $FCC001`, then copies it with `movep.l` (stride 2). So the 512 data bytes
occupy the **ODD bytes** of the window — offsets `$401,$403,…,$7FF` — and the
12-byte tag likewise at `$3E9,$3EB,…,$3FF` (`$FE1DB0: lea ($3E8,A0),A4`). This
is the same odd-lane arrangement the single-byte command cells already use
(`$01/$03/$05/…`): the 6504's 8-bit shared RAM sits on the odd byte of each
68000 word. `FloppyController.performRead` writes the buffers on that odd lane
accordingly. See docs/rom-trace-notes.md "Floppy boot (checkpoint C)".

### Command Protocol

- **Handshake:** 68000 busy-waits DISKCMD==0 before writing a command
  (START_RWTS: `TST.B DISKCMD; BNE` — SONYASM:123-125); the 6504 clears it
  when ready.
- **Go-bytes** (to `$01`) — SONY.TEXT:61-68: nulcmd=`$80` (no-op handshake),
  excmd=`$81` (execute staged sub-command), seek=`$83` (pre-seek,
  non-interrupting), clristat=`$85` (clear int status), enabstat=`$86`
  (enable drive/ints), clrmask=`$87` (disable ints), goaway=`$89` (disable
  controller). Teardown sequence: `$88`→DISKPARM then `$87`→DISKCMD
  (mover:737-738).
- **Sub-commands** (to `$03`, paired with excmd) — SONY.TEXT:51-59:
  readdisk=0, writedisk=1, unclamp=2, format=3, verify=4, formattrk=5,
  verifytrk=6, read_bf=7, write_bf=8 (Twiggy adds clampcmd=9 — twiggy:83).
- **`writedisk` — session-scoped write-through (M4 Task 4 round 4;
  supersedes the M2 "accepted and discarded" model).** The OS writes the
  boot floppy during startup (the parameter-memory snapshot rewrite when PM
  is bad but the MDDF snapshot is good — SOURCE-STARTUP:1140-1151
  `INIT_WRITE_PM`/`rewrite_pm` — plus FS metadata), and its driver stages
  the write exactly where reads land: `START_WRITE` (SOURCE-SONYASM:
  300-380) packs the 12-byte tag onto DISKHDR's odd lane and the 512 data
  bytes onto DISKHDR+24 = DISKDATA (`$400`) odd lane via `movep` stride 2 —
  the mirror of FINISH_READ. `FloppyController.performWrite` captures that
  block into an in-memory session overlay (keyed by DC42 block number)
  which `performRead` consults before the backing image; the `.dc42`
  image object and file are NEVER mutated, and `insert(_:)` clears the
  overlay (fresh insertion = fresh session; `reset()` deliberately keeps it
  — a warm reboot does not un-write real media). Counters: `writeAttempts`
  (every issued writedisk) and `blocksWritten` (stored ones). Pinned by
  `FloppyControllerTests` (`writedisk*`/`insertingAnImageClears*`).
- **Completion:** interrupt-generating commands return immediately
  (`response := waitint`); completion arrives as a hardware interrupt
  (SONYASM:136-157).
- **Errors:** DISKERR + 1800 = OS error (`ADDI.W #1800` —
  SONYASM:127-131,396-400). not_issued=1809 (driver resends the packet —
  twiggy:1520-1525), vererr=1821, read_err=1823, write_err=1824
  (SONY.TEXT:39-42).
- **`unclamp` (sub-command 2) — now an OS-commanded EJECT (M5 Task 3 round 2).**
  ~~Modeled as a benign no-op (M3 Task 3): it fell into the unsupported-sub-
  command path, answering `notIssued`/DISKERR 9.~~ **Superseded:** the loader's
  teardown only waits on the VIA2-PB4 completion line (still true), but the OS
  installer's `dskunclamp` (SONY:679-688) issues `unclamp` to physically EJECT
  the media mid-run and then sets `disk_present := nodisk`. `FloppyController`
  now removes the disk on `unclamp` and completes with a `bot_done` interrupt.
  See `FloppyController.SubCommand.unclamp`'s doc comment.
- **Media-change attention (M5 Task 3 round 2).** A disk inserted while the OS
  is running raises a level-1 floppy interrupt with `int_stat` = `bot_int|bot_in`
  (no `bot_done`); the OS's `DISK_INT` (SONY:469-481) reads `bot_in` and sets
  `disk_present := gooddisk` + `KEYPUSHED`, waking a process blocked on a disk
  (e.g. the installer's `Mount` retry at an "insert disk N" prompt). This is the
  ONLY runtime path that flips the cached presence — the synchronous `ISDISKIN`
  probe is init-only (SONYASM:431-442). `FloppyController.insertWhileRunning(_:)`
  raises it (the mailbox `insertFloppy` path); bare `insert(_:)` is the power-on
  path and raises nothing. `DISKSTAT` `bot_in` is thus an interrupt-EVENT bit
  (cleared by `clristat`), not a presence mirror — `DISKIN ($41)` is the
  persistent presence cell. A diskette's writes are retained across an
  eject/reinsert of the SAME disk via `export/importSessionOverlay` (so the boot
  disk's MDDF `overmount_stamp` survives for `boot_remount`, FSINIT2:466-468);
  the `.dc42` file is still never mutated.
- **User-forced eject — bare, no OS-visible attention (M6 Task 4 decision,
  cited).** `FloppyController.eject()` (the emulator's user-menu "Eject" /
  `lisadbg eject`, reached via `EmulationController.ejectFloppy()`) raises
  NOTHING — no DISKSTAT bits, no level-1 pending — unlike `unclamp` above
  (the OS's OWN commanded eject, which completes with `bot_done`) or
  insertion's media-change attention just above. This is deliberate, not the
  asymmetry it looks like: real hardware's ONLY commanded-eject path IS
  `unclamp`, a 68000-driven solenoid; there is no independent "diskette
  physically removed" sense line the 6504 reports as an interrupt, and
  `DISKIN` above is documented as a PASSIVE, POLLED cell, not an
  interrupt-backed one. A "user pulls the diskette while the OS still thinks
  it's present" scenario therefore has no real-hardware interrupt to
  fault-match in the first place — this emulator's forced-eject menu command
  models something a real Sony 400K drive on a Lisa cannot physically
  produce mid-session. The real-hardware-accurate consequence already
  happens for free: the OS finds out on its own next access, because
  `performRead`/`performWrite`'s `image == nil` guards already raise a
  normal completion interrupt carrying a read/write-class DISKERR — exactly
  what a real drive with no media returns to a `readdisk`/`writedisk`.
  Pinned by `FloppyControllerTests.bareEjectRaisesNoAttentionOrInterrupt`;
  full citation trail in `FloppyController.eject()`'s doc comment.
- **DISKCMD-during-completion-window (M3 Task 3 doc note, no behavior
  change).** The busy-rejection guard (`FloppyController.commandInFlight`)
  only spans the command-decode delay, not the SEPARATE completion-wait
  delay `excmd`'s readdisk/writedisk raise the completion line after
  (`response := waitint`, above) — DISKCMD clears as soon as the staged
  parameters are read, before the completion line rises, so a new DISKCMD
  write in that in-between window is accepted immediately, not rejected.
  This mirrors the real hardware's own two-phase handshake (command-ack vs.
  interrupt-arrival are different events); it is not something this model is
  uniquely permissive about, but the model's completion-line state is a
  single flag, not a queue, so two overlapping completions would coalesce
  rather than queue — undefended, because no traced boot path has ever
  issued a second `excmd` before the first's completion. Full mechanism:
  `FloppyController`'s type doc comment, "Handshake / busy rejection".

### Sector Addressing (Sony GCR Zones)

CONVERT (SONYASM:444-513; duplicated in ldmicro:436-531) maps linear block ↔
zone/track/sector/side:

- **Zones:** tracks 0-15 → 12 sec/trk; 16-31 → 11; 32-47 → 10; 48-63 → 9;
  64-79 → 8. 80 tracks/side, 800 blocks/side (SNYSNGL=800 — SONYASM:38). 400K
  single-sided = blocks 0-799 side 0 (TOPSIDE=0); double-sided adds side 1
  blocks 800-1599.
- **Zone offset table** (block-number bases): side0: trk0-15 off0(12/trk),
  trk16-31 off192(11), trk32-47 off368(10), trk48-63 off528(9), trk64-79
  off672(8) → 800.
- The "FORMATTED 2:1 INTERLEAVE" comment (SONYASM:16) documents that physical
  interleave lives in the 6504 firmware, invisible at this interface —
  HLE serves logical sectors.
- **Sector layout:** 512 data bytes + 12-byte packed on-disk tag at DISKHDR
  (`$3E8`); Pascal pagelabel record (24-byte unpacked): version:int2,
  datastat 2bit, volume:int1, fileid:int2, dataused:int2, abspage:int4
  (reconstructed, not stored), relpage:int4, fwdlink:int4, bkwdlink:int4
  (DRIVERDEFS:206-219; pack/unpack SONYASM:186-379). DC42's 12 tag
  bytes/block are exactly this packed tag.

### Interrupt Wiring

- **Completion line:** VIA2 PORTB2 bit 4 (`BTST #4` in the Level1 handler —
  LIBHW-DRIVERS:895-928); level-1 autovector. TwiggyRoutine → SONYINT
  installed per iomodel (STARTUP:1894-1896; mover:725-743) →
  SONY.DISK_INT (SONY.TEXT:417-541).
- **DISKSTAT (`$5F`) bits** (SONY.TEXT:84-90; eject masks
  ldmicro:48-49,213-224): bit7 bot_int, bit6 bot_done, bit5 (Twiggy
  button/unused Sony), bit4 bot_in, bit3 top_int, bit2 top_done, bit1
  top_button, bit0 top_in (Sony uses "bot" nibble only; low nibble unused).
- **Double-sided (800K) block order is INTERLEAVED BY TRACK (M8, MacWorks
  Plus live trace).** A Sony 800K image orders blocks track-major,
  side-minor — track 0 side 0's sectors, then track 0 side 1's, then track
  1 side 0 — NOT all of side 0 followed by all of side 1. The HLE's
  original `side == 1 -> block + 800` form dated from M2, when only
  single-sided 400K images existed and no traced path had ever read side 1
  (M3 Task 3 flagged the double-sided path as untested). MacWorks Plus's
  800K installer is the first software to exercise it: it read (track 0,
  side 0, sectors 0/2/4) then (track 0, **side 1**, sector 4) — block 16
  interleaved, block 804 under the old form. Every read returned DISKERR 0,
  so the guest received plausible garbage rather than an error and ejected
  the diskette as unreadable; with the interleaved mapping the volume
  mounts (`blocksRead` 656, "MW+ INSTALLER, 768K in disk"). Single-sided
  mapping is unchanged. See `FloppyController.blockNumber`.
- **Cell `$0D` -- a host-set busy flag the controller clears (M8, MacWorks
  Plus live trace).** Absent from SONYASM's equate table (which jumps
  `$0B` DISKTRAK -> `$0F` DISKCNFM) and never read or written by any Lisa
  OS path, so the HLE had no reason to model it. MacWorks Plus uses it as a
  second handshake alongside DISKCMD when booting System 6 off a
  MacWorks-formatted hard disk: guest code at `$4242B8` sets the cell to
  `$FF` itself, `$4242BC` writes go-byte `$84`, and `$4242C2` spins reading
  the cell until the controller zeroes it -- after which it reads DISKERR and
  stores it into the Mac drive queue element's `dQFlags`. (Addresses and
  behaviour only; the guest listing is Apple/Sun-derived and is not
  transcribed here.) Go-byte `$84` is itself
  undocumented (SONY.TEXT:61-68 lists `$80`/`$81`/`$83`/`$85`/`$86`/`$87`/
  `$89`); this model answers it as a handshake-only ack like any other
  unrecognized go-byte, and `clearDiskCmd()` now clears `$0D` for every
  command. Symptom when it is missing: the Mac Finder draws its menu bar
  and hangs with the watch cursor, no desktop, ~40,000 reads of `$FCC00D`
  per 2M cycles. Uncertainty noted in code: the clear fires when the go-byte
  is consumed, which for `excmd` precedes the data-completion interrupt.
- **DISKIN (`$41`) present-value = `$FF` (M8, MacWorks Plus live trace).**
  The Lisa OS constrains this cell only to "nonzero" (ISDISKIN returns the
  raw byte; `hdinit` tests `response <> 0` -- SONYASM:437-441,
  SONY.TEXT:629-636), so the HLE's original `1` was an unconstrained
  choice, not evidence. **MacWorks Plus 1.0.18 pins it:** its patched
  `.Sony` reads the cell ABSOLUTELY --
  at `$41B892` it compares the byte at `$FCC041` against `$FF` and, on any
  other value, loads `-65` (`offLinErr`) and returns it. With `1` in
  the cell, every Mac-side `_Read` returned `offLinErr`, the Mac drive
  queue element's `diskInPlace` (`$1DE3`) stayed `0` forever (watched via
  `lisadbg gw` across 600M cycles, never written), and MacWorks could not
  leave its splash. `$FF` satisfies BOTH drivers, so it replaces the guess
  outright rather than being special-cased per guest -- and it matches this
  firmware's own true-flag idiom elsewhere in the same window (DISKSKING
  `$19` is documented `$FF` while seeking). Evidence that it is the right
  value, not merely a value MacWorks likes: with `$FF` the guest
  immediately does what real hardware does and this model never could
  before -- it unclamps and **ejects the non-Mac boot floppy by itself**
  (`disk=OUT` at ~54M cycles), then mounts an inserted `'LK'` volume
  (`blocksRead` 310 -> 485, `$100000` = `4C 4B`, `diskInPlace` -> `1`) and
  reaches the Macintosh Finder. Pinned by
  `FloppyControllerTests.diskInCarriesFFWhileMediaIsPresent`; see
  `FloppyController.diskInPresent`.
- **DISKIN (`$41`)** polled at driver init via ISDISKIN (SONYASM:437-441).
  **Round-2 (M4 Task 4) live confirmation — our HLE answers this correctly.**
  ISDISKIN does `MOVE.B DISKIN(A2),D0; MOVE D0,RESPONSE(A3)` (read window `$41`,
  return it); hdinit sets `disk_present:=gooddisk` when `response<>0`
  (SONY.TEXT:629-636). `FloppyController.insert()` sets `window[$41]=1` and
  `$FCC041` routes to `floppy.read(0x41)` (IODispatcher `$C000…$C7FF`), so a
  live boot reads `1`, and the OS's `dskio` returns SUCCESS
  (`disk_present`=`gooddisk`, verified: the caller's `$4C026C tst.w/bgt` falls
  through to the wait, not the `nodiskpres`=614 error path). The OS's boot-time
  I/O-completion hang (Checkpoint F) is therefore **NOT** a disk-presence HLE
  gap. ~~It is the OS's own async request-START path (SOURCE-HDISK
  `ADD_REQUEST`/`START_NEW_REQUEST`) never flipping the queued reqblk
  `active`→`in_service`.~~ **(Struck — round 3, both the citation and the
  mechanism were wrong: that HDISK queue code never runs. Round-3 instruction
  trace shows the mount reqblk is dispatched to the boot-volume FS devrec
  "#14#1", which has a NIL `cb_addr` and an `entry_pt` stub (`$46124E`) that
  returns 0 without doing I/O, so the request is orphaned.)** See
  docs/rom-trace-notes.md "Checkpoint F (round-3)".
- **disk_control idle bit — AMBIGUITY (b) — SETTLED (Task 5, boot-ROM
  disassembly).** The Rev H boot ROM polls **bit 6 of `$FCD901`**, ~~not
  `$FCD801`~~. Its handshake/ready wait (`$FE1E04`, called after every go-byte)
  does `$FE1E14: movea.l #$fcd901,A3` / `$FE1E1A: andi.b #$bf,($10,A3)` (clear
  DDRB1 bit 6 → make PB6 an input) / `$FE1E24: btst #$6,(A3)` — i.e. it reads
  **VIA1 PORT B bit 6**. `$FCD901` is exactly our ROM-established VIA1 base
  (§3), so the address serves double duty (a VIA1 port-B input line IS the
  disk_control idle bit), resolving the in-source `$D901`/`$D801` contradiction
  in favor of `$D901`. **No new wiring needed:** VIA1's `portBInput` defaults
  to `0xFF` (an unconnected input floating high), so PB6 reads 1 = idle/ready,
  which is exactly what the handshake requires — the ROM reads block 0 to
  completion with the existing default. The `$FCD801` window remains unused by
  the boot path. See docs/rom-trace-notes.md "Floppy boot (checkpoint C)".

### Boot Path

- **Boot-device byte:** absolute `$1B3` (adr_bootdev — STARTUP:198;
  LDEQU:44). `$1B2` separately used by PROF for interleave choice
  (PROF:60-68).
- **FIND_BOOT decode** (STARTUP:1297-1393): bootdev 1 = internal Sony
  (2/10-class); 0 = internal hard disk (Pepsi) or upper Twiggy; 2 =
  parallel-port ProFile; 3-14 slots.
- **prof_entry parallel-port boot (M5 Task 4 live trace).** The
  `prof_entry` (`$FE0090`) jump-table slot resolves to **`$FE1F70`**, the boot
  ROM's own ProFile parallel read routine. It bit-bangs the parallel port at
  **VIA1 base `$FCD901`** (stride 8), NOT the OS `PROFASM` driver's `$FCD801`
  (§10.1): PORT A (`$FCD909`, DDRA=0) is the 8-bit data bus, PORT B carries the
  CMD strobe (bit 4, active-low) + DIR (bit 3) + BSY (bit 1, input), and the
  status error mask is the same `$C140C000` `PROFASM` uses. It is therefore the
  **same ProFile wire protocol** as the OS driver on a different VIA1 alias
  (`viaRegisterIndex` decodes `$FCD801`/`$FCD901`/`$FCDC01` to one physical
  register file). Selecting the hard-disk item in STARTUP FROM runs this routine
  to read block 0 and boot the installed OS off the Widget — see
  docs/rom-trace-notes.md "Checkpoint K". **Reconciliation (this task):**
  `IODispatcher` now forwards VIA1 PORT-B (register 0) writes to `WidgetDrive`
  for the `$FCD901` alias too (was `$FCD801`/`$FCDC01`-only, which blocked the
  ROM's boot probe and left STARTUP FROM listing only the floppy); §10.2's
  Port-B strobe applies to all three aliases.
- **ROM entry points** (LDEQU:59-62): prof_entry=`$FE0090`,
  twig_entry=`$FE0094` (SHARED by Sony — "use same entrypoint as twiggy",
  ldmicro:38-40,301-302,389-390), prom_monitor=`$FE0084`,
  prom_version=`$FE3FFC`.
- **twig_entry call signature** (LDTWIG:256-289; ldmicro:242-274): A0=
  controller base (`$FCC000`), A1=header dest, A2=data dest, D0=0 (drive
  speed), D1=packed drive/side/block/track, D2=timeout, A3=`$FCDD81`
  (prom_via1 compat dummy — note: that's our VIA2 base, §3); out: Carry set
  on error.
- **Low-core dev_type (`$22E`):** dev_twig=0/dev_prof=1/dev_sony=2/
  dev_widget=3 (LDEQU:38-41; ldmicro:124) — consumed by the Pascal loader
  (ldlfs).
- **ProFile interleave table** for contrast (LDPROF:311-314): 0,5,10,15,4,
  9,14,3,8,13,2,7,12,1,6,11.
- **Boot-ROM read sequence — Task 5 live trace.** The Rev H boot ROM does NOT
  auto-boot from an inserted floppy: it completes POST and parks in its
  boot-menu idle loop (`$FE2DBE`), byte-identical whether or not a disk is
  present. A floppy boot is triggered only by a menu selection — click
  "STARTUP FROM…" (button id `$F2`), then a device item — which runs the Sony
  loader (`$FE1BCC`) → twig_entry read routine (`$FE1D76`). That routine's
  go-byte choreography for one block read: `clr.b ($2,A0)` (DISKPARM = 0 =
  readdisk) → `move.b #$81,(A0)` (DISKCMD = excmd) → wait completion
  (`bsr $FE1E3E`, poll at `$FE1E46`: VIA2 PORTB2 bit 4 SET) → read DISKERR (`$11`) → `move.b #$85,(A0)`
  (clristat) → wait ready (`$FE1E04`: DISKCMD==0, gated on VIA1 `$FCD901` PB6) →
  check DISKERR==0 → copy 12 tag + 512 data bytes off the odd lane. The loader
  verifies the boot block's `$AAAA` signature (`$FE1EF2: cmpi.w #-$5556`) at
  block offset 4, then **JMPs to the loaded block at `$020000`** (first bytes
  `4E FA …` = JMP). Task 6 owns the loader journey beyond boot-block entry.
- **Boot-ROM read sequence — Task 6 loader-path validation (no device change).**
  Following the boot block into the "ldsony" loader-loader (source-ldmicro), the
  loader reads its remaining code blocks **and the LFS MDDF** (block `$1C`) via
  `twig_entry`, `blocksRead` climbing 1 → 24, every read `lastError == 0`; the
  block-28 MDDF data is served **byte-for-byte identical to the raw DC42 image**
  (`fsversion` 17, `volname` "Office System 1 3.0"), confirming the go-byte
  protocol, odd-lane buffer, and CONVERT zone map end-to-end on real OS-loader
  traffic. One new interface fact: the loader's `shutdown`/eject path
  (source-ldmicro:184-203) issues an `excmd` with sub-command **`unclamp`
  (2)**, which the read-only M2 HLE answers with `notIssued` (DISKERR `9`).
  This is **cosmetically harmless and needs no model change**: `shutdown` waits
  only on the VIA2-PB4 completion line and never reads DISKERR, so the eject
  teardown (`unclamp` → `clristat $85` → `clrmask $87`/parm `$88`) completes
  regardless. ~~The loader stops at a Lisa Pascal `trap #6` segment-call gate
  (an M3 CPU-runtime dependency, not a device) — see docs/rom-trace-notes.md
  "OS loader (Task 6)".~~ **M3 Task 3 sweep correction (strike-through-not-
  erase, both-docs rule):** this was left unhedged after M3 Task 1 diagnosed
  it — `trap #6` is the OS's **MMU-programming trap** `do_an_mmu`, not a
  Pascal segment-call gate, and the stop was an **emulation divergence** (a
  missing 12-bit MMU page-add wrap in `MMU.translate`), since FIXED — the
  gate now falls and the boot advances to a new, later frontier (the
  Checkpoint-D domain-1 crossover, M3 Task 2). See
  docs/rom-trace-notes.md "Gate diagnosis (M3 Task 1)" and "Checkpoint D
  (M3 Task 2)" for the full evidence chain and current frontier.

### Board IDs

- `$FCC031` (DiskROMId/adr_machinfo): bit7 = Pepsi-class; bit5 (when bit7)
  = LisaLite slow-timer variant (LIBHW-DRIVERS:578-588; changelog :54).
  iomodel decode (STARTUP:1876-1891): ≥0 → iob_lisa; `[$A0,$BF]` →
  iob_sony; `[$C0,$DF]` → iob_lite; else check `$FCC015` (adr_intdisk):
  0=twiggy, 1=single-sided Sony, 2=double-sided Sony (STARTUP:1747-1748)
  → iob_twiggy/iob_pepsi.
- ~~**Current emulator stubs:** `$C031`=0 (validated benign through the menu
  in M1b), `$C015` currently unknown-I/O `0xFF` → Task 4 sets `$C015`=1
  (single-sided, matches 400K install disks), Task 5 validates against the
  boot path with trace evidence.~~ **(Struck — M4 Task 4 round 4.
  `$C031`=0 was benign FOR THE ROM (whose only gate is the bit-7 Pepsi
  contrast tweak, framebuffer-neutral — menu FNV anchor unchanged), but the
  OS decodes `$C031` as the MACHINE IDENTITY: `0x00` ≥ 0 signed →
  `iomodel := iob_lisa` (Twiggy Lisa 1, STARTUP:1876-1878), which made
  BOOT_IO_INIT skip the Lisa-2 config path and instead run
  `MAKE_DISK_INFO(cd_twiggy,…)` for builtin positions 1/2 (STARTUP:
  1970-1972) — installing devrecs "#14#1"/"#14#2" with `cb_addr := nil`
  (SOURCE-CD:736) and `entry_pt := @TWIGIO` (SOURCE-CD:750), whose entire
  I/O body is compiled out in OS 3.1 under `(*$IFC TWIGGYBUILD*)`
  (source-twiggy:1235/1237 — the observed 3-instruction return-0 stub).
  That was the entire Checkpoint-F orphaned-mount-read stall.
  **`$C031` now returns `$88`** — bit7 set (Pepsi-class,
  LIBHW-DRIVERS:581), bit5 clear (not LisaLite, :583), outside `[$A0,$DF]`
  (iob_sony/iob_lite, STARTUP:1879-1885) — so with `$C015`=1 the decode
  falls through to the internal-disk check and lands `iomodel = iob_pepsi`
  (Lisa 2/10, STARTUP:1886-1890). **Source for the specific `$88` byte
  (round-5 precision): the decode derivation itself, not an external ident
  table** — the 6504 disk ROM is not in this source tree ("Could Not Find"
  #1 below), so no first-party citation for the exact real-hardware byte
  exists here. Any value with bit7 SET (`BTST #7,DiskROMId`,
  LIBHW-DRIVERS:581), bit5 CLEAR (`BTST #5`, LIBHW-DRIVERS:583 — not
  LisaLite), and outside `[$A0,$DF]` (STARTUP:1879-1885) satisfies every
  decode the ROM and the OS perform; `$88` is the chosen representative of
  that class. If the real 2/10 ident byte is ever established from the 6504
  firmware, swapping it in is a no-op as long as it stays in the same
  decode class. With that identity, INIT_BOOT_CDS installs the REAL Sony CD
  driver from the boot disk (see docs/rom-trace-notes.md "Checkpoint G
  (round 4)").)**
- **Task 4 update:** `$C015` now returns `1` (was `0xFF` unknown-I/O), per
  the line above. The `$C000-$C7FF` window (`FloppyController`, this
  section's shared-RAM cells) is now live RAM served by that device;
  ~~`$C031` is UNCHANGED (still the Task-3-era `0` stub, checked before the
  window range in `IODispatcher.currentValue` so it isn't shadowed by it).~~
  **Superseded (M4 round 4, 2026-08-07):** per the round-4 bullet above
  (`$C031` now returns `$88`, Pepsi-class/Lisa 2/10 identity, commit
  90d7cdf), `$C031` is no longer the Task-3-era `0` stub as of round 4 —
  this statement described the Task-4-era machine only. Re-ran the full
  ROM-gated boot suite (`ROMBootTests`,
  `LISAEMU_ROM_DIR=... swift test`) after this change: the exact boot-menu
  anchor (`romCompletesPOSTAndReachesBootMenu`'s FNV hash
  `0xd09234d25516d0b8` / 78,100 set pixels) is UNCHANGED, because the
  traced boot path never reaches the floppy driver at all -- it parks at
  the `$FE2DBE` COPS input-idle loop before ever touching `$FCC015` or the
  `$C000-$C7FF` shared-RAM window (the already-validated `$C031` board-ID
  reads at `$FE0B24`/`$FE0B2C`/`$FE119A` are the only `$FCC0xx` traffic
  pre-menu -- see docs/rom-trace-notes.md "`$C031` board ID -- read, and
  `0x00` does NOT divert POST") — so
  neither the `$C015` value change nor the new window is observed on this
  path yet. See `FloppyController.swift`'s type doc comment for the HLE
  model (go-byte state machine, zone mapping, completion-line wiring) and
  its two flagged, Task-5-revisable assumptions: the completion line's
  IDLE/ASSERTED polarity (chosen idle=0/asserted=1) and the DISKERR raw-byte
  values (inferred as the documented OS-level error codes minus the `1800`
  offset, not independently cited). **Task 5 update:** the completion-line
  polarity is now CONFIRMED (the ROM waits at `$FE1E46` — 8 bytes into the
  wait-completion subroutine entered via `bsr $FE1E3E` from `$FE1D94` — for
  VIA2 PORTB2 bit 4 to be SET — asserted=1 is correct; M3 Task 3 precision
  fix: the polling instruction itself is `$FE1E46`, not the subroutine's
  `$FE1E3E` entry point, see docs/rom-trace-notes.md "The read routine" for
  the full disassembly); block 0 reads to completion and the boot block
  executes. The DISKERR raw-byte values remain uncited (the successful read
  path sets DISKERR=0, so no error code was exercised).
- **`$C015` vs. double-sided images — RESOLVED (M8).** `$FCC015`
  (`adr_intdisk`) is no longer a static stub: `FloppyController.intDiskId`
  derives it from the inserted media (1 = single-sided Sony, 2 =
  double-sided Sony, per STARTUP:1747-1748), so DISKFLG and `$C015` can no
  longer contradict each other. Needed by MacWorks Plus, whose hard-disk
  installer ships on an 800K diskette. Physical caveat: on real hardware
  this byte describes the DRIVE, which cannot change with the disk in it —
  deriving it from media is sound only while a double-sided diskette is
  assumed to be inserted into a drive that can read it. Pinned by
  `IODispatcherTests.intDiskIdReflectsInsertedMediaSidedness`. The original
  note is kept below, struck.
- ~~**`$C015`=1 vs. double-sided (1600-block) images — a known, documented
  inconsistency (M3 Task 3 doc note, not fixed here).**~~ `$C015` is a STATIC
  stub hardcoded to `1` (single-sided Sony), per the Task 4 update above --
  but `FloppyController.insert(_:)` accepts ANY DC42 image, including a
  double-sided 800K one (`blockCount > 800`), and sets DISKFLG accordingly
  regardless of what `$C015` claims. On real hardware `$C015` describes the
  DRIVE's fixed physical capability (STARTUP:1747-1748), not the inserted
  media, so a double-sided image combined with a single-sided-reporting
  `$C015` is a combination no real Lisa configuration could produce. This is
  harmless for every boot path traced so far (M2/M3's install images are
  single-sided 400K, and no traced path reads `$C015` after insertion --
  see the "traced boot path never reaches the floppy driver" note above),
  but is a real latent inconsistency if a future task inserts a genuine
  800K double-sided image. **M4-ish resolution path:** make `$C015`
  configurable (or derive it from the currently-inserted image) instead of
  a fixed stub, closing the gap between the two signals. See
  `FloppyController.insert(_:)`'s doc comment for the mirrored note.

### Could Not Find

1. The 6504 firmware itself (I/O-board ROM) — not in this tree; its
   internal timing/GCR/steppers are invisible; HLE models the
   68000-visible contract only.
2. One-constant statement of the shared-RAM window size (offsets observed
   to `$B9` + `$3E8`-`$7FF` region).
3. Sony interleave remap table (firmware-internal).
4. ~~Resolution of ambiguities (a) buffer offset and (b) disk_control
   address — both assigned to Task 5 ROM-disassembly.~~ **RESOLVED (Task 5):**
   (a) buffer base `$400`, odd-lane stride-2; (b) `$FCD901` (VIA1) bit 6. See
   the AMBIGUITY (a)/(b) notes above and docs/rom-trace-notes.md "Floppy boot
   (checkpoint C)".

## Known Gaps (Flagged for M1b, Not M1a)

- Parity/bus-error status register bit layout not located. Check SOURCE-EXCEPRES/SOURCE-EXCEPASM BUS_ERR handler.
  M1b Task 5 found the ROM's own usage SITE for `$F801` bit 1 (an
  NMI-vector-installing RAM-probe at `$FE0F46-$FE0F72`, see §2 "Vertical
  Retrace" above and docs/rom-trace-notes.md "Trace checkpoint B") but not
  the bit's exact semantics. M1b Task 6 checked all three statically-cited
  gating sites for live reachability (unbounded single-step trace, reset
  through 30M cycles): `$FE00D0` is unreachable dead disassembly, and
  `$FE0F14`/`$FE0F72` scored zero live PC hits — none confirmed reached.
  Still fully open, not confirmed blocking or safe either way (see
  docs/rom-trace-notes.md "Bus-error frame spike").
- `$FCF000` RAM-size ID register bit encoding not located (M1b Task 6, see
  §6 "RAM Sizing" and docs/rom-trace-notes.md "Bus-error frame spike") — the
  boot ROM statically reads it for POST-level memory sizing, but the whole
  containing routine scored zero hits in the same live single-step
  reachability check; unstubbed (`0xFF`) either way, not confirmed blocking.
- ~~RS-232 SCC base (RSBASE) not chased. Consult SOURCE-SERCARD/SOURCE-DEVCONTROL.~~
  **CHASED (M7 Task 1): `RSBASE = IOMMU + $0D201 = $FCD201`** (source-mover:46);
  full Z8530 register map, driver init/transmit discipline, the ROM POST
  `$FCD241`-mirror probe, and the parameter-memory persistence answer are now in
  §11 "SCC / Serial B". The `$FCD241` ROM probe is a bus-error-guarded presence
  test that the `0xFF` stub satisfies by ACKing the cycle (§11.5).
- `$E01C`/`$E01E` (video-register-adjacent bare strobes, M1b Task 5) — usage
  site found (bracketing a RAM-sizing/checksum routine, result discarded),
  purpose not identified. See §2 "Vertical Retrace" above.

## 10. ProFile/Widget Parallel Hard-Disk Protocol

The contract the M5 Widget HLE (Task 2) is coded against. Every constant is
cited to the OS's own ProFile driver (`OS/SOURCE-PROFILEASM.TEXT.unix.txt` =
**PROFASM**, `OS/source-PROFILE.TEXT.unix.txt` = **PROFILE**), the boot
loader's ProFile path (`OS/source-LDPROF.TEXT.unix.txt` = **LDPROF**,
`OS/source-LDEQU.TEXT.unix.txt` = **LDEQU**), the hardware-equate library
(`LIBHW/LIBHW-DRIVERS.TEXT.unix.txt` = **LIBHW-DRIVERS**), and the boot-time
device-config machinery (`OS/SOURCE-CD.TEXT.unix.txt` = **CD**,
`OS/SOURCE-STARTUP.TEXT.unix.txt` = **STARTUP**). All paths under
`~/Development/Lisa_Source/LISA_OS/`. **No Apple-derived binary data is
reproduced here** — only equates and derived semantics.

### 10.1 Address map (the Hard-Disk VIA)

The parallel port and the built-in hard disk share **VIA1** (the "Hard Disk
VIA"). Its canonical register-file base is **`$FCD801`**, register stride 8:

- `VIA1 .EQU IOSpace+$D101|$D801` (LIBHW-DRIVERS:137; `IOSpace=$FC0000`,
  :134). The `$D101|$D801` notation is the 6522's two partial decodes
  (low-select `$FCD101`, high-select `$FCD801`).
- **Register offsets** (stride 8; LIBHW-DRIVERS:148-163): `PORTB1=$00`,
  `PORTA1=$08`, `DDRB1=$10`, `DDRA1=$18`, `T1CL1=$20`, `T1CH1=$28`,
  `T1LL1=$30`, `T1LH1=$38`, `T2CL1=$40`, `T2CH1=$48`, `SR1=$50`, `ACR1=$58`,
  `PCR1=$60`, `IFR1=$68`, `IER1=$70`, `IORA1=$78`. PROFASM uses the identical
  offsets under different names (`IRB/ORB=0, IRA/ORA=8, DDRB=$10, DDRA=$18,
  T2CL=$40, T2CH=$48, ACR=$58, PCR=$60, IFR=$68, IER=$70, PORTA=$78`,
  PROFASM:16-28).
- **The OS driver's built-in-port addressing** (PROFILE hdinit,
  PROFILE:253-256): `hwbase := iospacemmu*$20000 + $0D801` (= `$FCD801`),
  `hwstatus := hwbase + $400` (= `$FCDC01`), `hwddrb := hwstatus + 4` (=
  `$FCDC05`). So PROFASM's `HWBASE` register file is at `$FCD801` and its
  `HWSTATUS` (a Port-B mirror carrying busy/disconnect/parity) is at
  `$FCDC01` — a further 6522 mirror (`$D801 + $400`).
- **`disk_control = $FCD901`** (LDEQU:47, "address of disk-busy status
  byte"): the loader/ROM read the busy bit via a `$FCD901` mirror of Port B
  (`BTST #1,(disk_control)`, LDPROF:163-166). This is the same `$FCD901`
  the Rev-H boot ROM's **floppy** handshake reads for its PB6 idle bit (§9
  "disk_control idle bit"): one physical VIA, several address mirrors.
- **Multi-port-card addressing** (external ProFile on an expansion card,
  PROFILE:247-250): `hwbase := iospacemmu*$20000 + $4000*slot_no + $2001 +
  $800*iochannel`; `hwstatus := hwbase`; `hwddrb := hwbase + $10`.
- Slot ident probing (CARDS_EQUIPPED, CD:563-571) reads `ADR_DISK_CONTROL(i,0)
  - $2000` = the low-select windows `$FC0001/$FC4001/$FC8001` for slots 0/1/2
  (`slot_base=$FC2001`, `slot_offset=$4000`, CD:519-527).

> **Emulator-state note / Task-2 gap — and the `$D801` vs `$D901` tension.**
> `IODispatcher` currently decodes VIA1 **only at offset `$D901`, stride 8**
> (`viaRegisterIndex`, IODispatcher.swift:296), a decision made from the Rev-H
> **boot-ROM/floppy** evidence, which explicitly **refuted the `$D801`/`$DC01`
> OS-source equates for that path** (IODispatcher.swift:49-52; §9
> "disk_control idle bit"; docs/rom-trace-notes.md "Beyond the M1a boundary").
> That refutation is about the *ROM floppy handshake*, which reads the
> `$FCD901` Port-B mirror. The **OS ProFile driver (PROFASM) is a different
> code path** and its source computes `HWBASE = $FCD801` / `HWSTATUS =
> $FCDC01` (PROFILE:253-256, LIBHW-DRIVERS:137) — a real 6522 answers all of
> `$D101/$D801/$D901/$DC01` as mirrors, so "$D801 is wrong" is too strong;
> the accurate statement is that the ROM path *uses* `$D901`. **Which mirror
> the OS driver hits live is UNVERIFIED** because `PROF_INIT`/`PROFASM` never
> execute on our machine today (§10.9). So `$FCD801`/`$FCDC01`/`$FCDC05` and
> the slot windows are currently unmapped (`0xFF`). **Task-2 action:** once a
> `cd_intdisk` devrec exists and PROF_INIT runs, trace which address the
> driver actually drives, then either widen VIA1's decode to the `$D801`/
> `$DC01` mirrors or front those windows with the Widget model.
>
> **M5 Task 2 DONE — decode widened; live probe still UNOBSERVED (expected).**
> `IODispatcher` now decodes the `$FCD801` HWBASE register file and the
> `$FCDC01`/`$FCDC05` HWSTATUS/hwddrb mirrors to the same `via1` instance, with
> `WidgetDrive` attached to VIA1 Port A/B (IODispatcher.swift `viaRegisterIndex`
> / the `via1.portAInput`/`portBInput`/`onPortAAccess` wiring). A live probe was
> run (`ROMFloppyBootTests.checkpointH_widgetAttachedDoesNotDriveTheRegionOr
> MoveTheInstaller`): booting the checkpoint-G window **with a Widget attached**,
> `bus.widgetRegionAccesses == 0` and `bus.widget.completedCommands == 0` — the
> OS/ROM **never touches `$FCD801`/`$FCDC01`** on the boot-to-installer-dialog
> path, so which mirror the driver drives remains **UNOBSERVED**. This is the
> predicted result, now confirmed live: PROF_INIT only runs once the installer
> *builds and drives* the internal-disk devrec (via `CDMake`, §10.9), which
> happens when the user clicks Install — Task 3's frontier. `IODispatcher`'s
> `widgetRegionAccesses`/`firstWidgetRegionAccessCycle` are the seam that will
> capture the OBSERVED address the first time it goes non-zero (Task 3 records
> OBSERVED vs this decode there). Attaching a Widget also left the installer
> dialog **byte-identical** (same FNV `0x04a19e4eb59704f4`) — no boot-menu
> movement, no re-anchoring (contrast the M2 floppy-devrec precedent).

### 10.2 Handshake line semantics (Port A / Port B)

The protocol is a byte-at-a-time handshake over **Port A** (the 8-bit
bidirectional data bus, `PORTA/IORA1 = base+$78`) gated by control bits in
**Port B** (`ORB/PORTB1 = base+0`) and the status mirror
(`ORB(HWSTATUS)`). All bit assignments from PROFASM's own accesses:

Port B (`base+0`, and its HWSTATUS mirror) control/status bits:

| Bit | Mask | Role | Evidence |
|-----|------|------|----------|
| 0 | `$01` | **DISCONNECT** (cable), read on IRB: 1 = disconnected | `BTST #0,IRB` PROFASM:1478, PROF_INIT:1545 |
| 1 | `$02` | **BSY** (controller busy), read on IRB / IFR (CB-latched) | `BTST #1,IRB` PROFASM:1630/1646; `BTST #1,IFR` :268/289 |
| 3 | `$08` | **DIR** (Port A direction): set = input-from-drive, clear = output-to-drive | `ORI #$08,ORB`=in :265; `ANDI #$F7,ORB`=out :698 |
| 4 | `$10` | **CMD** (command strobe), active-low: `ANDI #$EF` = CMD true, `ORI #$10` = CMD false | PROFASM:265/333/389 |
| 5 | `$20` | **PARITY control** on HWSTATUS: `ANDI #$DF` then `ORI #$20` = clear/arm parity | PROFASM:355-356, 404-405; PROF_INIT parity-reset bit :1532-1533 |
| 7 | `$80` | **PROFILE-RESET** (with bit 5) set to output at init | `ORI #$A0` PROF_INIT:1532-1533 |

Other lines:

- **PARITY error flag:** `IFR` bit 3 (`$08`), tested after every byte
  transfer — `BTST #3,IFR` (PROFASM:385, 412, 731, 1180). Cleared by writing
  `#$08,IFR` before a transfer (PROFASM:357).
- **BSY interrupt:** VIA1 interrupts at **level 1** (§5). `PCR` selects the
  edge: `ANDI #$FE,PCR` = interrupt on falling edge (PROFASM:262), `ORI
  #$01,PCR` = rising edge (PROFASM:322). IFR bit 1 (`$02`) is the CB-latched
  BSY event; cleared with `#$02,IFR`.
- **Disconnect/timeout timer:** Timer 2 (`T2CL/T2CH`, `base+$40/$48`).
  `MOVE.B #$FF,T2CH` starts the ~0.1 s poll used to detect a hung/absent
  controller while "waiting for interrupt" (PROFASM:272, 293, 308; the
  `Dinterrupt` handler decrements `COUNTER` over `COUNTLIMIT=100` polls =
  ~12 s parallel timeout, PROFASM:1508-1512 / PROFILE:31).
- **Port A data:** `MOVE.B x,ORA` sends a byte to the drive (DIR=out,
  `DDRA=$FF`); `MOVE.B IRA,x` reads a byte (DIR=in, `DDRA=$00`). Direction is
  flipped by `DDRA` (`$FF`=out / `$00`=in, PROFASM:330/402) in step with the
  Port-B DIR bit.

### 10.3 The handshake exchange (per byte / per phase)

The two-wire choreography (PROFASM `RESPOND` :322-340, `DOSHAKE` :1653-1687,
states `S1/S2/S200` :260-310):

1. **Assert CMD, wait BSY.** Driver sets DIR=in, CMD true (`ANDI #$EF,ORB`),
   `DDRA=0`, then polls IFR/IRB bit 1 for BSY (`RSPTIME`≈1 ms, `#$0050`
   PROFASM:32). If BSY doesn't come, it arms T2 and waits for the level-1
   interrupt.
2. **Read the controller's response byte** off Port A (`MOVE.B PORTA,D1`) and
   compare to the **expected-response** code (`EXPECT_HS`). A negative
   `EXPECT_HS` is a wildcard (PROFASM:326-327).
3. **Reply.** On a good response the driver flips DIR=out, `DDRA=$FF`, and
   writes the **reply byte** to Port A, then raises CMD false. Reply codes:
   - `$55` = standard "proceed" reply (PROFASM:286, 305, S200/S2).
   - `$69` = "free device" reply for multi-block/Widget (PROFASM:284, S2A).
   - `$AA` = negative reply, Profile/Seagate bad-response (DOSHAKE:1682).
   - On bad response: reply `$00` (Profile/Seagate) or `$69` (Widget) and
     branch to the BDR error state (PROFASM:335-340).

**Expected-response (`EXPECT_HS`) codes seen from the controller:** `1` (idle
→ ready), `2` (read-command accepted), `3` (write-command accepted), `6`
(post-write status), `$22`/`$23` (multi-block read/write accepted, S50),
`$27` (multi-block write complete), `$0F`/`$10` (Widget spare-table
read/write), `$A3` (multi-block error) (PROFASM:260, 379, 382, 746, 1213,
1218, 1332-1347, 1363, 1410).

### 10.4 Command block format — VERIFY (brief's `$02` claim refuted)

The single-block command is a **6-byte** block (PROFASM `S3` :355-391;
PROFILE `command_buffer` :57-61):

```
byte 0 : command       (0 = read, 1 = write)     ; TST.B COMMAND_BUFFER; BNE=write  PROFASM:376
byte 1 : block# [23:16]                            ; 3-byte big-endian sector
byte 2 : block# [15:8]
byte 3 : block# [7:0]  (interleave-remapped for Profile/Seagate, PROFASM:363-373)
byte 4 : retry_count   (default 10 = $0A)          ; PROFILE:269, LDPROF:38
byte 5 : sparing_threshold (default 3)             ; PROFILE:270, LDPROF:39
```

- **Command codes (the byte on the wire): `0` = read, `1` = write.** There is
  **no `$02` "write-verify" command.** The brief's `$02` is the *driver-level*
  `Formatcmd` operation code (`PROFILE:44-46`: `Readcmd=0, Writecmd=1,
  Formatcmd=2`), which maps to a Widget spare-table sequence (§10.6), not a
  block command. **Write-verify is not a distinct command** — it is the
  driver re-issuing a *read* (`command_buffer := 0`) after a write when the
  `V_FLAG` verify flag is set (`S13`, PROFASM:923-929; enabled via the dcontrol
  `dcode 21` call, PROFILE:400-405). ~~`$02` = write-verify command byte.~~
  (Refuted; cite PROFILE:44-46 + PROFASM:376 + S13:923-929.)
- The driver builds the byte with `command_buffer.cmd := 1 - operation`
  *after* storing the sector (PROFILE:331-332) — the OS "operation" enum is
  inverted into the wire command.
- **Device-info / status read** uses command `0` with block **`$FFFFFF`**
  (retry `$0A`, sparing `0`): PROF_INIT reads it to fetch drive type +
  `discsize` (PROFILE-init DOIT, PROFASM:1567-1607); LDPROF reads block
  `$FFFFFF` to tell Profile from Widget (LDPROF:112-118).

### 10.5 Status bytes

After a command the driver reads **4 status bytes** into `ERRSTAT` (PROFASM
`RD_STATUS`:402-417, `S6`:424-440):

- **Fatal-error mask** `$C140C000` AND'd against the 4-byte `ERRSTAT`
  longword: non-zero ⇒ hard error `HD_ERR` (PROFASM:429-432).
- `ERRSTAT` byte 0 `== $09` ⇒ CRC/read error, treated as a soft checksum
  error, retryable (PROFASM:427, 602, 981).
- `ERRSTAT+1` bit 2 (`$04`) ⇒ **sparing occurred** on the last block →
  triggers the extra spare-update handshake (`HS` state, PROFASM:622-628,
  941-947, 996-1002).
- The Widget controller-abort/diagnostic status is 4 further bytes read after
  the `$13 $01 $05 $E6` "read state registers" diagnostic command, OR'd into
  `ACCSTAT` (PROFASM `S41`:1099-1116, `S42`:1124-1131).

### 10.5a Transfer byte ORDER + device-info layout — RECONCILED LIVE (M5 Task 3)

M5 Task 2's `WidgetDrive` transcribed §10.2-10.5 as a *contract* but got the
per-phase transport wrong; driving `PROF_INIT` live for the first time (Task 3,
docs/rom-trace-notes.md "Checkpoint H (M5 Task 3)") pinned the exact behaviour
against the driver's **state tables** (PROFASM `STATE_TABLE`:149-175). The facts
the HLE now implements:

- **BSY (Port B bit 1) is a LEVEL, idle = 1.** `WAIT_NOTBUSY` (PROFASM:1618-
  1632) exits when bit 1 = **1** (ready, CMD deasserted); `WAIT_BUSY` (:1633-
  1651) exits when bit 1 = **0** (controller presenting, CMD asserted).
  `PROF_INIT`'s first `WAIT_NOTBUSY` requires idle BSY = 1 *before* any CMD.
  (The Task-2 HLE held bit 1 = 0 always → `WAIT_NOTBUSY` spun the full ~16 s.)
- **Single-block READ order** (`NEW_CMD`:151-159): after the accept handshake
  the driver reads **`S6` status = 4 bytes FIRST** (`RD_STATUS`:402-417), then
  **`S7` = 20-byte header (RDHDR:448) + 512 data (RDDATA:537)**. So the wire
  stream is **status(4) · tag(20) · data(512)**.
- **Single-block WRITE order** (`WRT`:161-168 → `S10`:687-709): **header (20,
  WRHDR) FIRST, then 512 data (WRDATA)** — "Header followed by User Data"
  (PROFASM:687). (Widget/multi-block `S10A`:711-728 is the reverse, "User Data
  followed by Header"; §10.6.) The write is then followed by a **read-back
  verify** (`S13`/`S1`, PROFASM:167-168) that re-reads the block — so a wrong
  write order silently corrupts the block and fails as *"the Lisa could not
  write to the disk"*, not as a status error.
- **`PROF_INIT` device-info block** (`$FFFFFF`) is NOT a 512+20 block. After the
  2nd handshake the driver reads (PROFASM:1600-1613), at these **absolute byte
  offsets into the IRA stream** (the 4 status bytes are part of it): **4 status
  bytes (0-3)**, **14 skipped (4-17)**, **DRIVETYPE @ byte 18**, **3 skipped
  (19-21)**, **3-byte DISCSIZE @ bytes 22-24** (big-endian). `drivetype 0` +
  `discsize ∈ (9728,30000]` ⇒ T_Seagate single-block (§10.8).

Response codes come back on **PORTA = VIA reg 15** (`base+$78`, no-handshake),
one per handshake; data/status stream through **IRA = VIA reg 1** (`base+$8`,
handshake), auto-advancing. This is now the executable spec in
`WidgetDriveTests` and the end-to-end anchor `checkpointI`.

### 10.6 Multi-block & Widget commands (drivetype ≥ 2)

Widgets (and any controller reporting `DRIVETYPE ≥ 2`) use multi-block
commands (PROFASM `S0`:249-255, `MULTI_CMD`/`S50`:1193-1230):

- **Multi-block I/O**: `CMD_BUF` = `$26` (command-type+length nibble), then
  the 1-byte command, 3-byte block#, and a block-count (≤ 127 per request,
  PROFASM:1199-1206). Sent by `SEND_CMD` with a trailing XOR check byte
  (`EORI #$FF`, PROFASM:1166-1185).
- **Widget diagnostics** (`CMD_BUF` high nibble `$1x`): read-state-registers
  `$13 $01 $05 $E6` (S41), **read spare table** `$120D` (S60:1359), **write
  spare table** `$160E` + fence `$F0783C1E` (S62:1405-1406).
- Multi-block responses: `$22` (read block), `$23` (write block), `$27`
  (write done), `$A3` (error → read status). Free-device reply `$69`.

### 10.7 Checksum & sector data layout

- **Data:** 512 bytes/block, transferred as `RDDATA`/`WRDATA` (PROFASM
  :537-563, :760-799). Timing-critical: "14-21 CPU cycles between bytes"
  (PROFASM:533-535) — a pulse handshake, invisible to a cycle-approximate
  HLE that returns bytes on demand.
- **On-disk header/tag:** **20 bytes** (`disk_header equ 20`, LDPROF:41;
  read by `RDHDR` Profile / `RD_WHDR` Widget, PROFASM:448-524). The Widget
  header is bit-packed differently (version nibble + flags nibble, PROFASM
  RD_WHDR:491-524) from the Profile header. This is the same 20-byte soft
  header the Sony path exposes as a 24-byte unpacked Pascal pagelabel (§9
  "Sector layout"); DC42's 12 packed tag bytes are the subset stored.
- **Checksum:** a running **XOR** (`EOR`) over header+data bytes; a header
  flag bit (`$80` on the dataused byte, "cksum present" = `cksum_on $8000`,
  LDPROF:42) says whether the block carries a checksum. A non-zero final XOR
  ⇒ `CSERR` (PROFASM:590-598, C_SUM:631-661). Parity (`IFR` bit 3) and CRC
  (`ERRSTAT==$09`) also raise `CSERR`.

### 10.8 Block geometry & the 10 MB Widget count (partly underivable)

Derivable from source:

- **512 data bytes + 20-byte header** per block (§10.7).
- Drive-type decode after PROF_INIT reads `discsize` from the controller
  (PROFILE:283-301):
  - `discsize ≤ 9728` **or** `> 30000` ⇒ **`T_Profile`**, `num_bloks := 9720`
    (the 5 MB ProFile default, PROFILE:265, 283-284).
  - `9728 < discsize ≤ 30000` ⇒ Widget or Seagate: `num_bloks := discsize -
    strt_blok` (PROFILE:289); `DRIVETYPE ≠ 0` ⇒ **`T_Widget`**
    (`remap_interleave:=false`, `rvrs_hdr:=20` — headers at *end* of sector,
    PROFILE:290-295), else **`T_Seagate`** ("10 MB seagate", PROFILE:298).
- So the exact 10 MB Widget total block count is **controller-reported
  (`discsize`), not a source constant** — the OS accepts any value in
  `(9728, 30000]`.

**Underivable-from-source (chosen fallback):** the 6504/Widget controller
firmware that would report `discsize` is not in this tree (same class as §9
"Could Not Find" #1). The historically documented Widget-10 geometry is
**19456 blocks** (× 512 = ~9.96 MB usable), which is what the Task-2 image
container presents as `discsize`. `19456` is the chosen representative; any
value in `(9728, 30000]` works, swapping in with no logic change.

**Single-block T_Seagate vs multi-block T_Widget — the Task-2 advertisement
(review fix round 1, I2).** The `DRIVETYPE` byte the controller reports decides
which command path the OS driver uses: `CMPI.B #2,DRIVETYPE / BLT` — **`DRIVETYPE
< 2` (Profile=0 or Seagate=1) → single-block** read/write; **`DRIVETYPE == 2`
(Widget) → multi-block** (`CMD_BUF=$26`, §10.6) (PROFASM:250). The Task-2
`WidgetDrive` HLE implements the **single-block** path (§10.4) only, so it
advertises a **10 MB T_Seagate**: a raw `drivetype` byte of `0` with a `discsize`
in `(9728, 30000]` resolves to `T_Seagate` with `num_bloks := discsize - strt_blok`
(full 10 MB, PROFILE:288-298) — coherent with single-block I/O at full capacity.
A 10 MB single-block *T_Profile* is **incoherent** (PROFILE:283-284 forces
`num_bloks := 9720`, capping at 5 MB), and *T_Widget* (`drivetype ≠ 0`) would
demand the unimplemented multi-block path. So `WidgetDrive.deviceInfoData`
reports `discsize` only, leaving the `drivetype` byte 0 → T_Seagate. **Building
the §10.6 multi-block path + advertising T_Widget is a deferred Task 3+
enhancement**, needed only if the install is found to require Widget-specific
behaviour (spare tables, `Formatcmd` widget-format, PROFILE:419); single-block
read/write/device-info covers `CDMake`→FS `LookUp`/`Mount` (§10.9a).

### 10.9 Attach-path conditional — the crown jewel

**Whether the OS builds a ProFile/Widget devrec at all is gated on machine
identity, exactly as the M4 floppy devrec was.** Two source sites:

1. **Board detection** (BOOT_IO_INIT, STARTUP:1876-1891) reads two identity
   bytes and derives `iomodel`:
   - `adr_ioboard = $FCC031` (STARTUP:1746) — signed byte. `≥ 0` ⇒
     `iob_lisa`; `[-96,-33]` (`$A0..$DF`) ⇒ `iob_sony`/`iob_lite`; otherwise
     "some form of Pepsi" → read the second byte.
   - `adr_intdisk = $FCC015` (STARTUP:1747-1748) — **`0` ⇒ `iob_twiggy`,
     else `iob_pepsi`** (this byte selects the built-in *floppy* type:
     0=twiggy, 1=SS Sony, 2=DS Sony — *not* the hard disk).
   - Our machine returns `$FCC031 = $88` and `$FCC015 = 1`
     (IODispatcher.swift:204/213) ⇒ **`iomodel = iob_pepsi`** (Lisa 2/10),
     confirmed live in §"Checkpoint H prep" of rom-trace-notes.
2. **The devrec gate** (NEW_DEVICE, CD:1004-1030):
   ```
   if (slot = cd_paraport) then begin
      MACH_INFO(error, looker);
      if (looker.io_board = iob_pepsi) or (looker.io_board = iob_twiggy)
         then begin error := cdnoparaport; EXIT(new_device); end;  { CD:1006-1013 }
   end;
   ...
   else if (slot = cd_paraport) then via1 := ord(workptr)          { CD:1029 }
   else if (slot = cd_intdisk)  then via1 := ord(workptr);         { CD:1030 }
   ```
   - On a **Pepsi/Twiggy I/O board the external parallel port
     (`cd_paraport`) is refused** — `cdnoparaport` (757), no devrec (CD:1006-1013,
     comment "We explicitly guard against creating a CD driver for the
     parallel port on pepsi systems", CD:922-925).
   - The **internal hard disk (`cd_intdisk`)** devrec *is* allowed and stores
     its control-block pointer in the same `port_cb_ptrs.via1` field
     (CD:1030). ~~It is created **only if parameter memory carries a
     `cd_intdisk` entry**.~~ **REFUTED for the installer (M5 Task 2, §10.9a
     below) — struck, not erased.** Parameter memory gates only the *boot-time*
     `INIT_CDS` reconstruction (CD:1758-1935), not the installer, which builds
     and `CDMake`s the `cd_intdisk` position itself with zero PM. Task 1
     over-generalized the `INIT_CDS` PM path to all devrec creation. The
     BOOT_IO_INIT builtin loop (STARTUP:1950-2006) still creates only Twiggy
     floppy devrecs + FS_INIT (never a hard-disk devrec), so on the *boot ROM /
     STARTUP* path there is indeed no `cd_intdisk` — but the **installer** is a
     separate creator (§10.9a).
   - `MACH_INFO` folds `iob_twiggy → iob_pepsi` (CD:647-648), so both map the
     same way for the paraport guard *and* for the installer's slot-12
     internal-disk decision (§10.9a).

### 10.9a Installer disk-scan mechanism — OBSERVED (M5 Task 2, Task-1 Q2)

**How the Office System installer actually finds a disk** (installer source
`APPS/APIN/APIN-OFFICE.TEXT.unix.txt` = **APIN-OFFICE**; verified file:line).
Task 1's INFERRED "the installer scans devrecs/configinfo, and needs a
PM-created `cd_intdisk`" is **REFUTED**; the OBSERVED mechanism:

*(Line numbers are the `APPS/APIN` copy; the `LISA_OS/APIN` copy is offset ~1
line lower — e.g. the slot-12 lines are 2999-3000 in APPS, 2998-2999 in
LISA_OS. Corrected in review fix round 1 — the earlier `3010-3013` cite was the
unrelated `Port2ID` expansion-slot CASE arm, not the internal disk.)*

1. **The installer builds its own candidate list from machine type — it does
   NOT read configinfo/PM to discover disks.** `SetDevices` (PROC APIN-OFFICE:
   2749; the `CASE machineType.io_board` at 2987-3005) hardcodes, for
   **`IOPepsi`** (our Lisa 2/10), the internal disk at **slot 12, chan 0**:
   `SetDevPos(index,12,0)` (**APIN-OFFICE:2999**) + `devList[index].diskDrvrPos
   := ProfDloc` (**APIN-OFFICE:3000**). `IOLisa`/`IOLisaLite` get the
   parallel-port ProFile at slot 11 instead (2991/2993). **The internal disk is
   driven by the ProFile driver (`ProfDloc`)** — the same driver that
   auto-selects Profile/Seagate/Widget behaviour from the controller-reported
   `discsize`/`drivetype` (PROFILE:283-301; see §10.8 and the T_Seagate
   single-block choice in `WidgetDrive.deviceInfoData`). `io_board` comes from
   `Mach_Info` (APIN-OFFICE:1672) ← `iomodel` ← the `$FCC031`/`$FCC015` bytes
   (STARTUP:1746-1748, 1884-1895) we **already model** (`iob_pepsi`).
2. **The installer creates the devrec itself — gated on `hasInfo`.**
   `InitDrivers` (PROC APIN-OFFICE:2881-2949) `CDKill`s every position (loop
   2912-2925), then its inner `InstallDrvr` (2889-2904) does the real
   **`CDMake(err, theDevLoc, drvrList[theListLoc].infoBuf)` (APIN-OFFICE:2899)**
   — but **only `IF (drvrList[theListLoc].hasInfo)` (APIN-OFFICE:2897)**. The
   disk loop calls `InstallDrvr(devList[index].diskDrvrPos, …)` (**2946**), itself
   gated `IF (devList[index].diskDrvrPos > 0)` (2944, comment "isn't driverless
   or a built-in device (widget)"). `CDMake` (CD:1366-1428) → `NEW_DEVICE`
   (CD:898-1104), which for `cd_intdisk` stores the control block in
   `port_cb_ptrs.via1` (CD:1030) — **no PM entry consulted, no hardware probe;
   `cd_intdisk` is never refused** (only `cd_paraport` is, CD:1006-1013).
   - **`hasInfo` is a Task-3 navigation dependency (review fix round 1).** It is
     set TRUE only when `GetDrvrInfo` (PROC APIN-OFFICE:2759) finds the driver's
     entry while parsing the boot floppy's **`system.cdd`** file
     (`hasInfo := TRUE`, **APIN-OFFICE:2818**; field decl :345). So the
     slot-12 `CDMake` fires **only if the installer has loaded the ProFile
     driver info for `ProfDloc` from `system.cdd`**; if that parse doesn't find
     it, `InstallDrvr` silently no-ops (no `CDMake`, no devrec, no error). Task 3
     must confirm the install medium's `system.cdd` carries the ProFile driver
     entry (and that our FS reads reach `GetDrvrInfo`) before the devrec — and
     hence any `$FCD801` traffic — can appear.
3. **Then it tests for a real disk through the FS/driver.** `SetDevices` does
   `LookUp` on each candidate and sets `isDisk` only if `err ≤ 0 AND fsInfo.devT
   = diskDev` (**APIN-OFFICE:3051-3053**); `MountInit` (PROC APIN-OFFICE:2573)
   then `MountDisk`s each `isDisk` candidate. The **"can't find a suitable
   disk"** install alert (`LockAlert(installAlert, 162)`, APIN-OFFICE:1425)
   fires only if the scan ends with `foundOne = FALSE` (decl :2587).
4. **PM is an OUTPUT of install, not a precondition.** After the user picks a
   disk, `CheckPMList` (PROC APIN-OFFICE:880, FORWARD :409; doc 882-885) queues
   it so `Finished` → `PMWrite` (:1256) records "disk present" for the *next*
   boot's `INIT_CDS`. PM lives in small COPS-adjacent NVRAM (`READ_PMEM`/
   `WRITE_PMEM`, STARTUP:824-826; low level `W_PARAM_MEM`, source-twiggy:196,260).

**Bottom line (decides Task 3): NO parameter-memory model is needed to make the
installer find the disk.** The gate is entirely `Mach_Info.io_board = iob_pepsi`
(already satisfied by our `$FCC031=$88`/`$FCC015=1`). Task 3 must:
(a) let the installer reach `SetDevices`/`InitDrivers`/`MountInit` (script the
"Install" click); (b) ensure `GetDrvrInfo` finds the ProFile driver in the
install medium's `system.cdd` so `drvrList[ProfDloc].hasInfo` is TRUE — **without
it the slot-12 `CDMake` silently no-ops** (item 2 above); and (c) make the
**block device at slot-12/`$FCD801`** answer `CDMake`→FS `LookUp`/`Mount`
correctly (device-info read + single-block I/O — the §10.1-10.7 model this task
built, advertised as **T_Seagate** per §10.8). A PM/NVRAM model is a
*second-phase* concern (so the installed system can `INIT_CDS`-reconstruct and
boot next time, and so `PMWrite` has somewhere to write) — small (one checksummed
`pmem` record), but **out of the install-scan critical path**, so not built here.
*Could-not-find:* `GETNXTCONFIG`'s body (only call sites CD:1775/STARTUP:1447);
the numeric `$FCC015`/`$FCC031` hardware encoding (only STARTUP decode ranges).

**Live branch our machine takes today (the "no suitable disk" path, still
true):** on the boot-to-installer-*dialog* path no ProFile/Widget devrec is
built and `$FCD801`/`$FCDC01` are never touched — confirmed live with a Widget
attached (§10.1 checkpoint-H probe: `widgetRegionAccesses == 0`). The devrec is
created later, by the installer's own `CDMake` when the scan runs (the Install
click), not by the boot ROM/STARTUP.

**Consequence for M5:** making the installer see a disk requires (a) a Widget
device model answering the §10.1-10.7 protocol at `$FCD801` (**this task**),
and (b) driving the installer far enough to run its `SetDevices`/`CDMake`/
`MountInit` scan (**Task 3**). It does **not** require a parameter-memory model
(Task 1's "(b) a `cd_intdisk` devrec from PM" was the refuted inference).

### 10.10 Image-container, creation & persistence decisions

Decided for the Task-2 Widget HLE (reasoning inline):

- **Container = raw fixed-size blocks, no header.** `N` blocks × **532 bytes**
  each = `512` data + `20` header/tag (§10.7-10.8), laid out
  `[block0: 512 data][block0: 20 tag] … ` contiguously. Rationale: the
  protocol exposes exactly data+header per block (PROFASM `RDDATA`+`RDHDR`);
  a headerless raw image is the least-assumption container and mirrors how
  the Sony path already treats DC42 data+tag. (Alternative "data-only, tags
  synthesized" was rejected — the driver reads real header bytes and
  checksums them, PROFASM:581, so tags must be stored.) The Task-2 default is
  the Widget-10 geometry `N = 19456` (§10.8), file size `19456 × 532 =
  10,350,592` bytes; `discsize` reported to PROF_INIT = `N`.
- **Creation policy = emulator creates a blank image on demand.** When the
  configured Widget image path does not exist, the emulator creates an
  all-zero `N × 532` file (blocks read back as zeros with a zero XOR checksum,
  which the driver accepts as a valid unwritten block — no `CSERR`, PROFASM:591).
  This lets "Install" format-and-populate a fresh disk without a
  pre-seeded image, matching real hardware where a new Widget is blank.
- **Persistence policy = write-back to the file, flushed per completed write.**
  Each successful block write (PROFASM `S10`/`S10A` → completion) is written
  through to the backing file (offset `block × 532`), so an installed system
  survives across emulator sessions — unlike the floppy's copy-on-write
  session overlay (which deliberately never mutates the read-only `.dc42`,
  §9). The hard-disk image *is* the persistent store, so write-through is the
  correct model; flush granularity is per-block to bound data loss on an
  abrupt exit. (A future optimization may batch flushes, but per-block is the
  safe default.)

## 11. SCC / Serial B (RS-232) — the Z8530 contract (M7 Task 1)

The Lisa's two RS-232 ports (A and B) are a single Zilog **Z8530 SCC** (dual
channel). The built-in SCC is interrupt **Level 6** (§5 "Interrupt Levels":
`rsints = $600`; RSINT handler mover:827-849, INITRAP:136-137). This section is
the driver contract Task 2 codes the real device against. Constants are
SOURCE-DERIVED from `/Users/jdawson/Development/Lisa_Source/LISA_OS/` unless a
line is tagged **OBSERVED** (M7 Task 1 live trace: Rev H ROM + OS31-installed
Widget boot to desktop, release build; see docs/rom-trace-notes.md "Checkpoint N
prep").

### 11.1 RSBASE and the register-address map — SOURCE-DERIVED + OBSERVED

- `IOMMU = $FC0000` (source-PASCALDEFS.TEXT.unix.txt:47, source-SERNUM.TEXT.unix.txt:15).
- **`RSBASE = IOMMU + $0D201 = $FCD201`** (source-mover.text.unix.txt:46), with
  `PORTB = 0`, `CTRL = 0` (source-mover.text.unix.txt:47-48). This strikes the
  Known-Gaps "RSBASE not chased" record below.
- The four SCC registers are at **odd** byte addresses, stride 2 — the built-in
  port-control addresses the OS computes are `iospacemmu*$20000 + $0D203` for
  channel A control and `portacontrol − 2` for channel B control
  (source-rs232.text.unix.txt:516-523; `iospacemmu*$20000 = IOMMU`,
  i.e. `iospacemmu = $7E`). The data register is control **+4** (`DATA .EQU 4`,
  source-rsASM.TEXT.unix.txt:24):

  | Address     | Register             | Access                          |
  |-------------|----------------------|---------------------------------|
  | `$FCD201`   | channel **B** control | write reg#/value; read = RRn    |
  | `$FCD203`   | channel **A** control | "                               |
  | `$FCD205`   | channel **B** data    | Tx byte out / Rx byte in        |
  | `$FCD207`   | channel **A** data    | "                               |

  Address bit 1 selects channel (A = bit1 set, i.e. +2), bit 2 selects
  data (+4); higher address bits are **not decoded** — see the `$FCD241` ROM
  mirror in §11.5. **Serial B (the printer port) control = `$FCD201`,
  data = `$FCD205`.**
- Expansion-card serial ports (not the built-in) use the same scheme at slot
  bases `iospacemmu*$20000 + {$2003,$6003,$A003}` (control A) / `{$2001,$6001,$A001}`
  (control B) for slots 0/1/2 (source-rs232.text.unix.txt:503-513,
  SOURCE-SERCARD.TEXT.unix.txt:131-133). SOURCE-SERCARD is only the per-slot
  interrupt **dispatcher** (reads WR2/RR2 for the vector); the built-in RS-232
  byte engine is `source-rs232.text` (Pascal) + `source-rsASM` (assembly).

### 11.2 Register-access discipline — SOURCE-DERIVED

- **Write a WR register** — `WR_SCC(regno, val)` (source-rsASM.TEXT.unix.txt:528-566):
  `INTSOFF` (mask RS ints) → write `regno` byte to the control address →
  a NOP-equivalent delay (a memory access) → write `val` byte to the same
  control address → `INTSON`. Register-pointer-then-value, both to the one
  control port.
- **Read an RR register**: write the register number to control, then read the
  control address (e.g. RR1 error status, source-rsASM.TEXT.unix.txt:160-166).
  A bare read of control (no preceding select) returns **RR0** (the default
  pointer), which is how RSOUT and RESTORE sample status
  (source-rsASM.TEXT.unix.txt:429, 626).
- **Data**: `MOVE.B char,DATA(A0)` writes the Tx byte to control+4
  (source-rsASM.TEXT.unix.txt:489); `MOVE.B DATA(A0),Dn` reads the Rx byte
  (source-rsASM.TEXT.unix.txt:167).

### 11.3 Channel-B init sequence (`dinit`) — SOURCE-DERIVED

Order the OS driver programs when a Serial-B device is opened
(source-rs232.text.unix.txt:538-580, then RESTORE at :642; baud via the internal
`dcontrol` dcode 5 at :558-566 / :740-751):

1. Dummy read of control (resets the register pointer to RR0/WR0) (:544).
2. `WR9 = $4A` — reset channel B (:545). (Channel A uses `$8A`; a full-chip
   reset is `WR9 = $C0`, which is what the ROM POST issues — §11.5.)
3. `WR4 = $44` — async, ×16 clock, 1 stop bit, parity off (:548).
4. `WR11 = $D0` — clock source (channel B = oscillator), then a ~1000-iter wait
   for the oscillator to start (:554-555). (Channel A = `$50`, baud-rate
   generator, :551.)
5. **Baud** (dcode 5, :740-751): `WR14 = $00` (BRG off) → `WR12 = TC_lo` →
   `WR13 = TC_hi` → `WR14 = openwr14` (channel B `= 1`, i.e. BRG on from the
   oscillator). The time constant is `TC = (temp DIV baud) − 2` with
   **`temp = 115200` for channel B** (125000 for channel A). Default at init is
   **1200 baud** (:564) → `TC = 94 = $005E`.
6. `WR10 = $00` — NRZ encoding (:568).
7. `WR3 = $C1` — Rx 8 bits/char, Rx enable (:570).
8. `WR5` — Tx enable + DTR (channel-B byte from :542/:572; a later `dcontrol`
   parity call sets `$A8` for B, "port B always has RTS off", :679).
9. `WR15 = $A0` — enable external/status interrupts on **Break** and **CTS**
   change (channel B; channel A = `$90`, Break + Sync) (:577).
10. `controlreg := $10` — reset ext/status latch (:580).
11. `RESTORE` writes `WR1 = $17` — enable Rx / Tx / status interrupts on the
    channel (:642, source-rsASM.TEXT.unix.txt:600-647).

### 11.4 Transmit-a-byte + "printer connected and ready" — SOURCE-DERIVED

`RSOUT`/`BYTEO` sends one byte (source-rsASM.TEXT.unix.txt:426-525):

1. Read **RR0** (bare control read) → status (:429).
2. `BTST #2` — **RR0 bit 2 = Tx Buffer Empty**. If clear, return (can't send
   yet) (:430-431).
3. If hardware handshake (`xmt_hs = hw_hs`): require `(RR0 & xmtrr0) == xmtrr0`
   **and** `(~RR0 & xmtzrr0) == xmtzrr0` (:448-457). For **channel B**
   `xmtrr0 = 0`, `xmtzrr0 = $20` (source-rs232.text.unix.txt:540, :720) — i.e.
   **RR0 bit 5 (CTS) must read 0** for transmit to proceed (the OS comment calls
   it "DSR'"; on the DB-25 the modem-control input the port gates on).
4. Write the byte to the **data** register `$FCD205` (:489); set `AWAIT_TX = $04`
   (:491).
5. Completion arrives as a **Level-6 Tx-empty interrupt** (RSINT, mover:827-849
   → rsASM DRIVER `XMIT`): `WR0 = $29` (reset Tx-int-pending + point WR1) →
   `WR1 = 0` → `WR0 = $38` (reset IUS) (source-rsASM.TEXT.unix.txt:98-103).

**M7 Task 4 — our interrupt model (SOURCE-DERIVED from the `XMIT` ISR, and
LIVE-VERIFIED).** The ISR (source-rsASM.TEXT.unix.txt:96-133) is the load-bearing
detail: only the **first** byte is sent by the polled `RSOUT` above; every
byte after that is sent from inside the Level-6 ISR, which does `WR0=$29`
(clear the Tx-empty latch), `WR1=0` (disable), `WR0=$38`, then `RSOUT` the
**next** byte *while Tx-int is disabled*, and finally `RESTORE` writes
`WR1=$17` to re-enable — at which point the still-set Tx-empty latch re-asserts
`/INT` for the following byte. So our SCC models the Tx-empty as a **level
latch, not an edge**: `SCC8530.writeData` sets `txInterruptPending` on *every*
data write (the host sink empties the buffer instantly), and
`SCCChannel.irqAsserted = txInterruptPending && WR1 bit1 && WR9 bit3 (MIE)`
gates the CPU assertion. `WR9=$4A` (the ch-B reset that dinit issues, §11.3
step 2) carries MIE (bit3) + NV (bit1); our channel reset preserves those mode
bits (`wr[9] = value & $3F`) since the driver never re-writes WR9. The final
ISR clears the latch (`WR0=$29`) and sends no further byte, so `/INT` drops and
there is **no interrupt storm** at end-of-transfer. **Live proof:** without
this wiring a LisaWrite print emitted exactly 1 byte on Serial B and stalled;
with it, the same print emitted 9229 bytes and produced a full page raster
(m7-print-01.png). Ext/status (CTS/DCD/Break) and Rx interrupts are **not**
modeled/asserted — nothing in the transmit-only printer path changes a modem
line or feeds the receiver.

**RR2 dispatch (SOURCE-DERIVED, load-bearing).** The Level-6 handler `RSINT`
does **not** know a priori which port/interrupt fired — it reads it from the
SCC. `RSINT` selects **RR2 on channel B**, reads it, masks **`$0E`** (bits
3-1), `LSR #1`, and splits: bit 3 → port (0 = B, 4 = A), bits 2-1 → interrupt
type (0 = Tx buffer empty, 1 = ext/status, 2 = Rx available, 3 = special Rx);
`INTPAR == 0` dispatches into `XMIT` (source-mover.text.unix.txt:824-848). RR2
is the Z8530 **modified interrupt vector**: on channel A it reads the base
vector `WR2` unmodified; on channel B it reads `WR2` with the highest-priority
pending interrupt's status in bits 3-1 (status-**low**, since the driver's
`dinit` leaves `WR9` bit 4 clear). Our SCC asserts Level 6 only for the
channel-B Tx-empty interrupt (status code `000`), so channel-B RR2 forces bits
3-1 to `000` and RSINT correctly decodes "port B, output interrupt." **Our
model programs RR2 explicitly** (`SCCChannel.rr2()`) rather than letting it fall
to the unknown-register default (which returned 0 — the same `$0E`-masked
value, so dispatch "worked," but undocumented, fragile to any fallback change,
and logging an unknown access on *every* interrupt, ~thousands of drops per
print). Ext/status and Rx status codes aren't modeled because those interrupts
never fire.

So the driver's notion of **"connected and ready to accept a byte"** is:
**RR0 bit 2 (Tx buffer empty) set**, and — under hardware handshake — **RR0 bit 5
(CTS) asserted**. It learns of CTS/DCD/Break transitions via the Level-6
external/status (modem-change) interrupt enabled by `WR15 = $A0`; the handler
re-reads RR0 for modem status (rsASM.TEXT.unix.txt:295-320). RR0 bit assignments
the driver relies on: bit0 = Rx char available, bit2 = Tx buffer empty,
bit3 = DCD, bit5 = CTS. Input errors are read from **RR1** (mask `$70` =
framing/overrun/parity, source-rsASM.TEXT.unix.txt:160-166). Software XON/XOFF
(`$11`/`$13`) is an alternate handshake selected by `dcontrol` dcode 3
(source-rs232.text.unix.txt:727-731); the printer's exact handshake (DSR-hardware
vs XON/XOFF vs CR/LF-delay) is a Preferences/`dcontrol` choice (dcodes 2/3/4,
:714-738), not fixed in the driver.

The higher-level printer path (`LIBS/LIBPR`) is a QuickDraw grafPort
(`LibPr-ciprint.text:190-191 OpenPort`); its byte output reaches Serial B through
the OS device manager → the RS-232 CD device for the built-in SCC (slot 10,
below), i.e. this same driver — not a second register path.

### 11.5 ROM POST SCC probe, and why the `0xFF` stub passes — OBSERVED

- The Rev H boot ROM touches the SCC exactly once during POST, at **`$FE10D0`**,
  via the **mirror `$FCD241`** (`= $FCD201 | $40`; bits 0-2 identical to
  channel-B control, bit 6 undecoded → same register). OBSERVED live at
  cyc ≈ 692674: `R $FCD241=$FF`, then the table-driven write sequence
  **`$02,$00,$09,$C0,$05,$82`** (`move.b (A2)+,(A0)`), then `R $FCD241=$FF`.
  Decoded: `WR2=$00` (int vector), `WR9=$C0` (**force hardware reset**, both
  channels), `WR5=$82` (DTR + RTS asserted). It is **write-mostly**; the two RR0
  reads are **not value-compared**.
- The probe is **bus-error-guarded**: the ROM installs a bus-error handler at
  `$FE100C` before the access; the *only* failure path is a **bus timeout**
  (device absent), which loads boot error `$37`/`$38` and sets a soft-fail bit in
  D7, then continues POST (docs/rom-trace-notes.md:289-299, 722-732 —
  `cmpa.l #$fcd241,A0` at `$FE10EE`). POST is **non-fatal** on failure and never
  compares register values.
- **Why `0xFF` passes:** "present" means "the address ACKs the cycle without a
  bus error." Our dispatcher answers `$FCD241` (like all of `$FCD2xx`) with the
  generic unmapped-I/O default `0xFF` (IODispatcher.swift:316-332 — there is **no
  dedicated SCC case**; the M1b "$D241 candidate SCC / 0xFF stub passes" note is
  hereby confirmed, not merely candidate). A normal `$FF` read is a completed bus
  cycle, so no bus error fires, no `$37/$38`, no fail bit — the SCC reads as
  present and POST proceeds. **What the real device must return to keep POST
  passing: nothing specific — merely ACK the bus cycles.** (Value semantics
  matter only to the OS driver and to Task 2's transmit path, not to POST.)
- **OBSERVED boot-to-desktop:** the OS then runs the §11.3 `dinit` against
  **channel A** (`$FCD203`) at cyc ≈ 53.1M — full WR sequence
  `WR9=$8A, WR4=$44, WR11=$50, WR14=$00, WR12=$0B/WR13=$00` (TC 11 ⇒ ≈9600 baud,
  channel-A console default), `WR14=$03, WR10=$00, WR3=$C1, WR5=$EA, WR15=$00,
  WR1=$00` — exactly the register discipline of §11.2-11.3. **Channel B
  (`$FCD201`) is never initialized on the no-Preferences boot path** (no
  Serial-B device is configured — see §11.6). 29 SCC accesses total to the
  desktop; all absorbed by the `0xFF` stub with no fault, no halt. The stub is
  sufficient for boot; a real Z8530 is only needed to actually *move bytes*
  (Task 2).

### 11.6 Parameter memory (PM) — where it lives, and persistence — SOURCE-DERIVED + OBSERVED

**Where PM physically lives (SOURCE-DERIVED).** The 64 bytes of parameter memory
live in the **disk-controller (6504 / Sony-IOB) shared static RAM**, *not* in a
battery-backed NVRAM:

- `PMEMAD = TWIGBAS + $180 = IOMMU + $0C000 + $180 = $FCC180`
  (source-mover.text.unix.txt:42, :17).
- `W_PARAM_MEM` writes the 64 bytes with `MOVEP.L D0,1(A2)` stepping A2 by 8 —
  i.e. to the **odd** byte lanes `$FCC181, $FCC183, … $FCC1FF`
  (source-mover.text.unix.txt:617-633), the classic 6504-shared-RAM byte layout.
  It only writes when the disk is idle (source-twiggy.text.unix.txt:226-264,
  gated on the `$FCD801` diag bit).
- PM layout (source-PMEM.TEXT.unix.txt:29-49): version/timestamp, screen/beep/
  mouse prefs, `pm_cdCount` (byte 9), **`pm_DevConfig` (bytes 10-59)** — the
  device-connection table the Preferences serial-B printer entry would occupy —
  and a checksum (bytes 62-63). The built-in SCC **card** is CD position
  **(slot 10, chan 0, dev 0)** — the single auto-generated entry `GetNxtConfig`
  emits for it (source-PMEM.TEXT.unix.txt:267-276) — and `PutNxtConfig`
  **refuses to store any config record at exactly `(slot=10, chan=0)`**
  (source-PMEM.TEXT.unix.txt:445, the `(pos.slot=10) and (pos.chan=0)` guard),
  because that coordinate is the built-in port itself, rebuilt from scratch every
  boot. So a configurable Serial-B **printer** record is **not** keyed on
  `(10, 0)`. What *is* source-certain about how Serial B is distinguished: the SCC
  driver splits the two channels by **`iochannel`** — `iochannel = 0` → channel
  **B**, non-zero → channel **A** (SOURCE-SERCARD.TEXT.unix.txt:151) — and CD sets
  `iochannel := chan` from the device's position channel (SOURCE-CD.TEXT.unix.txt:741,
  `chan_offset = $800` per channel at :521-527). The exact `(slot, chan, dev)`
  triple the Preferences "Device Connections" tool assigns a Serial-B printer —
  and precisely how it clears the `(10,0)` guard (a non-zero `chan`/`dev` on the
  SCC card, or a distinct pseudo-slot) — is **not** unambiguously derivable from
  SERCARD/CD/PMEM alone (it lives in the Preferences tool's CD-building logic, not
  in these units). **Flagged as a Task-4 live-verification point**: capture the
  actual `pm_DevConfig` bytes a live "printer on Serial B" save produces and read
  back the stored position, rather than asserting a channel number here.

**Persistence on real hardware is the disk snapshot, not NVRAM (SOURCE-DERIVED).**
`Write_PMem` does **two** things: `Paramem_Write` (→ the volatile `$FCC181`
shared RAM) **and** `PMSnapshot` (→ a copy on the boot volume)
(source-PMEM.TEXT.unix.txt:156-157). At boot, `INIT_CDS` calls `READ_PMEM`
(SOURCE-CD.TEXT.unix.txt:1758) and `pmem_state` reconciles the RAM copy against
the disk snapshot (`PMg_SSg / PMb_SSg / …`, source-PMEM.TEXT.unix.txt:207-214).
The shared RAM survives a warm reset but is lost on power-off; **true
cross-power-cycle persistence is the boot-volume snapshot.**

**Our machine today (OBSERVED).**
- `$FCC180` falls inside the FloppyController's `$FCC000-$FCC7FF` shared-RAM
  window, so PM writes **are** backed (IODispatcher.swift:315/365 → `floppy.window`).
  Verified: writing `$A0…` to `$FCC181,$183,…` reads back; at power-on the region
  reads `$00` (window zero-init, FloppyController.swift:269).
- **`reset()` wipes PM.** `Machine.reset()` calls `bus.floppy.reset()`
  (Machine.swift:163), which **zeroes the whole window**
  (FloppyController.swift:495-496). Verified: `$A0…` → all `$00` after `reset()`.
  A soft power-**off** (`powerState = .off` via the COPS power-off handler,
  Machine.swift:105-107) does **not** call `reset()`, so PM survives *in memory*
  while powered off — but the next power-**on** is a `reset()`, so **PM does NOT
  survive a full off→on cycle** on our machine.
- On the live boot, `INIT_CDS` read PM **196 times, all `$00`** (empty/zeroed),
  and made **no** PM writes — so the OS built only the built-in devices and
  never a Serial-B printer CD. This is exactly why channel B is never inited
  (§11.5): no PM config ⇒ no Serial-B device ⇒ no `dinit`.

**Would a Preferences Serial-B printer config survive? — VERDICT.**
- Saving it triggers `Write_PMem` → `Paramem_Write` (lands in `floppy.window`,
  volatile) **+** `PMSnapshot` (a **disk** write). Our disk writes are
  **write-through-persistent** to the backing file (WidgetImage.swift:20-24, :176),
  so the snapshot path *already works in principle*. If the same Widget image is
  reused across boots, `READ_PMEM`/`INIT_CDS` would reload the config and rebuild
  the Serial-B CD — with `pmem_state` taking the `PMb_SSg` (RAM-bad, snapshot-good)
  fallback, which is faithful to a real Lisa after power loss.
- **Two gaps for M7 in practice:** (1) our boot harness runs from a **fresh /tmp
  copy** each time, so no snapshot survives between runs by construction; (2) the
  config also needs Task 2's real SCC (so the port opens) and the printer CD to
  be creatable.
- **Cost estimate to make PM persist:**
  - *Cheapest / most faithful (≈0 new code):* reuse one Widget image across boots
    and let the existing `PMSnapshot`/`READ_PMEM` disk path do the work — a
    harness/policy choice, already functional via write-through.
  - *Model battery-like RAM survival (small, ~20-40 lines):* carve the 64 PM bytes
    (`$180-$1FF`, odd lanes) out of `FloppyController.reset()`'s blanket zero, and
    optionally load/save that 64-byte slice to a host file at power-on/off so it
    survives an emulator restart without a disk round-trip.
  - *Full fidelity (medium):* also model the `pmem_state` checksum/snapshot
    reconciliation so RAM-vs-disk divergence behaves exactly as `SOURCE-PMEM`
    describes. Not needed for a working printer config; only for edge-case parity.

**M7 Task 4 — LIVE-VERIFIED (closes the Task-4 verification point above).**
Driving the real Preferences → **Connect Devices** flow live: the device list
for a serial connector is `Nothing / Serial Cable / Modem A / Imagewriter · ‖
DMP / Daisy Wheel Printer`; selecting **Serial B Connector → Imagewriter / ‖
DMP** attaches the dot-matrix printer, and **Set Aside** (which calls
`Write_PMem`) persists it. **Persistence works via the disk snapshot with ZERO
new emulator code:** a *fresh boot of the same Widget image* (a full power
cycle — new process, fresh `Machine.reset()` that zeroes shared-RAM PM) still
shows "Serial B Connector — Imagewriter / ‖ DMP", because `INIT_CDS`/`READ_PMEM`
reload the config from the `PMSnapshot` written to the write-through Widget and
`pmem_state` takes the RAM-bad/snapshot-good (`PMb_SSg`) path. This is the
"reuse image across boots" outcome (≈0 code) predicted above, now confirmed.
**Verdict on the PM-sparing `reset()` fix: NOT required** — neither for the
headless `lisadbg` flow (separate-process reboot re-reads the disk) nor, by the
same `pmem_state` reconciliation, for the app's warm `reset()` (RAM PM zeroes,
disk snapshot survives on the attached Widget, `READ_PMEM` rebuilds). The
faithful match to real hardware (which also loses battery-less shared-RAM PM on
power loss and rebuilds from the boot-volume snapshot) is exactly this
zero-code behavior, so the fix is deliberately **not** taken. The one standing
limitation: a config made against a *floppy*-only or *non-write-through* boot
volume would not persist; our Widget is write-through (§10.10), so it does.
The exact `pm_DevConfig` bytes were observed as a CDS-style table on the odd
lanes from `$FCC181` (record-separated by `$F8` markers, e.g. `$FCC183=04`,
`…95=1E $97=F8 …`); a precise (slot,chan,dev) decode was not pinned because the
monitor's CPU-context read of `$FCC180` is domain-dependent (reads cleanly only
when the current context maps the disk-controller window) — the load-bearing,
reproducible fact is the **round-trip**: the config the Preferences UI writes
survives a power cycle and re-enables channel B, which the live print proves
end to end.


## 12. ImageWriter escape contract (as ciprint emits it) — M7 Task 3

This is the *wire contract* the Lisa OS's C.Itoh/ImageWriter driver actually
puts on Serial-B, derived end-to-end from the driver source, **not** from a
printer manual. `LibPr/CiDev` (`LibPr-cidev.text.unix.txt`) is the byte-level
device layer — every escape sequence the printer ever sees is emitted by a
`CiOut` in that unit — and `LibPr/CiProcs` + `LibPr/CiGlobals` supply the
resolution/geometry choices above it. Citations are `file:line` into
`~/Development/Lisa_Source/LISA_OS/LIBS/LIBPR/`. Where a public
ImageWriter/C.Itoh 8510 reference disagrees, **the driver source wins** and the
divergence is noted.

### 12.1 Control bytes and the command alphabet
Non-command control bytes (CiDev:103):
`LF = 10`, `SO = 14`, `SI = 15`, `CAN = 24`, `ESC = 27`.

Every command below is `ESC` followed by one command byte (and, where noted,
ASCII decimal-digit operands or raw data), **except `SO`/`SI` which carry no
`ESC`** (CiDev:114, `CiSetWide` CiDev:641-645). Command-byte table verbatim from
CiDev:106-126:

| Sequence | Meaning | Operands | Emitter (CiDev) |
|---|---|---|---|
| `ESC 'T' d d` | set line-feed pitch (line height) | 2 ASCII digits, 144ths of an inch, max 99 (`cLFMax`) | `CiSetLineHt` :618-625 |
| `ESC 'G' d d d d` | **standard** bit-image graphics | 4 ASCII digits = column count `N`, then `N` data bytes | `CiPrGraf` :508-530 |
| `ESC 'g' d d d` | **fast** bit-image graphics | 3 ASCII digits = `N/8`, then `N` data bytes (`N` = digits×8) | `CiPrGraf` :508-530 |
| `ESC 'F' d d d d` | horizontal tab / absolute column | 4 ASCII digits = dot column from left | `CiPrTab` :532-538 |
| `ESC 'f'` / `ESC 'r'` | line-feed direction forward / reverse | — | `CiSetLFFwd` :610-616 |
| `ESC '<'` / `ESC '>'` | bidirectional / unidirectional print | — | `CiSetBiDir` :560-565 |
| `ESC 'o'` / `ESC 'O'` | paper-empty stop / override | — | `CiSetPEStop` :627-632 |
| `ESC '!'` / `ESC '"'` | emphasized (1/160" smear) on / off | — | `CiSetEmph` :598-603 |
| `SO` / `SI` (no ESC) | elongated (horizontal bit-double) on / off | — | `CiSetWide` :641-645 |
| `ESC 'X'` / `ESC 'Y'` | underline on / off | — | `CiSetUL` :634-639 |
| `ESC 'n' N E q Q p P` | set horizontal density (bpi) — see 12.2 | — | `CiSetBpi` :567-581 |
| `ESC 'Z' b1 b2` | open DIP switches (country) | 2 raw mask bytes | `CiSetCntry` :583-596 |
| `ESC 'D' b1 b2` | close DIP switches (country) | 2 raw mask bytes | `CiSetCntry` :583-596 |
| `ESC 'c'` | reset printer to power-on state | — | `CiDevClose` :253-255 |
| `LF` (bare) | advance paper by current line height | — | `CiBindV` :184 |
| `CAN` | abort a partial graphics line | — | `CiDevOpen` :272 |

`cmRun = 'V'` (CiDev:109) is **declared but never emitted** by this driver
(grep-confirmed: the only `'V'` reference is the constant declaration). Public
references list `ESC 'V'` as a repeated-graphics command; the Lisa path does not
use it, so the interpreter treats `ESC V` as unknown (bounded-log, no-op).

There is **no `FF` (0x0C)** anywhere in the C.Itoh path (grep-confirmed; only the
unrelated DaisyWheel driver defines `FF`). **Page ejection is done entirely by
line feeds**, not a form-feed byte — see 12.4.

### 12.2 Horizontal density (bpi) codes
`CiSetBpi` (CiDev:567-581) maps the internal `TTybpi` enum to one command byte
each (CiDev:117-118):

| Code | bpi | Code | bpi |
|---|---|---|---|
| `ESC 'n'` | 72 | `ESC 'q'` | 120 |
| `ESC 'N'` | 80 | `ESC 'Q'` | 136 |
| `ESC 'E'` | 96 | `ESC 'p'` | 144 |
| | | `ESC 'P'` | 160 |

Max columns per scan at a given bpi = `8 × bpi` (`CiMaxBits`/`CiHRes`
CiDev:355-377), i.e. an **8-inch** printable width at every density
(72→576, 96→768, 144→1152, 160→1280 dots; these are the `cNNNBits` constants,
CiGlobals:60-61). `CiDevOpen` initialises the printer to **96 bpi** (`tybpi96`,
CiDev:277); the real print path then re-commands the density **per band** inside
`CiPrBand` (`CiSetBpi(tybpi)` CiDev:435).

### 12.3 Which density the OS actually uses
`CiProcs.CiOpen` picks the band `tybpi`/`tyspi` once per job (CiProcs:531-546),
and `CiMetrics` derives the page geometry from it (CiProcs:402-509). All four
raster modes (paper page length is **always 11 in / 144ths**, independent of
orientation — CiProcs:548-549):

| Mode | H bpi | V spi | printable width | code emitted |
|---|---|---|---|---|
| Portrait Hi-Res | **160** | **144** | 1280 dots (`c160Bits`) | `ESC 'P'` |
| Portrait Lo-Res | 96 | 72 | 768 dots (`c96Bits`) | `ESC 'E'` |
| Landscape Hi-Res | 144 | 144 | 1152 dots (`c144Bits`) | `ESC 'p'` |
| Landscape Lo-Res | 96 | 144 | 768 dots (`c96Bits`) | `ESC 'E'` |

(CiProcs:408-421, :439-452, :531-546. `prPgFract = 120`, PrStdInfo:81, is the
PgSize unit — US Letter = 1020×1320 of those; e.g. Portrait Hi-Res paper width
= `1020×160/120 = 1360` dots, **clamped to the 1280-dot platen** `rPrintable`,
CiProcs:429-433.)

The WYSIWYG office path prints **purely as graphics** (`ESC G`/`ESC g` bands);
QuickDraw text is rasterised into the band bitmap upstream (`PrStdText` bottleneck,
CiPrint:197) and reaches CiDev already as dots. `CiPrText` (CiDev:540-558) emits
**raw text bytes** *only* in **draft mode** (`CiPrMode.Draft`, CiProcs:306), where
the driver leans on the printer's own ROM font (plus per-country DIP-switch
swaps, `CiEuropeanOut` CiDev:310-348). Our interpreter therefore models graphics
as the primary path; text bytes are handled defensively via a synthetic dot font
(see 12.6).

### 12.4 Graphics band format (`ESC G` / `ESC g`)
`CiPrGraf` (CiDev:508-530):
- **Standard** (`ESC 'G'`): operand = **4 ASCII decimal digits** = `cBits` =
  the number of dot **columns** `N` (`cDigits = 4`, `cNumber = cBits`), then
  `CiBlockOut(p, cBits)` sends exactly `N` **data bytes** — one byte per column.
- **Fast** (`ESC 'g'`): operand = **3 ASCII decimal digits** = `cBits DIV 8`
  (`cDigits = 3`, `cNumber = cBits DIV 8`), then `N = digits×8` data bytes.
  `CiPrBand` rounds `cBits` up to a multiple of 8 before calling
  (CiDev:440-441). Fast graphics is selected whenever the port is the built-in
  Serial A/B (`fFastGraf := (port=PortA) OR (port=PortB)`, CiProcs:519) — i.e.
  **the real Lisa serial printer uses `ESC g`**; `ESC G` is the parallel/slow path.

Each data byte is one **column of 8 vertical dots** (the band is 8 scanlines
tall; "Bit" runs along the scan = horizontal, "Scan" = vertical, CiDev:16-19).
**Bit-within-byte order (top vs bottom pin) is NOT visible in the Pascal** — the
byte columns are produced by the external assembly `PrVBand`/`PrHBand`
(CiDev:154-155), so it was a documented **modeling decision** in the interpreter
~~(we take bit 7 = top dot)~~ **[CORRECTED — M7 Task 4 fix round 3: bit 0 =
top dot (LSB-top), settled empirically — see §12.6 decision 2.]** `CiPrBand` white-space-trims each band left and right
and emits a leading `ESC 'F'` tab for the trimmed left margin (CiDev:419-448),
so real streams interleave `ESC F` + short `ESC g` runs rather than one
full-width band.

### 12.5 Vertical positioning, line feeds, and page breaks
There is **no absolute vertical command**; all vertical motion is relative LFs
metered by the line-height pitch (`CiBindV` is "the only place emitting LFs",
CiDev:164-197):
- Vertical position is tracked in **144ths of an inch**. To move down `Δ`:
  set direction (`ESC f`), and if `Δ > 99` emit `ESC 'T' 99` + `LF` repeatedly,
  then `ESC 'T' (Δ mod 99)` + `LF` (CiDev:176-184).
- Reverse motion sets `ESC r`, moves up, then **"burps"** a small forward LF
  (`cBurp144ths = 24`, CiDev:123, :191-195) to take up gear lash.
- Graphics bands advance vertically via `CiDeltaV` after each band: at 144 spi
  the two interlaced half-bands advance **1** then **15** (=16/144" per 16
  interlaced dots ⇒ 144 dpi), at 72 spi a band advances **16** (=16/144" per 8
  dots ⇒ 72 dpi) (CiDev:468-476, :492-502).

**Page eject** (`CiNewPage`, CiDev:379-395): `CiGotoV(cPg144ths + gap)` then
`CiBindV` LFs the paper to the next page top; `CiBindV` wraps the position
`cAct144ths := cCur144ths MOD cPg144ths` (CiDev:187). So **crossing the page
length in the LF accumulator IS the form feed** — there is no distinct eject
byte. `cPg144ths` defaults to `144×11 = 1584` (CiDev:276) and is reset from the
real `PgSize.Height` in `CiOpen` (CiProcs:549). The gap `cCiGap144ths = 80`
(≈0.55", CiGlobals:64) is the roller-to-printhead offset.

### 12.6 Interpreter modeling decisions (ours, documented)
The `ImageWriterInterpreter` implements 12.1-12.5 faithfully; the following are
choices where the source is silent or where we deliberately simplify. None
affect the byte-level command parsing:
1. **Fixed page geometry from a `Config`** (default = Portrait Hi-Res:
   1280×1584 dots at 160×144 dpi). The commanded density (12.2) is tracked and
   used for the emitted page's `dpi.h`, and disagreement with the canvas is
   bounded-logged; the canvas grid itself is fixed per page. Lo-Res preset =
   768×792 at 96×72. (Real jobs command one density before any ink, CiOpen:531,
   so no mid-page resize is needed.)
2. ~~**Bit 7 = top dot** within each graphics column byte (see 12.4 — not
   recoverable from the Pascal source).~~ **[CORRECTED — M7 Task 4 fix
   round 3.]** **Bit 0 = top dot** (LSB-top, the C.Itoh 8510 graphics-byte
   convention). Not recoverable from the Pascal (12.4), but settled
   **empirically** against the captured live LisaWrite stream
   (`m7-print-raw-stream.bin`): hand-decoding shows a normal 144-spi
   interlace (band pairs at 144ths 64/65, 80/81, 96/97, 112/113 —
   `ESC T 01`/`ESC T 15` advances exactly per 12.5), and re-rendering the
   pass bytes under both bit orders shows LSB-top yields a **single clean
   text line** ("This is a test of the lisa write application", inked rows
   72–116) while the old MSB-top guess vertically mirrors each 8-pin pass
   inside its 16/144 band window, scrambling the interlace into **two
   stacked garbled copies** — exactly the doubling observed in
   `m7-print-01.png`/`m7-print-02-interlace-corrected.png`. Pinned by
   `standardGraphicsColumnBitOrderTopIsBit0` and
   `capturedStreamSkeletonPlacesAscenderAtTopNotMirroredToBottom` (a
   synthetic-ink reconstruction of the capture's exact command skeleton);
   render evidence: `m7-print-03-full-page.png` /
   `m7-print-03-single-text-crop.png`.
3. **Vertical grid = the config's V dpi**, driven by the 144ths accumulator.
   ~~Interlace half-band advances (1/15) land on adjacent rows rather than
   physically interleaved passes — a raster-fidelity simplification, not a
   parsing one.~~ **[CORRECTED — M7 Task 4 fix round 2.]** The simplification
   made the two 144-spi half-bands **overlap** instead of interleave (a
   within-band "comb"): the head is a **72-dpi 8-pin column**, so a pin `p` sits
   `2/144"` below the band origin — its 144ths vertical position is
   **`y144 + 2·p`**, canvas row `(y144 + 2·p) × dpiV ÷ 144`. The driver
   (`CiPrBMVert`, LibPr-cidev:484-502) splits each hi-res band into two passes
   via `PrHBand`/`PrVBand` (every-other source scanline) and prints them
   `advance-1-then-15` (CiDeltaV, §12.5); with `2·p` pitch the two passes'
   pins interleave (`row y, y+1, y+2, …`) into a solid 144-dpi stroke. At 72 spi
   a single band's pins map through `dpiV=72` to consecutive rows (LO-res raster
   unchanged). The old `y144 + p` mapping put the passes 1/144 apart so they
   overlapped (rows 0..7 then 1..8). Pinned by
   `interlacedHalfBandsProduceASolidVerticalStroke` (16 contiguous inked rows)
   and the moved hi-res golden FNVs.

   > ~~**SCOPE (honest).** This corrects the *within-band* interlace geometry
   > only. The **whole-line vertical doubling** a user reported on a live
   > LisaWrite print (the text appearing as two stacked copies, ~2× the screen
   > height) is **NOT** this geometry and is not fixed by it: raw-stream capture
   > (`lisadbg --printer-raw`) shows the OS emits the text region as a single
   > 64-scanline `CiPrBMVert` block (8 interleaved sub-bands, print rows
   > 64-127) whose upper and lower 32-scanline halves are **different** rasters
   > (~3% aligned overlap) yet each read as the full line — i.e. the emitted
   > raster is ~2× the screen height. That duplication is **upstream** of the
   > `ImageWriterInterpreter` (the QuickDraw print-spool/banding path), which
   > renders the wire bytes faithfully. Flagged for a separate investigation.~~
   >
   > **[REFUTED — M7 Task 4 fix round 3.]** The "upstream duplication" was a
   > misreading of a stream rendered with the **wrong bit order** (decision 2):
   > MSB-top mirrors every 8-pin pass vertically inside its band, so the one
   > emitted text line *looked like* two different 32-scanline copies. The wire
   > content is a single, correctly-interlaced line (~45 print rows, not 2×
   > screen height — "64 scanlines" was the band-pair envelope 64–127, most of
   > it blank); under LSB-top the captured stream renders as one solid line.
   > Nothing is wrong upstream; no OS/QuickDraw involvement.
4. **Page emission triggers**: (a) the LF accumulator forward-crossing the page
   length (the real form-feed mechanism, 12.5); (b) `flush()` for an
   end-of-stream partial page; (c) `ESC c` reset flushes any dirty page. A bare
   `FF` (0x0C), which this driver never emits, is honored defensively as an
   explicit eject.
5. **Text bytes** (draft-mode raw ASCII, 12.3) render through a small **synthetic
   5×7 dot font that is ours** (committed fixture — Lisa fonts are never
   extracted), advancing the horizontal cursor per glyph.
6. **Unknown / unmodeled codes** (including `ESC V`, malformed digit runs,
   stray control bytes) are **bounded-logged and no-op'd, never fatal**
   (house pattern: a capped log array + a dropped counter, per `Bus.mmuPortLog`).

## §13 — The PFG (Programmable Frequency Generator)

**Optional third-party hardware, not part of a stock Lisa.** Modeled by
`PFG`, off by default (`SCC8530.pfg == nil`); `lisadbg --pfg`, or the
LisaApp Machine menu's "PFG Installed (SCC socket)".

### What it is

A board that **plugs into the Z8530 SCC socket** (9D on the I/O board), with
two flying leads to an LS132 at 6A. It provides real-time adjustment of the
floppy controller's bit-cell timing under software control, letting a Lisa
read Macintosh diskettes written with **3 bytes of bit-slip `$FF`** where the
Lisa's controller expects 5. **MacWorks Plus II 2.5 requires one and will not
boot without it.** No public technical documentation exists — the MacWorks
Plus II manual covers installation only — so everything below is derived from
the guest's own code and a live trace.

### Electrical seam

| Direction | Path |
|---|---|
| Host → PFG | SCC **channel A `WR7`** (`$FCD203`), the SDLC sync-character register |
| PFG → host | SCC **channel B `RR0` bit 3** (`$FCD201`), the DCD modem input |

`WR7` is the natural command port for a board in this socket: the Lisa's own
RS-232 driver never programs WR6/WR7, which is why `SCCChannel`'s
`modeledWriteRegisters` deliberately omits them.

### Identity handshake (MODELED — evidence: live `iot` trace + guest code)

Guest sites: writer `$023D7C`, sampler `$023E78`, boot gate `$423A96`.
Byte-identical in 2.5.0 and 2.5.3.

```text
setup   ch-A: read (reset pointer), WR9 <- $0D, WR7 <- $50, WR9 <- $09
        ch-B: read RR0, WR15 read, WR15 <- $00

8 iterations, addr stepping $10, $12, $14 ... $1E:
        ch-A: WR7 <- $00
        ch-A: WR7 <- addr      -> selects a bit pair
        ch-B: read RR0         -> bit, from DCD
        ch-A: WR7 <- $08       -> second phase
        ch-B: read RR0         -> bit, from DCD
```

16 bits, shifted MSB-first (`lsl.l #1,D1` + `ori.b #1,D1` when DCD is high).
Iteration `k` supplies bits `15-2k` and `14-2k`. The guest requires the
result's **low nibble to be `$A`** — `andi.w #$f` / `subi.w #$a`, applied
both at the probe and again at the boot gate `$423A96`, which is a literal
`beq`-to-itself spin on failure.

**Only the low nibble is evidenced.** `PFG.identity` defaults to `$000A`, the
minimal assumption; the upper 12 bits have never been observed being tested.

### The three real functions (user-supplied field report, 2026-08-16)

A first-hand account of the hardware, which reframes two things this section
previously got wrong. Recorded as provenance: a field report, not a datasheet.

1. **Floppy controller clock.** The Lisa clocks its FDC at 2 MHz; the PFG
   injects its own clock into **U6A via the two clip leads**, varying it
   slightly above/below 2 MHz *under MW+II software control*, which is what
   lets it read Mac disks the stock clock cannot. **A PFG works with the
   clips disconnected** -- you get a startup warning and lose the
   disk-reading improvement, nothing more. Inert under any other OS, since
   only MW+II ever asks for a change.
2. **256 bytes of PRAM in an on-board EEPROM** (the 8-pin chip). The stock
   Lisa has almost none -- it borrows leftover space in the floppy
   controller's shared RAM, and loses it when the I/O board batteries die.
   The PFG's is non-volatile and much larger, and **this is where MW+II keeps
   its startup configuration** (XLerator present/mode, etc.). Inert under
   other OSes.
3. **SCC clock 4 MHz -> 3.672 MHz** (the Mac Plus rate), for serial-port
   compatibility. **Unlike the other two this is always active, even under
   other operating systems** -- the one way a fitted PFG perturbs a
   non-MacWorks machine. No reported ill effects. We model no SCC baud clock
   at all, so it has no effect here; noted for fidelity.

**Consequences for this model.** Our PFG is, permanently and by
construction, *a PFG with the clips disconnected*: `FloppyController` is an
HLE that serves whole 512-byte blocks and never synthesizes a bit stream, so
there is no 2 MHz clock to vary and function 1 cannot exist here. MacWorks
Plus II's `TIMEOUT WAITING FOR FDC - CHECK PFG CLIPS` and `PFG CANNOT
CONTROL FDC - CHECK PFG CLIPS` are therefore **correct, expected output for
the configuration we present**, not defects to suppress. Function 2 (the
EEPROM) is the one with real work behind it -- see below. Function 3 is a
no-op for us.

### Configuration write stream (OBSERVED, NOT MODELED)

After a successful identity read the guest opens again (`WR7 <- $50`) and
then bit-bangs a serial write, captured as ~74,000 `WR7` writes in a single
boot:

| Byte | bit 3 (clock) | bit 1 (data) |
|---|---|---|
| `$04` | low | 0 |
| `$0C` | **high** | 0 |
| `$06` | low | 1 |
| `$0E` | **high** | 1 |

Bit 2 stays asserted throughout. `PFG` accepts and logs these with **no
modeled effect**, which is deliberate on two grounds: the real device's
function is retiming the floppy bit clock, and `FloppyController` is an HLE
that serves whole 512-byte blocks and never synthesizes a bit stream — there
is no frequency here to generate; and the register semantics behind the
stream are not evidenced, so modeling them would be invention.

**There is a read-back path we do not model.** The guest contains **8**
`btst #3,$00FCD201` sites (`$023E9C`/`$023EB2` are the identity sampler's
two; four more live in a second copy inside the later-loaded payload), so
DCD is consulted well beyond the identity exchange.

### Status

With the PFG installed, MacWorks Plus II 2.5.0 clears the `$423AA2` boot gate
that otherwise spins forever, and proceeds into code never previously
reached. It then reaches a **Sad Mac, code `000014`**. Whether that is caused
by the unmodeled EEPROM/read-back path, by the guessed upper identity bits,
or by something downstream is **not yet established** -- though the PRAM
hypothesis above is the leading candidate.

**We model a presence/identity responder, not a frequency generator.** Do not
read more into `PFG` than that.
