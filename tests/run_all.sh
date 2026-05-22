#!/bin/bash
#
# Convenience runner: executes every test layer in sequence and reports
# overall pass/fail. Each individual layer can also be run directly;
# this just sequences them for CI.
#
# Layers:
#   1. bats unit tests   (bash helpers, validation.sh, R script)
#   2. nf-test suite     (modules + workflow)

set -uo pipefail

cd "$(dirname "$0")/.."   # repo root

declare -i fail=0

echo "===== 1/2  bats unit tests ====="
if command -v bats > /dev/null 2>&1 ; then
    bats tests/bin/ || fail=1
else
    echo "SKIP: bats not in PATH"
fi
echo

echo "===== 2/2  nf-test suite (modules + workflow) ====="
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
