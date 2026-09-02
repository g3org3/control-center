#!/usr/bin/env python3
"""Convert streamed `ls -l` output to CSV."""

import argparse
import csv
import os
import re
import sys
from contextlib import nullcontext
from datetime import date
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import BinaryIO


LINE = re.compile(
    r"^(?P<permissions>\S+)\s+"
    r"(?P<links>\d+)\s+"
    r"(?P<owner>\S+)\s+"
    r"(?P<group>\S+)\s+"
    r"(?P<size>\S+)\s+"
    r"(?P<raw_datetime>"
    r"(?P<month>\S+)\s+"
    r"(?P<day>\d+)\s+"
    r"(?P<time_or_year>\S+)"
    r")\s+"
    r"(?P<name>.+?)\s*$"
)

FIELDS = [
    "permissions",
    "links",
    "owner",
    "group",
    "size",
    "size_in_bytes",
    "month",
    "day",
    "year",
    "time",
    "date",
    "raw_datetime",
    "path",
    "name",
]

MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4,
    "May": 5, "Jun": 6, "Jul": 7, "Aug": 8,
    "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}

SIZE = re.compile(r"^(?P<number>\d+(?:\.\d+)?)(?P<unit>[KMGTPE]?)(?:i?B)?$", re.I)
UNIT_MULTIPLIERS = {
    "": 1,
    "K": 1024,
    "M": 1024 ** 2,
    "G": 1024 ** 3,
    "T": 1024 ** 4,
    "P": 1024 ** 5,
    "E": 1024 ** 6,
}


def size_in_bytes(value: str) -> int:
    """Convert sizes such as 558B, 14K, and 2.9M to bytes."""
    match = SIZE.fullmatch(value)
    if not match:
        raise ValueError(f"invalid size: {value}")
    try:
        amount = Decimal(match.group("number"))
    except InvalidOperation as error:
        raise ValueError(f"invalid size: {value}") from error
    multiplier = UNIT_MULTIPLIERS[match.group("unit").upper()]
    return int((amount * multiplier).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def make_row(
    match: re.Match[str], current_year: int, base_dir: str
) -> dict[str, str | int]:
    """Build one CSV row from a parsed listing line."""
    row: dict[str, str | int] = match.groupdict()
    time_or_year = str(row.pop("time_or_year"))
    year = current_year if ":" in time_or_year else int(time_or_year)
    time = time_or_year if ":" in time_or_year else ""
    month = str(row["month"])
    day = int(row["day"])
    original_path = str(row.pop("name"))
    path = os.path.normpath(
        original_path
        if os.path.isabs(original_path)
        else os.path.join(base_dir, original_path)
    )

    row["size_in_bytes"] = size_in_bytes(str(row["size"]))
    row["year"] = year
    row["time"] = time
    row["date"] = date(year, MONTHS[month], day).isoformat()
    row["path"] = path
    row["name"] = os.path.basename(path.rstrip("/"))
    return row


def show_progress(bytes_read: int, total_bytes: int | None, lines: int) -> None:
    """Display progress on one updating terminal line."""
    processed_mb = bytes_read / (1024 ** 2)
    if total_bytes is None:
        status = f"{processed_mb:,.1f} MB | {lines:,} lines"
    else:
        percent = 100 if total_bytes == 0 else bytes_read / total_bytes * 100
        total_mb = total_bytes / (1024 ** 2)
        status = (
            f"{percent:6.2f}% | "
            f"{processed_mb:,.1f}/{total_mb:,.1f} MB | {lines:,} lines"
        )
    print(
        f"\rProcessing: {status}",
        end="",
        file=sys.stderr,
        flush=True,
    )


def convert(source: Path | None, destination: Path) -> int:
    """Convert source to destination one line at a time."""
    skipped = 0
    current_year = date.today().year
    base_dir = os.getcwd()
    total_bytes = source.stat().st_size if source else None
    bytes_read = 0
    lines = 0
    progress_interval = max((total_bytes or 0) // 100, 1024 ** 2)
    next_progress = progress_interval
    input_context = source.open("rb") if source else nullcontext(sys.stdin.buffer)

    with input_context as input_file, \
            destination.open("w", encoding="utf-8", newline="") as output_file:
        input_file: BinaryIO
        writer = csv.DictWriter(output_file, fieldnames=FIELDS)
        writer.writeheader()
        for line_number, raw_line in enumerate(input_file, start=1):
            lines = line_number
            bytes_read += len(raw_line)
            line = raw_line.decode("utf-8", errors="replace")
            match = LINE.match(line.rstrip("\n"))
            if not match:
                skipped += 1
                print(f"warning: skipped line {line_number}", file=sys.stderr)
            else:
                try:
                    writer.writerow(make_row(match, current_year, base_dir))
                except (KeyError, ValueError) as error:
                    skipped += 1
                    print(f"warning: skipped line {line_number}: {error}", file=sys.stderr)

            if bytes_read >= next_progress:
                show_progress(bytes_read, total_bytes, line_number)
                next_progress = bytes_read + progress_interval

    show_progress(bytes_read, total_bytes, lines)
    print(file=sys.stderr)
    return skipped


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert ls -l output to CSV.")
    parser.add_argument("file", help="input file containing ls -l output, or - for stdin")
    parser.add_argument("-o", "--output", type=Path, help="output CSV path")
    args = parser.parse_args()

    source = None if args.file == "-" else Path(args.file)
    if source is None and args.output is None:
        parser.error("--output is required when reading from stdin")
    output = args.output or source.with_suffix(".csv")
    if source is not None and source.resolve() == output.resolve():
        parser.error("input and output paths must be different")

    try:
        skipped = convert(source, output)
    except OSError as error:
        parser.error(str(error))
    print(f"wrote {output} ({skipped} skipped line(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
