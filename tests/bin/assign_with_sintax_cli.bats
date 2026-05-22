#!/usr/bin/env bats
#
# End-to-end CLI tests for bin/assign_with_sintax.sh.
#
# Scope: behaviour at the script's outer boundary — accepted input
# formats, exit codes, error messages. We do NOT re-test cutadapt or
# vsearch.
#
# Run with:
#   bats tests/bin/assign_with_sintax_cli.bats

bats_require_minimum_version 1.5.0

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/assign_with_sintax.sh"
    export FIXTURE="${REPO_ROOT}/tests/fixtures/fastq_dir/fastq_pass/barcode01/reads.fastq.gz"
    export REFS="${REPO_ROOT}/tests/fixtures/references.fasta"

    for tool in cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 \
            || skip "${tool} not in PATH"
    done
}

# Build a per-test fastq_pass directory holding exactly one file
# matching one of the four supported extensions. The original reads
# come from the committed .fastq.gz fixture so they survive primer
# trimming and end up as confident assignments.
make_input_dir() {
    local -r ext="${1}"
    local -r dir="${BATS_TEST_TMPDIR}/fastq_pass/barcode01"
    mkdir -p "${dir}"
    case "${ext}" in
        fastq)
            zcat "${FIXTURE}" > "${dir}/reads.fastq" ;;
        fastq.gz)
            cp "${FIXTURE}" "${dir}/reads.fastq.gz" ;;
        fastq.bz2)
            zcat "${FIXTURE}" | bzip2 > "${dir}/reads.fastq.bz2" ;;
        fastq.xz)
            zcat "${FIXTURE}" | xz     > "${dir}/reads.fastq.xz" ;;
        *)
            return 1 ;;
    esac
    echo "${BATS_TEST_TMPDIR}/fastq_pass"
}

# Run the script against an input dir with default primers/refs.
run_pipeline() {
    local -r input_dir="${1}"
    run bash "${SCRIPT}" \
        --input-dir       "${input_dir}" \
        --references      "${REFS}" \
        --forward-primer  "GTACACACCGCCCGTCG" \
        --reverse-primer  "CGCCTSCSCTTANTDATATGC" \
        --threads         1
}

# --------------------------------------------------------------------- SX-05

@test "SX-05-gz validate_inputs accepts .fastq.gz input directory" {
    local input_dir ; input_dir="$(make_input_dir fastq.gz)"
    run_pipeline "${input_dir}"
    [ "${status}" -eq 0 ]
    [ -s "${input_dir}/barcode01/reads.sintax" ]
}

@test "SX-05-plain validate_inputs accepts uncompressed .fastq input directory" {
    local input_dir ; input_dir="$(make_input_dir fastq)"
    run_pipeline "${input_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"no fastq files"* ]]
    [ -s "${input_dir}/barcode01/reads.sintax" ]
}

@test "SX-05-bz2 validate_inputs accepts .fastq.bz2 input directory" {
    local input_dir ; input_dir="$(make_input_dir fastq.bz2)"
    run_pipeline "${input_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"no fastq files"* ]]
    [ -s "${input_dir}/barcode01/reads.sintax" ]
}

@test "SX-05-xz validate_inputs accepts .fastq.xz input directory" {
    local input_dir ; input_dir="$(make_input_dir fastq.xz)"
    run_pipeline "${input_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"no fastq files"* ]]
    [ -s "${input_dir}/barcode01/reads.sintax" ]
}

@test "SX-05-empty validate_inputs rejects a directory with no fastq files of any extension" {
    mkdir -p "${BATS_TEST_TMPDIR}/empty/barcode01"
    : > "${BATS_TEST_TMPDIR}/empty/barcode01/not_a_fastq.txt"
    run bash "${SCRIPT}" \
        --input-dir       "${BATS_TEST_TMPDIR}/empty" \
        --references      "${REFS}" \
        --forward-primer  "GTACACACCGCCCGTCG" \
        --reverse-primer  "CGCCTSCSCTTANTDATATGC" \
        --threads         1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no fastq files"* ]]
}
