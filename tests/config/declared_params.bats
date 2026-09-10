#!/usr/bin/env bats
#
# PRM-03: the pipeline declares every parameter it reads.
#
# Run with:
#   bats tests/config/declared_params.bats
#
# Background (v1.13.x). Nextflow warns when a parameter is *read* without
# having been declared:
#
#   WARN: Access to undefined parameter `require_slurm_account` --
#   Initialise it to a default value eg. `params.require_slurm_account = some_value`
#
# `require_slurm_account` was read by main.nf's startup validation on every
# run, but its default lived in conf/slurm.config, which nothing but the
# cluster profiles loads. Every local run therefore printed that warning
# directly above the run summary, where it reads like a misconfiguration.
# An `?:` fallback cannot suppress it — the warning fires on the read,
# before the elvis operator ever sees a value — so the fix is a declared
# default, exactly as the warning itself advises.
#
# This is the mirror of PRM-01: that one stops the *user* passing a name
# the pipeline does not declare, this one stops the *pipeline* reading one.
# Kept general on purpose — it fails for any future parameter that is read
# without a default, not just the one that prompted it.
#
# `-stub-run`, so no cutadapt/vsearch/dorado is needed: the warning is
# emitted during startup, long before any tool would run.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"
}

# A fully valid invocation with no profile, plus whatever is appended.
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

# ------------------------------------------------------------------- PRM-03

@test "PRM-03 a default run reads no undefined parameter" {
    pipeline -stub-run
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Access to undefined parameter"* ]]
}

@test "PRM-03b nor does a run with the optional branches enabled" {
    # krona = true reaches the conditional KRONA branch, and the cluster
    # parameters are read by the same startup validation either way.
    pipeline -stub-run --krona true
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Access to undefined parameter"* ]]
}
