#!/usr/bin/env bats
#
# End-to-end CLI tests for bin/assign_with_sintax.sh (per-barcode interface).
#
# Scope: behaviour at the script's outer boundary — accepted input
# formats, the primer-filter toggle, exit codes, error messages. We do
# NOT re-test cutadapt or vsearch. The script writes <barcode>.sintax and
# <barcode>.log into the current directory, so each test runs in its own
# BATS_TEST_TMPDIR.
#
# Run with:
#   bats tests/bin/assign_with_sintax_cli.bats

bats_require_minimum_version 1.5.0

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/assign_with_sintax.sh"
    export FIXDIR="${REPO_ROOT}/tests/fixtures/fastq_dir/fastq_pass"
    export REFS="${REPO_ROOT}/tests/fixtures/references.fasta"

    for tool in cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 \
            || skip "${tool} not in PATH"
    done
}

# Materialise barcode01's reads (which carry primers and survive
# trimming) as a single file with the requested extension, in CWD.
make_fastq() {
    local -r ext="${1}"
    case "${ext}" in
        fastq)     zcat "${FIXDIR}/barcode01/reads.fastq.gz" >  "reads.fastq" ;;
        fastq.gz)  cp   "${FIXDIR}/barcode01/reads.fastq.gz"    "reads.fastq.gz" ;;
        fastq.bz2) zcat "${FIXDIR}/barcode01/reads.fastq.gz" | bzip2 > "reads.fastq.bz2" ;;
        fastq.xz)  zcat "${FIXDIR}/barcode01/reads.fastq.gz" | xz    > "reads.fastq.xz" ;;
        *)         return 1 ;;
    esac
    echo "reads.${ext}"
}

# --------------------------------------------------------------------- SX-05

@test "SX-05-gz accepts a .fastq.gz file" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -eq 0 ]
    [ -s "bc.sintax" ]
}

@test "SX-05-plain accepts an uncompressed .fastq file" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -eq 0 ]
    [ -s "bc.sintax" ]
}

@test "SX-05-bz2 accepts a .fastq.bz2 file" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.bz2)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -eq 0 ]
    [ -s "bc.sintax" ]
}

@test "SX-05-xz accepts a .fastq.xz file" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.xz)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -eq 0 ]
    [ -s "bc.sintax" ]
}

@test "SX-05-noargs rejects an invocation with no fastq files" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no fastq files given"* ]]
}

# --------------------------------------------------------------------- SX-11

@test "SX-11 missing --barcode yields a clear error" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    run bash "${SCRIPT}" -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--barcode is required"* ]]
}

# --------------------------------------------------------------------- SX-12

@test "SX-12 rejects a reference that is not sintax-formatted" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    printf '>refA free-text header with no tax annotation\nACGTACGTACGT\n' > "bad_ref.fasta"
    run bash "${SCRIPT}" --barcode bc -d "bad_ref.fasta" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be sintax-formatted"* ]]
    # Must abort before any *.sintax is written.
    [ ! -e "bc.sintax" ]
}

# --------------------------------------------------------------------- SX-13

# barcode03's reads carry NO primers, so they probe the primer-presence
# filter.
b03() { echo "${FIXDIR}/barcode03/reads.fastq.gz" ; }

@test "SX-13a default discards reads with no primer (empty .sintax)" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" --barcode b03 -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "$(b03)"
    [ "${status}" -eq 0 ]
    [ -e "b03.sintax" ]
    [ ! -s "b03.sintax" ]
}

@test "SX-13b --discard-untrimmed is the explicit default" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" --barcode b03 -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 --discard-untrimmed "$(b03)"
    [ "${status}" -eq 0 ]
    [ ! -s "b03.sintax" ]
}

@test "SX-13c --keep-untrimmed keeps reads with no primer (non-empty .sintax)" {
    cd "${BATS_TEST_TMPDIR}"
    run bash "${SCRIPT}" --barcode b03 -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 --keep-untrimmed "$(b03)"
    [ "${status}" -eq 0 ]
    [ -s "b03.sintax" ]
}

# --------------------------------------------------------------------- SX-14

@test "SX-14a accepts a valid --randseed" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 --randseed 42 "${f}"
    [ "${status}" -eq 0 ]
    [ -s "bc.sintax" ]
}

@test "SX-14b rejects a negative --randseed" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 --randseed -5 "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--randseed must be a non-negative integer"* ]]
}

@test "SX-14c rejects a non-integer --randseed" {
    cd "${BATS_TEST_TMPDIR}"
    local f ; f="$(make_fastq fastq.gz)"
    run bash "${SCRIPT}" --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 --randseed abc "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--randseed must be a non-negative integer"* ]]
}

# --------------------------------------------------------------------- SX-40

@test "SX-40 a multi-file barcode yields one .sintax with combined reads" {
    cd "${BATS_TEST_TMPDIR}"
    # Two files (barcode01 + barcode02 fixtures), both primer-bearing.
    run bash "${SCRIPT}" --barcode multi -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 \
        "${FIXDIR}/barcode01/reads.fastq.gz" "${FIXDIR}/barcode02/reads.fastq.gz"
    [ "${status}" -eq 0 ]
    # one output file, 10 reads (5 + 5) merged into a single .sintax
    [ "$(wc -l < multi.sintax)" -eq 10 ]
}
