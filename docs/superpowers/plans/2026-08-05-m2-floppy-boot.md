# LisaEmu M2 — Floppy Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The real Rev H ROM boots from the Office System 3.1 install disk: the emulated Sony 400K floppy (6504 shared-RAM HLE) serves the DC42 image, the ROM loads and jumps into the boot block, and the Lisa OS loader executes to a documented milestone. Plus the two structural debts the M1b final review made load-bearing: the real 68000 bus-error frame and warm-reset semantics.

**Architecture:** A `FloppyController` HLE device owns the `$C000`-offset shared-RAM window inside the IODispatcher: a go-byte command state machine (per the newly mined OS-source protocol), the Sony GCR zone mapping between track/sector/side and DC42 linear blocks, data+tag buffers, and completion interrupts via VIA2 PORTB2 bit 4 (an input line, exactly how COPS feeds CRDY). A `DC42Image` loader parses the container (data + tag planes). The Musashi bus-error path gains the real 68000 group-0 frame with plumbed fault address/direction. Trace-driven iteration closes the gaps the OS source left ambiguous.

**Tech Stack:** existing LisaEmu stack. Disk images at `~/Development/LisaImages/` (OS31_Install_1.dc42 + 13 more; NEVER committed). ROMs at `~/Development/LisaROMs/`.

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m2-floppy-boot` from main (`91f5f60`); commit per task, never amend; TDD for device code; investigative tasks produce evidence docs.
- Never commit ROMs, disk images, or Apple-derived binaries. Disk-dependent tests env-gated on `LISAEMU_DISK_DIR` (skip cleanly when unset), ROM tests on `LISAEMU_ROM_DIR` as before.
- Authorities: `docs/hardware-notes.md` + `docs/rom-trace-notes.md`; ROM/observed behavior wins over OS-source claims, both docs updated with evidence (established rule). The floppy research report (controller provides it in Task 1's dispatch) carries three flagged ambiguities to resolve empirically: (a) live sector data at window offset `$400` vs `$600`; (b) `disk_control` at `$FCD801` vs `$FCD901` (in-source contradiction); (c) Sony 2:1 interleave — implemented in 6504 firmware, invisible to us (HLE serves logical sectors; note it and move on unless the ROM proves otherwise.)
- Key protocol constants (full set with citations goes into hardware-notes §7 in Task 1): shared-RAM base = I/O offset `$C000`; cells DISKCMD=$01 (go-byte; 68000 waits for 0, 6504 clears when ready), DISKPARM=$03, DISKDRIV=$05, DISKHEAD=$07, DISKSEC=$09, DISKTRAK=$0B, DISKCNFM=$0F, DISKERR=$11 (error+1800 = OS code; not_issued=1809), DISKFLG=$13, DISKSKING=$19, DISKIN=$41 (nonzero = disk present), DISKSTAT=$5F (Sony: bit7 int, bit6 done, bit4 in — "bot" nibble; low nibble unused), DISKHDR=$3E8 (12-byte packed tag), DISKDATA=$400 (512-byte sector; see ambiguity (a)); go-bytes nulcmd=$80, excmd=$81, seek=$83, clristat=$85, enabstat=$86, clrmask=$87, goaway=$89; sub-commands read=0, write=1, unclamp=2, format=3, verify=4; completion line = VIA2 PORTB2 **bit 4** → level-1 interrupt; Sony zone table (12/11/10/9/8 sectors per 16-track zone, 800 blocks/side, side 0 = blocks 0-799); board IDs $FCC031 (iomodel ranges) and **$FCC015 = intdisk: 0 twiggy / 1 single-sided Sony / 2 double-sided** (400K install disks ⇒ 1); boot-device byte at low-core $1B3 (bootdev 1 = internal Sony on 2/10-class); ROM RWTS entry twig_entry=$FE0094 shared by Twiggy+Sony.
- DC42 container: 84-byte header (name pstring; data length at +64 big-endian = 409,600; tag length at +68 = 9,600), then data plane (800×512), then tag plane (800×12). Verified against the real images.
- CPU-driving suites under MusashiSuites; Swift warning-free; suites green both ways; full TomHarte release run at milestone end (807147/0/192913).
- M1b anchor breakage is EXPECTED: inserting a disk changes the boot menu (error-42 icon disappears / auto-boot proceeds); ROMBootTests pixel/FNV anchors get updated alongside rom-trace-notes with the new documented states — never deleted, re-anchored.
- One test/lisadbg process at a time; foreground with generous timeouts; no background test processes.

---

### Task 1: Real 68000 bus-error frame (the M2-load-bearing Musashi fix)

**Files:**
- Modify: `Sources/CMusashi/m68kcpu.h` (patch via the established mechanism), `Scripts/vendor-musashi.sh` (re-apply), `Sources/CMusashi/include/shim.h` + `shim.c` (fault-info setters if needed), `Sources/LisaCore/M68K.swift`, `Sources/LisaCore/Bus.swift` (plumb address/isWrite into the pulse)
- Create: `Tests/LisaCoreTests/BusErrorFrameTests.swift` (under MusashiSuites)
- Modify: `docs/hardware-notes.md` §7 (NEW: the floppy-interface constants from the research report, full citations + the three ambiguities flagged) — folded here so the constants authority exists before the device tasks

**Interfaces:**
- `m68ki_exception_bus_error` switches from `m68ki_stack_frame_1000` (68010 format-8, 29 words, fault address hardcoded 0) to `m68ki_stack_frame_buserr` (real 68000 group-0 7-word frame), consuming `m68ki_aerr_address`/`m68ki_aerr_write_mode`/`m68ki_aerr_fc` — set before the pulse by the shim path from `M68K.pulseBusError(address:isWrite:)` (whose parameters finally become load-bearing). Patch applied in-tree AND via a vendor-script re-apply block with unique anchors + fail-loud, exactly like the two existing patches.
- Test (TDD): machine with a bus-error HANDLER that reads the stacked fault address from the group-0 frame (SP+2..5 per the 68000 frame layout — verify offsets against the vendored `m68ki_stack_frame_buserr` code), stores it to a known RAM cell, RTEs back; the faulting instruction's successor sets a flag. Assert: handler ran, captured fault address == the actual faulted address, RTE resumed cleanly (successor flag set), SP restored. This is the exact shape the OS loader will use.

- [ ] **Step 1:** Read the vendored `m68ki_stack_frame_buserr` + `m68ki_exception_bus_error` + the address-error machinery; write the failing RTE round-trip test (bytes hand-assembled, in-test comments documenting the frame layout consulted). Run: FAIL (current 68010 frame → wrong SP unwinding / garbage address).
- [ ] **Step 2:** Implement the patch + plumbing + vendor-script block. Run: test green; ALL existing suites green (BusErrorTests' no-RTE tests must still pass — the frame changed but they never unwind it; verify the double-fault HALT path still works).
- [ ] **Step 3:** Write hardware-notes §7 from the research report (separate commit OK).
- [ ] **Step 4:** Commit(s).

---

### Task 2: Warm-reset semantics

**Files:**
- Modify: `Sources/LisaCore/Machine.swift`, `Sources/LisaCore/Bus.swift`, `Sources/LisaCore/VIA6522.swift` (+`reset()`), `Sources/LisaCore/IODispatcher.swift` as needed
- Test: `Tests/LisaCoreTests/MachineTests.swift` additions + an env-gated warm-reset ROM test in `ROMBootTests`

**Interfaces:**
- `VIA6522.reset()` per 6522 datasheet reset state (DDRs/ORs/ACR/PCR/IER/IFR cleared; timers stopped — document the datasheet basis).
- `Machine.reset()` becomes a true hardware reset: CPU reset, cycles/queue cleared, COPS + VideoTiming re-init (existing), PLUS both VIAs reset, `Bus` setup latch re-asserted (setupMode = true — the hardware reset line sets the SETUP flip-flop; cite hardware-notes latch section), context/domain latches cleared to 0, `halted`/fault tracking cleared. MMU SORG/SLIM registers: leave contents (RAM-like registers survive reset on real hardware) — with setup re-asserted the ROM re-fetches vectors from the mirror regardless; document the modeling choice.
- Cold-init-only doc caveat from M1b is removed; `reset()` doc describes warm-reset semantics.
- Fold-in (M1b review input): `COPS` gains an injectable clock source `clockSource: () -> Date` (default `{ Date() }`), used by the `$02` read-clock reply — the OS loader may exercise it, and `Date()` is LisaCore's only nondeterminism. Tests inject a fixed date and assert a deterministic reply byte sequence (per hardware-notes §4 clock format as currently understood; placeholder honesty preserved).
- Tests: unit — after boot-ish state mutation (setup off, domain 2, VIA registers dirtied), `reset()` restores the documented baseline. Env-gated integration — boot to the menu, `machine.reset()`, boot again: second run reaches the same documented menu state (same POST-complete markers; framebuffer invariant — reuse the robust >1% assertion, not the FNV anchor, to stay insensitive to Task-5+ anchor moves).

- [ ] **Step 1:** Failing tests. **Step 2:** Implement. **Step 3:** Full suites green both ways. **Step 4:** Commit.

---

### Task 3: DC42 image loader

**Files:**
- Create: `Sources/LisaCore/DC42Image.swift`, `Tests/LisaCoreTests/DC42ImageTests.swift`

**Interfaces:**
- `struct DC42Image`: `init(data: Data) throws` validating the container (data length 409,600 @+64 BE, tag length 9,600 @+68; reject mismatches with typed errors); `var blockCount: Int` (800); `func data(block: Int) -> ArraySlice<UInt8>` (512 bytes); `func tag(block: Int) -> ArraySlice<UInt8>` (12 bytes); `static func load(url: URL) throws -> DC42Image`; read-only for M2 (writes to the floppy come later — the boot path only reads; a write command in the HLE returns success-and-discards WITH a logged warning, documented).
- Tests: synthetic container round-trip (build a tiny valid header + planes in-test); malformed rejects; env-gated real-image test (`LISAEMU_DISK_DIR`): OS31_Install_1.dc42 loads, block 0 data begins `4E FA` (the boot block's JMP — cite the M2 procurement finding), tag plane non-empty.

- [ ] **Step 1:** Failing tests. **Step 2:** Implement. **Step 3:** Green both ways. **Step 4:** Commit.

---

### Task 4: FloppyController HLE device

**Files:**
- Create: `Sources/LisaCore/FloppyController.swift`, `Tests/LisaCoreTests/FloppyControllerTests.swift` (protocol-level, CPU-free)
- Modify: `Sources/LisaCore/IODispatcher.swift` (route offsets `$C000-$C7FF` window + `$C015`/`$C031` reads), `Sources/LisaCore/Machine.swift` (event scheduling + interrupt line wiring), `Sources/lisadbg/main.swift` (`--disk <path.dc42>` option; status line shows disk state)

**Interfaces:**
- `final class FloppyController`: owns a 2KB shared-RAM byte array (the 68000 reads/writes it as plain RAM through the dispatcher — the 6504-side behavior is our HLE); `func insert(_ image: DC42Image)` / `func eject()`; DISKIN cell reflects presence.
- Go-byte state machine on writes to DISKCMD ($01): value latched; after a plausible delay (Machine event, ~thousands of cycles — tune during trace) the HLE "6504" executes: `excmd` reads DISKPARM + DISKDRIV/HEAD/SEC/TRAK, performs the sub-command (read: zone-map track/sector/side → linear block → copy 512 bytes to the data buffer and packed 12-byte tag to $3E8; sub-commands ≥2 per constants, unsupported ones set DISKERR), clears DISKCMD to 0 (ready), sets DISKSTAT done/int bits, raises the completion line. `seek`/`clristat`/`enabstat`/`clrmask`/`goaway`/`nulcmd` per protocol (state-flag effects + DISKCMD clear; clristat drops the interrupt line).
- **Zone mapping:** implement the CONVERT table verbatim (zones 12/11/10/9/8 × 16 tracks; side 0 blocks 0-799; inverse: (track, sector, side) → linear block). Property-test: forward CONVERT (implemented in-test from the table) and the controller's inverse agree for all 800 blocks.
- **Data buffer ambiguity (a):** implement the copy destination as a single constant defaulting to `$400`, with a doc comment naming the `$600` alternative and the plan to settle it in Task 5's trace (the ROM's own RWTS reads the buffer — where it looks IS the answer).
- **Completion line:** wired like COPS's CRDY — an input closure feeding VIA2 PORTB2 bit 4 + level-1 contribution (per hardware-notes: the Level1 handler polls PORTB2 bit 4 directly; give the line both the port-bit and, per trace evidence in Task 5, any IFR involvement).
- `$FCC015` returns 1 (single-sided Sony) — evidence-cited stub move from 0xFF-unknown to the documented intdisk value; `$FCC031` UNCHANGED for now (Task 5 decides with trace evidence).
- Tests: full command round-trip against a synthetic DC42 (issue excmd/read for several (track,sector,side) combos incl. zone boundaries; assert data+tag land in the window cells, DISKCMD cleared, DISKSTAT bits, line raised, DISKERR=0); error paths (no disk → error; bad track); handshake (command while busy).

- [ ] **Step 1:** Failing protocol tests. **Step 2:** Implement. **Step 3:** Green both ways. **Step 4:** Commit.

---

### Task 5: Trace checkpoint C — the ROM meets the disk

**Files:**
- Modify: `docs/rom-trace-notes.md` (new "Floppy boot (checkpoint C)" section), `Tests/LisaCoreTests/ROMBootTests.swift` (re-anchor), stubs/constants as evidence dictates
- Possibly modify: `Sources/lisadbg/main.swift` (key-injection command `k <code>` via COPS.postKey, IF the menu needs interaction to boot)

**Interfaces:** investigative. Deliverables:
- [ ] **Step 1:** Boot with `--disk` inserted from power-on. Document how the menu/POST behavior changes (DISKIN now nonzero): does the ROM auto-boot the floppy, does the menu lose the error icon, does it need a menu selection (if so: disassemble the menu's input handling enough to inject the right key via COPS — add the lisadbg `k` command)?
- [ ] **Step 2:** Trace the ROM's floppy boot read: which go-bytes/sub-commands in what order, where its RWTS looks for the data buffer (**settles ambiguity (a) — update the FloppyController constant + hardware-notes with the disassembly citation**), what DISKSTAT/handshake sequencing it expects, whether it polls `disk_control` ($FCD801 vs $FCD901 — **settles ambiguity (b)** the same way), and what it does with $FCC031/$FCC015 on the boot path (adjust values ONLY with observed-branch evidence; expect the menu anchors to move — re-anchor ROMBootTests per the constraint).
- [ ] **Step 3:** Iterate until the ROM successfully reads block 0, and executes the boot block (`4EFA...` — watch PC enter RAM at the load address). Document the load address and the boot block's first actions. Update wait-target table. Commit(s) with evidence per change.

---

### Task 6: OS loader milestone — M2 exit criterion

**Files:**
- Modify: `Tests/LisaCoreTests/ROMBootTests.swift` (final M2 assertions), `docs/rom-trace-notes.md`, `docs/m2-demo.md` (new)

**Interfaces:**
- [ ] **Step 1:** Follow the boot block into the loader-loader ("ldsony"/ldmicro per the OS source): it issues its own shared-RAM commands to pull the OS loader off disk (multiple blocks). Iterate stalls exactly as before (trace → evidence → fix). Known landmarks from the OS source to watch for: `dev_type` ($22E) set to 2 (dev_sony), boot-device byte $1B3, twig_entry calls, block reads walking up the disk. The honest exit bar: **the Lisa OS loader is executing from RAM and progressing** — define "progressing" from what the trace shows (e.g. it loads the LFS loader, draws a progress/hourglass screen, or reaches a documented next-subsystem dependency such as the hard-disk/Widget probe or an OS kernel handoff). If it runs into a genuinely new subsystem (Widget, SCC), STOP at a documented boundary — that's M3's requirements doc, not scope creep.
- [ ] **Step 2:** ROMBootTests M2 final form: boot-with-disk to the documented milestone; assert the loader-execution markers (PC ranges in RAM, $22E == 2, block-read counts from the controller's stats, framebuffer state if the loader draws); robust invariants alongside any exact anchors; citations throughout.
- [ ] **Step 3:** docs/m2-demo.md (reproduce commands + screenshot path outside repo, ~/Development/LisaEmu-artifacts/m2-loader-screen.png if the loader draws anything; else the lisadbg status transcript). Full regression: suites green both ways + full TomHarte release run 807147/0/192913. Update memory-worthy facts in rom-trace-notes final section. Commit.
