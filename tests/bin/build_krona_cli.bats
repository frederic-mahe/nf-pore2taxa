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

load "${BATS_TEST_DIRNAME}/../lib/guards.bash"

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/build_krona.sh"
    export FIXDIR="${REPO_ROOT}/tests/fixtures/krona"

    require_tools ktImportText
}

# --------------------------------------------------------------------- KR-40

@test "KR-40 build_krona.sh produces a non-empty <stem>.krona.html with a Krona marker" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv"
    [ "${status}" -eq 0 ]
    [ -s "occurrence.krona.html" ]
    grep -qi "krona" "occurrence.krona.html"
    # Leaf taxa from the fixture are present in the chart data.
    grep -q "Alpha_one" "occurrence.krona.html"
    grep -q "Beta_two"  "occurrence.krona.html"
}

# --------------------------------------------------------------------- KR-41

@test "KR-41 one dataset per non-empty barcode; the all-zero barcode is absent" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv"
    [ "${status}" -eq 0 ]
    # barcode01 and barcode02 appear as dataset labels; barcode03 (all zero)
    # is skipped and never becomes a dataset.
    grep -q "barcode01" "occurrence.krona.html"
    grep -q "barcode02" "occurrence.krona.html"
    ! grep -q "barcode03" "occurrence.krona.html"
}

# --------------------------------------------------------------------- KR-42

@test "KR-42a each chart is named after its own input table's stem" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" "${FIXDIR}/occurrence.tsv" "${FIXDIR}/occurrence_optimistic.tsv"
    [ "${status}" -eq 0 ]
    # Both HTMLs produced, each carrying the stem of the table it came from —
    # which is what keeps two runs' charts apart once they are gathered into
    # one directory (WF-13d).
    [ -s "occurrence.krona.html" ]
    [ -s "occurrence_optimistic.krona.html" ]
}

@test "KR-42b a table named *_optimistic does not collapse both charts" {
    # The name used to be chosen by testing the basename for the substring
    # '_optimistic', so a run whose own table was called mytable_optimistic.tsv
    # sent BOTH charts to krona_optimistic.html: one overwrote the other and
    # the process emitted a single HTML where it declares two.
    cd "${BATS_TEST_TMPDIR}"
    cp "${FIXDIR}/occurrence.tsv"            "mytable_optimistic.tsv"
    cp "${FIXDIR}/occurrence_optimistic.tsv" "mytable_optimistic_optimistic.tsv"

    run bash "${SCRIPT}" "mytable_optimistic.tsv" "mytable_optimistic_optimistic.tsv"
    [ "${status}" -eq 0 ]
    [ -s "mytable_optimistic.krona.html" ]
    [ -s "mytable_optimistic_optimistic.krona.html" ]
}
