#!/usr/bin/env bats
#
# CFG-04: the resource ceiling (params.max_cpus / params.max_memory and
# process.resourceLimits).
#
# Run with:
#   bats tests/config/resources.bats
#
# Background (v1.8.0). The per-process requests in nextflow.config are
# written for a well-provisioned machine — SINTAX asks for 20 cpus and
# 16 GB. The local executor does not scale those down, it refuses:
#
#   Process requirement exceeds available CPUs -- req: 20; avail: 8
#
# so on any workstation with fewer than 20 cores the pipeline died before
# doing any biology, with an error that reads like the machine's fault.
# `process.resourceLimits` (native Nextflow >= 24.04) clamps every
# request — including a retry's escalated one — to the ceiling, and the
# ceiling defaults to what the machine actually has, queried through the
# same helper the local executor uses for that comparison. The two
# therefore cannot disagree: req <= avail holds by construction.
#
# CFG-04g is the one that matters: it runs the REAL resource config (not
# tests/nextflow.config's reduced one) against a deliberately tiny
# ceiling, and checks the clamped value reached the tool.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"
}

# Baseline valid invocation; extra flags appended. Publishes into a
# scratch copy of the fixture, never the committed one.
run_pipeline() {
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/fastq_dir/fastq_pass" "${DATA}/" 2> /dev/null || true
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

# ------------------------------------------------------------------- CFG-04

@test "CFG-04a the default ceiling is the machine's own capacity" {
    cd "${REPO_ROOT}"
    run nextflow config -flat
    [ "${status}" -eq 0 ]

    local cpus
    cpus="$(sed -nE 's/^params\.max_cpus = ([0-9]+)$/\1/p' <<< "${output}")"
    [ -n "${cpus}" ]
    # Same number the local executor would compare a request against.
    [ "${cpus}" -eq "$(nproc --all)" ]

    # And a memory ceiling is set (the exact figure is the host's RAM).
    [[ "${output}" == *"params.max_memory = "* ]]
}

@test "CFG-04b resourceLimits is wired to the two params" {
    cd "${REPO_ROOT}"
    run nextflow config -flat
    [ "${status}" -eq 0 ]

    local cpus limit
    cpus="$(sed -nE 's/^params\.max_cpus = ([0-9]+)$/\1/p' <<< "${output}")"
    limit="$(sed -nE 's/^process\.resourceLimits\.cpus = ([0-9]+)$/\1/p' <<< "${output}")"
    [ -n "${limit}" ]
    [ "${limit}" -eq "${cpus}" ]
    [[ "${output}" == *"process.resourceLimits.memory = "* ]]
}

@test "CFG-04c the cluster profile sets the ceiling explicitly, not by detection" {
    # params.max_cpus describes the host Nextflow runs on. Under slurm
    # that is the submit node, whose size says nothing about the compute
    # nodes — detecting it would silently shrink every submitted job.
    cd "${REPO_ROOT}"
    run nextflow config -flat -profile cluster
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"params.max_cpus = 16"* ]]
    [[ "${output}" == *"process.resourceLimits.cpus = 16"* ]]
    [[ "${output}" == *"process.executor = 'slurm'"* ]]

    # Only meaningful if the site's number differs from this host's.
    if [ "$(nproc --all)" -eq 16 ] ; then
        skip "this host happens to have 16 cores; the assertion cannot discriminate"
    fi
    run bash -c "nextflow config -flat -profile cluster | sed -nE 's/^params\.max_cpus = ([0-9]+)\$/\1/p'"
    [ "${output}" -ne "$(nproc --all)" ]
}

@test "CFG-04d an explicit --max_cpus overrides the detected default" {
    # `nextflow config` accepts neither pipeline params nor -c, so the
    # override is observed through the startup notice instead. Pointing
    # the reference at a missing file makes the run abort immediately
    # after the notice (checkIfExists fires later than the log line), so
    # this needs no cutadapt/vsearch.
    run_pipeline --max_cpus 3 \
        --sintax_references "${FIXTURES}/__does_not_exist__.fasta"
    [ "${status}" -ne 0 ]
    # The ceiling row of the startup summary (CFG-06 owns its exact shape).
    [[ "${output}" == *"resource ceiling"* ]]
    [[ "${output}" == *"3 cpus"* ]]
    # Not the machine's own count.
    if [ "$(nproc --all)" -ne 3 ] ; then
        [[ "${output}" != *"$(nproc --all) cpus"* ]]
    fi
}

@test "CFG-04d2 an explicit --max_memory overrides the detected default" {
    run_pipeline --max_memory '7.GB' \
        --sintax_references "${FIXTURES}/__does_not_exist__.fasta"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"resource ceiling"* ]]
    [[ "${output}" == *"7.GB"* ]]
}

@test "CFG-04e a non-positive max_cpus is rejected at startup" {
    run_pipeline --max_cpus 0
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'max_cpus' must be a positive integer"* ]]
}

@test "CFG-04f an unparseable max_memory is rejected at startup" {
    # Otherwise this surfaces much later as a bare "Not a valid FileSize
    # value" on the first task submission.
    run_pipeline --max_memory banana
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'max_memory' must be a positive memory size"* ]]
}

@test "CFG-04g the real resource config runs under a tiny ceiling, clamped" {
    # No tests/nextflow.config here, so SINTAX asks for its production
    # 20 cpus / 16 GB. A 2-cpu / 3 GB ceiling stands in for a small
    # workstation: the run must succeed with the request reduced, rather
    # than refused.
    for tool in cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 || skip "${tool} not in PATH"
    done

    run_pipeline --max_cpus 2 --max_memory '3.GB'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"exceeds available"* ]]

    # The ceiling is announced, so a run that used fewer threads than the
    # config requests is explicable.
    [[ "${output}" == *"resource ceiling"* ]]
    [[ "${output}" == *"2 cpus"* ]]
    [[ "${output}" == *"SINTAX gets 2 thread(s)"* ]]

    # The clamp reached the tool: vsearch was given 2 threads, not 20.
    run bash -c "grep -ho -- '--threads \"[0-9]*\"' '${BATS_TEST_TMPDIR}'/work/*/*/.command.sh | sort -u"
    [ "${output}" = '--threads "2"' ]

    # And the science still came out.
    run head -1 "${BATS_TEST_TMPDIR}/out.tsv"
    [[ "${output}" == "taxonomy"$'\t'"total"* ]]
}
