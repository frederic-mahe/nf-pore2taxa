#!/usr/bin/env bats
#
# SX-19: the SINTAX module hands assign_with_sintax.sh a list *file*, not
# a command line full of file names.
#
# Why this lives here rather than in tests/modules/sintax.nf.test: the
# assertion is about the text of the rendered `.command.sh`, which needs a
# real run and a reachable work directory — the same shape as CFG-04g in
# resources.bats, which reads the clamped `--threads` back out of it.
#
# Background (v1.13.x). `${fastqs}` interpolated every staged name onto
# one line of the task script, and that line becomes the argv of an
# `execve`. Measured ceiling on a default 8 MB stack (ARG_MAX = 2 MiB):
# about 32,000 names of 56 characters — a scattered barcode of a large
# PromethION run is within reach of it. Over the limit the task dies with
# exit 126 and `Argument list too long`. A heredoc is read from the script
# file instead, so the list file has no such ceiling.
#
# Run with:
#   bats tests/config/sintax_fastq_list.bats

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    # Presence is not usability (SX-17): a broken launcher would abort the
    # run at startup, which would fail this test for the wrong reason.
    for tool in cutadapt vsearch ; do
        "${tool}" --version > /dev/null 2>&1 || skip "${tool} not usable"
    done
    FIXTURES="${REPO_ROOT}/tests/fixtures"
}

# flat_dir's barcode01 is split across two fastq files, which is what makes
# the one-line-argv question observable at all.
run_pipeline() {
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/flat_dir/fastq_pass" "${DATA}/"
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${DATA}" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        --max_cpus 2 --max_memory '3.GB' \
        "$@"
}

# The SINTAX task's rendered script, found by the driver it invokes.
sintax_command_sh() {
    grep --files-with-matches --recursive --include='.command.sh' \
        'assign_with_sintax.sh' "${BATS_TEST_TMPDIR}/work"
}

@test "SX-19e the SINTAX task passes its fastq files through a list file" {
    run_pipeline
    [ "${status}" -eq 0 ]

    local script
    script="$(sintax_command_sh)"
    [ -n "${script}" ]

    run grep -c -- '--fastq-list' "${script}"
    [ "${status}" -eq 0 ]

    # No line carries two fastq names: the old form put every name on the
    # single invocation line, the list file puts one per line.
    run grep -c -E '\.fastq(\.gz)?[^\n]*\.fastq(\.gz)?' "${script}"
    [ "${output}" = "0" ]

    # And the reads still reached vsearch: barcode01's two files are
    # pooled into one assignment (SX-40 asserts the counts).
    run head -1 "${BATS_TEST_TMPDIR}/out.tsv"
    [[ "${output}" == "taxonomy"$'\t'"total"* ]]
}
