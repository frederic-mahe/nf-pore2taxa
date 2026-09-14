#!/usr/bin/env bats
#
# OUT-01..OUT-06: the consolidated output directory.
#
# Run with:
#   bats tests/config/outdir.bats
#
# Before v1.12.0 a run's outputs were spread across two trees: the tables
# went wherever `results_table` pointed, while each barcode's .sintax/.log
# were published back into `fastq_dir/fastq_pass/<barcode>/`. That meant the
# raw-data directory had to be writable, two projects sharing one fastq_dir
# overwrote each other's assignments, a flat layout acquired invented barcode
# subdirectories, and there was no single directory to archive as "the results
# of this run".
#
# `outdir` replaces it. `results_table` and `publish_beside_reads` are the
# deprecated ways to get the old behaviour, honoured with a warning and due
# for removal at v2.0.0 — the same treatment `sintax_silva` got.
#
# Needs cutadapt + vsearch: these assert where files land, so the runs have
# to complete.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../lib/guards.bash"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    require_tools nextflow cutadapt vsearch

    FIXTURES="${REPO_ROOT}/tests/fixtures"
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/fastq_dir/fastq_pass" "${DATA}/"
}

pipeline() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${DATA}" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        --max_cpus 2 \
        "$@"
}

# ------------------------------------------------------------------- OUT-01

@test "OUT-01 everything a run produces lands under outdir" {
    # The only case in this file that renders charts, so the only one
    # needing KronaTools.
    require_tools ktImportText

    pipeline --outdir "${BATS_TEST_TMPDIR}/out" --krona true
    [ "${status}" -eq 0 ]
    local -r out="${BATS_TEST_TMPDIR}/out"

    # tables, per-barcode results, charts and provenance, one tree.
    [ -s "${out}/sintax.tsv" ]
    [ -s "${out}/sintax_optimistic.tsv" ]
    [ -s "${out}/per_barcode/barcode01.sintax" ]
    [ -e "${out}/per_barcode/barcode01.log" ]
    [ -s "${out}/sintax.krona.html" ]
    [ -s "${out}/pipeline_info/software_versions.yml" ]
    [ -s "${out}/pipeline_info/execution_report.html" ]
}

@test "OUT-01b the raw-data tree is left untouched" {
    # It no longer has to be writable, and two projects can share one.
    pipeline --outdir "${BATS_TEST_TMPDIR}/out"
    [ "${status}" -eq 0 ]
    run find "${DATA}" -name '*.sintax' -o -name '*.log'
    [ -z "${output}" ] || { echo "results leaked into fastq_dir: ${output}"; return 1; }
}

# ------------------------------------------------------------------- OUT-02

@test "OUT-02 outdir defaults to results/ when nothing names it" {
    # Neither outdir nor the deprecated results_table: a bare invocation must
    # still be valid rather than an error about a path nobody set.
    cd "${REPO_ROOT}" || return 1
    run nextflow config -flat
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"results/pipeline_info/execution_report.html"* ]]
}

@test "OUT-02b table_name names the table inside outdir" {
    pipeline --outdir "${BATS_TEST_TMPDIR}/out" --table_name "profile.tsv"
    [ "${status}" -eq 0 ]
    [ -s "${BATS_TEST_TMPDIR}/out/profile.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/out/profile_optimistic.tsv" ]
}

@test "WF-13d table_name names the Krona charts too" {
    # The point of naming the charts after the table: two runs launched in
    # parallel produce charts that can be told apart, and stay apart when
    # they are gathered into one directory or a browser's download folder.
    # A fixed krona.html could not.
    require_tools ktImportText

    pipeline --outdir "${BATS_TEST_TMPDIR}/out" \
             --table_name "profile.tsv" --krona true
    [ "${status}" -eq 0 ]
    [ -s "${BATS_TEST_TMPDIR}/out/profile.krona.html" ]
    [ -s "${BATS_TEST_TMPDIR}/out/profile_optimistic.krona.html" ]
    [ ! -e "${BATS_TEST_TMPDIR}/out/krona.html" ]
}

# ------------------------------------------------------------------- OUT-03

@test "OUT-03 the deprecated results_table still produces exactly what it did" {
    # An existing project config must keep working: its parent becomes outdir
    # and its basename the table name, so the tables appear where they always
    # did — with a warning naming the replacement.
    pipeline --results_table "${BATS_TEST_TMPDIR}/legacy/mytable.tsv"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"'results_table' is deprecated"* ]]
    [[ "${output}" == *"outdir"* ]]
    [ -s "${BATS_TEST_TMPDIR}/legacy/mytable.tsv" ]
    [ -s "${BATS_TEST_TMPDIR}/legacy/mytable_optimistic.tsv" ]
    # ...and the consolidated extras arrive alongside, not in the data tree.
    [ -s "${BATS_TEST_TMPDIR}/legacy/per_barcode/barcode01.sintax" ]
    [ -s "${BATS_TEST_TMPDIR}/legacy/pipeline_info/software_versions.yml" ]
}

@test "OUT-03b the reports follow the deprecated parameter too" {
    # The report paths are config-level, resolved without main.nf's help, so
    # they need their own copy of the outdir fallback. This is where the two
    # would drift apart.
    pipeline --results_table "${BATS_TEST_TMPDIR}/legacy/mytable.tsv"
    [ "${status}" -eq 0 ]
    [ -s "${BATS_TEST_TMPDIR}/legacy/pipeline_info/execution_report.html" ]
    [ -s "${BATS_TEST_TMPDIR}/legacy/pipeline_info/execution_trace.txt" ]
}

# ------------------------------------------------------------------- OUT-04

@test "OUT-04 outdir wins when both are set, and the clash is reported" {
    pipeline --outdir "${BATS_TEST_TMPDIR}/chosen" \
             --results_table "${BATS_TEST_TMPDIR}/ignored/mytable.tsv"
    [ "${status}" -eq 0 ]
    # The table keeps the name from results_table, in the outdir directory.
    [ -s "${BATS_TEST_TMPDIR}/chosen/mytable.tsv" ]
    [ ! -e "${BATS_TEST_TMPDIR}/ignored/mytable.tsv" ]
    # Silently picking one of two conflicting instructions would be worse
    # than saying which won.
    [[ "${output}" == *"disagree about the directory"* ]]
}

# ------------------------------------------------------------------- OUT-05

@test "OUT-05 publish_beside_reads restores the old location, additively" {
    pipeline --outdir "${BATS_TEST_TMPDIR}/out" --publish_beside_reads true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"'publish_beside_reads' is deprecated"* ]]
    # The old location is populated again...
    [ -s "${DATA}/fastq_pass/barcode01/barcode01.sintax" ]
    # ...without giving up the consolidated one, so enabling it to keep an
    # existing habit does not cost the new layout.
    [ -s "${BATS_TEST_TMPDIR}/out/per_barcode/barcode01.sintax" ]
}

@test "OUT-05b it is off by default and warns only when on" {
    pipeline --outdir "${BATS_TEST_TMPDIR}/out"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"'publish_beside_reads' is deprecated"* ]]
    [ ! -e "${DATA}/fastq_pass/barcode01/barcode01.sintax" ]
}

@test "OUT-05c a non-boolean publish_beside_reads is rejected" {
    pipeline --outdir "${BATS_TEST_TMPDIR}/out" --publish_beside_reads yes
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'publish_beside_reads' must be true or false"* ]]
}

# ------------------------------------------------------------------- OUT-06

@test "OUT-06 table_name must be a filename, not a path" {
    # Otherwise it would silently escape outdir, which is the one thing the
    # consolidation is for.
    pipeline --outdir "${BATS_TEST_TMPDIR}/out" --table_name "sub/dir/t.tsv"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'table_name' must be a filename, not a path"* ]]
    [[ "${output}" == *"outdir"* ]]
}
