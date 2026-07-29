#!/bin/bash
#
# Convenience runner: executes every test layer in sequence and reports
# overall pass/fail. Each individual layer can also be run directly;
# this just sequences them for CI.
#
# Layers:
#   1. python unit tests (bin/build_occurrence_table.py)
#   2. bats unit tests   (bash helpers, validation.sh, table-builder CLI,
#                         config invariants, publish modes, -resume)
#   3. nf-test suite     (modules + workflow)
#   4. hermeticity       (the run must not modify tests/fixtures/)
#   5. coverage gate     (SPECIFICATIONS <-> COVERAGE <-> tests mapping)

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1   # repo root

declare -i fail=0

# Content snapshot of the committed fixtures, for the hermeticity check at
# the end. Checksums rather than mtimes, so a test that rewrites a fixture
# with identical content is (correctly) not flagged.
fixtures_manifest() {
    find tests/fixtures -type f -exec sha1sum {} + 2> /dev/null | sort
}
fixtures_before="$(fixtures_manifest)"

echo "===== 1/5  python unit tests ====="
if command -v python3 > /dev/null 2>&1 ; then
    python3 -m unittest discover -s tests/bin -p 'test_*.py' || fail=1
else
    echo "SKIP: python3 not in PATH"
fi
echo

echo "===== 2/5  bats unit tests ====="
if command -v bats > /dev/null 2>&1 ; then
    bats tests/bin/ tests/config/ || fail=1
else
    echo "SKIP: bats not in PATH"
fi
echo

echo "===== 3/5  nf-test suite (modules + workflow) ====="
if command -v nf-test > /dev/null 2>&1 ; then
    nf-test test tests/ || fail=1
else
    echo "SKIP: nf-test not in PATH"
fi
echo

# Hermeticity check: the test RUN must not modify tests/fixtures/.
#
# The pipeline publishes per-barcode results into params.fastq_dir, so a test
# that points that at the committed fixtures instead of a scratch copy writes
# .sintax/.log into them — silently, and noticed later only as stray files.
# A dirty fixture tree also feeds the *next* run files the fixture does not
# declare, so it can mask or invent failures.
#
# Compared against a snapshot taken BEFORE the run rather than against git:
# `git status` cannot tell "the run wrote this" from "the author is editing a
# fixture and has not committed yet", and failing on the latter is a false
# alarm. (The CI steps do use git, which is correct there: the checkout is
# pristine and the run happened in an earlier step.)
echo "===== 4/5  hermeticity: tests/fixtures/ unchanged ====="
fixtures_after="$(fixtures_manifest)"
if [[ "${fixtures_before}" == "${fixtures_after}" ]] ; then
    echo "OK: tests/fixtures/ untouched"
else
    echo "FAIL: the test run modified tests/fixtures/:"
    diff <(printf '%s\n' "${fixtures_before}") \
         <(printf '%s\n' "${fixtures_after}") | sed 's/^/  /'
    echo "      A test is publishing into the committed fixtures."
    echo "      Copy the fixture into a scratch dir and point"
    echo "      params.fastq_dir at the copy (see tests/config/"
    echo "      publish_modes.bats or tests/workflow/main.nf.test)."
    fail=1
fi
echo

echo "===== 5/5  coverage gate ====="
bash "$(dirname "$0")/coverage-gate.sh" || fail=1
echo

if (( fail == 0 )) ; then
    echo "ALL GOOD"
    exit 0
else
    echo "FAILURES — see output above"
    exit 1
fi
