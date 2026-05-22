#!/usr/bin/env bats
#
# Unit tests for the pure-function helpers in bin/assign_with_sintax.sh:
#   - trim_extension      (SX-20, SX-21)
#   - reverse_complement  (SX-22, SX-23, SX-24)
#
# Run with:
#   bats tests/bin/assign_with_sintax_helpers.bats

setup() {
    # Resolve repo root from this test file's location.
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SRC="${REPO_ROOT}/bin/assign_with_sintax.sh"

    # The script's argument-parsing block runs at the top level on
    # source, which would abort the test. Extract just the helper
    # function definitions.
    HELPERS="${BATS_TEST_TMPDIR}/helpers.sh"
    awk '
        /^trim_extension\(\)/     { in_block=1 }
        /^reverse_complement\(\)/ { in_block=1 }
        in_block                  { print }
        in_block && /^\}/         { in_block=0 ; print "" }
    ' "${SRC}" > "${HELPERS}"

    # shellcheck source=/dev/null
    source "${HELPERS}"
}

# ---------------------------------------------------------------- SX-20, SX-21

@test "SX-20a trim_extension: strips .fastq.gz" {
    [ "$(trim_extension reads.fastq.gz)" = "reads" ]
}

@test "SX-20b trim_extension: strips .fastq.bz2" {
    [ "$(trim_extension reads.fastq.bz2)" = "reads" ]
}

@test "SX-20c trim_extension: strips .fastq.xz" {
    [ "$(trim_extension reads.fastq.xz)" = "reads" ]
}

@test "SX-20d trim_extension: strips bare .fastq" {
    [ "$(trim_extension reads.fastq)" = "reads" ]
}

@test "SX-20e trim_extension: preserves path components" {
    [ "$(trim_extension barcode01/reads.fastq.gz)" = "barcode01/reads" ]
}

@test "SX-20f trim_extension: idempotent on names without a recognised suffix" {
    [ "$(trim_extension noext)" = "noext" ]
}

@test "SX-21 trim_extension: .bak is not a recognised suffix — passthrough" {
    [ "$(trim_extension foo.fastq.gz.bak)" = "foo.fastq.gz.bak" ]
}

# ---------------------------------------------------------------- SX-22, SX-23

@test "SX-22a reverse_complement: A -> T" {
    [ "$(reverse_complement A)" = "T" ]
}

@test "SX-22b reverse_complement: T -> A" {
    [ "$(reverse_complement T)" = "A" ]
}

@test "SX-22c reverse_complement: C -> G" {
    [ "$(reverse_complement C)" = "G" ]
}

@test "SX-22d reverse_complement: G -> C" {
    [ "$(reverse_complement G)" = "C" ]
}

@test "SX-22e reverse_complement: ACGT -> ACGT (palindrome)" {
    [ "$(reverse_complement ACGT)" = "ACGT" ]
}

@test "SX-22f reverse_complement: N is self-complementary" {
    [ "$(reverse_complement N)" = "N" ]
}

@test "SX-23a reverse_complement: lower-case preserved (tgca palindrome)" {
    [ "$(reverse_complement tgca)" = "tgca" ]
}

@test "SX-23b reverse_complement: IUPAC lower-case (yyrr palindrome)" {
    [ "$(reverse_complement yyrr)" = "yyrr" ]
}

@test "SX-22-roundtrip reverse_complement is an involution on the project's reverse primer" {
    local pr="CGCCTSCSCTTANTDATATGC"
    [ "$(reverse_complement "$(reverse_complement "${pr}")")" = "${pr}" ]
}

# --------------------------------------------------------------------- SX-24

@test "SX-24 reverse_complement: empty string aborts with a clear error" {
    # The helper calls `exit 1` directly; run it in a child bash that
    # re-sources the helpers (functions don't cross the `run` boundary).
    run env HELPERS="${HELPERS}" bash -c 'source "${HELPERS}"; reverse_complement "" 2>&1'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"empty string"* ]]
}
