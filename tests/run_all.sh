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

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1   # repo root

declare -i fail=0

echo "===== 1/4  python unit tests ====="
if command -v python3 > /dev/null 2>&1 ; then
    python3 -m unittest discover -s tests/bin -p 'test_*.py' || fail=1
else
    echo "SKIP: python3 not in PATH"
fi
echo

echo "===== 2/4  bats unit tests ====="
if command -v bats > /dev/null 2>&1 ; then
    bats tests/bin/ tests/config/ || fail=1
else
    echo "SKIP: bats not in PATH"
fi
echo

echo "===== 3/4  nf-test suite (modules + workflow) ====="
if command -v nf-test > /dev/null 2>&1 ; then
    nf-test test tests/ || fail=1
else
    echo "SKIP: nf-test not in PATH"
fi
echo

# Hermeticity check. The pipeline publishes per-barcode results into
# params.fastq_dir, so a test that points that at tests/fixtures/ instead
# of a scratch copy writes .sintax/.log into the committed fixture tree —
# silently, and only noticed later as stray files in `git status`. A dirty
# fixture directory also makes the *next* run's discovery see files the
# fixture does not declare, so it can mask or invent failures.
echo "===== 4/4  hermeticity: tests/fixtures/ unchanged ====="
if command -v git > /dev/null 2>&1 && git rev-parse --git-dir > /dev/null 2>&1 ; then
    dirty="$(git status --porcelain -- tests/fixtures/)"
    if [[ -n "${dirty}" ]] ; then
        echo "FAIL: the test run modified tests/fixtures/:"
        echo "${dirty}"
        echo "      A test is publishing into the committed fixtures."
        echo "      Copy the fixture into a scratch dir and point"
        echo "      params.fastq_dir at the copy (see tests/config/"
        echo "      publish_modes.bats or tests/workflow/main.nf.test)."
        fail=1
    else
        echo "OK: tests/fixtures/ untouched"
    fi
else
    echo "SKIP: not a git checkout"
fi
echo

if (( fail == 0 )) ; then
    echo "ALL GOOD"
    exit 0
else
    echo "FAILURES — see output above"
    exit 1
fi
