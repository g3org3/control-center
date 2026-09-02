#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
snapshot_date=$(date +%F)
cache_file=".fd_${snapshot_date}.cache.txt"
csv_file="${cache_file%.txt}.csv"

fd --hidden --no-ignore --no-ignore-vcs --list-details | tee "$cache_file" | \
    "$script_dir/ls_to_csv.py" - --output "$csv_file"

printf 'Snapshot complete: %s and %s\n' "$cache_file" "$csv_file"
