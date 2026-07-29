#!/usr/bin/env python3
"""Collect tool version strings into a YAML mapping.

Every run records what produced its tables: the external tools, the
Python interpreter, the pipeline release and the Nextflow that ran it,
into ``<results dir>/pipeline_info/software_versions.yml``. Without this
two labs comparing occurrence tables have no way to tell whether they ran
the same software.

Each input line is ``<name><TAB><raw version output>`` — the raw text a
tool prints when asked for its version. The tools disagree wildly on
shape:

    vsearch       vsearch v2.31.0_linux_x86_64, 125.3GB RAM, 24 cores
    cutadapt      5.2
    python3       Python 3.12.3
    ktImportText  ... / KronaTools 2.8.1 - ktImportText \\...
    dorado        1.1.1+3c7eef9

so the version token is extracted with one permissive regex (the first
``MAJOR.MINOR[.PATCH...]`` run). A tool that prints nothing recognisable
— missing from PATH, ``command not found`` — is recorded as ``n/a``
rather than dropped, so a broken environment is *visible* in the report
instead of silently absent: an omitted line looks like a tool that was
not used, which is a different and much more misleading claim.

Reads the lines from stdin (or from files given as arguments) and writes
the sorted YAML mapping to stdout. Standard library only.

Adapted from nf-metabarcoding's ``bin/collect_versions.py`` (same author,
same users), so a lab running both pipelines gets the same artefact in
the same format.
"""

from __future__ import annotations

import re
import sys
from typing import Iterable

# The first MAJOR.MINOR[.PATCH...] run anywhere in the raw output. Kept
# permissive on purpose: it has to cope with a bare '5.2', a banner
# ('KronaTools 2.8.1 - ktImportText'), a suffixed build
# ('v2.31.0_linux_x86_64'), and a git-describe form ('1.1.1+3c7eef9').
_VERSION_RE = re.compile(r"\d+\.\d+(?:\.\d+)*")

UNKNOWN = "n/a"


# --------------------------------------------------------------- pure helpers


def extract_version(raw: str) -> str:
    """Return the first ``MAJOR.MINOR[.PATCH...]`` token, or ``"n/a"``."""
    match = _VERSION_RE.search(raw)
    return match.group(0) if match else UNKNOWN


def collect(lines: Iterable[str]) -> dict[str, str]:
    """Map each ``name<TAB>raw`` line to ``name -> extracted version``.

    Blank lines and lines with no name are skipped. A later duplicate of
    the same name wins, so a caller can append an override (e.g. the
    dorado line emitted by BASECALL) after the probe's own output.
    """
    versions: dict[str, str] = {}
    for line in lines:
        if not line.strip():
            continue
        name, _, raw = line.rstrip("\n").partition("\t")
        name = name.strip()
        if not name:
            continue
        versions[name] = extract_version(raw)
    return versions


def to_yaml(versions: dict[str, str]) -> str:
    """Render *versions* as a deterministic, sorted YAML mapping."""
    return "".join(f"{name}: {versions[name]}\n" for name in sorted(versions))


# ----------------------------------------------------------------------- CLI


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args:
        lines: list[str] = []
        for path in args:
            with open(path, encoding="utf-8") as handle:
                lines.extend(handle.readlines())
    else:
        lines = sys.stdin.readlines()
    sys.stdout.write(to_yaml(collect(lines)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
