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
- While SETUP is on, SORG/SLIM writes program the inactive domain's registers without disturbing live translation
- Sequence (per do_an_mmu): toggle setupoff → interrupt-window → setupon per write (LDASM:387-394)

### Domain Context Latches

Source: OS/source-starasm1.text.unix.txt:232-258 (SET_DOMAIN), LDASM:145-151
- ctbit1on = $FCE00A
- ctbit1off = $FCE008
- ctbit2on = $FCE00E
- ctbit2off = $FCE00C
- Behavior: Access-triggered like SetUp; 2 bits encode domains 0..3

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
- StatusRegister bit 2: vertical retrace pending
- VRIRENB (V-Retrace Interrupt Enable): $E01A + IOMMU
- VRIRDIS (V-Retrace Interrupt Disable): $E018 + IOMMU

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

### VIA1 Function

Source: libhw-DRIVERS:578-588, 595-596

- **Timer1:** System millisecond tick
  - Pre-Pepsi reload: $CA/$27
  - Post-Pepsi reload: $7B/$63
- **Ports:** Drive contrast DAC and disk-enable signals
- **Shift Register:** Used for alarm interrupts
- **Interrupt Level:** 1 (IRQ)

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

**State 3:** Receive 5 clock bytes (after $E0-$EF seen in state 4) → update ClockHigh/ClockLow

**State 4 (reset dispatch):**
- $00-$DF: keyboard ID
- $E0-$EF: clock start (year nibble = low 4 bits)
- $F0-$FA: reserved
- $FB: power button (synthesized as key $08 down/up)
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

## 5. Interrupts

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
- **Bit 2 (low byte):** Vertical sync pending

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

**Power Commands:**
- $20: Power off (timer off, clock off)
- $21: Power off (timer off, clock on)
- $23: Power off, reboot later
- $2D: Disable timer enable, set clock for reboot alarm
- $25: Enable clock, disable timer

**Shutdown Sequence:**
- PowerDown/PowerCycle dims contrast to 255
- Reads clock (validate or use $0FFF sentinel if unset)
- Sends COPS power-off command

**Power Button:**
- Synthesized by COPS as reset-code $FB
- Dispatched as key $08 down/up event

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
  - `$41` DISKIN (nonzero=disk present; Sony)
  - `$5F` DISKSTAT (interrupt/status)
  - `$95` DISKCS (checksum err count; mover says `TWIGCS=$BB`!)
  - `$B9` DISKB2
  - `$FB` CMDINDEX (+0/+2/+A = prev cmd/parm/trak save)
  - `$180` PMEMAD (64-byte parameter memory mirror)
  - `$3E8` DISKHDR (12-byte packed tag)
  - `$400` DISKDATA (512-byte sector buffer)

**AMBIGUITY (a):** FINISH_READ/START_WRITE treat DISKDATA+1024 as the END of
a 512-byte transfer (SONYASM:221-231,323-326) → live data may sit at
`$600`-`$7FF`, not `$400`-`$5FF`. Settle from ROM disassembly (Task 5).

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
- **Completion:** interrupt-generating commands return immediately
  (`response := waitint`); completion arrives as a hardware interrupt
  (SONYASM:136-157).
- **Errors:** DISKERR + 1800 = OS error (`ADDI.W #1800` —
  SONYASM:127-131,396-400). not_issued=1809 (driver resends the packet —
  twiggy:1520-1525), vererr=1821, read_err=1823, write_err=1824
  (SONY.TEXT:39-42).

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
- **DISKIN (`$41`)** polled at driver init via ISDISKIN (SONYASM:437-441).
- **disk_control idle bit — AMBIGUITY (b):** bit 6 of a byte at `$FCD901`
  (LDEQU:47, boot ROM wait_drv LDTWIG:174-186) vs `$FCD801` (twiggy:258
  computes `iospacemmu*$20000+$0D801`). In-source contradiction; settle from
  ROM disassembly (Task 5). NOTE: `$FCD901` is ALSO our ROM-established
  VIA1 base (§3) — plausibly the same address serving double duty (VIA1
  port bit), which would resolve the contradiction in favor of `$D901`.

### Boot Path

- **Boot-device byte:** absolute `$1B3` (adr_bootdev — STARTUP:198;
  LDEQU:44). `$1B2` separately used by PROF for interleave choice
  (PROF:60-68).
- **FIND_BOOT decode** (STARTUP:1297-1393): bootdev 1 = internal Sony
  (2/10-class); 0 = internal hard disk (Pepsi) or upper Twiggy; 2 =
  parallel-port ProFile; 3-14 slots.
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

### Board IDs

- `$FCC031` (DiskROMId/adr_machinfo): bit7 = Pepsi-class; bit5 (when bit7)
  = LisaLite slow-timer variant (LIBHW-DRIVERS:578-588; changelog :54).
  iomodel decode (STARTUP:1876-1891): ≥0 → iob_lisa; `[$A0,$BF]` →
  iob_sony; `[$C0,$DF]` → iob_lite; else check `$FCC015` (adr_intdisk):
  0=twiggy, 1=single-sided Sony, 2=double-sided Sony (STARTUP:1747-1748)
  → iob_twiggy/iob_pepsi.
- **Current emulator stubs:** `$C031`=0 (validated benign through the menu
  in M1b), `$C015` currently unknown-I/O `0xFF` → Task 4 sets `$C015`=1
  (single-sided, matches 400K install disks), Task 5 validates against the
  boot path with trace evidence.

### Could Not Find

1. The 6504 firmware itself (I/O-board ROM) — not in this tree; its
   internal timing/GCR/steppers are invisible; HLE models the
   68000-visible contract only.
2. One-constant statement of the shared-RAM window size (offsets observed
   to `$B9` + `$3E8`-`$7FF` region).
3. Sony interleave remap table (firmware-internal).
4. Resolution of ambiguities (a) buffer offset and (b) disk_control
   address — both assigned to Task 5 ROM-disassembly.

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
- RS-232 SCC base (RSBASE) not chased. Consult SOURCE-SERCARD/SOURCE-DEVCONTROL.
- `$E01C`/`$E01E` (video-register-adjacent bare strobes, M1b Task 5) — usage
  site found (bracketing a RAM-sizing/checksum routine, result discarded),
  purpose not identified. See §2 "Vertical Retrace" above.
