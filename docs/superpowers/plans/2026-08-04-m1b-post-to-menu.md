# LisaEmu M1b — Special-Space Decode, Devices & POST-to-Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry the real Rev H boot ROM from the M1a halt boundary (`$FE0446` fetch fault on undecoded special-space nibbles) through POST — functional VIAs with interrupt delivery, COPS handshake, video timing — to a rendered boot-menu (or boot-error) screen captured from the emulated framebuffer. Headless: the demo is a `lisadbg` screenshot, not a window (app shell is the next milestone).

**Architecture:** MMU learns the two ROM-discovered special nibbles (`$F` prom, `$9` iospace) as hardwired decodes routed by Bus. The VIA stubs become a real register-accurate 6522 core (shared by both instances, parameterized by stride) with timer events on the Machine clock and IRQ delivery into Musashi's interrupt lines (level 1 = VIA1+vsync, level 2 = VIA2/COPS). COPS is an HLE byte-protocol endpoint behind VIA2 port A per `docs/hardware-notes.md` §4. Video adds real vsync timing (status bit 2, `$E018/$E01A` arm/reset, ~60 Hz on the master clock) and a scanout path that renders the latched framebuffer page to PNG/ASCII. Investigative tasks alternate with device tasks, ROM-trace-driven exactly like M1a Task 7.

**Tech Stack:** existing LisaEmu stack; CoreGraphics (ImageIO) for PNG in lisadbg only — LisaCore stays UI-framework-free.

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m1b-post-to-menu` from main (`bd9aa1b`); commit per task, never amend; TDD for device code; investigative tasks produce evidence documents.
- Never commit ROM images or Apple-derived data. ROM-dependent tests env-gated on `LISAEMU_ROM_DIR` (skip cleanly when unset). ROMs live at `~/Development/LisaROMs`.
- Authorities: `docs/hardware-notes.md` (constants; cites Lisa OS source) and `docs/rom-trace-notes.md` (observed ROM behavior; M1b requirements). Where the ROM's observed behavior contradicts an OS-source-derived assumption, the ROM wins and BOTH docs get updated with the evidence.
- CPU-driving test suites nest under `@Suite(.serialized) enum MusashiSuites`. Swift warning-free; vendored C warnings pre-existing/acceptable. Existing suites stay green (73 tests + TomHarte full run at milestone end).
- One `swift test`/`lisadbg` process at a time; long runs foreground with generous timeout; no concurrent test spawning.
- Trace instrumentation is fair game; device behavior changes need either hardware-notes citations or ROM-trace evidence recorded in the task report.
- Known deferred items intentionally NOT in M1b scope: OQ1 inactive-domain experiment (needs a running OS), Musashi 68010-style bus-error frame fix (Task 6 runs a spike to confirm it can defer to M2), sound, app shell.

---

### Task 1: Special-space decode — through the M1a halt boundary

**Files:**
- Modify: `Sources/LisaCore/MMU.swift` (nibbles `$F`, `$9`), `Sources/LisaCore/Bus.swift` (routing), `Tests/LisaCoreTests/MMUTests.swift`, `Tests/LisaCoreTests/ROMBootTests.swift`
- Create: none

**Interfaces:**
- `Translation` gains `case special(UInt32)` (prom/special space, nibble `$F`): offset within the 128 KB segment. Nibble `$9` translates to the existing `.io(offset)` (it IS the I/O space — seg126 SLIM=`$901` and the flat window must behave identically through either path; limit byte semantics for `$9`/`$F`: model as full-segment (no limit check) initially — the ROM programs `$901`/`$F00` whose low bytes under two's-complement would mean tiny limits, evidence the limit byte is not a page count for these nibbles; document this reasoning in a comment citing rom-trace-notes).
- Bus routes `.special(offset)`: offsets `0x0000-0x3FFF` → ROM bytes (writes ignored + logged); offsets `0x4000-0x1FFFF` → read `0xFF`, log to ioTrace as unknown-special (the SNUM serial-number region lives up here per hardware-notes §2 — stub until the trace shows what the ROM expects). `.io` unchanged.
- ROMBootTests: the M1a boundary assertions (halt at `$FE0446`) are REPLACED — the ROM must now run past `$FE0446`. New loose assertion: with 2M cycles, `machine.halted == false` at some later point or a NEW documented stall; keep `mmuPortWrites == 4132` and setup-drop assertions.

- [ ] **Step 1: Failing MMU tests** — `translate` of a seg with SLIM `$F00` returns `.special(offset)` for any in-segment offset; SLIM `$901` returns `.io(offset)`; both ignore the limit byte (test offsets near both ends of the 128 KB window). Run: FAIL.
- [ ] **Step 2: Implement** MMU decode + Bus `.special` routing per Interfaces. Update the `$F`-related "NOT YET HANDLED" comments from M1a (they now ARE handled — point them at this task).
- [ ] **Step 3: Run suite** — MMU/Bus/IODispatcher suites green; ROMBootTests (env-gated) now FAILS its old halt-boundary assertion — update it per Interfaces, re-run, document in the commit message where the ROM now reaches (`t`/`g` trace: new PC frontier, new I/O touches). Full `swift test` green both with and without env.
- [ ] **Step 4: Commit** — `git commit -m "feat: decode ROM-discovered special-space nibbles \$F/\$9 — ROM runs past the M1a boundary"`

---

### Task 2: Trace checkpoint A — post-boundary ROM behavior

**Files:**
- Modify: `docs/rom-trace-notes.md` (new "Beyond the M1a boundary" section)
- Possibly modify: stub return values in `Sources/LisaCore/IODispatcher.swift` (evidence-gated only)

**Interfaces:** investigative. Deliverables:
- [ ] **Step 1:** Trace (`t`/`g`) from the old boundary until the next stall/loop/halt. Document: PC frontier, every new I/O offset touched (annotated), what the ROM appears to wait for (busy-poll target bits), whether board-ID `$C031` is now read and whether `0x00` diverts POST (try hardware-notes-documented alternatives ONLY with trace evidence; record before/after).
- [ ] **Step 2:** Where the stall is a status/VIA/COPS dependency, record the exact bit and hand it to the matching later task (these notes are Tasks 3-5's requirements). Where it's a missing decode (e.g. the `0x4000+` special region), implement the minimal evidence-backed response, with citation.
- [ ] **Step 3:** Update ROMBootTests to the new documented frontier (assertions cite the notes). Full suite green. Commit.

---

### Task 3: Real 6522 VIA core with timers and IRQ delivery

**Files:**
- Create: `Sources/LisaCore/VIA6522.swift`
- Modify: `Sources/LisaCore/IODispatcher.swift` (VIA register files → two `VIA6522` instances), `Sources/LisaCore/Machine.swift` (timer event scheduling + IRQ line updates), `Sources/LisaCore/M68K.swift` (+shim if needed: expose `m68k_set_irq`)
- Test: `Tests/LisaCoreTests/VIA6522Tests.swift` (CPU-free, datasheet-driven), `Tests/LisaCoreTests/InterruptTests.swift` (under MusashiSuites)

**Interfaces:**
- `final class VIA6522` — 16 registers by INDEX (0-15; stride mapping stays in IODispatcher): ORB/IRB(0) ORA/IRA(1) DDRB(2) DDRA(3) T1CL(4) T1CH(5) T1LL(6) T1LH(7) T2CL(8) T2CH(9) SR(10) ACR(11) PCR(12) IFR(13) IER(14) ORA-no-handshake(15). Semantics implemented and unit-tested: T1 one-shot & free-run (ACR bit 6), reload from latches, IFR bit 6 set on underflow, cleared by T1CL read / T1LH write; T2 one-shot (IFR bit 5, cleared by T2CL read); IER set/clear protocol (bit 7 = set/clear selector, reads return IER|0x80); IFR bit 7 = master (any enabled & flagged); writing IFR clears written bits; port A/B input closures + output latches with DDR mixing. `var irqAsserted: Bool { (ifr & ier & 0x7F) != 0 }`. `func tick(cycles: Int)` advances timers (called from Machine's event loop with elapsed slice cycles — event-queue precision refined to exact underflow events only if the ROM's timing loops demand it; document the choice).
- Machine: after each slice/step, computes `irqLevel = max(via1.irqAsserted || vsyncPending ? 1 : 0, via2.irqAsserted ? 2 : 0)` and calls `cpu.setIRQ(level:)` (wrapper over `m68k_set_irq` — autovectored; confirm Musashi's int_ack default serves autovectors, else set the callback in the shim).
- IODispatcher: VIA reads/writes route to the instances (peek uses side-effect-free register inspection — reads like T1CL clear IFR bits, so peek MUST NOT go through the normal read path; add `func peek(_ index: Int) -> UInt8`).

- [ ] **Step 1: Failing datasheet tests** (CPU-free): T1 free-run underflow sets IFR6 and reloads; T1CL read clears IFR6; IER protocol; IFR master bit; DDR port mixing; T2 one-shot. Exact values in tests. Run: FAIL.
- [ ] **Step 2: Implement VIA6522** minimal-but-correct per the tested semantics.
- [ ] **Step 3: Failing interrupt test** (MusashiSuites): program VIA1 T1 one-shot via bus writes, tiny 68000 program with level-1 autovector handler that increments D2 and clears the IFR, run until the timer fires; assert handler ran (D2), interrupt taken at the right level (SR mask visible in handler via stacked SR if convenient — keep it simple: D2 increment suffices).
- [ ] **Step 4: Implement wiring** (Machine tick/IRQ, shim if needed). All suites green. Commit.

---

### Task 4: COPS HLE endpoint behind VIA2

**Files:**
- Create: `Sources/LisaCore/COPS.swift`
- Modify: `Sources/LisaCore/IODispatcher.swift` (VIA2 port A ↔ COPS), `Sources/LisaCore/Machine.swift` (COPS byte-delivery events)
- Test: `Tests/LisaCoreTests/COPSTests.swift` (protocol-level, CPU-free where possible)

**Interfaces:**
- `final class COPS` per hardware-notes §4: output path — bytes the 68000 writes to VIA2 port A with the CRDY (port A bit 6) handshake are commands (`$02` read clock → queue clock reply; `$10|n` set-clock nibbles; power commands logged; `$7C` mouse-enable stored); input path — a FIFO of bytes delivered one at a time to VIA2 port A, each raising the VIA2 CA1/IFR interrupt (whichever mechanism hardware-notes' Level2 handler implies — IFR bit 1 per §3), next byte gated on the previous being read. Power-on behavior: after reset, deliver the documented startup stream — `$80` + keyboard-ID byte (state-4 path; use a real keyboard ID from hardware-notes if listed, else `$2F`-style placeholder flagged for trace validation in Task 5), plus clock-unset data if the trace shows the ROM asks. Host clock backed; keyboard/mouse injection API (`postKey(code:down:)`, `postMouse(dx:dy:)`) for later milestones.
- CRDY timing: commands complete after a plausible cycle delay (Machine event), not instantly — the ROM busy-polls CRDY both directions per the `COPSCMD` listing.

- [ ] **Step 1: Failing protocol tests** — command handshake (CRDY toggles with plausible delays), `$02` produces a clock reply stream, input FIFO delivers bytes one-per-read with interrupt flag each time. Run: FAIL.
- [ ] **Step 2: Implement.** All suites green. Commit.

---

### Task 5: Video timing + scanout + screenshot; trace checkpoint B

**Files:**
- Create: `Sources/LisaCore/VideoTiming.swift` (vsync scheduling + status bit + framebuffer snapshot)
- Modify: `Sources/LisaCore/IODispatcher.swift` ($E018/$E01A/$F801 become real), `Sources/lisadbg/main.swift` (screenshot + ASCII preview commands; fold in deferred minors: negative-n guard on t/s/g, print `ioTraceDropped` when nonzero in `t`), `docs/rom-trace-notes.md`
- Test: `Tests/LisaCoreTests/VideoTimingTests.swift`

**Interfaces:**
- Vsync every 83,333 CPU cycles (5 MHz / 60 Hz; refine only with evidence): sets status bit 2 (`$F801`), and if armed via `$E01A` contributes to level-1 IRQ; access to `$E018` clears/re-arms per hardware-notes §2 (VRIRDIS/reset). `Bus.framebufferSnapshot() -> [UInt8]` — 32,760 bytes starting at `videoPageLatch << 15` physical.
- lisadbg: `sc <path.png>` renders the snapshot 720×364 1bpp → PNG via ImageIO (1 bit = 1 pixel, set bit = black); `sca` prints a coarse ASCII preview (~90×45, block-averaged) straight to the terminal.
- Trace checkpoint B: with Tasks 3-5 in place, trace the ROM's device-init phase: does it program VIA T1 (which reload values — Pepsi-check via `$C031` bit 7), wait on COPS bytes (validate/replace the keyboard-ID placeholder with what the ROM accepts), read the serial-number region? Document; evidence-gated stub adjustments allowed; update rom-trace-notes.

- [ ] **Step 1: Failing timing tests** — vsync sets bit 2 on schedule; `$E018` access clears it; armed vsync asserts level 1; snapshot returns the latched page. Run: FAIL.
- [ ] **Step 2: Implement**; screenshot commands; lisadbg minors. Suites green. Commit.
- [ ] **Step 3: Trace checkpoint B** per Interfaces; update ROMBootTests frontier; document; commit.

---

### Task 6: Bus-error frame spike + board-ID/memory-sizing validation

**Files:**
- Modify: `docs/rom-trace-notes.md`; possibly `Sources/CMusashi/*` + `Scripts/vendor-musashi.sh` (ONLY if the spike proves necessity)
- Test: existing suites; ROMBootTests frontier update

**Interfaces:** investigative spike per the M1a final review:
- [ ] **Step 1:** From traces so far, determine whether the ROM takes any RECOVERABLE bus error before the menu (memory sizing by fault? parity probing?). Method: instrument `pulseBusError` count/log during a full boot trace; inspect whether any bus-error exception RTEs back (handler analysis at the vector target).
- [ ] **Step 2:** If YES: implement the real 68000 group-0 frame — swap `m68ki_exception_bus_error` to `m68ki_stack_frame_buserr`, plumb address/isWrite from `pulseBusError` into `m68ki_aerr_address`/`m68ki_aerr_write_mode`, patch via vendor-script mechanism, cover with a test that RTEs through a bus-error handler. If NO: document the deferral evidence ("no recoverable bus error observed through <frontier>") in rom-trace-notes + ledger; M2 owns the fix.
- [ ] **Step 3:** Validate board-ID/memory sizing: whatever `$C031` value the trace justified in Task 2, confirm POST's memory test passes against our 2MB flat RAM (watch for parity-latch expectations at status bits — implement evidence-gated). Document. Commit.

---

### Task 7: POST to menu — M1b exit criterion

**Files:**
- Modify: `Tests/LisaCoreTests/ROMBootTests.swift`, `docs/rom-trace-notes.md`
- Create: `docs/m1b-demo.md` (one page: the screenshot + how to reproduce)

**Interfaces:**
- [ ] **Step 1:** Iterate: run the ROM with everything in place; at each stall, diagnose (trace), fix within the evidence rules (device-behavior changes cite hardware-notes or trace), repeat — until the ROM completes POST and renders its startup UI into the framebuffer. NOTE the honest expected outcome: with no floppy/hard-disk devices, the ROM will reach POST completion and then show the startup/boot-device UI or an error screen (e.g. no-boot-device) — EITHER is the M1b success state; which one we get is itself a documented finding. If a stall proves to need a whole new subsystem beyond M1b's scope, STOP and report BLOCKED with the evidence rather than scope-creeping.
- [ ] **Step 2:** ROMBootTests final form: boot N cycles (documented), assert POST-complete markers (documented from trace: e.g. specific I/O sequence or memory cell) AND `framebufferSnapshot()` is non-blank with a stable content hash recorded in the test (cite the notes; hash may be brittle across future timing changes — also assert a robust weaker invariant like >1% black pixels).
- [ ] **Step 3:** `lisadbg` screenshot of the final screen saved OUTSIDE the repo (e.g. ~/Development/LisaEmu-artifacts/m1b-boot-screen.png), referenced by path in docs/m1b-demo.md with the reproduce command. Do NOT commit the PNG (it renders Apple's ROM-drawn UI; keep the repo clean of Apple-derived artifacts — conservative, cheap).
- [ ] **Step 4:** Full regression: `swift test` green (no env), green with LISAEMU_ROM_DIR, AND the full TomHarte release run matching 807147/0/192913. Update rom-trace-notes final state. Commit.
