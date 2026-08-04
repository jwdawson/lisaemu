#!/bin/bash
# Sparse-clones the TomHarte/ProcessorTests 68000 vectors into Vendor/.
# Usage: ./Scripts/fetch-processortests.sh
# Then:  LISAEMU_TH_DIR=$PWD/Vendor/ProcessorTests/680x0/68000/v1 swift test
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ProcessorTests"
if [ ! -d "$DEST" ]; then
  git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/TomHarte/ProcessorTests.git "$DEST"
  git -C "$DEST" sparse-checkout set 680x0/68000/v1
fi
# Vectors may be shipped gzipped; decompress in place, keep originals out of git (Vendor/ is ignored).
find "$DEST/680x0/68000/v1" -name '*.json.gz' -exec gunzip -kf {} +
echo "Vectors ready in $DEST/680x0/68000/v1"
ls "$DEST/680x0/68000/v1" | head
