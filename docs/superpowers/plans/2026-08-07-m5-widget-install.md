# LisaEmu M5 — Widget: Hard Disk HLE, In-Emulator OS Install, Boot to the Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the machine the hard disk the installer is scanning for — a ProFile-family Widget HLE behind the parallel-port VIA — then install Office System 3.1 onto it in-emulator and boot from it toward the spec's M4 ⭐ desktop.

**Architecture:** Investigation-led as established. One protocol-derivation task (the ProFile parallel handshake, from the OS's own driver source — constants cited, never guessed), one device task (WidgetDrive HLE + persistent image container, TDD), then the install run (installer UI driven by input scripting, multi-disk swaps), then boot-from-Widget. The floppy write-through overlay stays session-scoped; the Widget image is the opposite by design — writes PERSIST to the user's image file (installing is the point).

**Tech Stack:** existing (Swift 6 SPM, Musashi vendored, Swift Testing). OS-source references now central: `OS/source-PROFILE.TEXT.unix.txt` + `OS/SOURCE-PROFILEASM.TEXT.unix.txt` (the OS's ProFile driver — the code that will run), `LIBHW` + `OS/SOURCE-CD` (device config/attach — the machinery M4 Task 4 already mapped), `LIBHW-DRIVERS` (parallel-port VIA handling). Full install media confirmed on hand: `~/Development/LisaImages/Lisa_Office_System_3.1/682-009{6,7,7,9}*-B_Office_System_3.1_{1..5}/*.dc42` (5 disks, DC42).

## Global Constraints

- Repo `~/Development/LisaEmu`; branch `m5-widget-install` from current main (`62e9e1e`); commit per task, never amend; TDD for device/core; investigative tasks produce evidence docs; both-docs rule (`docs/hardware-notes.md` + `docs/rom-trace-notes.md`); strike-not-erase.
- Never commit Apple-derived data: no ROMs, no disk images, no installed-Widget images, no symbol dumps. A **blank** Widget image (zeros + our own header-free raw format) is NOT Apple-derived — the emulator may create one and tests may synthesize them freely (no env gating needed for protocol tests). Anything the installer has WRITTEN is Apple-derived: installed images live in `~/Development/LisaImages/` only, never in the repo, never in fixtures.
- Screenshots of every new screen state → `~/Development/LisaEmu-artifacts/` (never committed).
- Env gates as established: `LISAEMU_ROM_DIR` / `LISAEMU_DISK_DIR` / `LISAEMU_TH_DIR` / `LISAEMU_LINKMAP_DIR`; new `LISAEMU_WIDGET_DIR` for tests needing a user-supplied (possibly installed) Widget image. Real-data suites SKIP without their env var. Release builds for long runs; one process at a time.
- Every prior pin stays green or gets a stop-the-line investigation before re-anchor: menu FNV `0xd09234d25516d0b8`/78,100 px, POST markers, checkpointE (blocksRead 344), checkpointG installer FNV `0x04a19e4eb59704f4`/60,107 px, TomHarte exactly 807147/0/192913 at close. NOTE: attaching a hard disk may legitimately change the ROM boot menu (a new boot device appears — the M2 precedent: anchors updated alongside rom-trace-notes with citation) and checkpointG's installer screen (the scan now finds a disk). Expected-movement re-anchors need the same citation discipline as always.
- Frontier facts (M4 close): the OS boots to the Lisa 7/7 Office System 3.0 installer dialog (Finished/Repair/Install/Restore); Install reports no suitable disk — no hard disk is modeled. VIA1 (`$FCD901`, stride 8) is the parallel-port/hard-disk VIA (hardware-notes §2). COPS keycap `$05` = ParallelPort (plug events). `dev_widget=3` (LDEQU:38-41); ProFile interleave table at LDPROF:311-314; the ROM's STARTUP FROM dialog enumerates boot devices. M4's device-attach machinery map (SOURCE-CD devrecs, `$C031` machine identity, Checkpoint G notes) is the starting map for how a ProFile devrec attaches.
- OQ residual watch (from OQ1″'s closure): the falsifier — a supervisor data access to a segment both domains map present-but-different — has never been observed; if the install's kernel↔user copies produce one, capture PC/SR/domain-latch/address-class BEFORE touching `Bus.translationDomain`.
- Deferred items riding here if convenient, NOT gating: soft-power/Power menu (deferred 4×), `$C015`/800K double-sided, parked 1MB-POST divergence `$FE099C`, merged-symbol-table ambiguity (revisit when a specific app loads — the overlay should finally resolve names once Office apps run off the Widget).
- Honest exit bar: OS 3.1 installed onto the Widget image in-emulator AND the machine boots from that Widget to the Office System desktop — OR a documented genuinely-new-subsystem boundary with the exact unsatisfiable condition cited.

---

### Task 1: The ProFile contract — protocol derivation + live probe trace

**Files:**
- Modify: `docs/hardware-notes.md` (new "§ ProFile/Widget parallel protocol" section — the contract Task 2 codes against), `docs/rom-trace-notes.md` ("Checkpoint H prep: the installer's disk scan")
- No production code in this task.

**Interfaces:**
- Produces: the written protocol contract — handshake line semantics on VIA1 (which port bits are CMD/BSY/PARITY/DATA, read/write sequencing), the command block format (`$00` read / `$01` write / `$02` write-verify — VERIFY against source, do not trust this line), status byte layout, block geometry (bytes per block incl. tag count, total block count for the 10 MB Widget — cited), spare-table/status-block behavior the OS actually exercises, and the attach path (what probe, over which port, makes the OS build a ProFile devrec — the exact conditional, file:line).

- [ ] **Step 1:** Read the OS's own driver: `OS/source-PROFILE.TEXT.unix.txt` + `OS/SOURCE-PROFILEASM.TEXT.unix.txt` end to end, plus the parallel-VIA handling in `LIBHW-DRIVERS` and the ProFile devrec construction in `OS/SOURCE-CD` (M4's Checkpoint G notes map this machinery — start there). Write the protocol contract into hardware-notes with a citation per constant. Anything the driver reads that we don't model gets an explicit line.
- [ ] **Step 2:** Live trace: run the boot to the installer (`bootdisk`), click Install (Task-3-style scripting is not built yet — a scratch harness reusing checkpointG's mechanism is fine, deleted after), and trace the scan: what addresses does the OS actually touch looking for a disk? Confirm the derived attach conditional against the live branch our machine takes today (the "no suitable disk" path). Document in rom-trace-notes.
- [ ] **Step 3:** Decide and document (in hardware-notes, with reasoning): the image container format (raw N-byte blocks, data+tag layout, no header — state N and the layout), creation policy (emulator creates blank images), persistence policy (write-back to file; when flushed). Both docs committed. Suites untouched this task; `swift test` no-env still green. Commit(s).

---

### Task 2: WidgetDrive HLE + persistent image container

**Files:**
- Create: `Sources/LisaCore/WidgetImage.swift` (image container: `init(createBlankAt: URL, blockCount: Int)`, `init(contentsOf: URL)`, `data(block:) -> Data`, `tag(block:) -> Data`, `write(block: Int, data: Data, tag: Data)`, `flush()`; write-back persistence per Task 1's documented policy; strict typed validation errors like DC42Image)
- Create: `Sources/LisaCore/WidgetDrive.swift` (the HLE state machine implementing Task 1's contract behind the VIA1 parallel port; `Device`-conformant like COPS/FloppyController; completion interrupts per the contract)
- Modify: `Sources/LisaCore/IODispatcher.swift` (route the parallel-port VIA1 port lines to WidgetDrive), `Sources/LisaShell/EmulationController.swift` (attach/detach Widget image via the mailbox seam, mirroring insertFloppy), `Sources/lisadbg/main.swift` (`--widget <path>` flag + `widget create <path>` command), `LisaApp` menu (Choose Widget Image… / Create Blank Widget Image…, mirroring the floppy-insert plumbing)
- Test: `Tests/LisaCoreTests/WidgetImageTests.swift`, `Tests/LisaCoreTests/WidgetDriveTests.swift` (synthetic blank images in temp dirs — NO env gating; protocol cases: read block round-trip, write persists across a reopen, status/handshake sequencing per the contract, error/status paths the OS driver checks), `Tests/LisaShellTests` attach seam case

**Interfaces:**
- Consumes: Task 1's written contract (every constant cited there — the implementer transcribes, never invents).
- Produces: `WidgetDrive` attached behind VIA1; `machine.attachWidget(image: WidgetImage)` (exact name per EmulationController's existing insertFloppy idiom); lisadbg `--widget`.

- [ ] **Step 1:** TDD WidgetImage (failing tests first: blank creation produces blockCount×N zeroed file; round-trip; reopen persistence; truncated-file typed error). Implement. Commit.
- [ ] **Step 2:** TDD WidgetDrive against the contract (failing protocol tests first — the handshake as the OS driver performs it, from Task 1's citations). Implement + IODispatcher routing. Commit.
- [ ] **Step 3:** Plumbing (EmulationController, lisadbg, LisaApp menu) + shell/app tests. Full matrix: `swift test` no-env; full-env release; `xcodegen generate --spec LisaApp/project.yml && xcodebuild test -scheme LisaApp`. **The ROM checkpoint watch:** with a Widget attached, does the ROM boot menu change (new boot device icon — the M2 precedent)? If yes: stop-the-line rules — document WHY with the ROM trace, then re-anchor menu FNV/px alongside rom-trace-notes; if no: say so in the ledger. Commit(s).

---

### Task 3: The install — drive the installer, swap five disks, watch every write

**Files:**
- Modify: `Sources/lisadbg/main.swift` (`click <x> <y>` and `type <text>` scripting primitives if not sufficient from bootdisk's mechanism), `Tests/LisaCoreTests/ROMFloppyBootTests.swift` (checkpointG re-anchor if the installer screen changes with a disk present; new install-progress checkpoint if a stable one exists)
- Docs: `docs/rom-trace-notes.md` ("Checkpoint H: the install")

**Interfaces:**
- Consumes: Task 2's `--widget` + attach seam; the 5-disk set at `~/Development/LisaImages/Lisa_Office_System_3.1/`.

- [ ] **Step 1:** With a blank Widget attached, re-run the scan (Install click): the installer should now FIND the disk. Screenshot the target-selection state. If the scan still fails: stop-the-line — trace the probe against Task 1's contract (this is the contract's first live test; fix with evidence, never by making the probe lie).
- [ ] **Step 2:** Run the install: initialize/name the disk as the installer directs (`type` scripting), feed disk swaps on request (eject/insert via the existing mailbox seam — script the sequence; the OS was told about ejects via COPS/floppy events per hardware-notes, so use the real eject path, not image-swapping behind its back). Long release run. Screenshot every distinct stage. Watch: Widget write traffic (persistence working — verify blocks land in the image file), the OQ falsifier, floppy reads off all five disks. Iterate stalls with evidence — any OS wait that never completes gets the full M4 Task-4 treatment (find the poster, cite the source, fix OUR divergence or document the boundary).
- [ ] **Step 3:** Install completes (installer says so — screenshot). Document Checkpoint H; re-anchor tests to the furthest STABLE state (the install itself is too long/stateful for CI — pin the stable precursor states; note what's narrative). Full matrix green. Commit(s).

---

### Task 4: Boot from the Widget — the desktop ⭐

**Files:**
- Modify: `Tests/LisaCoreTests/ROMFloppyBootTests.swift` or new `ROMWidgetBootTests.swift` (env-gated on `LISAEMU_WIDGET_DIR` — needs the user's installed image; SKIP without it), docs (`rom-trace-notes` "Checkpoint I: boot from Widget"), `docs/m5-demo.md` started
- Possible: `Sources/LisaCore/` evidence-gated fixes as stalls appear

**Interfaces:**
- Consumes: the installed Widget image from Task 3 (at `~/Development/LisaImages/`, never committed).

- [ ] **Step 1:** Warm restart (media survives — M2's warm reset); STARTUP FROM should now list the Widget; boot from it. The installed OS boot is new territory (LFS on the Widget, more drivers, the Desktop Manager). Iterate stalls with the established method. Screenshot every screen. **Symbol watch:** the Office System apps loading off the Widget are what the 22 Linkmaps actually cover — the moment `d`/`t` output starts resolving `UNIT.PROC` names, note it in the ledger (spec §4's overlay finally has data; the merged-table ambiguity minor becomes live — handle per its self-documented note if it bites).
- [ ] **Step 2:** Exit bar: the Office System desktop drawn (menu bar, icons — screenshot) with mouse/keyboard live — OR the documented boundary. Re-anchor: desktop framebuffer FNV pin in the env-gated Widget-boot suite; checkpointE/G unaffected (floppy-boot path unchanged when no Widget attached — verify). Full matrix. Commit(s).

---

### Task 5: Milestone close

**Files:** `docs/m5-demo.md`, spec annotation update (§5 spec-M3 "Widget" + spec-M4 "Desktop ⭐" lines — dated, annotate-not-erase), rom-trace-notes final state, OQ table check

**Interfaces:** none new.

- [ ] m5-demo (what the app shows now, reproduction incl. how to create a blank Widget and run the install, honest frontier); spec milestone annotations; full regression: `swift test` no-env + full-env release (+ `LISAEMU_WIDGET_DIR` suite if an installed image exists) + `xcodebuild test -scheme LisaApp` + TomHarte (re-extract `.json.gz`, run, totals must be EXACTLY 807147/0/192913, delete `.json` after — any movement is stop-the-line, no re-baselining); OQ statuses; separate commits. Report per convention.
