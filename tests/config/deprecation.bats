#!/usr/bin/env bats
#
# Deprecation behaviour of the `sintax_silva` parameter alias.
#
# Run with:
#   bats tests/config/deprecation.bats
#
# The warning is emitted via `log.warn`, which Nextflow writes to its
# console/log stream (not to the pipeline's own stdout), so nf-test
# cannot observe it. Here we drive `nextflow run` directly and inspect
# its combined output. We point the alias at a non-existent reference so
# the run aborts immediately after the warning is printed, keeping the
# test fast and free of cutadapt/vsearch dependencies.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
}

# ------------------------------------------------------------------- WF-08

@test "WF-08 supplying sintax_silva emits a deprecation warning" {
    cd "${BATS_TEST_TMPDIR}"
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall \
        --fastq_dir "${REPO_ROOT}/tests/fixtures/fastq_dir" \
        --sintax_silva "${REPO_ROOT}/tests/fixtures/__does_not_exist__.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC"

    # The run aborts (missing reference), but the warning must appear and
    # name both the deprecated parameter and its status.
    [[ "${output}" == *"sintax_silva"* ]]
    [[ "${output,,}" == *"deprecated"* ]]
}
