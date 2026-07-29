#!/usr/bin/env python3
"""Unit tests for bin/collect_versions.py (PRV-10..PRV-13).

The tools this pipeline drives disagree completely on how they print a
version, and one of them (KronaTools) has no --version at all. These
tests pin the extraction against the real shapes, captured from the
installed tools, plus the failure mode that matters: a tool that cannot
be probed must appear as ``n/a`` rather than vanish from the report — an
absent line reads as "not used", which is a different and more misleading
claim than "could not determine".

    python3 -m unittest discover -s tests/bin -p 'test_*.py'
"""

import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory

_SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "collect_versions.py"
_spec = importlib.util.spec_from_file_location("collect_versions", _SCRIPT)
cv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cv)


# Real output captured from the installed tools — the point of the
# permissive regex is that all of these reduce to a clean version.
REAL_OUTPUTS = {
    "vsearch": ("vsearch v2.31.0_linux_x86_64, 125.3GB RAM, 24 cores", "2.31.0"),
    "cutadapt": ("5.2", "5.2"),
    "python": ("Python 3.12.3", "3.12.3"),
    "krona": ("KronaTools 2.8.1", "2.8.1"),
    # dorado reports a git-describe form; the build hash is dropped.
    "dorado": ("1.1.1+3c7eef9", "1.1.1"),
    "nextflow": ("26.04.4", "26.04.4"),
}


class ExtractVersion(unittest.TestCase):
    """PRV-10 — the version token is found in every real output shape."""

    def test_real_tool_outputs(self):
        for name, (raw, expected) in REAL_OUTPUTS.items():
            with self.subTest(tool=name):
                self.assertEqual(cv.extract_version(raw), expected)

    def test_unrecognisable_output_is_not_a_version(self):
        """PRV-11 — no version token means 'n/a', never a guess."""
        for raw in (
            "",
            "command not found",
            "ktImportText: Unknown option: version",
            "no digits here",
        ):
            with self.subTest(raw=raw):
                self.assertEqual(cv.extract_version(raw), "n/a")

    def test_first_version_run_wins(self):
        # vsearch prints its own version before the RAM/core figures.
        self.assertEqual(
            cv.extract_version("vsearch v2.31.0_linux, 125.3GB RAM"), "2.31.0"
        )


class Collect(unittest.TestCase):
    def test_maps_name_to_extracted_version(self):
        lines = ["vsearch\tvsearch v2.31.0_linux\n", "cutadapt\t5.2\n"]
        self.assertEqual(
            cv.collect(lines), {"vsearch": "2.31.0", "cutadapt": "5.2"}
        )

    def test_unprobeable_tool_is_kept_as_na(self):
        """PRV-11 — the line survives, so a broken env is visible."""
        got = cv.collect(["vsearch\t\n", "cutadapt\t5.2\n"])
        self.assertEqual(got, {"vsearch": "n/a", "cutadapt": "5.2"})
        # Present, not dropped: that is the whole point.
        self.assertIn("vsearch", got)

    def test_blank_and_nameless_lines_are_skipped(self):
        self.assertEqual(cv.collect(["\n", "  \n", "\torphan\n"]), {})

    def test_later_duplicate_wins(self):
        """PRV-12 — so an appended fragment can override the probe.

        BASECALL's dorado fragment is concatenated *after* the probe's own
        lines, which is what lets the task that really ran dorado correct
        a probe that could not see it.
        """
        lines = ["dorado\t\n", "dorado\t1.1.1+3c7eef9\n"]
        self.assertEqual(cv.collect(lines), {"dorado": "1.1.1"})


class ToYaml(unittest.TestCase):
    def test_sorted_and_deterministic(self):
        """PRV-13 — byte-identical output for the same inputs, any order."""
        a = cv.to_yaml({"vsearch": "2.31.0", "cutadapt": "5.2"})
        b = cv.to_yaml({"cutadapt": "5.2", "vsearch": "2.31.0"})
        self.assertEqual(a, b)
        self.assertEqual(a, "cutadapt: 5.2\nvsearch: 2.31.0\n")

    def test_empty_input_is_empty_output(self):
        self.assertEqual(cv.to_yaml({}), "")


class Cli(unittest.TestCase):
    def test_reads_files_given_as_arguments(self):
        with TemporaryDirectory() as d:
            probe = Path(d) / "probe.tsv"
            probe.write_text("vsearch\tvsearch v2.31.0\n", encoding="utf-8")
            fragment = Path(d) / "versions_dorado.tsv"
            fragment.write_text("dorado\t1.1.1+3c7eef9\n", encoding="utf-8")

            buffer = io.StringIO()
            with redirect_stdout(buffer):
                rc = cv.main([str(probe), str(fragment)])
            self.assertEqual(rc, 0)
            self.assertEqual(
                buffer.getvalue(), "dorado: 1.1.1\nvsearch: 2.31.0\n"
            )


if __name__ == "__main__":
    unittest.main()
