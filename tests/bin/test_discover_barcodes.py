#!/usr/bin/env python3
"""Unit tests for bin/discover_barcodes.py.

Covers the discovery/grouping logic across the layouts the pipeline must
handle: demultiplexed-into-folders, flat with the barcode embedded in the
filename, multi-file barcodes, the unclassified/mixed tokens, and the
no-token abort (decision D2). Run with:

    python3 -m unittest discover -s tests/bin -p 'test_*.py'
"""

import importlib.util
import io
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory

# Import the script by path (bin/ is not a package).
_SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "discover_barcodes.py"
_spec = importlib.util.spec_from_file_location("discover_barcodes", _SCRIPT)
db = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(db)


def _touch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")


class PureHelpers(unittest.TestCase):
    def test_is_fastq_name(self):
        for good in ("a.fastq", "a.fastq.gz", "a.fastq.bz2", "a.fastq.xz"):
            self.assertTrue(db.is_fastq_name(good), good)
        for bad in ("a.txt", "a.sintax", "a.fastq.bak", "a.fasta"):
            self.assertFalse(db.is_fastq_name(bad), bad)

    def test_barcode_for_folder_and_filename(self):
        # token in a directory component
        self.assertEqual(db.barcode_for("barcode01/reads.fastq.gz"), "barcode01")
        # token embedded in the filename (flat layout)
        self.assertEqual(
            db.barcode_for("FAX123_pass_barcode07_0.fastq.gz"), "barcode07"
        )
        self.assertEqual(db.barcode_for("unclassified/x.fastq"), "unclassified")
        self.assertEqual(db.barcode_for("run_mixed_0.fastq"), "mixed")
        self.assertIsNone(db.barcode_for("random_sample_0.fastq.gz"))


class GroupByBarcode(unittest.TestCase):
    def test_subfolder_layout(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            _touch(root / "barcode01" / "reads.fastq.gz")
            _touch(root / "barcode02" / "reads.fastq.gz")
            rows, untagged = db.group_by_barcode(root, db.discover(root))
            self.assertEqual(untagged, [])
            self.assertEqual(sorted(bc for bc, _ in rows), ["barcode01", "barcode02"])

    def test_flat_embedded_and_multifile(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            _touch(root / "run1_barcode01_0.fastq.gz")
            _touch(root / "run1_barcode01_1.fastq.gz")  # multi-file barcode
            _touch(root / "run1_barcode02_0.fastq.gz")
            rows, untagged = db.group_by_barcode(root, db.discover(root))
            self.assertEqual(untagged, [])
            by_bc = {}
            for bc, p in rows:
                by_bc.setdefault(bc, []).append(p)
            self.assertEqual(len(by_bc["barcode01"]), 2)
            self.assertEqual(len(by_bc["barcode02"]), 1)

    def test_parent_dir_token_is_not_picked_up(self):
        # A barcode-like token in the *parent* directory must not leak in;
        # the match is on the path relative to input_dir.
        with TemporaryDirectory() as d:
            root = Path(d) / "barcode99_project" / "fastq_pass"
            _touch(root / "barcode01" / "reads.fastq.gz")
            rows, untagged = db.group_by_barcode(root, db.discover(root))
            self.assertEqual([bc for bc, _ in rows], ["barcode01"])

    def test_untagged_files_collected(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            _touch(root / "barcode01" / "reads.fastq.gz")
            _touch(root / "mystery_sample.fastq.gz")
            rows, untagged = db.group_by_barcode(root, db.discover(root))
            self.assertEqual([bc for bc, _ in rows], ["barcode01"])
            self.assertEqual([p.name for p in untagged], ["mystery_sample.fastq.gz"])


class MainCLI(unittest.TestCase):
    def test_no_token_aborts_and_lists_offenders(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            _touch(root / "mystery.fastq.gz")
            err = io.StringIO()
            with redirect_stderr(err):
                rc = db.main(["--input-dir", str(root)])
            self.assertEqual(rc, 1)
            self.assertIn("no barcode token", err.getvalue())
            self.assertIn("mystery.fastq.gz", err.getvalue())

    def test_no_fastq_files_aborts(self):
        with TemporaryDirectory() as d:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = db.main(["--input-dir", d])
            self.assertEqual(rc, 1)
            self.assertIn("No fastq files found", err.getvalue())

    def test_not_a_directory_aborts(self):
        with TemporaryDirectory() as d:
            f = Path(d) / "afile"
            f.write_text("x")
            err = io.StringIO()
            with redirect_stderr(err):
                rc = db.main(["--input-dir", str(f)])
            self.assertEqual(rc, 1)
            self.assertIn("not a directory", err.getvalue())

    def test_happy_path_writes_tsv(self):
        with TemporaryDirectory() as d:
            root = Path(d) / "fastq_pass"
            _touch(root / "barcode01" / "reads.fastq.gz")
            _touch(root / "run_barcode02_0.fastq.gz")
            out = Path(d) / "barcodes.tsv"
            rc = db.main(["--input-dir", str(root), "--output", str(out)])
            self.assertEqual(rc, 0)
            lines = out.read_text().splitlines()
            self.assertEqual(lines[0], "barcode\tpath")
            barcodes = sorted(line.split("\t")[0] for line in lines[1:])
            self.assertEqual(barcodes, ["barcode01", "barcode02"])
            # paths are absolute so Nextflow can stage them
            for line in lines[1:]:
                self.assertTrue(line.split("\t")[1].startswith("/"))


if __name__ == "__main__":
    unittest.main()
