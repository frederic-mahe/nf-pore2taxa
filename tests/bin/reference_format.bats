#!/usr/bin/env bats
#
# Unit tests for check_reference_format in bin/lib/validation.sh — the
# startup format sniff of a user-supplied sintax reference database.
#
# This mirrors the reference-format check in nf-metabarcoding
# (check_reference_format / [S73]), restricted to the sintax format that
# `vsearch --sintax` expects: the first FASTA header must carry a `tax=`
# taxonomy annotation (`>id;tax=d:...,p:...;`). Only the first line is
# read; the rest is left for vsearch. Plain and gzip references are
# sniffed; a missing path is left for the presence check; a bzip2 file is
# skipped with a warning.
#
# Run with:
#   bats tests/bin/reference_format.bats

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/lib/validation.sh"
}

# --------------------------------------------------------------------- SX-12

@test "SX-12a a sintax-formatted reference passes the format check" {
    local f="${BATS_TEST_TMPDIR}/sintax.fasta"
    printf '>refA;tax=d:Bacteria,p:Proteobacteria;\nACGTACGTACGT\n' > "${f}"
    run -0 check_reference_format "${f}"
    [ -z "${output}" ]
}

@test "SX-12b the committed references.fasta fixture passes the format check" {
    run -0 check_reference_format "${REPO_ROOT}/tests/fixtures/references.fasta"
    [ -z "${output}" ]
}

@test "SX-12c a FASTA whose first header carries no 'tax=' is rejected" {
    local f="${BATS_TEST_TMPDIR}/no_tax.fasta"
    printf '>refA some free-text description\nACGTACGTACGT\n' > "${f}"
    run -1 check_reference_format "${f}"
    [[ "${output}" == *"must be sintax-formatted"* ]]
    [[ "${output}" == *"tax="* ]]
}

@test "SX-12d a file whose first line is not a '>' header is rejected as non-FASTA" {
    local f="${BATS_TEST_TMPDIR}/not_fasta.txt"
    printf 'query\ttaxonomy\nrefA\td:Bacteria\n' > "${f}"
    run -1 check_reference_format "${f}"
    [[ "${output}" == *"does not look like FASTA"* ]]
}

@test "SX-12e a missing reference path is not sniffed (presence handled elsewhere)" {
    run -0 check_reference_format "${BATS_TEST_TMPDIR}/__does_not_exist__.fasta"
    [ -z "${output}" ]
}

@test "SX-12f a .bz2 reference is skipped with a warning (not sniffed)" {
    local f="${BATS_TEST_TMPDIR}/ref.fasta.bz2"
    # Arbitrary bytes — must be skipped by extension, never decompressed.
    printf 'not a real bzip2 stream\n' > "${f}"
    run -0 check_reference_format "${f}"
    [[ "${output}" == *"bzip2-compressed"* ]]
    [[ "${output}" == *"skipping"* ]]
}

@test "SX-12g a gzip sintax reference is decompressed and passes" {
    local f="${BATS_TEST_TMPDIR}/sintax.fasta.gz"
    printf '>refG;tax=d:Bacteria,p:Firmicutes;\nACGTACGTACGT\n' | gzip > "${f}"
    run -0 check_reference_format "${f}"
    [ -z "${output}" ]
}

@test "SX-12h a gzip FASTA with no 'tax=' is decompressed and rejected" {
    local f="${BATS_TEST_TMPDIR}/no_tax.fasta.gz"
    printf '>refG free-text description\nACGTACGTACGT\n' | gzip > "${f}"
    run -1 check_reference_format "${f}"
    [[ "${output}" == *"must be sintax-formatted"* ]]
}
