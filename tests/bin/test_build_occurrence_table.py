#!/usr/bin/env python3
"""Unit + integration tests for ``bin/build_occurrence_table.py``.

These mirror the BT-.. specifications in ``tests/SPECIFICATIONS.md`` and
the behaviour previously pinned by ``build_occurrence_table.bats`` against
the R implementation. They are pure-stdlib (``unittest``) so they run with
nothing more than the Python interpreter the pipeline already requires.

Run with::

    python3 -m unittest tests.bin.test_build_occurrence_table
    # or, from the repo root:
    python3 -m unittest discover -s tests/bin -p 'test_*.py'
"""

from __future__ import annotations

import importlib.util
import io
import unittest
from contextlib import redirect_stderr
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "bin" / "build_occurrence_table.py"
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "sintax_dir" / "fastq_pass"


def _load_module():
    """Import the CLI script by path so ``bin/`` need not be a package."""
    spec = importlib.util.spec_from_file_location("build_occurrence_table", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bot = _load_module()


# The exact tables the R implementation produced for the committed fixture
# (4 barcodes: barcode01/02 with 5 identical reads each, barcode03/99 empty).
EXPECTED_FILTERED = (
    "taxonomy\ttotal\tbarcode01\tbarcode02\tbarcode03\tbarcode99\n"
    "d:Synthetica,k:Alphakingdom,p:Alphaphylum,c:Alphaclass,o:Alphaorder,"
    "f:Alphafamily,g:Alphagenus,s:Alpha_one\t5\t5\t0\t0\t0\n"
    "d:Synthetica,k:Betakingdom,p:Betaphylum,c:Betaclass,o:Betaorder,"
    "f:Betafamily,g:Betagenus,s:Beta_two\t5\t0\t5\t0\t0\n"
)
# For this fixture every assignment has probability 1.00, so the optimistic
# table is byte-identical to the filtered one.
EXPECTED_OPTIMISTIC = EXPECTED_FILTERED


class PureHelpers(unittest.TestCase):
    """BT-30, BT-32, BT-33, BT-34 — pure, side-effect-free helpers."""

    def test_name_optimistic_output_flat(self) -> None:  # BT-30
        self.assertEqual(bot.name_optimistic_output("foo.tsv"), "foo_optimistic.tsv")

    def test_name_optimistic_output_nested(self) -> None:  # BT-30
        self.assertEqual(
            bot.name_optimistic_output("a/b/foo.tsv"), "a/b/foo_optimistic.tsv"
        )

    def test_extract_barcode(self) -> None:  # BT-32 / BT-16
        self.assertEqual(
            bot.extract_barcode("x/fastq_pass/barcode07/reads.sintax"), "barcode07"
        )
        self.assertEqual(bot.extract_barcode("a/unclassified/r.sintax"), "unclassified")
        self.assertEqual(bot.extract_barcode("a/mixed/r.sintax"), "mixed")
        self.assertIsNone(bot.extract_barcode("a/b/reads.sintax"))

    def test_strip_probabilities(self) -> None:  # BT-33 / BT-17 / BT-23
        raw = "d:Fungi(0.99),p:Asco(0.80),s:Foo_bar(1.00)"
        self.assertEqual(bot.strip_probabilities(raw), "d:Fungi,p:Asco,s:Foo_bar")
        # idempotent / no annotations to strip
        self.assertEqual(bot.strip_probabilities("d:Fungi"), "d:Fungi")

    def test_mark_unassigned(self) -> None:  # BT-34 / BT-14
        self.assertEqual(bot.mark_unassigned(""), "unknown")
        self.assertEqual(bot.mark_unassigned(None), "unknown")
        self.assertEqual(bot.mark_unassigned("d:Fungi"), "d:Fungi")


class FileDiscovery(unittest.TestCase):
    """BT-06 / BT-13 — finding and partitioning the input files."""

    def test_find_sintax_files_sorted(self) -> None:
        files = bot.find_sintax_files(FIXTURE, r"\.sintax$")
        names = [p.parent.name for p in files]
        self.assertEqual(names, ["barcode01", "barcode02", "barcode03", "barcode99"])

    def test_partition_by_size(self) -> None:  # BT-13
        files = bot.find_sintax_files(FIXTURE, r"\.sintax$")
        non_empty, empty = bot.partition_by_size(files)
        self.assertEqual([p.parent.name for p in non_empty], ["barcode01", "barcode02"])
        self.assertEqual([p.parent.name for p in empty], ["barcode03", "barcode99"])


class BuildTable(unittest.TestCase):
    """BT-10..BT-17, BT-20..BT-23 — end-to-end table assembly."""

    def setUp(self) -> None:
        files = bot.find_sintax_files(FIXTURE, r"\.sintax$")
        self.non_empty, empty = bot.partition_by_size(files)
        self.empty_barcodes = bot.resolve_empty_barcodes(self.non_empty, empty)

    def _filtered(self) -> str:
        return bot.build_table(self.non_empty, self.empty_barcodes, bot.select_filtered)

    def _optimistic(self) -> str:
        return bot.build_table(
            self.non_empty, self.empty_barcodes, bot.select_optimistic
        )

    def test_filtered_matches_golden(self) -> None:  # BT-10..BT-13, BT-15
        self.assertEqual(self._filtered(), EXPECTED_FILTERED)

    def test_optimistic_matches_golden(self) -> None:  # BT-20, BT-21
        self.assertEqual(self._optimistic(), EXPECTED_OPTIMISTIC)

    def test_header_shape(self) -> None:  # BT-10
        header = self._filtered().splitlines()[0].split("\t")
        self.assertEqual(header[:2], ["taxonomy", "total"])
        self.assertEqual(len(header), 6)

    def test_total_is_row_sum(self) -> None:  # BT-11
        for line in self._filtered().splitlines()[1:]:
            cells = line.split("\t")
            total = int(cells[1])
            self.assertEqual(total, sum(int(c) for c in cells[2:]))

    def test_sorted_total_desc_then_taxonomy(self) -> None:  # BT-12
        rows = [ln.split("\t") for ln in self._filtered().splitlines()[1:]]
        keys = [(-int(r[1]), r[0]) for r in rows]
        self.assertEqual(keys, sorted(keys))

    def test_empty_barcodes_are_rightmost(self) -> None:  # BT-13
        header = self._filtered().splitlines()[0].split("\t")
        self.assertEqual(header[-2:], ["barcode03", "barcode99"])

    def test_no_probability_leaks(self) -> None:  # BT-23
        import re

        prob = re.compile(r"\([0-9]+\.[0-9]+\)")
        for table in (self._filtered(), self._optimistic()):
            for line in table.splitlines()[1:]:
                self.assertIsNone(prob.search(line.split("\t")[0]))


class BlankFilteredRegression(unittest.TestCase):
    """BT-24 — an all-blank filtered column must not crash and maps to 'unknown'."""

    def test_blank_filtered_maps_to_unknown(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            bc = Path(tmp) / "fastq_pass" / "barcode01"
            bc.mkdir(parents=True)
            (bc / "reads.sintax").write_text(
                "read1_b01;length=160\td:Synthetica(0.30),p:Foo(0.20)\t+\t\n"
                "read2_b01;length=160\td:Synthetica(0.40),p:Bar(0.10)\t+\t\n"
            )
            files = bot.find_sintax_files(bc.parent, r"\.sintax$")
            non_empty, empty = bot.partition_by_size(files)
            table = bot.build_table(non_empty, [], bot.select_filtered)
        rows = {ln.split("\t")[0]: ln.split("\t") for ln in table.splitlines()[1:]}
        self.assertIn("unknown", rows)
        self.assertEqual(rows["unknown"][1:], ["2", "2"])  # total=2, barcode01=2


class MultiChunkEmptyRegression(unittest.TestCase):
    """BT-25 — an empty chunk of a non-empty barcode is not a phantom sample.

    Real Nanopore barcodes hold many fastq chunks; a chunk yielding no
    surviving reads produces a 0-byte ``.sintax`` file. Such a file must
    not spawn a duplicate, count-cloned column for its (otherwise
    non-empty) barcode. Only barcodes whose every chunk is empty appear as
    zero-filled, right-most columns.
    """

    def test_empty_chunk_does_not_duplicate_barcode(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "fastq_pass"
            # barcode33: one chunk with reads + two empty chunks
            b33 = root / "barcode33"
            b33.mkdir(parents=True)
            (b33 / "FAX_pass_barcode33_0.sintax").write_text(
                "r1\td:Bacteria(0.99)\t+\td:Bacteria\n"
                "r2\td:Bacteria(0.99)\t+\td:Bacteria\n"
            )
            (b33 / "FAX_pass_barcode33_1.sintax").write_text("")
            (b33 / "FAX_pass_barcode33_2.sintax").write_text("")
            # barcode35: genuinely empty (its only chunk is empty)
            b35 = root / "barcode35"
            b35.mkdir(parents=True)
            (b35 / "FAX_pass_barcode35_0.sintax").write_text("")

            files = bot.find_sintax_files(root, r"\.sintax$")
            non_empty, empty = bot.partition_by_size(files)
            empty_barcodes = bot.resolve_empty_barcodes(non_empty, empty)
            table = bot.build_table(non_empty, empty_barcodes, bot.select_filtered)

        header = table.splitlines()[0].split("\t")
        # barcode33 appears exactly once; barcode35 is the lone empty column.
        self.assertEqual(empty_barcodes, ["barcode35"])
        self.assertEqual(header.count("barcode33"), 1)
        self.assertEqual(header, ["taxonomy", "total", "barcode33", "barcode35"])
        # barcode35's reads are zero, not a clone of barcode33's.
        row = table.splitlines()[1].split("\t")  # d:Bacteria, total=2
        self.assertEqual(row, ["d:Bacteria", "2", "2", "0"])


class CliValidation(unittest.TestCase):
    """BT-01..BT-07 — argument validation and the optimistic sibling file."""

    def _run(self, argv: list[str]) -> tuple[int, str]:
        err = io.StringIO()
        with redirect_stderr(err):
            code = bot.main(argv)
        return code, err.getvalue()

    def test_missing_input_dir(self) -> None:  # BT-01
        code, msg = self._run(["--output", "/tmp/x.tsv"])
        self.assertNotEqual(code, 0)
        self.assertIn("--input-dir is required", msg)

    def test_missing_output(self) -> None:  # BT-02
        code, msg = self._run(["--input-dir", str(FIXTURE)])
        self.assertNotEqual(code, 0)
        self.assertIn("--output is required", msg)

    def test_nonexistent_input_dir(self) -> None:  # BT-03
        code, msg = self._run(
            ["--input-dir", "/no/such/dir", "--output", "/tmp/x.tsv"]
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Path does not exist", msg)

    def test_input_dir_is_a_file(self) -> None:  # BT-04
        import tempfile

        with tempfile.NamedTemporaryFile() as f:
            code, msg = self._run(["--input-dir", f.name, "--output", "/tmp/x.tsv"])
        self.assertNotEqual(code, 0)
        self.assertIn("not a directory", msg)

    def test_no_sintax_files(self) -> None:  # BT-06
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            code, msg = self._run(
                ["--input-dir", tmp, "--output", f"{tmp}/out.tsv"]
            )
        self.assertNotEqual(code, 0)
        self.assertIn("No sintax files found", msg)

    def test_optimistic_sibling_and_parent_creation(self) -> None:  # BT-05, BT-07
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "nested" / "sintax.tsv"  # parent missing on purpose
            code, _ = self._run(
                ["--input-dir", str(FIXTURE), "--output", str(out)]
            )
            self.assertEqual(code, 0)
            opt = out.with_name("sintax_optimistic.tsv")
            self.assertTrue(out.is_file() and out.stat().st_size > 0)
            self.assertTrue(opt.is_file() and opt.stat().st_size > 0)
            self.assertEqual(out.read_text(), EXPECTED_FILTERED)


if __name__ == "__main__":
    unittest.main()
