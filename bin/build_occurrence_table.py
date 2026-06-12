#!/usr/bin/env python3
"""Build a taxonomic occurrence table from vsearch SINTAX output files.

This is a pure standard-library replacement for the former
``build_occurrence_table.R`` script: it removes the heavy R + tidyverse
dependency while producing byte-identical output.

Given a directory tree of ``*.sintax`` files (one per barcode, as written
by ``assign_with_sintax.sh``), it emits two tab-separated tables of taxa
(rows) against barcodes (columns), each cell holding a read count:

* ``--output``                  the *filtered* table, using the
                                high-confidence taxonomy (column 4 of the
                                ``.sintax`` file);
* ``<stem>_optimistic.<ext>``   the *optimistic* table, using the full
                                taxonomy (column 2) with its ``(0.xx)``
                                probability annotations stripped.

Rows are sorted by total read count (descending) then taxonomy
(ascending). Barcodes whose ``.sintax`` file is empty contribute no reads
but still appear, zero-filled, as the right-most columns.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Callable

# A SINTAX line is: query \t full_taxonomy \t strand \t taxonomy
FULL_TAXONOMY_COL = 1
TAXONOMY_COL = 3

BARCODE_PATTERN = re.compile(r"barcode[0-9]+|unclassified|mixed")
PROBABILITY_PATTERN = re.compile(r"\([0-9]+\.[0-9]+\)")
UNASSIGNED = "unknown"

# A row selector maps the tab-split fields of one SINTAX line to a taxonomy
# string (or None / "" when the read is unassigned).
Selector = Callable[[list[str]], "str | None"]


# --------------------------------------------------------------- pure helpers


def name_optimistic_output(output: str) -> str:
    """Insert ``_optimistic`` before the final extension of *output*.

    ``foo.tsv`` -> ``foo_optimistic.tsv``;
    ``a/b/foo.tsv`` -> ``a/b/foo_optimistic.tsv``.
    """
    path = Path(output)
    return str(path.with_name(f"{path.stem}_optimistic{path.suffix}"))


def extract_barcode(text: str) -> str | None:
    """Pull the barcode token (``barcodeNN``/``unclassified``/``mixed``) from a path."""
    match = BARCODE_PATTERN.search(text)
    return match.group(0) if match else None


def strip_probabilities(taxonomy: str) -> str:
    """Remove ``(0.xx)`` confidence annotations from a taxonomy string."""
    return PROBABILITY_PATTERN.sub("", taxonomy)


def mark_unassigned(taxonomy: str | None) -> str:
    """Map a missing/empty taxonomy to the literal ``"unknown"``."""
    return taxonomy if taxonomy else UNASSIGNED


def select_filtered(fields: list[str]) -> str | None:
    """High-confidence taxonomy: column 4 of the SINTAX line."""
    if len(fields) > TAXONOMY_COL:
        return fields[TAXONOMY_COL]
    return None


def select_optimistic(fields: list[str]) -> str | None:
    """Full taxonomy (column 2) with probability annotations stripped."""
    if len(fields) > FULL_TAXONOMY_COL:
        return strip_probabilities(fields[FULL_TAXONOMY_COL])
    return None


# ------------------------------------------------------------- file discovery


def find_sintax_files(input_dir: Path, pattern: str) -> list[Path]:
    """Return every file under *input_dir* whose name matches *pattern* (a regex).

    Results are sorted by path so the column order is deterministic.
    """
    regex = re.compile(pattern)
    return sorted(
        p for p in input_dir.rglob("*") if p.is_file() and regex.search(p.name)
    )


def partition_by_size(files: list[Path]) -> tuple[list[Path], list[Path]]:
    """Split *files* into (non-empty, empty) preserving order within each group."""
    non_empty = [p for p in files if p.stat().st_size > 0]
    empty = [p for p in files if p.stat().st_size == 0]
    return non_empty, empty


def resolve_empty_barcodes(
    non_empty: list[Path], empty: list[Path]
) -> list[str]:
    """Barcodes that produced no reads at all, as a sorted, de-duplicated list.

    A barcode is *empty* only when every one of its ``.sintax`` files is
    empty. A barcode with at least one non-empty file — e.g. a multi-chunk
    Nanopore barcode where a single chunk yielded no surviving reads — is
    excluded: its reads are already counted, so re-adding it here would
    duplicate the column and copy its counts into a phantom sample.
    """
    has_reads = {bc for p in non_empty if (bc := extract_barcode(str(p)))}
    return sorted(
        {
            bc
            for p in empty
            if (bc := extract_barcode(str(p))) and bc not in has_reads
        }
    )


# ------------------------------------------------------------- table assembly


def count_assignments(
    files: list[Path], select: Selector
) -> Counter[tuple[str, str]]:
    """Count reads per ``(barcode, taxonomy)`` pair across *files*."""
    counts: Counter[tuple[str, str]] = Counter()
    for path in files:
        barcode = extract_barcode(str(path)) or path.parent.name
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line:
                    continue
                fields = line.split("\t")
                taxonomy = mark_unassigned(select(fields))
                counts[(barcode, taxonomy)] += 1
    return counts


def render_table(
    counts: Counter[tuple[str, str]], empty_barcodes: list[str]
) -> str:
    """Turn per-pair counts into the wide, sorted, zero-filled TSV text."""
    barcodes = sorted({barcode for barcode, _ in counts})
    columns = barcodes + [b for b in empty_barcodes if b is not None]

    totals: Counter[str] = Counter()
    for (_, taxonomy), reads in counts.items():
        totals[taxonomy] += reads

    # desc(total), then taxonomy ascending
    taxa = sorted(totals, key=lambda tax: (-totals[tax], tax))

    lines = ["\t".join(["taxonomy", "total", *columns])]
    for taxonomy in taxa:
        cells = [str(counts.get((barcode, taxonomy), 0)) for barcode in columns]
        lines.append("\t".join([taxonomy, str(totals[taxonomy]), *cells]))
    return "\n".join(lines) + "\n"


def build_table(
    files: list[Path], empty_barcodes: list[str], select: Selector
) -> str:
    """Full pipeline from input files to a rendered TSV string."""
    return render_table(count_assignments(files, select), empty_barcodes)


# ----------------------------------------------------------------------- CLI


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build a taxonomic occurrence table from SINTAX files.",
        # Validate manually below so we can emit the historical
        # "<arg> is required" messages the test-suite pins.
        add_help=True,
    )
    parser.add_argument("-i", "--input-dir", dest="input_dir", default=None,
                        help="Input directory to search (recursively).")
    parser.add_argument("-o", "--output", dest="output", default=None,
                        help="Output TSV file (filtered table).")
    parser.add_argument("-p", "--pattern", dest="pattern", default=r"\.sintax$",
                        help="Filename regex to match [default: %(default)s].")
    return parser


def validate_args(args: argparse.Namespace) -> Path:
    """Validate parsed arguments, create the output parent, return the input dir.

    Raises ``ValueError`` with a user-facing message on any problem.
    """
    if args.input_dir is None:
        raise ValueError("--input-dir is required. Use --help for usage.")
    input_dir = Path(args.input_dir)
    if not input_dir.exists():
        raise ValueError(f"Path does not exist: '{args.input_dir}'")
    if not input_dir.is_dir():
        raise ValueError(f"Path exists but is not a directory: '{args.input_dir}'")

    if args.output is None:
        raise ValueError("--output is required. Use --help for usage.")
    output_parent = Path(args.output).parent
    output_parent.mkdir(parents=True, exist_ok=True)

    return input_dir


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        input_dir = validate_args(args)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    files = find_sintax_files(input_dir, args.pattern)
    if not files:
        print("No sintax files found. Aborting.", file=sys.stderr)
        return 1

    non_empty, empty = partition_by_size(files)
    empty_barcodes = resolve_empty_barcodes(non_empty, empty)

    Path(args.output).write_text(
        build_table(non_empty, empty_barcodes, select_filtered), encoding="utf-8"
    )
    Path(name_optimistic_output(args.output)).write_text(
        build_table(non_empty, empty_barcodes, select_optimistic), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
