#!/bin/bash
#
# Convenience runner: executes every test layer in sequence and reports
# overall pass/fail. Each individual layer can also be run directly;
# this just sequences them for CI.
#
# Layers:
#   1. python unit tests (bin/build_occurrence_table.py)
#   2. bats unit tests   (bash helpers, validation.sh, table-builder CLI)
#   3. nf-test suite     (modules + workflow)

set -uo pipefail

cd "$(dirname "$0")/.."   # repo root

declare -i fail=0

echo "===== 1/3  python unit tests ====="
if command -v python3 > /dev/null 2>&1 ; then
    python3 -m unittest discover -s tests/bin -p 'test_*.py' || fail=1
else
    echo "SKIP: python3 not in PATH"
fi
echo

echo "===== 2/3  bats unit tests ====="
if command -v bats > /dev/null 2>&1 ; then
    bats tests/bin/ tests/config/ || fail=1
else
    echo "SKIP: bats not in PATH"
fi
echo

echo "===== 3/3  nf-test suite (modules + workflow) ====="
if command -v nf-test > /dev/null 2>&1 ; then
    nf-test test tests/ || fail=1
else
    echo "SKIP: nf-test not in PATH"
fi
echo

if (( fail == 0 )) ; then
    echo "ALL GOOD"
    exit 0
else
    echo "FAILURES — see output above"
    exit 1
fi
