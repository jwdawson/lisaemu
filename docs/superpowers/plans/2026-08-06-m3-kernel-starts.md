# LisaEmu M3 — Gate Diagnosis & Kernel Start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discharge the spec bar M2 inherited — "kernel starts": diagnose why the Pascal loader stops at the trap #6 segment-call gate (emulation divergence vs genuine runtime boundary), fix what the evidence demands, and carry the boot as far as the evidence allows toward the Lisa OS kernel executing — with the long-open OQ1 (inactive-domain MMU semantics) watched at its predicted forcing point. Plus the parked-debt bundle both prior finals flagged.

**Architecture:** Investigation-led, exactly like M1b/M2: a diagnosis task (with the recorded anchors and the 1 MB RAM discriminator), then trace-checkpoint/device-debt alternation. No new peripherals unless the boot path proves it needs them (Widget + Power menu remain consciously deferred to M4 unless evidence forces them).

**Tech Stack:** existing LisaEmu stack. ROM at `~/Development/LisaROMs`, images at `~/Development/LisaImages` (`LISAEMU_ROM_DIR`/`LISAEMU_DISK_DIR`). OS-source references for loader interpretation: `/Users/jdawson/Development/Lisa_Source/LISA_OS/OS/source-ldlfs.text.unix.txt` (the Pascal loader), `source-ldmicro`, `source-LDEQU`, and the OS proper (`SOURCE-STARTUP` etc.) as the journey advances.

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m3-kernel-starts` from current main (`4cea30f`); commit per task, never amend; TDD for device/core changes; investigative tasks produce evidence docs; both-docs rule (ROM/loader-observed behavior wins; strike-through-not-erase).
- Never commit ROMs/images/Apple-derived data; env-gating as established; one test/lisadbg process at a time; release builds for long runs; watched-PC single-step technique for reachability; TomHarte full run at milestone end (re-extract .json.gz first, delete .json after).
- Recorded gate anchors (from M2, docs/rom-trace-notes.md "OS loader (Task 6)" + "Two open hypotheses"): TRAP #6 vector `$98` overwritten `$FE1D14 → $A84000`; `$A84000` = seg-84 (`84<<17=$A80000`) offset `$4000`, unrelocated placeholder read from DC42 block 1 offset 478; loader-programmed seg 84: `SORG=$FE4` (phys `$FE4×512=$1FC800`), `SLIM=$7DB`; `$A84000` → phys `$200800`, just past the 2 MB RAM end; loader relocated to `$100000` = `prom_realsize($2A8)/2`; hand-off cells `$22E=2`, `$210=$1C`, `$212=1`; cascade after the gate: `$FE1D14 → $FE06AC` spin → menu return (verified live).
- Hypothesis discriminators to run FIRST (Task 1): (i) **1 MB RAM configuration** — `prom_realsize` halves, the loader relocates to `$080000`, and if the seg-84 math is RAM-size-relative the gate may resolve or move diagnostically; (ii) **source-ldlfs comparison** — read the Pascal loader's own segment-call/relocation machinery in the OS source to establish what SHOULD happen at the first inter-segment call on real hardware (does ldlfs expect the PROM's trap #6 to still be installed? does it relocate the vector later? is `$A84000` a to-be-patched literal the loader fixes AFTER something we're not providing?); (iii) MMU decode re-check against the gate's exact SLIM/SORG values (limit semantics for `SLIM=$7DB` — nibble 7 readWrite, limit byte $DB = two's-comp → 37 pages? verify offset $4000 is within/without the decoded window and whether real hardware would fault here at all).
- Parked/carried debts folded into this milestone (Task 3): halted-status staleness (M1c), the two unhedged "(M3 boundary)" doc fragments (rom-trace-notes:1163, m2-demo:7), unclamp-as-benign-no-op modeling note, DISKCMD-during-completion-window doc note, $C015-vs-double-sided doc note, COPS clock-test comment precision, completion-wait citation $FE1E3E→$FE1E46. Widget/Power menu: NOT here (M4), re-record the deferral.
- Honest exit bar (Task 5): "kernel starts" per spec = the Lisa OS kernel (or its loader-handoff) executing with documented evidence — realistic outcomes range from "gate falls, ldlfs completes, SYSTEM.OS loading begins" to "gate diagnosed as genuine runtime boundary requiring X, documented with the implementation path" — either is a legitimate milestone end if the evidence is complete; scope-creep into new subsystems is not.

---

### Task 1: The gate diagnosis (investigative — the milestone pivot)

**Files:**
- Modify: `docs/rom-trace-notes.md` ("Gate diagnosis (M3 Task 1)" section), possibly `Sources/LisaCore/MMU.swift`/`Machine.swift`/`Bus.swift` (ONLY if a divergence is proven, evidence-gated), `Tests/LisaCoreTests/*` (diagnosis-derived regression pins)

**Interfaces:** deliverables:
- [ ] **Step 1 — discriminator (i):** run the full boot script on a 1 MB Machine (`Machine(ramSize: 0x10_0000)` — check `prom_realsize` handling: does our setup write $2A8, or does the ROM size RAM itself? trace it; the ROM's RAM sizing was never fully traced — M2 noted it reads $FCF000-region and low-core cells; establish what value lands in $2A8 for 1 MB and follow the loader's relocation + seg-84 programming + gate address). Document the delta vs 2 MB.
- [ ] **Step 2 — discriminator (ii):** read source-ldlfs (and ldmicro's tail) for the segment-call contract: identify the code that SHOULD patch/relocate the trap #6 vector or the segment bases; determine the expected value of vector $98 and of the seg-84 window at the first inter-segment call on real hardware; compare against our observed `$A84000`/`SORG=$FE4/SLIM=$7DB`. Name the divergence precisely (or confirm the placeholder is expected and the fault is the designed mechanism — Lisa Pascal segment faults may be HOW segments load lazily! Check ldlfs for a trap-handler installation that LOADS the missing segment on fault — if the Pascal runtime uses fault-driven segment loading, then the "failure" is our bus-error/fault delivery diverging from what the handler expects, and the M2 Task-1 group-0 frame work becomes load-bearing here: verify the handler RTEs and what it reads from the frame).
- [ ] **Step 3 — discriminator (iii):** decode seg-84's exact SLIM/SORG under our MMU rules vs the hardware rules for this case; verify whether $A84000's offset $4000 SHOULD fault, and whether the fault class (bus error via MMU limit vs something else) matches what the loader's handler (if any) expects.
- [ ] **Step 4:** synthesize: root cause named with evidence; if an emulation divergence — fix it (TDD; regression pin; both-docs update; re-run the boot: does the gate fall?); if a genuine runtime boundary — document the implementation path (what Task 2/5 must build). Update the two unhedged doc fragments while in the file (fold from the debt list). Suites green all combos. Commit(s) with evidence.

---

### Task 2: Trace checkpoint D — beyond the gate (contingent on Task 1's outcome)

**Files:**
- Modify: `docs/rom-trace-notes.md` ("Checkpoint D"), stubs/devices as evidence dictates, `Tests/LisaCoreTests/ROMFloppyBootTests.swift` (frontier)

**Interfaces:** investigative; shaped by Task 1:
- [ ] If the gate fell: follow ldlfs onward — expected landmarks from source-ldlfs: LFS catalog reads (blocksRead climbing well past 24), locating + loading the OS files (SYSTEM.OS-class objects), screen activity (the loader may draw a progress/"hourglass"), interrupt unmasking (**SR finally < $2700 — the floppy completion IRQ delivers for real for the first time: watch for delay-vs-timeout issues against twig_entry's D2 timeout and fix with evidence**), COPS clock reads ($02 — now deterministic), **OQ1 WATCH at its predicted forcing point: the Pascal segment loader mapping many segments — if it programs SLIM/SORG with setup toggles from non-zero domains or switches domains, capture EVERYTHING; this may close OQ1 at last**. Document the new frontier honestly (next boundary named with evidence).
- [ ] If the gate stands (runtime boundary): implement the documented minimal mechanism from Task 1's path IF it is loader-runtime-scoped (e.g. fault-driven segment loading requiring correct frame contents/RTE resume — core-emulation work, in scope) — NOT if it requires a new peripheral (document and stop).
- [ ] Floppy WRITES contingency: if the boot path writes (swap/temp), implement write-through to the in-memory image ONLY (session-scoped; file persistence explicitly deferred with a documented policy note), DISKERR write-path codes per §9, tests. If no writes observed, record that and defer.
- [ ] Suites green; frontier re-anchored with citations; commit(s).

---

### Task 3: Parked-debt bundle

**Files:**
- Modify: `Sources/LisaShell/EmulationController.swift` (halted-status staleness: publish on transition AND periodically while halted — the M1c parked item; test via the extracted decision function + if feasible the debugSync halt seam), `Sources/LisaCore/FloppyController.swift` + `docs/hardware-notes.md` (unclamp benign-no-op modeling + DISKCMD-during-completion-window note + $C015/double-sided note), `docs/rom-trace-notes.md` (completion-wait citation $FE1E46; any remaining unhedged fragments not already fixed in Task 1), `Tests/*` as needed

**Interfaces:**
- [ ] Each debt item fixed/documented per its ledger ruling; tests for the behavioral one (halted-status); doc items cited. Re-record the Widget/Power-menu deferral to M4 explicitly. Suites green; commit.

---

### Task 4: Kernel-start push (the milestone attempt)

**Files:** trace-driven; `docs/rom-trace-notes.md`, tests, evidence-gated core/device changes

**Interfaces:**
- [ ] With Tasks 1-3 landed, drive the boot as far as it goes: iterate stalls with the established loop (trace → OS-source interpretation → evidence-gated fix). Landmarks to watch: ldlfs completing; the OS kernel image loading (the loader's hand-off per SOURCE-STARTUP's expectations — low-core cells, MMU state at hand-off); the kernel's own initialization beginning (INITSYS-class code from SOURCE-STARTUP — trap vector installation, sysglobal setup). STOP at a genuinely-new-subsystem dependency (Widget probe, serial, etc.) with the boundary documented — that's M4's requirements doc.
- [ ] OQ1: if checkpoint D didn't close it, this is the second chance — same capture instructions.
- [ ] ROMFloppyBootTests final M3 form: assert the documented furthest-state markers (robust + exact, cited). Suites green; commit(s).

---

### Task 5: Milestone close — docs, demo, regression

**Files:**
- Modify: `docs/m3-demo.md` (new), `docs/rom-trace-notes.md` (final state), `docs/superpowers/specs/2026-08-03-lisa-emulator-design.md` (milestone-table annotation: M2 = disk loads ✓; kernel-starts status per THIS milestone's outcome — honest wording), memory-worthy facts summarized

**Interfaces:**
- [ ] docs/m3-demo.md: what now happens on boot (in-window + lisadbg), how far, reproduce commands, screenshot to ~/Development/LisaEmu-artifacts/m3-boot-progress.png if the screen changed (never committed).
- [ ] Full regression: suites green all env combos; xcodebuild test green; full TomHarte release run 807147/0/192913 (re-extract/delete per procedure). OQ1 status honestly recorded wherever it landed. Commit.
