#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
snapshot_stamp=$(date +%F_%H%M%S)
csv_file="snapshot_${snapshot_stamp}.csv"
debug_file="snapshot_${snapshot_stamp}.debug.txt"

# fd finds paths fast (no stat); fd_snapshot.py does one stat per file.
fd --hidden --no-ignore --no-ignore-vcs --type file --type symlink --print0 \
    | "$script_dir/fd_snapshot.py" - --output "$csv_file" --debug "$debug_file"

printf 'Snapshot complete: %s and %s\n' "$csv_file" "$debug_file"
