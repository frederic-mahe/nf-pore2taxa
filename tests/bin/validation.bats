#!/usr/bin/env bats
#
# Unit tests for bin/lib/validation.sh — the require_arg and
# check_readable helpers reused by both bin/ scripts.
#
# Run with:
#   bats tests/bin/validation.bats

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/lib/validation.sh"
}

# ----------------------------------------------------------------- VL-01..02

@test "VL-01 require_arg returns 1 and writes 'Error: <name> is required.' to stderr when value is empty" {
    run -1 require_arg "--input-dir" ""
    [[ "${output}" == "Error: --input-dir is required." ]]
}

@test "VL-02 require_arg returns 0 and prints nothing when value is non-empty" {
    run -0 require_arg "--input-dir" "/some/path"
    [ -z "${output}" ]
}

# --------------------------------------------------------------------- VL-03

@test "VL-03a check_readable file: returns 0 for a readable file" {
    local f="${BATS_TEST_TMPDIR}/exists.txt"
    : > "${f}"
    run -0 check_readable file "${f}" "the file"
}

@test "VL-03b check_readable file: returns 1 with 'not found' for a missing file" {
    run -1 check_readable file "${BATS_TEST_TMPDIR}/__missing__" "the file"
    [[ "${output}" == *"the file not found"* ]]
}

@test "VL-03c check_readable file: returns 1 with 'is not readable' for an unreadable file" {
    local f="${BATS_TEST_TMPDIR}/no_read.txt"
    : > "${f}"
    chmod 000 "${f}"
    run -1 check_readable file "${f}" "the file"
    [[ "${output}" == *"the file is not readable"* ]]
    chmod 644 "${f}"  # let bats clean up
}

# --------------------------------------------------------------------- VL-04

@test "VL-04a check_readable dir: returns 0 for a readable directory" {
    mkdir -p "${BATS_TEST_TMPDIR}/d"
    run -0 check_readable dir "${BATS_TEST_TMPDIR}/d" "the dir"
}

@test "VL-04b check_readable dir: returns 1 for a missing directory" {
    run -1 check_readable dir "${BATS_TEST_TMPDIR}/__nosuchdir__" "the dir"
    [[ "${output}" == *"the dir not found"* ]]
}

@test "VL-04c check_readable dir: rejects a file passed as 'dir'" {
    local f="${BATS_TEST_TMPDIR}/regular_file"
    : > "${f}"
    run -1 check_readable dir "${f}" "the dir"
    [[ "${output}" == *"the dir not found"* ]]
}
