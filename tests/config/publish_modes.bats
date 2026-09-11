#!/usr/bin/env bats
#
# CFG-02 / CFG-03: the publish_mode allowed set, and its interaction with
# `cleanup`.
#
# Run with:
#   bats tests/config/publish_modes.bats
#
# Background (v1.7.1). `cleanup = true` used to be the shipped default
# while `publish_mode` accepted `symlink`/`rellink`. Together they
# published links *into* the work directory and then deleted it, so every
# output — both occurrence tables, every per-barcode .sintax, both Krona
# HTMLs — was a dangling link, under a run that reported SUCCESS. The
# defaults are now `cleanup = false` + `publish_mode = 'link'`, and the
# incompatible combination is rejected at startup rather than left to a
# default that a project config could silently flip back.
#
# `move` is rejected outright: BASECALL's downstream handoff reads the
# freshly written fastq_pass back out of the task work directory, which
# moving the files away would empty.
#
# These drive `nextflow run` because the checks live in main.nf's startup
# validation, but they all abort before any process is submitted, so no
# cutadapt/vsearch is needed.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../lib/guards.bash"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"

    # Hermeticity: the pipeline publishes per-barcode results into
    # params.fastq_dir, so the cases below that pass validation would
    # write .sintax/.log into the committed fixture tree if pointed at it
    # directly. Copy it per test (same reason tests/workflow/main.nf.test
    # copies into outputDir).
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/fastq_dir/fastq_pass" "${DATA}/"
}

# Run the pipeline with a valid baseline plus whatever extra flags are
# given. Most invocations here stop in validation; the two that do not
# (CFG-02c, CFG-03c) run to completion, hence the copied input above.
run_pipeline() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${DATA}" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        "$@"
}

# ------------------------------------------------------------------- CFG-02

@test "CFG-02a cleanup defaults to false so published links stay valid" {
    cd "${REPO_ROOT}"
    run nextflow config -flat
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cleanup = false"* ]]
}

@test "CFG-02b publish_mode = move is rejected (breaks the BASECALL handoff)" {
    run_pipeline --publish_mode move
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Parameter validation failed"* ]]
    [[ "${output}" == *"publish_mode"* ]]
}

@test "CFG-02c symlink + cleanup off publishes readable outputs" {
    # Not merely 'not rejected': the link modes are the right choice when
    # work and results live on different filesystems, so they must stay
    # available *and* usable. This is the positive half of P0-1 — the same
    # configuration that used to yield dangling links.
    require_tools cutadapt vsearch

    run_pipeline --publish_mode symlink --cleanup false
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Parameter validation failed"* ]]

    # A link, as asked for — and one that resolves to real content.
    [ -L "${BATS_TEST_TMPDIR}/out.tsv" ]
    [ -r "${BATS_TEST_TMPDIR}/out.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/out.tsv" ]
    run head -1 "${BATS_TEST_TMPDIR}/out.tsv"
    [[ "${output}" == "taxonomy"$'\t'"total"* ]]
    [ -s "${BATS_TEST_TMPDIR}/out_optimistic.tsv" ]
}

@test "CFG-02d an unknown publish_mode is still rejected" {
    run_pipeline --publish_mode hardlink
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"publish_mode"* ]]
}

# ------------------------------------------------------------------- CFG-03

@test "CFG-03a cleanup = true with publish_mode = symlink aborts at startup" {
    run_pipeline --publish_mode symlink --cleanup true
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Parameter validation failed"* ]]
    [[ "${output}" == *"cannot be combined with 'cleanup = true'"* ]]
}

@test "CFG-03b cleanup = true with publish_mode = rellink aborts at startup" {
    run_pipeline --publish_mode rellink --cleanup true
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot be combined with 'cleanup = true'"* ]]
}

@test "CFG-03c cleanup = true with publish_mode = copy keeps the outputs" {
    # copy materialises real files, so reclaiming work/ is safe — the
    # supported way to have both automatic cleanup and usable results.
    require_tools cutadapt vsearch

    run_pipeline --publish_mode copy --cleanup true
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Parameter validation failed"* ]]

    # Real file, not a link, and still readable after the work dir went.
    [ ! -L "${BATS_TEST_TMPDIR}/out.tsv" ]
    [ -f "${BATS_TEST_TMPDIR}/out.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/out.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/out_optimistic.tsv" ]
}

@test "CFG-03d a non-boolean cleanup is rejected, not coerced" {
    run_pipeline --cleanup yes
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'cleanup' must be true or false"* ]]
}
