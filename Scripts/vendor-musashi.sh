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
if "m68ki_stack_frame_buserr(sr);\n\n\tm68ki_jump_vector(EXCEPTION_BUS_ERROR);" in text and "m68ki_stack_frame_1000(REG_PPC, sr, EXCEPTION_BUS_ERROR)" not in text:
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
