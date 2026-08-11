# LisaEmu M6 — A Real Machine: Soft Power, RTC, and Living on the Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the machine's daily-life loop — power on, correct clock, work on the desktop, power off cleanly — killing both startup nag dialogs and satisfying the north star's last clause ("working mouse, keyboard, and clock").

**Architecture:** Investigation-led as established. Soft-power first (the COPS power-button event → the OS's own shutdown sequence → honoring the COPS power-off command — most machinery already exists: `powerCommandLog`, the documented command table), then the RTC (read/set clock via the documented COPS commands, host-time backed, deterministic for tests), then living on the desktop (Filer operations and app work with the now-live symbol overlay). Small carried quality fixes ride in a cleanup task. Close updates README status per user instruction.

**Tech Stack:** existing. Primary sources: `LIBHW` TIMERS + MACHINE units (clock/power commands — the hardware-notes §4/§7 citations), `source-SCHED`/PM for the OS shutdown path, the Office System sources for desktop flows. Key existing code: `Sources/LisaCore/COPS.swift` (`powerCommandLog`, `clockSource`, `defaultHostClockBytes`, the $E0-$EF clock-start stream), `EmulationController` (mailbox), lisadbg `click`/`type`.

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m6-real-machine` from current main (`8d2cafe`); commit per task, never amend; TDD for device/core; both-docs rule; strike-not-erase; evidence-gated changes cited file:line.
- Never commit Apple-derived data (incl. installed Widget images — canonical `~/Development/LisaImages/OS31-installed.widget` is precious: boot COPIES only; if a task produces a cleanly-shut-down image worth keeping, it lives in `~/Development/LisaImages/` with a documented name). Screenshots → `~/Development/LisaEmu-artifacts/` (m6-*.png).
- Env gates as established (`LISAEMU_ROM_DIR`/`DISK_DIR`/`WIDGET_DIR`/`TH_DIR`/`LINKMAP_DIR`); asset suites SKIP without env; release builds for long runs; one process at a time.
- Every prior pin stays green or stop-the-line: menu FNV `0xd09234d25516d0b8`/78,100 px, checkpointE 344, G/H installer FNVs, I/J/K, TomHarte exactly 807147/0/192913 at close. Clock changes may LEGITIMATELY move boot-time framebuffer pins that render a date — expected-movement re-anchors carry citations.
- COPS command facts (hardware-notes §4/§7, all cited): $02 read clock (TIMERS:620), $2C disable-for-set (TIMERS:656), $10 write clock nibble (TIMERS:666, MACHINE:468), $25 enable clock (TIMERS:673), $20 power off clock-off (MACHINE:425), $21 power off clock-on (MACHINE:427), $23 power off reboot-later (MACHINE:473), $2D reboot alarm (MACHINE:462); keyboard byte $FB = power button (synthesized key $08 down/up); $E0-$EF clock-start stream carries 5 clock bytes.
- Determinism discipline: `clockSource` injection exists — tests pin exact clock bytes with a fixed source; only interactive runs use host time.
- OQ falsifier watch continues (supervisor data access to both-present-differing segment): capture before any `Bus.translationDomain` change.
- Honest exit bar per task; the desktop task stops at a documented boundary if app flows require unbuilt subsystems (e.g. an app-install flow needing something new — document, don't fake).

---

### Task 1: Soft power — the button, the shutdown, the off state

**Files:**
- Modify: `Sources/LisaCore/COPS.swift` (power-button event injection: keyboard byte $FB per hardware-notes §4 — verify against the OS/ROM's expectation of $FB vs synthesized key $08 down/up and model what the OS's power-button handler actually consumes, cited; power-off commands $20/$21/$23 transition a new `powerState` and notify), `Sources/LisaCore/Machine.swift` (powered-off = stop executing, publish state), `Sources/LisaShell/EmulationController.swift` (power-button mailbox event; powered-off status publication), `Sources/lisadbg/main.swift` (`power` command = press the button), `LisaApp` (Power menu item/keyboard shortcut → button event; powered-off UI state; spec §4's "power on/off via COPS" — deferred since M1c, closes here)
- Test: `Tests/LisaCoreTests/COPSTests.swift` (+ shell/app cases): button event reaches the OS's input stream; $20/$21 sets powerState + stops machine; $23/$2D documented (reboot-later modeled or explicitly deferred with citation)

**Interfaces:**
- Produces: `cops.pressPowerButton()`; `Machine.powerState` (`.on`/`.off`); `EmulationController` `.powerButton` mailbox event + `.poweredOff` status.

- [ ] **Step 1:** Read the OS's power-button → shutdown path (the handler consuming the button event; the Desk-menu/dialog flow if any; the final COPS command write — MACHINE:425-473 region) and the ROM's $FB handling. Document in hardware-notes §7 (supersede/extend, strike-not-erase).
- [ ] **Step 2:** TDD: button-event delivery test; power-off-command test (machine stops, state published). Implement COPS/Machine/Shell/lisadbg/app plumbing.
- [ ] **Step 3:** THE LIVE PROOF: boot the installed Widget (copy), reach the desktop, press the power button (lisadbg `power`), and watch the OS run its own shutdown (screenshot any shutdown UI) → COPS power-off honored → machine stops. Then REBOOT THE SAME COPY: the dirty-volume dialog must be GONE (screenshot the clean boot). If the OS shutdown stalls, full root-cause method. Re-anchor/extend checkpoint (env-gated) to the furthest stable state; document Checkpoint L. Full matrix green. Commit(s).

---

### Task 2: The RTC — read it, set it, keep it

**Files:**
- Modify: `Sources/LisaCore/COPS.swift` (command $02 → clock-byte response per TIMERS:620's expected format — derive the exact byte layout from the OS source, cited, reconciling with `defaultHostClockBytes`/the $E0-$EF stream; set-clock sequence $2C → $10×N → $25 accepted and stored; clock state survives power-off with $21 [clock-on] vs cleared with $20 [clock-off], cited semantics), possibly `VIA6522`/dispatcher if delivery timing matters
- Test: `Tests/LisaCoreTests/COPSTests.swift` (fixed `clockSource`: $02 returns pinned bytes; set-sequence round-trips; power-off clock semantics)

**Interfaces:**
- Consumes: Task 1's `powerState`.
- Produces: a machine whose OS believes the clock.

- [ ] **Step 1:** Derive the exact $02 response format and set-sequence semantics from TIMERS:620-680 + MACHINE:462-473 (and the Office System's Preferences set-date flow if reachable). Document in hardware-notes §4 (strike-not-erase for anything the M1b-era stream model got wrong).
- [ ] **Step 2:** TDD with fixed clockSource; implement.
- [ ] **Step 3:** LIVE PROOF: boot the installed system — the clock-not-set dialog must be GONE (or the OS's date visibly correct — screenshot); if the OS still complains, trace its clock read and reconcile. Set the date via Preferences if reachable (screenshot). Watch boot-time pins for legitimate date-rendering movement (expected-movement re-anchors with citations). Full matrix. Commit(s).

---

### Task 3: Living on the desktop

**Files:** investigative; lisadbg scripting as needed; `docs/rom-trace-notes.md` ("Checkpoint M: the desktop in use"); evidence-gated fixes; screenshots
- Test: extend the env-gated Widget suite with any newly-stable pinnable state

**Interfaces:**
- Consumes: Tasks 1-2 (clean boot, correct clock).

- [ ] **Step 1:** Drive real desktop work: open the Internal Hard Disk window (Filer), navigate folders, create/rename a folder, open Preferences, pull down every menu (screenshot each distinct UI state). Symbol overlay: report which UNIT.PROC names resolve during Filer work (spec §4 payoff; the merged-table ambiguity minor may go live — handle per its self-documented note).
- [ ] **Step 2:** Attempt an application: the tool/document model (LisaWrite disks are on hand at `~/Development/LisaImages/Lisa_Office_System_3.1/682-0093-B_LisaWrite1_3.1/` + `682-0094-A_LisaWrite2_3.0/`) — insert the LisaWrite disk at the desktop, follow the Office System's own flow for installing/copying a tool onto the Widget, tear off a document, type into it (keyboard-at-desktop — closing Task 5's honest gap from M5). Every stall root-caused or documented. Screenshots throughout.
- [ ] **Step 3:** Document Checkpoint M; re-anchor stable states; full matrix. Commit(s).

---

### Task 4: Carried quality fixes

**Files:**
- Modify: `Tests/LisaCoreTests/ROMFloppyBootTests.swift` (checkpointJ guard-return → explicit `.enabled(if:)` skip, matching checkpointK's house style), `Sources/LisaCore/WidgetImage.swift` (legacy exception-raising `FileHandle.write(_:)` → throwing `write(contentsOf:)` so a disk-full error surfaces as a catchable throw, not an ObjC crash; doc comment aligned), `Sources/LisaShell/EmulationController.swift` + call sites (`ejectFloppy` bare-`eject()` asymmetry: route the user-menu eject through the OS-visible path or document why bare eject stands, cited), `Sources/LisaCore/FloppyController.swift` (session-overlay keyed by disk identity IF cheap and clean — a per-image-identity overlay store enabling arbitrary UI swaps; else document the decision and defer with scope estimate)
- Test: covering cases per change (skip behavior, write-error throw path, eject visibility)

**Interfaces:** none new beyond the above.

- [ ] Each fix: failing test (where testable) → implement → suites green → commit individually. $C015/800K and $FE099C stay parked unless one of these touches them (note in ledger if so).

---

### Task 5: Milestone close

**Files:** `docs/m6-demo.md`, spec annotation update (§5 M4-Desktop line: clock clause status; north star assessment), rom-trace-notes final state, OQ table, **`README.md` project-status update (USER INSTRUCTION — the "Current status" paragraph and milestone table must reflect M6's end state)**

- [ ] m6-demo (the daily-life loop: power on → clean boot, right clock → desktop work → power off; screenshots; honest frontier + M7 candidates); spec annotations (dated, annotate-not-erase); README status + milestone table updated; full regression all combos + xcodebuild + TomHarte (re-extract, exactly 807147/0/192913, delete .json, keep .gz); OQ statuses; separate commits. Report per convention.
