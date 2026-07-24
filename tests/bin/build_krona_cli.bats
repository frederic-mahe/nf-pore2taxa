#!/usr/bin/env bats
#
# End-to-end tests for bin/build_krona.sh: occurrence TSV -> Krona HTML.
#
# Scope: our orchestration (per-sample text files + ktImportText argv +
# output naming). We do NOT re-test Krona's rendering internals. Needs
# ktImportText (KronaTools) on PATH; skips gracefully if absent.
#
# Run with:
#   bats tests/bin/build_krona_cli.bats

bats_require_minimum_version 1.5.0

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/build_krona.sh"
    export FIXDIR="${REPO_ROOT}/tests/fixtures/krona"

    command -v ktImportText > /dev/null 2>&1 || skip "ktImportText not in PATH"
}

# --------------------------------------------------------------------- KR-40

@test "KR-40 build_krona.sh produces a non-empty krona.html with a Krona marker" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv"
    [ "${status}" -eq 0 ]
    [ -s "krona.html" ]
    grep -qi "krona" "krona.html"
    # Leaf taxa from the fixture are present in the chart data.
    grep -q "Alpha_one" "krona.html"
    grep -q "Beta_two"  "krona.html"
}

# --------------------------------------------------------------------- KR-41

@test "KR-41 one dataset per non-empty barcode; the all-zero barcode is absent" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv"
    [ "${status}" -eq 0 ]
    # barcode01 and barcode02 appear as dataset labels; barcode03 (all zero)
    # is skipped and never becomes a dataset.
    grep -q "barcode01" "krona.html"
    grep -q "barcode02" "krona.html"
    ! grep -q "barcode03" "krona.html"
}

# --------------------------------------------------------------------- KR-42

@test "KR-42 an _optimistic table is written to krona_optimistic.html" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv" "${FIXDIR}/occurrence_optimistic.tsv"
    [ "${status}" -eq 0 ]
    # Both HTMLs produced, named by the input table.
    [ -s "krona.html" ]
    [ -s "krona_optimistic.html" ]
}
