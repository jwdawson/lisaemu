# LisaEmu M1a — Hardware-Accurate MMU, Bus Errors & ROM Bring-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace M0's semantic MMU with the real Lisa hardware register model, wire genuine 68000 bus errors, load and execute the real Rev H boot ROM under an instrumented I/O space, and produce a trace of the ROM's actual early behavior — the foundation M1b (POST passes, boot menu draws) builds on.

**Architecture:** The Bus gains a physical dispatch layer: RAM, the 16 KB boot ROM window, and an `IODispatcher` for the Lisa's `$FCxxxx`-pattern I/O offsets (setup/context latches, video latch, status register, VIA stubs that log, board-ID). MMU segment registers become raw 12-bit SORG/SLIM pairs programmed through their memory-mapped ports under the setup latch, decoded per the OS source's `do_an_mmu`. MMU faults pulse real bus errors into Musashi. `lisadbg` learns to load the interleaved ROM and trace I/O.

**Tech Stack:** Existing LisaEmu stack (Swift 6 toolchain, lang mode v5, Swift Testing, Musashi/CMusashi). ROM images at `~/Development/LisaROMs/` (NOT committed).

## Global Constraints

- Repo `~/Development/LisaEmu`; work on a feature branch from main (`m1a-hardware-mmu`); commit per task; TDD.
- **Never commit ROM images or any Apple-derived binary/source.** Tests needing the real ROM are env-gated on `LISAEMU_ROM_DIR` (skip cleanly when unset), same pattern as `LISAEMU_TH_DIR`.
- All hardware constants come from the mined OS-source citations recorded in `docs/hardware-notes.md` (created in Task 1). Key values used throughout this plan: I/O space base `$FC0000`; setup latches SET=`$FCE010`/RESET=`$FCE012` (any access toggles; data ignored); domain context latches `$FCE008/A/C/E`; SLIM port offset `$8000` and SORG `$8008` within each 128 KB segment block; access nibbles `$5`=readOnly `$6`=stack `$7`=readWrite `$8`=io `$C`=absent; page size 512 bytes; limits two's-complement page counts; video latch `$FCE800`; status register low byte `$FCF801` (vsync-pending = bit 2), vsync reset `$FCE018` / enable `$FCE01A`; VIA1 base offset `$D801` (stride ×8), VIA2 base offset `$DC01` (stride ×2); board-ID `$FCC031`; boot ROM = `341-0175-H.BIN` (even bytes) + `341-0176-H.BIN` (odd bytes) interleaved to 16 KB, living at special-space `$FE0000-$FE3FFF`, mirrored at address 0 while the setup latch is on.
- Musashi singleton discipline: all CPU-driving test suites nest under `@Suite(.serialized) enum MusashiSuites`.
- Swift code warning-free; vendored C warnings pre-existing/acceptable. Existing suites stay green (27 tests + TomHarte gated).
- M1a explicitly does NOT include: video scanout/UI, working VIA timers/interrupt delivery, COPS protocol, POST passing. Those are M1b. VIA/COPS addresses get *logging stubs* only.

---

### Task 1: Hardware notes doc + hardening batch

**Files:**
- Create: `docs/hardware-notes.md`
- Modify: `Sources/LisaCore/M68K.swift` (thread-ownership debug assertion)
- Modify: `Sources/LisaCore/Bus.swift` (bounded `unmappedAccesses`, `domain` validation)
- Modify: `Scripts/vendor-musashi.sh` (pin to recorded commit by default)
- Test: `Tests/LisaCoreTests/BusTests.swift` (additions)

**Interfaces:**
- Produces: `docs/hardware-notes.md` — the citation-backed constants reference later tasks consult; `Bus.unmappedAccesses` capped at 1024 entries with `public private(set) var unmappedDropped: Int`; `Bus.domain` setter clamps via `precondition((0...3).contains(newValue))`; `M68K` records its creation thread and `assert`s (debug-only) that run/step/subscript execute on it; `Bus.withPeek<T>(_ body: () -> T) -> T` — sets a private `peeking` flag for the duration; while peeking, faults/unmapped/ioTrace recording is suppressed (reads still return data; writes are forbidden by convention). `Monitor.disassembly` and `Monitor.hexDump` wrap their reads in `withPeek` so debugger inspection never pollutes `unmappedAccesses`/`lastFault` (deferred carry-forward from the M0 final review).

- [ ] **Step 1: Write `docs/hardware-notes.md`**

Content: the full mined-constants report (MMU register model & port addressing, setup/context latch semantics, video, VIA bases + register strides + init sequences, COPS command/packet tables, interrupt levels, memory map, boot ROM facts), organized by subsystem, every value with its `Lisa_Source` file:line citation. Source material: the constants listed in Global Constraints above plus the full research report the controller provides in the task dispatch. This document is reference-only (no code); keep the citations — they are the audit trail.

- [ ] **Step 2: Write failing tests for the hardening changes**

Append to `Tests/LisaCoreTests/BusTests.swift`:
```swift
@Test func unmappedAccessListIsBounded() {
    let bus = Bus(ramSize: 0x100)
    for i in 0..<1500 { _ = bus.read8(0x80_0000 + UInt32(i)) }
    #expect(bus.unmappedAccesses.count == 1024)
    #expect(bus.unmappedDropped == 1500 - 1024)
}

@Test func peekSuppressesDiagnostics() {
    let bus = Bus(ramSize: 0x100)
    let v = bus.withPeek { bus.read8(0x80_0000) }
    #expect(v == 0xFF)
    #expect(bus.unmappedAccesses.isEmpty)
}
```
Run: `swift test --filter BusTests` — expect FAIL (`unmappedDropped`/`withPeek` not found).

- [ ] **Step 3: Implement**

In `Bus.swift`: add `public private(set) var unmappedDropped = 0`; in the two unmapped paths, `if unmappedAccesses.count < 1024 { unmappedAccesses.append(...) } else { unmappedDropped += 1 }`. Change `public var domain = 0` to a didSet/willSet `precondition((0...3).contains(domain), "Bus.domain out of range")` (or a computed property over private storage). In `M68K.swift`: store `private let ownerThread = Thread.current` in init; add `private func assertOwner() { assert(Thread.current === ownerThread, "M68K used off its creation thread — Musashi is a process-global singleton") }` and call it at the top of `run`, `step`, subscript get/set, and `disassemble`. In `Scripts/vendor-musashi.sh`: after clone, `git -C "$TMP/musashi" checkout "$(cat "$DEST/MUSASHI_COMMIT.txt")"` when the file exists unless `--latest` is passed (then update the file).

- [ ] **Step 4: Run tests**

Run: `swift test` — all suites green (new test passing, no regressions).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "docs+hardening: hardware notes, bounded unmapped log, domain guard, thread assertion, pinned vendor script"
```

---

### Task 2: Supervisor-state plumb-through

**Files:**
- Modify: `Sources/CMusashi/include/shim.h`, `Sources/CMusashi/shim.c` (add `lisa_cpu_supervisor`)
- Modify: `Sources/LisaCore/M68K.swift` (`isSupervisor`)
- Modify: `Sources/LisaCore/MMU.swift`, `Sources/LisaCore/Bus.swift` (`translate` gains `isSupervisor:`)
- Test: `Tests/LisaCoreTests/MMUTests.swift`, `Tests/LisaCoreTests/M68KTests.swift` (additions)

**Interfaces:**
- Produces (C): `unsigned int lisa_cpu_supervisor(void);` — returns nonzero when Musashi's S-flag is set (same pattern as the existing `lisa_cpu_stopped()`).
- Produces (Swift): `M68K.isSupervisor: Bool`; `MMU.translate(_:domain:isSupervisor:isWrite:)` (spec §2 parity — parameter accepted and carried; no access rule keys off it yet, documented as such); `Bus.physical` passes the live CPU state via an injected `supervisorProvider: () -> Bool` closure (default `{ true }`), set by `Machine.init` to `{ [weak cpu] in cpu?.isSupervisor ?? true }`.

- [ ] **Step 1: Failing tests**

```swift
// M68KTests addition (nested in MusashiSuites):
@Test func supervisorFlagTracksSR() {
    let bus = makeMachineRAM()
    let cpu = M68K(bus: bus)
    cpu.reset()
    #expect(cpu.isSupervisor == true)      // 68000 resets in supervisor mode
    cpu[.sr] = 0x0700                      // clear S bit
    #expect(cpu.isSupervisor == false)
}
// MMUTests addition: translate signature accepts isSupervisor and behaves identically for now
@Test func translateAcceptsSupervisorParameter() {
    let mmu = mmuWith(1, .init(origin: 0x40000, limitBytes: 0x20000, access: .readWrite))
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: false, isWrite: false)
            == mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false))
}
```
Run: `swift test --filter MMUTests --filter M68KTests` — expect FAIL.

- [ ] **Step 2: Implement**

shim.c: `unsigned int lisa_cpu_supervisor(void) { return m68ki_cpu.s_flag; }` (verify the field name in m68kcpu.h — it is the same struct `lisa_cpu_stopped` reads; adjust spelling to the actual member). M68K: `public var isSupervisor: Bool { lisa_cpu_supervisor() != 0 }`. MMU: add the parameter (update all call sites and existing tests mechanically — keep behavior identical, with a doc comment: "no supervisor-conditional rule is enforced yet; the parameter exists so M1b hardware rules can be added without another signature change"). Bus: add `public var supervisorProvider: () -> Bool = { true }` consulted in `physical`; Machine.init wires it to the cpu.

- [ ] **Step 3: Run tests** — `swift test`, all green.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: supervisor-state plumb-through (shim accessor, MMU translate parameter)"`

---

### Task 3: Real bus errors into Musashi

**Files:**
- Modify: `Sources/LisaCore/Bus.swift`, `Sources/LisaCore/M68K.swift`
- Test: `Tests/LisaCoreTests/BusErrorTests.swift` (new, nested under MusashiSuites)

**Interfaces:**
- Produces: `Bus.busErrorHandler: ((UInt32, Bool) -> Void)?` — invoked (address, isWrite) on MMU fault when translation is active; `Machine.init` wires it to `cpu.pulseBusError(address:isWrite:)` which calls Musashi's `m68k_pulse_bus_error()` after `m68k_set_reg`-independent setup. Faulting still records `lastFault` and returns 0xFF/drops the write for the non-CPU (peek/direct) paths.
- CAUTION for the implementer: `m68k_pulse_bus_error()` longjmps out of the memory callback (the address-error sigsetjmp machinery we already patched). Read the vendored `m68kcpu.c/h` bus-error path FIRST; confirm what state it expects (it uses the same `m68ki_aerr` jump buffer family). The Swift callback must do nothing after calling it (no cleanup code below the call), and it must only be called from within a Musashi execution context (i.e., when the CPU is actually running). Guard: only pulse when a flag `insideCpuCallback` is true — set/cleared in the shim trampolines (simplest: a Bool the M68K wrapper sets around `m68k_execute`).

- [ ] **Step 1: Failing test**

`BusErrorTests.swift` (nested in MusashiSuites): build a machine (setupMode false) whose MMU maps segment 0 readWrite (vectors+code) and leaves segment 1 absent; vector table at 0: SSP=0x3000, PC=0x400; bus-error vector ($8) → handler at 0x500 that executes `MOVEQ #99,D1; BRA *` (handler bytes at 0x500: 72 63 60 FE); program at 0x400: `MOVE.B $20000,D0` (absolute-long read of absent segment: 10 39 00 02 00 00) then `NOP`. Run; expect `cpu[.d1] == 99` (bus-error exception was taken and the handler ran) and `bus.lastFault?.reason == .invalidSegment`.
Run: expect FAIL (no bus error is currently raised; D1 stays 0).

- [ ] **Step 2: Implement** per the Interfaces block. Verify against the vendored source how `m68k_pulse_bus_error` interacts with `m68ki_aerr_trap`; document what you found in code comments. Confirm the 68000 exception frame Musashi pushes suffices for the test handler (we don't RTE back).

- [ ] **Step 3: Run** — new test green; full suite green; TomHarte suite unaffected (it runs in setup mode — no MMU faults).

- [ ] **Step 4: Commit** — `git commit -m "feat: MMU faults raise real 68000 bus errors via Musashi"`

---

### Task 4: Hardware MMU register model (SORG/SLIM)

**Files:**
- Modify: `Sources/LisaCore/MMU.swift` (raw register model + decode)
- Test: `Tests/LisaCoreTests/MMUTests.swift` (rewrite/extend)

**Interfaces:**
- Produces:
  - `SegmentRegister` becomes `{ public var sorg: UInt16; public var slim: UInt16 }` (12-bit significant, masked on set).
  - Decode per `do_an_mmu`/`ReadMMU` semantics (docs/hardware-notes.md §1): `accessNibble = (slim >> 8) & 0xF`; page = 512 bytes; for readOnly($5)/readWrite($7)/io($8): `limitPages = (0x100 - (slim & 0xFF)) & 0xFF` (two's-complement count; 0 means 256 pages = full 128 KB), valid while `pageOffset < limitPages`; for stack($6): `limitPages = (slim & 0xFF) + 1` with validity in the TOP of the window per the OS's stack layout (grow-down; derive the exact window from the `origin adjustment +length-$100` rule in the notes and encode it as a pure function with its own tests); `$C`/unknown nibbles = absent → `.invalidSegment` fault. Physical = `(UInt32(sorg & 0xFFF) << 9) + offsetWithinSegment` for memory types; `io` type returns a distinct `.io(offset:)` result so the Bus routes to the IODispatcher instead of RAM.
  - `MMU.translate` returns `enum Translation { case memory(UInt32); case io(UInt32); case fault(MMUFault) }` (replaces the Result — mechanical update of Bus + tests).
  - Convenience factory for tests/M0 compatibility: `SegmentRegister.make(originPage:limitPages:access:)` building raw sorg/slim.
- The M0 semantic fields (`origin`/`limitBytes`/`access: SegmentAccess`) are REMOVED — update every existing usage (Bus wiring, MMUTests, BusErrorTests) to the raw model via the factory. This is the point of the task; no compatibility shim layer.

- [ ] **Step 1: Failing tests** — rewrite MMUTests around the raw model:

```swift
@Test func rawReadWriteSegmentDecodes() {
    var mmu = MMU()
    // origin page 0x200 (=phys 0x40000), readWrite, limit 16 pages (8KB): slim low byte = 0x100-16 = 0xF0
    mmu.domains[0][1] = SegmentRegister(sorg: 0x200, slim: 0x7F0)
    #expect(mmu.translate(0x2_0000, domain: 0, isSupervisor: true, isWrite: false) == .memory(0x40000))
    #expect(mmu.translate(0x2_0000 + 16*512 - 1, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x40000 + 16*512 - 1))
    if case .fault(let f) = mmu.translate(0x2_0000 + 16*512, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .limitViolation)
    } else { Issue.record("expected limit fault") }
}

@Test func fullSegmentLimitZeroMeans256Pages() {
    var mmu = MMU()
    mmu.domains[0][0] = SegmentRegister(sorg: 0, slim: 0x700)   // limit byte 0 → 256 pages → full 128KB
    #expect(mmu.translate(0x1_FFFF, domain: 0, isSupervisor: true, isWrite: true) == .memory(0x1_FFFF))
}

@Test func ioSegmentRoutesToIO() {
    var mmu = MMU()
    mmu.domains[0][126] = SegmentRegister(sorg: 0, slim: 0x800)  // access $8 = io
    #expect(mmu.translate(126 << 17 | 0xE010, domain: 0, isSupervisor: true, isWrite: false) == .io(0xE010))
}

@Test func absentSegmentFaults() {
    let mmu = MMU()   // default slim 0 → nibble 0 → absent
    if case .fault(let f) = mmu.translate(0, domain: 0, isSupervisor: true, isWrite: false) {
        #expect(f.reason == .invalidSegment)
    } else { Issue.record("expected fault") }
}
```
Plus stack-decode tests (exact window math per hardware-notes; derive expected values by hand in the test comments) and read-only-write fault test. Run — expect FAIL (compile errors: new model).

- [ ] **Step 2: Implement** the raw model + decode as specified; update `Bus`, `Machine`, `BusErrorTests`, and any other call sites via the factory. Setup-mode path in Bus is untouched (still flat).

- [ ] **Step 3: Run** — full suite green (TomHarte still setup-mode/flat; run a quick `LISAEMU_TH_DIR=... swift test -c release --filter TomHarteTests` smoke on ONE opcode file to confirm no harness regression).

- [ ] **Step 4: Commit** — `git commit -m "feat: hardware SORG/SLIM MMU register model with do_an_mmu decode semantics"`

---

### Task 5: I/O dispatcher, latches, MMU ports, ROM window

**Files:**
- Create: `Sources/LisaCore/IODispatcher.swift`
- Modify: `Sources/LisaCore/Bus.swift` (physical routing + latch/port handling + ROM)
- Test: `Tests/LisaCoreTests/IODispatcherTests.swift` (new), `BusTests` additions

**Interfaces:**
- Produces:
  - `Bus.loadROM(_ bytes: [UInt8])` — stores the 16 KB ROM; reads of `$FE0000-$FE3FFF`-pattern special-space physical addresses AND (while `setupMode == true`) reads of `$000000-$003FFF` return ROM bytes (reset-vector mirror); ROM writes are ignored+logged.
  - `IODispatcher` (owned by Bus): handles I/O-space offsets (the low 17 bits of an `.io` translation, or the `$FC0000`-block offsets while in setup mode):
    - `$E010`/`$E012`: ANY access sets/clears `bus.setupMode` (data ignored) — this replaces manual setupMode toggling; property becomes `private(set)` with the latch as the hardware path (tests may still use an internal helper).
    - `$E008/$E00A`: context bit 1 off/on; `$E00C/$E00E`: bit 2 off/on → `bus.domain = bit1 | (bit2 << 1)`.
    - `$8000 + mmuIndex*0x20000` pattern — NOTE: SLIM/SORG ports are per-segment-block addresses, not I/O-space offsets. Implement in Bus: while `setupMode == true`, a WRITE to any address whose low-17-bit offset is `$8000` (SLIM) or `$8008` (SORG) programs `mmu.domains[bus.domain][addr >> 17]`'s slim/sorg (12-bit masked) and increments `public private(set) var mmuPortWrites: Int`. Reads of those ports return the current register (needed by the ROM's MMU test) — implement read-back too.
    - `$E800`: video page latch (store byte; expose `bus.videoPageLatch`).
    - `$F801`: status register low byte — return a stored `bus.statusByte` (default 0; M1b will drive vsync bit 2). `$E018`/`$E01A`: vsync reset/enable — store flags, log.
    - `$C031`: board ID byte — return `0x00` initially (pre-Pepsi; revisit in ROM-trace task if POST objects).
    - VIA1 block (offset `$D801`+n*8, 16 regs) and VIA2 block (`$DC01`+n*2, 16 regs): logging stubs — reads return 0, writes stored in a 16-byte register file per VIA (so ROM read-back sees what it wrote), every access appended to `bus.ioTrace: [IOAccess]` (bounded 4096 + drop counter).
    - Everything else in I/O space: log to `ioTrace` as `.unknown`, reads return 0xFF.
  - `struct IOAccess { let offset: UInt32; let value: UInt8; let isWrite: Bool; let cycles: UInt64 }` — cycles stamped via a `cycleProvider: () -> UInt64` closure Machine wires up.
- [ ] **Step 1: Failing tests** — latch toggling (access to `$FCE010` during setup... bootstrapping note: at power-on setupMode starts TRUE and translation is off, so I/O access happens via the flat `$FCxxxx` physical addresses; test both paths), SLIM/SORG programming (write slim/sorg via ports in setup mode, exit setup, verify translation matches Task 4 expectations end-to-end), ROM mirror (loadROM then read8(0x0) == rom[0] in setup mode; after clearing setup with an MMU mapping, mirror is gone), VIA register-file read-back, ioTrace recording with bounded growth. Write the tests with exact hex values; run — FAIL.
- [ ] **Step 2: Implement** — `Bus.physical` becomes a router: setup mode → flat RAM except `$FC0000-$FDFFFF` offsets → IODispatcher, `$FE0000-$FE3FFF` → ROM, low mirror per above, SLIM/SORG port intercept; translated mode → `.memory` → RAM (bounds-checked), `.io` → IODispatcher, `.fault` → existing bus-error path.
- [ ] **Step 3: Run** — full suite green.
- [ ] **Step 4: Commit** — `git commit -m "feat: I/O dispatcher with hardware latches, MMU ports, VIA stubs, ROM window"`

---

### Task 6: ROM loader utility + lisadbg --rom

**Files:**
- Create: `Sources/LisaCore/ROMImage.swift`
- Modify: `Sources/lisadbg/main.swift`
- Test: `Tests/LisaCoreTests/ROMImageTests.swift`

**Interfaces:**
- Produces: `ROMImage.interleave(even: Data, odd: Data) throws -> [UInt8]` (requires equal 8 KB halves; byte i of output = even[i/2] when i is even else odd[i/2] — 68000 big-endian word = high byte from the 0175 "even" chip; VERIFY lane order empirically in Step 2 and fix the doc comment to match reality); `ROMImage.load(directory: URL) throws -> [UInt8]` looking for `341-0175-H.BIN`/`341-0176-H.BIN`.
- lisadbg: `lisadbg --rom <dir>` loads+interleaves, `bus.loadROM`, resets (setup mode on, so vectors fetch from the ROM mirror), enters the REPL; new REPL command `t [n]` = trace n instructions (disassemble each before stepping, print I/O accesses that occurred during the step by diffing `bus.ioTrace count`).

- [ ] **Step 1: Failing tests** — interleave: synthetic 8-byte halves produce the expected 16-byte interleave; error on length mismatch. Env-gated real-ROM test (`LISAEMU_ROM_DIR` set): interleaved ROM is 16384 bytes and **contains the ASCII bytes of "SERVICE MODE"** (the string we spotted at ~offset 0x44 of the interleave — compute the assertion by scanning for the substring, not a hardcoded offset). Run — FAIL.
- [ ] **Step 2: Implement**; against the real ROM, verify byte-lane order by checking the reset vectors make sense (initial PC must land inside the 16 KB ROM window / mirror — a sane PC like `$0000009x`-ish region or `$FE00xx`; if the vectors are garbage, the lanes are swapped — flip and re-check, then document the verified order).
- [ ] **Step 3: Run** — suite green without env var (ROM tests skipped); green with `LISAEMU_ROM_DIR=$HOME/Development/LisaROMs`.
- [ ] **Step 4: Commit** — `git commit -m "feat: ROM interleave loader and lisadbg --rom with instruction trace"`

---

### Task 7: Real-ROM execution trace (M1a exit criterion)

**Files:**
- Create: `docs/rom-trace-notes.md`
- Test: `Tests/LisaCoreTests/ROMBootTests.swift` (env-gated, nested under MusashiSuites)

**Interfaces:**
- This task is investigative but has hard deliverables. Consumes everything above.

- [ ] **Step 1: Automated boot-progress test (write it first, expectations loose)**

`ROMBootTests` (gated on `LISAEMU_ROM_DIR`): build Machine, loadROM, reset, `run(until: 2_000_000)` (0.4 emulated seconds). Assert: (a) `machine.halted == false` OR — if it halts — the test records WHERE (`cpu[.pc]`) and fails with that diagnostic; (b) `bus.ioTrace` is non-empty (the ROM touched I/O); (c) at least one SLIM/SORG port write occurred (the ROM programmed the MMU) — assert `bus.mmuPortWrites > 0` (counter from Task 5). These assertions are the honest minimum for "the ROM runs"; tighten them as reality permits.

- [ ] **Step 2: Trace and document**

Using `lisadbg --rom` (`t` command) and the test's failure diagnostics, trace the ROM's first few thousand instructions. Document in `docs/rom-trace-notes.md`: the reset vectors (SSP/PC values); the first I/O offsets touched, in order, annotated against hardware-notes.md names; how and when it programs SLIM/SORG (which segments, what values — decode them); when it drops setup mode; where it first reads VIA/COPS/status registers and what it appears to wait for (this list is M1b's requirements document); where execution stalls or faults under our current stubs, with PC and disassembly. Iterate: where a wrong stub response (e.g. board-ID `$C031` value, status bits) visibly diverts the ROM down an error path, adjust the stub default, note the evidence, and re-run. Do NOT implement new device behavior beyond stub return values — that's M1b.

- [ ] **Step 3: Finalize test expectations** to match documented reality (e.g. assert the known first MMU port write, assert setup mode gets dropped if the ROM in fact does so) — every assertion must cite the trace notes.

- [ ] **Step 4: Run** — full suite green without env; ROMBootTests green with env.

- [ ] **Step 5: Commit** — `git commit -m "feat: real Rev H ROM executes under trace; rom-trace-notes documents observed behavior"`
