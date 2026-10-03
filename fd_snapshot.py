#!/usr/bin/env python3
"""Snapshot file metadata: read NUL-separated paths, stat each, emit CSV.

Replaces the `fd --list-details | ls_to_csv.py` pipeline. fd handles fast
path discovery; this script does exactly one stat() per file and writes
exact values (no humanized sizes, no year-guessing from ls output).

Also writes a raw debug log (one `path|bytes|epoch|perms|uid|gid|links`
line per file) when --debug is given.
"""

from __future__ import annotations

import argparse
import csv
import grp
import os
import pwd
import stat as stat_mod
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

FIELDS = [
    "path",
    "name",
    "type",
    "size_bytes",
    "mtime",
    "mtime_epoch",
    "permissions",
    "owner",
    "group",
    "links",
    "symlink_target",
]


def iter_paths(stream) -> Iterator[str]:
    """Yield NUL-separated paths from a binary stream, handling chunk boundaries."""
    buf = b""
    for chunk in iter(lambda: stream.read(65536), b""):
        buf += chunk
        *parts, buf = buf.split(b"\0")
        yield from parts
    if buf:
        yield buf


def stat_paths(stream, output: Path, debug: Path | None) -> tuple[int, int]:
    """Stat every path in stream, write CSV (and debug log). Return (rows, errors)."""
    uid_names: dict[int, str] = {}
    gid_names: dict[int, str] = {}

    def uid_name(uid: int) -> str:
        if uid not in uid_names:
            try:
                uid_names[uid] = pwd.getpwuid(uid).pw_name
            except KeyError:
                uid_names[uid] = str(uid)
        return uid_names[uid]

    def gid_name(gid: int) -> str:
        if gid not in gid_names:
            try:
                gid_names[gid] = grp.getgrgid(gid).gr_name
            except KeyError:
                gid_names[gid] = str(gid)
        return gid_names[gid]

    debug_file = debug.open("w", encoding="utf-8") if debug else None
    rows = 0
    errors = 0
    try:
        with output.open("w", encoding="utf-8", newline="") as out, \
                debug_file or open(os.devnull):
            writer = csv.DictWriter(out, fieldnames=FIELDS)
            writer.writeheader()
            if debug_file:
                debug_file.write("path|size_bytes|mtime_epoch|permissions|uid|gid|links\n")
            for raw in iter_paths(stream):
                if not raw:
                    continue
                path = raw.decode("utf-8", errors="replace")
                try:
                    st = os.lstat(path)
                except OSError as error:
                    errors += 1
                    print(f"warning: {path}: {error}", file=sys.stderr)
                    continue
                mode = stat_mod.S_IMODE(st.st_mode)
                kind = stat_mod.S_IFMT(st.st_mode)
                type_ = {
                    stat_mod.S_IFREG: "file",
                    stat_mod.S_IFDIR: "dir",
                    stat_mod.S_IFLNK: "symlink",
                }.get(kind, "other")
                target = ""
                if kind == stat_mod.S_IFLNK:
                    try:
                        target = os.readlink(path)
                    except OSError:
                        target = ""
                mtime_epoch = int(st.st_mtime)
                writer.writerow({
                    "path": path,
                    "name": os.path.basename(path.rstrip("/")) or path,
                    "type": type_,
                    "size_bytes": st.st_size,
                    "mtime": datetime.fromtimestamp(
                        mtime_epoch, tz=timezone.utc
                    ).isoformat(),
                    "mtime_epoch": mtime_epoch,
                    "permissions": f"{stat_mod.filemode(st.st_mode)} ({oct(mode)})",
                    "owner": uid_name(st.st_uid),
                    "group": gid_name(st.st_gid),
                    "links": st.st_nlink,
                    "symlink_target": target,
                })
                rows += 1
                if debug_file:
                    debug_file.write(
                        f"{path}|{st.st_size}|{mtime_epoch}|"
                        f"{stat_mod.filemode(st.st_mode)}|{st.st_uid}|"
                        f"{st.st_gid}|{st.st_nlink}\n"
                    )
    finally:
        if debug_file:
            debug_file.close()
    return rows, errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stat NUL-separated paths from stdin and write a CSV snapshot."
    )
    parser.add_argument("file", nargs="?", default="-",
                        help="input file with NUL-separated paths, or - for stdin")
    parser.add_argument("-o", "--output", type=Path, required=True,
                        help="output CSV path")
    parser.add_argument("--debug", type=Path,
                        help="write raw stat values to this file for debugging")
    parser.add_argument("--progress", action="store_true",
                        help="show a progress line on stderr")
    args = parser.parse_args()

    stream = sys.stdin.buffer if args.file == "-" else open(args.file, "rb")

    if args.progress:
        print("Processing...", file=sys.stderr, flush=True)

    started = time.monotonic()
    rows, errors = stat_paths(stream, args.output, args.debug)
    elapsed = time.monotonic() - started
    rate = rows / elapsed if elapsed > 0 else 0
    print(
        f"wrote {args.output} ({rows:,} files, {errors} errors, "
        f"{elapsed:.2f}s, {rate:,.0f} files/s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
