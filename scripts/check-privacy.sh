#!/usr/bin/env bash
# Greps the tracked working tree for patterns that should never be committed.
# Used by `make check-privacy` and by CI. Exits non-zero on any violation.
# Uses bash regex — portable across macOS BSD and Linux GNU userlands.

set -euo pipefail

PATTERNS=(
    '(\.sqlite(-shm|-wal)?|\.db(-shm|-wal)?)$'
    '^location-history.*\.json$'
    '\.takeout\.zip$'
    '\.(heic|HEIC)$'
    '^Timeline.*\.json$'
    '^Config\.xcconfig$'
    '\.(mobileprovision|p12|pem)$'
)

mapfile -t tracked < <(git ls-files)

violations=()
for path in "${tracked[@]}"; do
    # Anything under sample-data/ except the README is forbidden.
    if [[ "$path" == sample-data/* && "$path" != "sample-data/README.md" ]]; then
        violations+=("$path")
        continue
    fi
    for pat in "${PATTERNS[@]}"; do
        if [[ "$path" =~ $pat ]]; then
            violations+=("$path")
        fi
    done
done

if (( ${#violations[@]} > 0 )); then
    echo "✗ Privacy check failed: tracked files match forbidden patterns:"
    printf '    %s\n' "${violations[@]}"
    exit 1
fi

echo "✓ no privacy-sensitive paths tracked"
