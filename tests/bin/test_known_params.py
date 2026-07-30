#!/usr/bin/env python3
"""PRM-02 — the declared-parameter list cannot drift from the config.

``known_params()`` in ``modules/local/functions.nf`` is what startup
validation rejects unknown parameters against (PRM-01). It is a hand-written
list, so it has two failure modes, and both are silent:

* a parameter added to ``nextflow.config`` but not to the list is **rejected**
  the moment anyone uses it — the pipeline refusing its own parameter;
* a name left in the list after the parameter is removed stays **accepted**
  forever, so a typo matching that stale name goes unnoticed again, which is
  the whole defect PRM-01 exists to close.

This asserts both directions, the same drift-guard shape as DSC-07
(fastq extensions) and BC-12 (the dorado model prefix).

    python3 -m unittest discover -s tests/bin -p 'test_*.py'
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FUNCTIONS_NF = REPO_ROOT / "modules" / "local" / "functions.nf"
MAIN_CONFIG = REPO_ROOT / "nextflow.config"
SLURM_CONFIG = REPO_ROOT / "conf" / "slurm.config"


def known_params() -> set[str]:
    """The names listed in ``known_params()`` in functions.nf."""
    body = FUNCTIONS_NF.read_text(encoding="utf-8")
    match = re.search(r"def\s+known_params\(\)\s*\{(.*?)\n\}", body, re.S)
    assert match, "no known_params() in modules/local/functions.nf"
    return set(re.findall(r"'([a-z_0-9]+)'", match.group(1)))


def config_params() -> set[str]:
    """Names declared in the top-level ``params { }`` block of nextflow.config.

    Sliced from the ``params {`` line to the first line that is a bare ``}``:
    values inside the block contain their own braces, so a non-greedy
    ``{...}`` match would stop too early.
    """
    lines = MAIN_CONFIG.read_text(encoding="utf-8").splitlines()
    start = next(
        i for i, ln in enumerate(lines) if re.match(r"^params\s*\{", ln)
    )
    end = next(
        i for i in range(start + 1, len(lines))
        if re.match(r"^\}", lines[i])
    )
    names = set()
    for line in lines[start + 1:end]:
        m = re.match(r"^\s*([a-z_0-9]+)\s*=", line)
        if m:
            names.add(m.group(1))
    return names


def profile_injected_params() -> set[str]:
    """Names assigned as ``params.x = ...`` in conf/slurm.config.

    The scheduler parameters are declared there rather than in the base
    ``params`` block, but a user can still pass them, so they must be
    accepted.
    """
    body = SLURM_CONFIG.read_text(encoding="utf-8")
    return set(re.findall(r"^params\.([a-z_0-9]+)\s*=", body, re.M))


class KnownParamsMatchesConfig(unittest.TestCase):
    def test_every_declared_parameter_is_known(self):
        """PRM-02 — or the pipeline would reject its own parameter."""
        declared = config_params() | profile_injected_params()
        missing = sorted(declared - known_params())
        self.assertEqual(
            missing,
            [],
            f"declared in the config but absent from known_params(), so "
            f"passing one would be rejected as unknown: {missing}",
        )

    def test_every_known_parameter_is_declared(self):
        """PRM-02 — or a stale name keeps a typo acceptable forever."""
        declared = config_params() | profile_injected_params()
        stale = sorted(known_params() - declared)
        self.assertEqual(
            stale,
            [],
            f"listed in known_params() but declared nowhere, so a typo "
            f"matching it would still slip through: {stale}",
        )

    def test_the_lists_are_not_trivially_empty(self):
        # A regex that silently matched nothing would make both checks pass.
        self.assertGreater(len(known_params()), 20)
        self.assertGreater(len(config_params()), 20)
        self.assertGreater(len(profile_injected_params()), 3)

    def test_the_deprecated_parameters_are_still_known(self):
        """Rejecting them would break the configs the deprecation protects."""
        for name in ("sintax_silva", "results_table", "publish_beside_reads"):
            self.assertIn(name, known_params(), name)


if __name__ == "__main__":
    unittest.main()
