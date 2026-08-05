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

## 4. COPS (via VIA2 Port A)

### Command Protocol

Source: libhw-DRIVERS:822-887

**Flow:**
1. Write command byte to IORA2
2. Poll CRDY (Port A bit 6, aka VIA2 base + bit 6)
3. Wait for transition: ready → not-ready
4. ~10-cycle wait
5. Set DDRA2 = $FF (output)
6. Send command
7. Poll CRDY again
8. Set DDRA2 = $00 (input)

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

## Known Gaps (Flagged for M1b, Not M1a)

- Parity/bus-error status register bit layout not located. Check SOURCE-EXCEPRES/SOURCE-EXCEPASM BUS_ERR handler.
- RS-232 SCC base (RSBASE) not chased. Consult SOURCE-SERCARD/SOURCE-DEVCONTROL.
