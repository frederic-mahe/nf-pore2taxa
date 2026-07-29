#!/usr/bin/env bats
#
# PRM-01: an undeclared parameter is rejected at startup.
#
# Run with:
#   bats tests/config/params_strict.bats
#
# Nextflow accepts any `--foo bar` silently and puts it in `params`, so until
# v1.12.0 a typo left the real parameter at its default while the user
# believed they had set it: `--subsampl 100` ran with subsample = 0 and said
# nothing. That is the same silent-wrong-result class as the v1.7.1 defects,
# and the only one of them the pipeline could not see itself.
#
# Every case here stops in validation, so no cutadapt/vsearch is needed.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"
}

# A fully valid invocation, plus whatever is appended.
pipeline() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${FIXTURES}/fastq_dir" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --outdir "${BATS_TEST_TMPDIR}/out" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        "$@"
}

# ------------------------------------------------------------------- PRM-01

@test "PRM-01 an undeclared parameter aborts the run" {
    pipeline --subsampl 100
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Parameter validation failed"* ]]
    [[ "${output}" == *"unknown parameter 'subsampl'"* ]]
}

@test "PRM-01b the nearest declared parameter is suggested" {
    # A rejection that only says "unknown" leaves the user re-reading the help
    # to spot a one-character difference.
    pipeline --subsampl 100
    [[ "${output}" == *"Did you mean 'subsample'?"* ]]

    pipeline --max_cpu 4
    [[ "${output}" == *"Did you mean 'max_cpus'?"* ]]

    pipeline --primerf ACGT
    [[ "${output}" == *"Did you mean 'primer_f'?"* ]]
}

@test "PRM-01c a name far from everything gets no misleading guess" {
    # Guessing at three edits from any real name would point somewhere wrong,
    # which is worse than not guessing.
    pipeline --wibble 1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unknown parameter 'wibble'"* ]]
    [[ "${output}" != *"Did you mean"* ]]
    # It still says where to look.
    [[ "${output}" == *"--help"* ]]
}

@test "PRM-01d every undeclared parameter is listed, not just the first" {
    pipeline --kron true --max_cpu 4
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unknown parameter 'kron'"* ]]
    [[ "${output}" == *"unknown parameter 'max_cpu'"* ]]
}

@test "PRM-01e a valid invocation is unaffected" {
    # The check must not reject any parameter the pipeline really declares —
    # including the ones profiles inject and the deprecated ones.
    pipeline --randseed 7 --subsample 3 --krona false \
             --table_name out.tsv --reference_size_gb 2 \
             --slurm_account acct --publish_beside_reads false
    [[ "${output}" != *"unknown parameter"* ]]
}

@test "PRM-01f --help alone is not an undeclared-parameter error" {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"unknown parameter"* ]]
    [[ "${output}" == *"Usage:"* ]]
}

@test "PRM-01g the deprecated parameters are still accepted" {
    # They warn, but they are declared: rejecting them would break exactly the
    # configs the deprecation period exists to protect.
    pipeline --results_table "${BATS_TEST_TMPDIR}/legacy/t.tsv"
    [[ "${output}" != *"unknown parameter"* ]]

    pipeline --sintax_silva "${FIXTURES}/references.fasta"
    [[ "${output}" != *"unknown parameter"* ]]
}
