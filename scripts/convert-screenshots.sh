#!/usr/bin/env bash
# Convert HEIC reference screenshots to PNG into docs/ui/screenshots/.
# Source HEICs live under sample-data/screenshots-heic/ (gitignored).
# The generated PNGs are committed only after a manual redaction review.

set -euo pipefail

SRC_DIR="sample-data/screenshots-heic"
OUT_DIR="docs/ui/screenshots"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "No source HEICs at $SRC_DIR — nothing to do."
    exit 0
fi

mkdir -p "$OUT_DIR"

count=0
shopt -s nullglob nocaseglob
for heic in "$SRC_DIR"/*.heic; do
    base="$(basename "$heic")"
    out="$OUT_DIR/${base%.*}.png"
    sips -s format png "$heic" --out "$out" >/dev/null
    count=$(( count + 1 ))
    echo "  $heic → $out"
done
shopt -u nocaseglob

echo "Converted $count screenshot(s)."
echo "REVIEW each PNG in $OUT_DIR/ before committing — they may contain identifying info."
