#!/usr/bin/env python3
"""Convert an occurrence table (TSV) into per-sample Krona text files.

Given an occurrence table as written by ``build_occurrence_table.py`` — taxa
(rows) against barcodes (columns), each cell a read count — this emits one
`ktImportText`-format text file per **non-empty** barcode:

    <count>\\t<level1>\\t<level2>\\t...

The taxonomy hierarchy comes straight from the table's ``taxonomy`` column:
its comma-separated ranks (``d:...,k:...,...,s:...``) become the tab-separated
Krona levels, rank prefixes kept (unambiguous). An unassigned read
(``taxonomy == "unknown"``) becomes a single-level ``unknown`` entry.

A barcode whose every cell is zero carries no signal and would make an empty
Krona dataset, so it is **skipped** and reported on stderr (no silent
truncation). The driver ``build_krona.sh`` then feeds the emitted files to
``ktImportText`` to build one HTML with a per-sample dropdown.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# An occurrence-table row is: taxonomy \t total \t <barcode counts...>.
# The barcode columns therefore start at index 2.
FIRST_BARCODE_COL = 2


# --------------------------------------------------------------- pure helpers


def parse_header(line: str) -> list[str]:
    """Barcode column names from the header line.

    Drops the leading ``taxonomy`` and ``total`` columns.
    """
    return line.rstrip("\n").split("\t")[FIRST_BARCODE_COL:]


def taxonomy_to_levels(taxonomy: str) -> list[str]:
    """Split a comma-separated taxonomy into ordered Krona levels.

    ``"d:X,k:Y,s:Z"`` -> ``["d:X", "k:Y", "s:Z"]``; ``"unknown"`` ->
    ``["unknown"]``.
    """
    return [level.strip() for level in taxonomy.split(",")]


def rows_for_barcode(
    data_rows: list[list[str]], col_index: int
) -> list[tuple[int, list[str]]]:
    """``(count, levels)`` for each non-zero taxonomy in one column."""
    result: list[tuple[int, list[str]]] = []
    for row in data_rows:
        count = int(row[col_index])
        if count == 0:
            continue
        result.append((count, taxonomy_to_levels(row[0])))
    return result


def render_krona_text(rows: list[tuple[int, list[str]]]) -> str:
    """Render ``(count, levels)`` pairs as ktImportText lines.

    An empty row set renders to the empty string.
    """
    lines = ["\t".join([str(count), *levels]) for count, levels in rows]
    return "\n".join(lines) + "\n" if lines else ""


# ------------------------------------------------------------- table -> files


def read_table(path: Path) -> tuple[list[str], list[list[str]]]:
    """Return ``(barcodes, data_rows)`` from an occurrence TSV."""
    lines = path.read_text(encoding="utf-8").splitlines()
    barcodes = parse_header(lines[0]) if lines else []
    data_rows = [line.split("\t") for line in lines[1:] if line]
    return barcodes, data_rows


def write_sample_files(tsv_path: Path, out_dir: Path) -> list[Path]:
    """Write one ``<barcode>.txt`` per non-empty barcode; skip + log empties.

    Returns the paths written, in column order. *out_dir* is created if
    missing.
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    barcodes, data_rows = read_table(Path(tsv_path))
    written: list[Path] = []
    skipped: list[str] = []
    for offset, barcode in enumerate(barcodes):
        rows = rows_for_barcode(data_rows, FIRST_BARCODE_COL + offset)
        if not rows:
            skipped.append(barcode)
            continue
        path = out_dir / f"{barcode}.txt"
        path.write_text(render_krona_text(rows), encoding="utf-8")
        written.append(path)

    if skipped:
        print(
            "Skipping empty barcode(s) (no assigned reads): "
            f"{', '.join(skipped)}",
            file=sys.stderr,
        )
    return written


# ----------------------------------------------------------------------- CLI


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build per-sample Krona text files from a table."
    )
    parser.add_argument("-i", "--input", dest="input", default=None,
                        help="Occurrence table (TSV) to convert.")
    parser.add_argument("-o", "--output-dir", dest="output_dir", default=None,
                        help="Directory for the per-barcode Krona text files.")
    return parser


def validate_args(args: argparse.Namespace) -> Path:
    """Validate parsed arguments, returning the input path.

    Raises ``ValueError`` with a user-facing message on any problem.
    """
    if args.input is None:
        raise ValueError("--input is required. Use --help for usage.")
    input_path = Path(args.input)
    if not input_path.exists():
        raise ValueError(f"Path does not exist: '{args.input}'")
    if not input_path.is_file():
        raise ValueError(f"Path exists but is not a file: '{args.input}'")

    if args.output_dir is None:
        raise ValueError("--output-dir is required. Use --help for usage.")

    return input_path


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        input_path = validate_args(args)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    files = write_sample_files(input_path, Path(args.output_dir))
    if not files:
        print("No non-empty barcodes; no Krona input files written.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
