#!/bin/bash
# Vendors Musashi into Sources/CMusashi. Requires network + a C compiler.
# Re-runnable; overwrites previously vendored files.
# By default pins to the commit in MUSASHI_COMMIT.txt; pass --latest to update.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CMusashi"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

LATEST=false
if [[ "${1:-}" == "--latest" ]]; then
    LATEST=true
fi

if [[ "$LATEST" == "false" && -f "$DEST/MUSASHI_COMMIT.txt" ]]; then
    # Pin to recorded commit by fetching it specifically (can't use --depth 1 for old commits)
    COMMIT="$(cat "$DEST/MUSASHI_COMMIT.txt")"
    git clone https://github.com/kstenerud/Musashi.git "$TMP/musashi"
    git -C "$TMP/musashi" fetch --depth 1 origin "$COMMIT"
    git -C "$TMP/musashi" checkout FETCH_HEAD
else
    # Clone latest (--depth 1) and record the commit
    git clone --depth 1 https://github.com/kstenerud/Musashi.git "$TMP/musashi"
    git -C "$TMP/musashi" rev-parse HEAD > "$DEST/MUSASHI_COMMIT.txt"
fi

# Musashi generates its opcode handlers with a bootstrap tool.
cc -O2 -o "$TMP/m68kmake" "$TMP/musashi/m68kmake.c"
( cd "$TMP/musashi" && "$TMP/m68kmake" . m68k_in.c )

mkdir -p "$DEST/include"

require() {
  if [ ! -f "$1" ]; then
    echo "vendor-musashi: expected file missing: $1" >&2
    exit 1
  fi
}

require "$TMP/musashi/m68k.h"
cp "$TMP/musashi/m68k.h" "$DEST/include/"

# Use upstream's default configuration if the repo ships one, else the example.
# NOTE: this must live under include/, next to m68k.h. m68k.h does
# `#include "m68kconf.h"` with a quoted (relative) include, which C resolves
# against the including file's own directory first. Swift's `import CMusashi`
# only exposes the publicHeadersPath (include/) to consumers -- it does not
# see the target's private header search path -- so if m68kconf.h lived at
# the target root instead, module builds from other targets would fail with
# "'m68kconf.h' file not found" even though building CMusashi itself works.
if [ -f "$TMP/musashi/m68kconf.h" ]; then
  cp "$TMP/musashi/m68kconf.h" "$DEST/include/"
elif [ -f "$TMP/musashi/m68kconf.h.example" ]; then
  cp "$TMP/musashi/m68kconf.h.example" "$DEST/include/m68kconf.h"
else
  echo "vendor-musashi: no m68kconf.h or m68kconf.h.example found upstream" >&2
  exit 1
fi

# LisaEmu override: upstream ships M68K_EMULATE_ADDRESS_ERROR OFF. The Lisa's
# 68000 relies on real address-error trapping (and so does the
# TomHarte/ProcessorTests 68000 harness), so re-vendoring must not silently
# drop this back to OFF. Patch it back to ON every time we re-copy
# m68kconf.h from upstream.
CONF="$DEST/include/m68kconf.h"
if grep -q '^#define M68K_EMULATE_ADDRESS_ERROR  *M68K_OPT_OFF' "$CONF"; then
  sed -i '' 's/^#define M68K_EMULATE_ADDRESS_ERROR  *M68K_OPT_OFF/#define M68K_EMULATE_ADDRESS_ERROR  M68K_OPT_ON/' "$CONF"
  echo "vendor-musashi: patched M68K_EMULATE_ADDRESS_ERROR to ON (see Sources/CMusashi/include/m68kconf.h)"
elif ! grep -q 'M68K_EMULATE_ADDRESS_ERROR  *M68K_OPT_ON' "$CONF"; then
  echo "vendor-musashi: WARNING - could not find M68K_EMULATE_ADDRESS_ERROR OFF line to patch;" >&2
  echo "  verify Sources/CMusashi/include/m68kconf.h sets it to M68K_OPT_ON by hand." >&2
fi

require "$TMP/musashi/m68kcpu.c"
require "$TMP/musashi/m68kcpu.h"
cp "$TMP/musashi/m68kcpu.c" "$DEST/"
cp "$TMP/musashi/m68kcpu.h" "$DEST/"

# LisaEmu fix: upstream's sigsetjmp (BSD/macOS) variant of
# m68ki_set_address_error_trap() is missing the "stop if the cycle budget is
# exhausted" check that the plain-setjmp (#else, non-BSD) variant has right
# below it. macOS always defines _BSD_SETJMP_H, so this is the branch that
# actually compiles on our build machines. Without the check, an
# m68k_execute(N) call that hits an address error keeps running the main
# do-while loop and executes one extra "phantom" instruction at the
# exception vector target before the loop's own while(cycles>0) condition
# catches up -- corrupting PC/SP/memory for every address-error case (found
# via TomHarte 68000 ADD.w vectors, e.g. "d864 [ADD.w -(A4), D4] 6"). Patch
# it to mirror the #else branch's cycle check every time we re-vendor.
# Uses python3 (not sed/perl) for an exact literal-string replace -- this
# macro body is tab-indented, backslash-continued C, which is easy to get
# subtly wrong with a hand-typed regex (an earlier version of this script
# had exactly that bug: the pattern silently failed to match).
CPU_H="$DEST/m68kcpu.h"
python3 - "$CPU_H" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = (
    "\t\tif(CPU_STOPPED) \\\n"
    "\t\t{ \\\n"
    "\t\t\tif (m68ki_remaining_cycles > 0) \\\n"
    "\t\t\t\tm68ki_remaining_cycles = 0; \\\n"
    "\t\t\treturn m68ki_initial_cycles; \\\n"
    "\t\t} \\\n"
    "\t}\n"
)
patched = (
    "\t\tif(CPU_STOPPED) \\\n"
    "\t\t{ \\\n"
    "\t\t\tif (m68ki_remaining_cycles > 0) \\\n"
    "\t\t\t\tm68ki_remaining_cycles = 0; \\\n"
    "\t\t\treturn m68ki_initial_cycles; \\\n"
    "\t\t} \\\n"
    "\t\tif(m68ki_remaining_cycles <= 0) \\\n"
    "\t\t{ \\\n"
    "\t\t\treturn m68ki_initial_cycles - m68ki_remaining_cycles; \\\n"
    "\t\t} \\\n"
    "\t}\n"
)
if "if(m68ki_remaining_cycles <= 0)" in text:
    print("vendor-musashi: sigsetjmp address-error trap already has the cycle-exhaustion check")
elif anchor in text:
    assert text.count(anchor) == 1, "anchor is not unique, refusing to guess which occurrence to patch"
    open(path, 'w').write(text.replace(anchor, patched, 1))
    print("vendor-musashi: patched m68ki_set_address_error_trap (sigsetjmp/BSD variant) to check cycle exhaustion")
else:
    sys.stderr.write(
        "vendor-musashi: WARNING - could not find the sigsetjmp address-error trap macro to patch;\n"
        "  verify Sources/CMusashi/m68kcpu.h's m68ki_set_address_error_trap(m68k) (BSD branch, guarded\n"
        "  by #ifdef _BSD_SETJMP_H) includes a cycle-exhaustion check by hand -- see the comment above\n"
        "  it for what upstream's version is missing.\n"
    )
PYEOF

# LisaEmu fix: upstream's m68ki_exception_bus_error() (m68kcpu.h) always
# builds the 68010 format-8 (29-word) bus/address-error frame via
# m68ki_stack_frame_1000 -- which also hardcodes the FAULT ADDRESS field to
# 0 -- regardless of CPU_TYPE. That's wrong for our 68000-only emulation:
# the real 68000 group-0 (7-word) frame is built by m68ki_stack_frame_buserr
# (m68kcpu.h, right above m68ki_stack_frame_1000), which
# m68ki_exception_address_error() already calls for address errors. This
# patch makes m68ki_exception_bus_error() call the same builder, so real bus
# errors (MMU translation faults, via M68K.pulseBusError) get a correct,
# unwindable frame instead of a fabricated 68010-shaped one with a zeroed
# fault address. Uses python3 (not sed) for an exact literal-string replace,
# same rationale as the sigsetjmp patch above: the anchor is tab-indented,
# multi-line C, easy to get subtly wrong with a hand-typed regex.
python3 - "$CPU_H" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = (
    "\tuint sr = m68ki_init_exception();\n"
    "\n"
    "\t/* Note: This is implemented for 68010 only! */\n"
    "\tm68ki_stack_frame_1000(REG_PPC, sr, EXCEPTION_BUS_ERROR);\n"
    "\n"
    "\tm68ki_jump_vector(EXCEPTION_BUS_ERROR);\n"
)
patched = (
    "\tuint sr = m68ki_init_exception();\n"
    "\n"
    "\t/* LisaEmu fix: upstream's m68ki_exception_bus_error() unconditionally\n"
    "\t * built the 68010 format-8 (29-word) frame via m68ki_stack_frame_1000,\n"
    "\t * which also hardcodes the FAULT ADDRESS field to 0 -- wrong for a real\n"
    "\t * 68000, which pushes the compact 7-word group-0 frame built by\n"
    "\t * m68ki_stack_frame_buserr() (m68kcpu.h:1681), consuming\n"
    "\t * m68ki_aerr_address/m68ki_aerr_write_mode/m68ki_aerr_fc -- the same\n"
    "\t * three globals m68ki_exception_address_error() below already consumes\n"
    "\t * via the same builder (see the M68K_EMULATE_ADDRESS_ERROR block\n"
    "\t * above). Musashi's own 68000 address-error path already calls\n"
    "\t * m68ki_stack_frame_buserr(); this patch makes the 68000 bus-error path\n"
    "\t * match it. Callers (Swift's M68K.pulseBusError(address:isWrite:), via\n"
    "\t * the lisa_set_bus_error_fault shim -- see shim.h/shim.c) must set\n"
    "\t * those three globals before calling m68k_pulse_bus_error(). See\n"
    "\t * Scripts/vendor-musashi.sh, which re-applies this patch after\n"
    "\t * re-vendoring from upstream.\n"
    "\t */\n"
    "\tm68ki_stack_frame_buserr(sr);\n"
    "\n"
    "\tm68ki_jump_vector(EXCEPTION_BUS_ERROR);\n"
)
if "m68ki_stack_frame_1000(REG_PPC, sr, EXCEPTION_BUS_ERROR)" not in text:
    # Either this stage's plain m68ki_stack_frame_buserr(sr) form or the
    # round-4 stage's frame_pc/frame_addr form (applied further below) --
    # both mean the 68010 frame call is already gone.
    print("vendor-musashi: m68ki_exception_bus_error already patched to use m68ki_stack_frame_buserr")
elif anchor in text:
    assert text.count(anchor) == 1, "anchor is not unique, refusing to guess which occurrence to patch"
    open(path, 'w').write(text.replace(anchor, patched, 1))
    print("vendor-musashi: patched m68ki_exception_bus_error to build the real 68000 group-0 frame (m68ki_stack_frame_buserr)")
else:
    sys.stderr.write(
        "vendor-musashi: WARNING - could not find m68ki_exception_bus_error's m68ki_stack_frame_1000 call to patch;\n"
        "  verify Sources/CMusashi/m68kcpu.h's m68ki_exception_bus_error() calls m68ki_stack_frame_buserr(sr) by\n"
        "  hand -- see the comment above it (and M68K.swift's pulseBusError doc comment) for what upstream is\n"
        "  missing and why it matters (a real 68000 group-0 frame vs. upstream's fabricated 68010 one).\n"
    )
PYEOF

# LisaEmu fix (M4 Task 4 round 4): real-68000 jump-gate bus-error frame
# semantics. The Lisa OS's recoverable-bus-error engine (SOURCE-EXCEPASM
# BUS_ERR) decodes the group-0 frame's instruction register and re-runs
# faulting JSR/JMP/RTS/RTE gates with instruction-specific frame-PC
# adjustments (JSR.L -> PC-6, JSR d16(An) -> PC-4, JSR (An)/JMP/RTS -> PC-2),
# expecting a faulting JSR's return address to be UN-pushed and a faulting
# RTS's pop to be committed -- real 68000 microcode order (target prefetch
# inside the jump instruction). Stock Musashi completes the jump and faults
# at the next loop-top opcode fetch, which made the OS's gate re-runs push a
# second return address into syscall parameter frames (fatal OS error 10201
# observed live -- docs/rom-trace-notes.md "Checkpoint G (round 4)").
# This stage: (a) instruments the execute loop to flag the opcode fetch and
# record each instruction's start, (b) parameterizes the group-0 frame
# builder on PC + access address (address-error path keeps legacy REG_PC /
# m68ki_aerr_address for TomHarte conformance), (c) rewrites the bus-error
# exception to push real-68000 jump-fault frames and undo a JSR's committed
# push. Pinned by Tests/LisaCoreTests/BusErrorFrameTests.swift.
python3 - "$DEST/m68kcpu.c" "$CPU_H" <<'PYEOF'
import sys
cpath, hpath = sys.argv[1], sys.argv[2]

# --- m68kcpu.c: globals ---
# Idempotence note: 'm68ki_opcode_fetch_active' is the key for BOTH
# m68kcpu.c sub-patches (the globals AND the execute-loop instrumentation)
# -- a hypothetical half-applied file (globals present, loop untouched)
# would be skipped wholesale here. That state is near-impossible in
# practice: both sub-patches run in one pass below and each asserts its
# anchor is unique before writing, so a failure aborts before the file is
# written at all. Documented rather than defended (per M4 Task 4 round-5
# review); if it ever occurs, delete the LisaEmu globals block from
# m68kcpu.c and re-run this script.
c = open(cpath).read()
if 'm68ki_opcode_fetch_active' in c:
    print("vendor-musashi: m68kcpu.c round-4 globals already present")
else:
    anchor = "uint    m68ki_aerr_fc;\n\njmp_buf m68ki_bus_error_jmp_buf;"
    assert c.count(anchor) == 1, "m68kcpu.c globals anchor not unique/found"
    c = c.replace(anchor, """uint    m68ki_aerr_fc;

/* LisaEmu (M4 Task 4 round 4): set around the execute loop's opcode fetch
 * so m68ki_exception_bus_error() (m68kcpu.h) can distinguish a
 * next-instruction (jump-target) prefetch fault from a mid-instruction data
 * fault, and recover the address of the jump instruction that caused it.
 * The Lisa OS's recoverable-bus-error engine (its BUS_ERR handler) decodes
 * the group-0 frame's IR + PC to re-run faulting JSR/JMP/RTS/RTE gates;
 * see m68ki_exception_bus_error()'s LisaEmu comment for the full contract.
 * Re-applied after re-vendoring by Scripts/vendor-musashi.sh. */
uint    m68ki_opcode_fetch_active;
uint    m68ki_ppc_prev;

jmp_buf m68ki_bus_error_jmp_buf;""")
    # --- m68kcpu.c: execute-loop instrumentation ---
    anchor = ("\t\t\t/* Read an instruction and call its handler */\n"
              "\t\t\tREG_IR = m68ki_read_imm_16();\n"
              "\t\t\tm68ki_instruction_jump_table[REG_IR]();\n"
              "\t\t\tUSE_CYCLES(CYC_INSTRUCTION[REG_IR]);")
    assert c.count(anchor) == 1, "m68kcpu.c execute-loop anchor not unique/found"
    c = c.replace(anchor, ("\t\t\t/* Read an instruction and call its handler */\n"
              "\t\t\t/* LisaEmu (M4 Task 4 round 4): flag the opcode fetch so a bus\n"
              "\t\t\t * error raised here is classified as a jump-target prefetch\n"
              "\t\t\t * fault (real 68000: the fault happens DURING the jump\n"
              "\t\t\t * instruction); record each instruction's start address so\n"
              "\t\t\t * the exception builder can re-point the frame PC at it. */\n"
              "\t\t\tm68ki_opcode_fetch_active = 1;\n"
              "\t\t\tREG_IR = m68ki_read_imm_16();\n"
              "\t\t\tm68ki_opcode_fetch_active = 0;\n"
              "\t\t\tm68ki_instruction_jump_table[REG_IR]();\n"
              "\t\t\tUSE_CYCLES(CYC_INSTRUCTION[REG_IR]);\n"
              "\t\t\tm68ki_ppc_prev = REG_PPC;"))
    open(cpath, 'w').write(c)
    print("vendor-musashi: patched m68kcpu.c (round-4 globals + execute-loop instrumentation)")

# --- m68kcpu.h ---
h = open(hpath).read()
if 'm68ki_stack_frame_buserr(uint sr, uint pc, uint address)' in h:
    print("vendor-musashi: m68kcpu.h round-4 frame semantics already present")
    sys.exit(0)

anchor = ("extern uint           m68ki_aerr_address;\n"
          "extern uint           m68ki_aerr_write_mode;\n"
          "extern uint           m68ki_aerr_fc;")
assert h.count(anchor) == 1, "m68kcpu.h extern anchor not unique/found"
h = h.replace(anchor, anchor + "\n/* LisaEmu (M4 Task 4 round 4) -- see m68kcpu.c and\n * m68ki_exception_bus_error() below. */\nextern uint           m68ki_opcode_fetch_active;\nextern uint           m68ki_ppc_prev;")

anchor = ("static inline void m68ki_stack_frame_buserr(uint sr)\n"
          "{\n"
          "\tm68ki_push_32(REG_PC);\n"
          "\tm68ki_push_16(sr);\n"
          "\tm68ki_push_16(REG_IR);\n"
          "\tm68ki_push_32(m68ki_aerr_address);\t/* access address */")
assert h.count(anchor) == 1, "m68kcpu.h frame-builder anchor not unique/found"
h = h.replace(anchor, ("/* LisaEmu (M4 Task 4 round 4): parameterized on the pushed PC and access\n"
          " * address so the 68000 bus-error path can push real-68000 jump-fault\n"
          " * values while the address-error path keeps its historical REG_PC /\n"
          " * m68ki_aerr_address behavior (TomHarte conformance). */\n"
          "static inline void m68ki_stack_frame_buserr(uint sr, uint pc, uint address)\n"
          "{\n"
          "\tm68ki_push_32(pc);\n"
          "\tm68ki_push_16(sr);\n"
          "\tm68ki_push_16(REG_IR);\n"
          "\tm68ki_push_32(address);\t/* access address */"))

anchor = "\tm68ki_stack_frame_buserr(sr);\n\n\tm68ki_jump_vector(EXCEPTION_ADDRESS_ERROR);"
assert h.count(anchor) == 1, "m68kcpu.h address-error call-site anchor not unique/found"
h = h.replace(anchor, "\tm68ki_stack_frame_buserr(sr, REG_PC, m68ki_aerr_address);\n\n\tm68ki_jump_vector(EXCEPTION_ADDRESS_ERROR);")

anchor = "\tm68ki_stack_frame_buserr(sr);\n\n\tm68ki_jump_vector(EXCEPTION_BUS_ERROR);"
assert h.count(anchor) == 1, "m68kcpu.h bus-error call-site anchor not unique/found (run the group-0 frame patch first)"
h = h.replace(anchor, """\t/* LisaEmu fix (M4 Task 4 round 4): real-68000 jump-gate frame
\t * semantics. The Lisa OS's recoverable-bus-error engine
\t * (SOURCE-EXCEPASM BUS_ERR) decodes the group-0 frame's instruction
\t * register and applies instruction-specific PC adjustments to RE-RUN a
\t * faulting jump after its target code segment is swapped in:
\t * JSR.L -> PC-6, JSR d16(An) -> PC-4, JSR (An)/JMP/RTS/RTE -> PC-2,
\t * and for RTS it additionally un-pops the return address. Those
\t * constants encode real 68000 microcode order: the TARGET PREFETCH
\t * happens inside the jump instruction, BEFORE a JSR pushes its return
\t * (so a re-run pushes it exactly once) and AFTER an RTS pops it.
\t * Musashi instead completes the jump and faults at the next loop-top
\t * opcode fetch with PC = target+2 -- which made the OS's re-run push a
\t * SECOND return address into a syscall parameter frame (observed live;
\t * docs/rom-trace-notes.md "Checkpoint G (round 4)"). When the fault is
\t * that loop-top fetch (m68ki_opcode_fetch_active) and the previous
\t * instruction (still in REG_IR -- the aborted fetch never overwrote
\t * it) is one of the OS-recoverable jump forms, push the frame the real
\t * 68000 way: PC = jump address + the OS's expected offset, access
\t * address = the full unmasked target (REG_PC-2, preserving the OS's
\t * $A0xxxxxx gate tag bits, which the 24-bit bus mask strips before the
\t * Swift Bus ever sees them), and undo a JSR's already-committed push.
\t * Mid-instruction data faults push PC = instruction start + 2 (the
\t * convention the OS's TST stack-probe case decodes with PC-2). */
\t{
\t\tuint frame_pc = REG_PC;
\t\tuint frame_addr = m68ki_aerr_address;
\t\tif(m68ki_opcode_fetch_active)
\t\t{
\t\t\t/* Edge (documented, accepted): REG_IR still holds the LAST
\t\t\t * EXECUTED instruction. If an exception/interrupt dispatched
\t\t\t * right after a completed jump form and the FIRST opcode fetch
\t\t\t * of its handler faulted, that fetch would be misclassified as
\t\t\t * the jump's own target prefetch (PC re-pointed at the old jump
\t\t\t * site, a JSR's push wrongly undone). Unreachable on traced
\t\t\t * Lisa paths: every exception/interrupt vector points into
\t\t\t * resident kernel segments (vec dump at Checkpoint G --
\t\t\t * $2E2xxx/$5208xx/$F80018/$4602xx), whose fetches cannot
\t\t\t * fault; only the deliberate $A0xxxxxx gate targets do, and
\t\t\t * those are always reached by the jump itself. */
\t\t\tuint op = REG_IR;
\t\t\tuint adj = 0, undo_push = 0, matched = 0;
\t\t\tif(op == 0x4eb9)                 { adj = 6; undo_push = 1; matched = 1; } /* JSR (xxx).L */
\t\t\telse if((op & 0xfff8) == 0x4ea8) { adj = 4; undo_push = 1; matched = 1; } /* JSR d16(An) */
\t\t\telse if((op & 0xfff8) == 0x4e90) { adj = 2; undo_push = 1; matched = 1; } /* JSR (An)    */
\t\t\telse if(op == 0x4ef9 || (op & 0xfff8) == 0x4ed0 ||
\t\t\t        op == 0x4e75 || op == 0x4e73)
\t\t\t                                 { adj = 2; matched = 1; }               /* JMP.L / JMP (An) / RTS / RTE */
\t\t\tif(matched)
\t\t\t{
\t\t\t\tframe_pc = m68ki_ppc_prev + adj;
\t\t\t\tframe_addr = REG_PC - 2;
\t\t\t\tif(undo_push)
\t\t\t\t{
\t\t\t\t\tif(sr & 0x2000) REG_SP += 4;
\t\t\t\t\telse            REG_USP += 4;
\t\t\t\t}
\t\t\t}
\t\t\tm68ki_opcode_fetch_active = 0;
\t\t}
\t\telse
\t\t{
\t\t\tframe_pc = REG_PPC + 2;
\t\t}
\t\tm68ki_stack_frame_buserr(sr, frame_pc, frame_addr);
\t}

\tm68ki_jump_vector(EXCEPTION_BUS_ERROR);""")
open(hpath, 'w').write(h)
print("vendor-musashi: patched m68kcpu.h (round-4 jump-gate bus-error frame semantics)")
PYEOF

require "$TMP/musashi/m68kops.h"
cp "$TMP/musashi/m68kops.h" "$DEST/"
# m68kmake writes the generated opcode table source as m68kops.c in the
# working directory it was invoked from (see the m68kmake call above).
require "$TMP/musashi/m68kops.c"
cp "$TMP/musashi/m68kops.c" "$DEST/"

require "$TMP/musashi/m68kdasm.c"
cp "$TMP/musashi/m68kdasm.c" "$DEST/"

# m68k_in.c is the raw opcode-info input consumed by m68kmake; it is not
# compiled, but keep it alongside the generated output for provenance.
[ -f "$TMP/musashi/m68k_in.c" ] && cp "$TMP/musashi/m68k_in.c" "$DEST/"

# Included-not-compiled sources, if present in this Musashi revision:
for f in m68kfpu.c m68kmmu.h; do
  [ -f "$TMP/musashi/$f" ] && cp "$TMP/musashi/$f" "$DEST/"
done
[ -d "$TMP/musashi/softfloat" ] && cp -R "$TMP/musashi/softfloat" "$DEST/softfloat"

echo "Vendored Musashi $(cat "$DEST/MUSASHI_COMMIT.txt")"
