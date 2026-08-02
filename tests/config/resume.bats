#!/usr/bin/env bats
#
# SX-35 / DSC-06: `-resume` must reflect the fastq actually present.
#
# Run with:
#   bats tests/config/resume.bats
#
# This needs two successive `nextflow run` invocations against a mutating
# input directory, which nf-test cannot express (each test gets a fresh
# outputDir and there is no resume hook), so it lives here and drives
# Nextflow directly. Needs cutadapt + vsearch, and skips without them.
#
# Background (v1.7.1). DISCOVER_BARCODES receives the fastq_pass path as
# an unstaged `val`, so Nextflow had nothing content-derived to hash and
# its cache key ignored the tree's contents. Adding a fastq to an
# EXISTING barcode directory and resuming was a full cache hit: the run
# reported SUCCESS and republished the previous table, silently dropping
# the new reads. That is the normal way a Nanopore run grows — a topped-up
# library, a second flow cell for one barcode — so it mattered. main.nf
# now enumerates the fastq in the workflow and passes the sorted list
# into the process, putting the input set in the cache key.
#
# Adding a *new* barcode directory always worked (the parent's mtime
# changed), which is why the bug looked like working behaviour; DSC-06c
# pins both halves.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    for tool in nextflow cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 || skip "${tool} not in PATH"
    done

    FIXTURES="${REPO_ROOT}/tests/fixtures"
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/fastq_dir/fastq_pass" "${DATA}/"

    # Written by the run itself: nextflow.config enables the trace scope
    # beside the tables, under results_table's parent as set below.
    TRACE="${BATS_TEST_TMPDIR}/results/pipeline_info/execution_trace.txt"

    # Keep the requests small enough to schedule on a CI runner.
    cat > "${BATS_TEST_TMPDIR}/test.config" << EOF
params {
    skip_basecall     = true
    fastq_dir         = "${DATA}"
    sintax_references = "${FIXTURES}/references.fasta"
    results_table     = "${BATS_TEST_TMPDIR}/results/table.tsv"
    primer_f          = "GTACACACCGCCCGTCG"
    primer_r          = "CGCCTSCSCTTANTDATATGC"
}
process { cpus = 1; memory = '2 GB'; withName: 'SINTAX' { cpus = 2 } }
EOF
}

pipeline() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -c "${BATS_TEST_TMPDIR}/test.config" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        "$@"
    [ "${status}" -eq 0 ] || {
        echo "pipeline failed:" ; echo "${output}" ; return 1
    }
}

# Every task in the last run's trace that was NOT a cache hit, as
# "<status> <name>". Empty output means the whole run was cached.
#
# Read from the trace rather than from Nextflow's own cache summary in the
# log: that line's wording is not something to depend on. 25.10.2 prints
# "[ab/cdef12] SINTAX (barcode03) | 3 of 3, cached: 3", 26.04.4 prints
# "[SUCCESS] completed=0 failed=0 cached=7", and whatever the CI action
# installs as latest-stable prints neither — matching `completed=0` is what
# had this test and PRV-08b red in GitHub CI on resumes that were, as the
# trace showed once it was consulted, full cache hits. The `status` column
# reads CACHED on all three, and it *names* the task that re-executed
# instead of only counting it — the thing worth knowing when this fails on
# a machine you cannot reach. trace.overwrite is true, so the file
# describes the resumed run and not the one before it.
#
# Columns are located by header name, not by position, so extending the
# `fields` list in nextflow.config cannot silently move the goalposts.
not_cached() {
    awk -F'\t' '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == "status") s = i
                if ($i == "name")   n = i
            }
            next
        }
        $s != "CACHED" { print $s, $n }
    ' "${TRACE}"
}

# How many tasks the trace lists at all, so that "nothing re-executed"
# cannot be satisfied by a trace that recorded nothing.
traced_tasks() {
    awk 'END { print NR - 1 }' "${TRACE}"
}

# Sum one barcode's column in the published table.
column_total() {
    local -r barcode="${1}"
    awk -F'\t' -v bc="${barcode}" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == bc) c = i; next }
        c      { s += $c }
        END    { print s + 0 }
    ' "${BATS_TEST_TMPDIR}/results/table.tsv"
}

# ------------------------------------------------------------------- SX-35

@test "SX-35 an unchanged -resume is a full cache hit" {
    pipeline
    pipeline -resume
    # The trace has to describe a real run for the check below to mean
    # anything.
    [ "$(traced_tasks)" -gt 0 ]
    # Nothing re-executed. Asserted as "no task has a status other than
    # CACHED" rather than a hardcoded cached=N, so adding a process later
    # does not silently turn this into a test of the wrong number.
    run not_cached
    [ -z "${output}" ] || {
        echo "an unchanged -resume re-executed:" ; echo "${output}" ; return 1
    }
}

# ------------------------------------------------------------------- DSC-06

@test "DSC-06a a fastq added to an EXISTING barcode is picked up on -resume" {
    pipeline
    [ "$(column_total barcode02)" -eq 5 ]

    # A second file for a barcode that already ran. The directory holding
    # it changes, but fastq_pass itself does not.
    cp "${DATA}/fastq_pass/barcode01/reads.fastq.gz" \
       "${DATA}/fastq_pass/barcode02/reads_extra.fastq.gz"

    pipeline -resume
    # 5 original + 5 added reads, all primer-bearing.
    [ "$(column_total barcode02)" -eq 10 ]
}

@test "DSC-06b the untouched barcodes stay cached across that resume" {
    pipeline
    cp "${DATA}/fastq_pass/barcode01/reads.fastq.gz" \
       "${DATA}/fastq_pass/barcode02/reads_extra.fastq.gz"
    pipeline -resume
    # The invalidation is targeted, not a blanket cache miss: only the
    # barcode whose files changed is re-assigned. Asserted on which tasks
    # ran rather than on a task count, so it survives new processes.
    [[ "${output}" == *"SINTAX (barcode02)"* ]]
    [[ "${output}" != *"SINTAX (barcode01)"* ]]
    [[ "${output}" != *"SINTAX (barcode03)"* ]]
    [ "$(column_total barcode01)" -eq 5 ]
}

@test "DSC-06c a NEW barcode directory is picked up on -resume" {
    pipeline
    run bash -c "head -1 '${BATS_TEST_TMPDIR}/results/table.tsv'"
    [[ "${output}" != *"barcode04"* ]]

    mkdir -p "${DATA}/fastq_pass/barcode04"
    cp "${DATA}/fastq_pass/barcode01/reads.fastq.gz" \
       "${DATA}/fastq_pass/barcode04/reads.fastq.gz"

    pipeline -resume
    run bash -c "head -1 '${BATS_TEST_TMPDIR}/results/table.tsv'"
    [[ "${output}" == *"barcode04"* ]]
    [ "$(column_total barcode04)" -eq 5 ]
}

@test "DSC-06d a removed fastq is reflected on -resume" {
    cp "${DATA}/fastq_pass/barcode01/reads.fastq.gz" \
       "${DATA}/fastq_pass/barcode02/reads_extra.fastq.gz"
    pipeline
    [ "$(column_total barcode02)" -eq 10 ]

    rm "${DATA}/fastq_pass/barcode02/reads_extra.fastq.gz"
    pipeline -resume
    # Shrinking the input set must invalidate too, not just growing it.
    [ "$(column_total barcode02)" -eq 5 ]
}
