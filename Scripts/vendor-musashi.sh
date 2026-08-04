#!/bin/bash
# Vendors Musashi into Sources/CMusashi. Requires network + a C compiler.
# Re-runnable; overwrites previously vendored files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CMusashi"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

git clone --depth 1 https://github.com/kstenerud/Musashi.git "$TMP/musashi"
git -C "$TMP/musashi" rev-parse HEAD > "$DEST/MUSASHI_COMMIT.txt"

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

require "$TMP/musashi/m68kcpu.c"
require "$TMP/musashi/m68kcpu.h"
cp "$TMP/musashi/m68kcpu.c" "$DEST/"
cp "$TMP/musashi/m68kcpu.h" "$DEST/"

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
