#!/usr/bin/env python3
"""Unit + CLI tests for ``bin/build_krona.py``.

These mirror the KR-.. specifications in ``SPECIFICATIONS.md``. They
are pure-stdlib (``unittest``) and need no Krona install — they exercise the
TSV-to-Krona-text conversion, which is the part of the feature that is ours.
The ``ktImportText`` invocation is covered separately by the driver/module
tests (which do require Krona).

Run with::

    python3 -m unittest tests.bin.test_build_krona
    # or, from the repo root:
    python3 -m unittest discover -s tests/bin -p 'test_*.py'
"""

from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "bin" / "build_krona.py"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "krona"
FILTERED = FIXTURE_DIR / "occurrence.tsv"
OPTIMISTIC = FIXTURE_DIR / "occurrence_optimistic.tsv"


def _load_module():
    """Import the CLI script by path so ``bin/`` need not be a package."""
    spec = importlib.util.spec_from_file_location("build_krona", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bk = _load_module()


class PureHelpers(unittest.TestCase):
    """KR-30, KR-31, KR-33 — deterministic conversions."""

    def test_KR30_taxonomy_to_levels(self):
        """KR-30."""
        self.assertEqual(
            bk.taxonomy_to_levels("d:X,k:Y,s:Z"), ["d:X", "k:Y", "s:Z"]
        )
        # An unassigned read is a single-level 'unknown' entry.
        self.assertEqual(bk.taxonomy_to_levels("unknown"), ["unknown"])

    def test_KR31_parse_header_drops_taxonomy_and_total(self):
        """KR-31."""
        self.assertEqual(
            bk.parse_header("taxonomy\ttotal\tbarcode01\tbarcode02"),
            ["barcode01", "barcode02"],
        )

    def test_KR33_render_krona_text_format(self):
        """KR-33."""
        text = bk.render_krona_text([(5, ["d:X", "s:Z"]), (1, ["unknown"])])
        self.assertEqual(text, "5\td:X\ts:Z\n1\tunknown\n")
        self.assertEqual(bk.render_krona_text([]), "")


class SampleFiles(unittest.TestCase):
    """KR-32, KR-34, KR-35 — one file per non-empty barcode."""

    def test_KR32_counts_exact_and_zero_cells_excluded(self):
        """KR-32."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            bk.write_sample_files(FILTERED, out)
            lines = (out / "barcode01.txt").read_text().splitlines()
            # barcode01: Alpha_one=5 and unknown=1 (Beta_two=0 excluded).
            self.assertEqual(len(lines), 2)
            first = lines[0].split("\t")
            self.assertEqual(first[0], "5")          # count matches the cell
            self.assertEqual(first[1], "d:Synthetica")
            self.assertEqual(first[-1], "s:Alpha_one")
            self.assertEqual(lines[1].split("\t"), ["1", "unknown"])
            # The zero-count Beta_two taxon must not leak into barcode01.
            self.assertNotIn("Beta", (out / "barcode01.txt").read_text())

    def test_KR34_one_file_per_nonempty_barcode_empty_skipped(self):
        """KR-34."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            err = io.StringIO()
            with redirect_stderr(err):
                written = bk.write_sample_files(FILTERED, out)
            names = sorted(p.name for p in written)
            self.assertEqual(names, ["barcode01.txt", "barcode02.txt"])
            # barcode03 is all-zero → no file, and it is reported.
            self.assertFalse((out / "barcode03.txt").exists())
            self.assertIn("barcode03", err.getvalue())

    def test_KR35_no_probability_annotations_leak(self):
        """KR-35."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for p in bk.write_sample_files(FILTERED, out):
                self.assertNotRegex(p.read_text(), r"\([0-9]+\.[0-9]+\)")


class CLI(unittest.TestCase):
    """KR-01..KR-04 — argument validation."""

    def _run(self, argv):
        err = io.StringIO()
        with redirect_stderr(err):
            rc = bk.main(argv)
        return rc, err.getvalue()

    def test_KR01_missing_input(self):
        """KR-01."""
        with tempfile.TemporaryDirectory() as tmp:
            rc, err = self._run(["--output-dir", tmp])
            self.assertEqual(rc, 1)
            self.assertIn("--input is required", err)

    def test_KR02_missing_output_dir(self):
        """KR-02."""
        rc, err = self._run(["--input", str(FILTERED)])
        self.assertEqual(rc, 1)
        self.assertIn("--output-dir is required", err)

    def test_KR03_input_does_not_exist(self):
        """KR-03."""
        with tempfile.TemporaryDirectory() as tmp:
            rc, err = self._run(
                ["--input", str(FIXTURE_DIR / "__nope__.tsv"),
                 "--output-dir", tmp]
            )
            self.assertEqual(rc, 1)
            self.assertIn("Path does not exist", err)

    def test_KR04_output_dir_created_if_missing(self):
        """KR-04."""
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "made" / "here"
            rc, _ = self._run(
                ["--input", str(FILTERED), "--output-dir", str(target)]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(target.is_dir())
            self.assertTrue((target / "barcode01.txt").exists())


if __name__ == "__main__":
    unittest.main()
