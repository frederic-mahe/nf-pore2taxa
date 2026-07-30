#!/usr/bin/env bats
#
# DEM-01..DEM-04: the self-contained demo profile.
#
# Run with:
#   bats tests/config/demo_profile.bats
#
# `nextflow run main.nf -profile demo` is the first thing to try after
# installing: it runs the whole pipeline with no flags against the committed
# dataset in assets/demo/, so it separates "my environment is broken" from
# "my data is awkward" before a lab has wired up any data of their own. It is
# also the topology the tool-free stub run drives (STB-02).
#
# The reads are synthetic and not biologically meaningful; what the demo
# demonstrates is that the tools, the wiring and the environment work end to
# end and produce a table with the shape a real one has.
#
# Needs cutadapt + vsearch — the pipeline's core dependencies, and
# deliberately nothing more (DEM-04).

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    DEMO="${REPO_ROOT}/assets/demo"
}

need_tools() {
    local tool
    for tool in cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 || skip "${tool} not in PATH"
    done
}

# ------------------------------------------------------------------- DEM-01

@test "DEM-01 -profile demo runs the whole pipeline with no flags" {
    need_tools
    # Run from a scratch directory, as a user would from a fresh clone: the
    # only argument is the profile.
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" -profile demo \
        -work-dir "${BATS_TEST_TMPDIR}/work"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }

    [ -s "${BATS_TEST_TMPDIR}/demo_results/sintax.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/demo_results/sintax_optimistic.tsv" ]

    # A real table: three barcodes and at least the two demo taxa.
    run head -1 "${BATS_TEST_TMPDIR}/demo_results/sintax.tsv"
    [[ "${output}" == "taxonomy"$'\t'"total"* ]]
    for bc in barcode01 barcode02 barcode03 ; do
        [[ "${output}" == *"${bc}"* ]] || {
            echo "no ${bc} column: ${output}"; return 1
        }
    done
    run bash -c "tail -n +2 '${BATS_TEST_TMPDIR}/demo_results/sintax.tsv' | wc -l"
    [ "${output}" -ge 2 ]
}

# ------------------------------------------------------------------- DEM-02

@test "DEM-02 the demo dataset is committed and self-contained" {
    # No generation step: a fresh clone can run the demo immediately.
    [ -s "${DEMO}/reference.fasta" ]
    [ -s "${DEMO}/fastq_pass/barcode01/reads.fastq.gz" ]
    [ -s "${DEMO}/fastq_pass/barcode02/reads.fastq.gz" ]
    [ -s "${DEMO}/fastq_pass/barcode03/reads.fastq.gz" ]
    [ -x "${DEMO}/make_demo.sh" ]

    # sintax-formatted, or the assignment step would silently produce nothing.
    run head -1 "${DEMO}/reference.fasta"
    [[ "${output}" == ">"*";tax="* ]]

    # And it is tracked, not a leftover from someone's local run.
    cd "${REPO_ROOT}" || return 1
    run git ls-files --error-unmatch \
        "assets/demo/reference.fasta" \
        "assets/demo/fastq_pass/barcode01/reads.fastq.gz"
    [ "${status}" -eq 0 ]
}

@test "DEM-02b one demo barcode mixes both taxa" {
    # So the table has the shape a real occurrence table has — counts spread
    # across taxa within a sample — rather than a diagonal that would hide a
    # per-barcode counting bug.
    need_tools
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" -profile demo \
        -work-dir "${BATS_TEST_TMPDIR}/work"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }

    # barcode03 has 3 reads of one taxon and 2 of the other: two non-zero
    # cells in its column.
    run awk -F'\t' '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "barcode03") c = i; next }
        c && $c > 0 { n++ }
        END { print n + 0 }
    ' "${BATS_TEST_TMPDIR}/demo_results/sintax.tsv"
    [ "${output}" -eq 2 ]
}

# ------------------------------------------------------------------- DEM-03

@test "DEM-03 everything lands under demo_results/, reports included" {
    # The report/timeline/trace/dag blocks are evaluated above `profiles { }`,
    # where params.outdir is still null, so they resolve to the 'results'
    # fallback unless the profile restates them. Without that, the reports
    # would scatter outside the demo's own directory.
    cd "${REPO_ROOT}" || return 1
    run nextflow config -flat -profile demo
    [ "${status}" -eq 0 ]
    for f in execution_report.html execution_timeline.html \
             execution_trace.txt pipeline_dag.html ; do
        [[ "${output}" == *"demo_results/pipeline_info/${f}"* ]] || {
            echo "report path not under demo_results: ${f}"; return 1
        }
    done
    # Nothing points at the bare 'results' fallback.
    [[ "${output}" != *"= 'results/pipeline_info"* ]]
}

@test "DEM-03b the reports are really written there" {
    need_tools
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" -profile demo \
        -work-dir "${BATS_TEST_TMPDIR}/work"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
    local -r info="${BATS_TEST_TMPDIR}/demo_results/pipeline_info"
    [ -s "${info}/execution_report.html" ]
    [ -s "${info}/execution_trace.txt" ]
    [ -s "${info}/software_versions.yml" ]
    [ -s "${info}/params.json" ]
    # And nowhere else.
    [ ! -d "${BATS_TEST_TMPDIR}/results" ]
}

# ------------------------------------------------------------------- DEM-04

@test "DEM-04 the demo needs only the core dependencies" {
    # krona is off, so a lab's first run cannot fail for want of KronaTools.
    # The stub run passes --krona true explicitly, so the branch is still
    # covered (STB-02).
    cd "${REPO_ROOT}" || return 1
    run nextflow config -flat -profile demo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"params.krona = false"* ]]
    # And basecalling is off, so no dorado and no GPU either.
    [[ "${output}" == *"params.skip_basecall = true"* ]]
}

@test "DEM-04b --krona on top of the demo still works" {
    # The documented way to see the charts.
    command -v ktImportText > /dev/null 2>&1 || skip "ktImportText not in PATH"
    need_tools
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" -profile demo --krona true \
        -work-dir "${BATS_TEST_TMPDIR}/work"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
    [ -s "${BATS_TEST_TMPDIR}/demo_results/krona.html" ]
    [ -s "${BATS_TEST_TMPDIR}/demo_results/krona_optimistic.html" ]
}
