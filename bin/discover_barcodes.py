#!/usr/bin/env python3
"""Discover fastq files under a ``fastq_pass`` tree and group them by barcode.

Emits a tab-separated ``barcode<TAB>path`` table (one row per fastq file,
with a header) for the Nextflow workflow to turn into a
``[barcode, [files...]]`` channel via ``splitCsv`` + ``groupTuple``.

The barcode token is extracted from the path *relative to the input
directory* using the same ``BARCODE_PATTERN`` as
``build_occurrence_table.py``, so it is found whether the token is a
directory component (demultiplexed-into-folders layout) or part of the
filename (flat layout, e.g. ``FAX123_pass_barcode01_0.fastq.gz``).
Matching the relative path (not the absolute one) keeps a barcode-like
token in a parent/project directory name from being picked up by mistake.

Discovery is rooted at the given ``fastq_pass`` directory, so a sibling
``fastq_fail`` is never seen. A file with no recognisable barcode token
aborts the run (decision D2), listing the offending paths.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Kept in lock-step with build_occurrence_table.py's BARCODE_PATTERN so
# discovery and table assembly can never disagree on a barcode name.
BARCODE_PATTERN = re.compile(r"barcode[0-9]+|unclassified|mixed")

# The fastq extensions the pipeline supports, mirroring the FASTQ_REGEX
# in assign_with_sintax.sh (.fastq, .fastq.gz, .fastq.bz2, .fastq.xz).
FASTQ_SUFFIXES = (".fastq", ".fastq.gz", ".fastq.bz2", ".fastq.xz")


# --------------------------------------------------------------- pure helpers


def is_fastq_name(name: str) -> bool:
    """True if *name* ends with a supported fastq extension."""
    return name.endswith(FASTQ_SUFFIXES)


def barcode_for(relative_path: str) -> str | None:
    """Extract the barcode token from a path, or None if there is none."""
    match = BARCODE_PATTERN.search(relative_path)
    return match.group(0) if match else None


def discover(input_dir: Path) -> list[Path]:
    """Every fastq file under *input_dir*, sorted for deterministic order."""
    return sorted(
        p for p in input_dir.rglob("*") if p.is_file() and is_fastq_name(p.name)
    )


def group_by_barcode(
    input_dir: Path, files: list[Path]
) -> tuple[list[tuple[str, Path]], list[Path]]:
    """Pair each file with its barcode; split off files that carry none.

    The barcode is read from the path *relative to* ``input_dir``.
    Returns ``(rows, untagged)`` where ``rows`` is ``[(barcode, path)]``
    and ``untagged`` is the list of files with no recognisable token.
    """
    rows: list[tuple[str, Path]] = []
    untagged: list[Path] = []
    for path in files:
        barcode = barcode_for(str(path.relative_to(input_dir)))
        if barcode is None:
            untagged.append(path)
        else:
            rows.append((barcode, path))
    return rows, untagged


def render_table(rows: list[tuple[str, Path]]) -> str:
    """Render ``[(barcode, path)]`` as the ``barcode<TAB>path`` TSV text."""
    lines = ["barcode\tpath"]
    lines += [f"{barcode}\t{path}" for barcode, path in rows]
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------------- CLI


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Group fastq files under a fastq_pass tree by barcode."
    )
    parser.add_argument("-i", "--input-dir", dest="input_dir", default=None,
                        help="The fastq_pass directory to search (recursively).")
    parser.add_argument("-o", "--output", dest="output", default=None,
                        help="Output TSV file [default: stdout].")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    if args.input_dir is None:
        print("--input-dir is required. Use --help for usage.", file=sys.stderr)
        return 1
    input_dir = Path(args.input_dir)
    if not input_dir.is_dir():
        print(f"Path is not a directory: '{args.input_dir}'", file=sys.stderr)
        return 1

    files = discover(input_dir)
    if not files:
        print(f"No fastq files found under: '{args.input_dir}'", file=sys.stderr)
        return 1

    rows, untagged = group_by_barcode(input_dir, files)
    if untagged:
        listing = "\n  ".join(str(p) for p in untagged)
        print(
            "Error: no barcode token (barcodeNN / unclassified / mixed) could be "
            f"derived for:\n  {listing}",
            file=sys.stderr,
        )
        return 1

    table = render_table(rows)
    if args.output:
        Path(args.output).write_text(table, encoding="utf-8")
    else:
        sys.stdout.write(table)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
