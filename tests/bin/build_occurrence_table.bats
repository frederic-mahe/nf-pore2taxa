#!/usr/bin/env bats
#
# Integration tests for bin/build_occurrence_table.R.
#
# Runs the R script against the committed sintax_dir fixture (4
# barcodes: 2 with assignments, 2 empty) and asserts structural
# properties of the resulting TSV files.
#
# Requires Rscript + tidyverse + optparse. If those are missing the
# whole file is skipped.
#
# Run with:
#   bats tests/bin/build_occurrence_table.bats

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/build_occurrence_table.R"
    export FIXTURE="${REPO_ROOT}/tests/fixtures/sintax_dir/fastq_pass"

    if ! command -v Rscript > /dev/null 2>&1 ; then
        skip "Rscript not found in PATH"
    fi
    if ! Rscript -e 'suppressWarnings(suppressMessages(library(tidyverse))); library(optparse)' \
            > /dev/null 2>&1 ; then
        skip "R packages tidyverse + optparse are required"
    fi
}

setup() {
    # Per-test scratch directory. Bats already provides BATS_TEST_TMPDIR.
    OUT="${BATS_TEST_TMPDIR}/sintax.tsv"
    OPT="${BATS_TEST_TMPDIR}/sintax_optimistic.tsv"
}

run_build() {
    Rscript --no-save --no-restore "${SCRIPT}" "$@"
}

# ---------------------------------------------------------- BT-01..BT-07 (CLI)

@test "BT-01 missing --input-dir aborts with a clear error" {
    run run_build --output "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" =~ (inputdir|--input-dir)" is required" ]]
}

@test "BT-02 missing --output aborts with a clear error" {
    run run_build --input-dir "${FIXTURE}"
    [ "${status}" -ne 0 ]
    [[ "${output}" =~ output" is required" ]]
}

@test "BT-03 non-existent --input-dir aborts with 'Path does not exist'" {
    run run_build --input-dir "${BATS_TEST_TMPDIR}/__no_such_dir__" --output "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Path does not exist"* ]]
}

@test "BT-04 file as --input-dir aborts with 'not a directory'" {
    touch "${BATS_TEST_TMPDIR}/not_a_dir"
    run run_build --input-dir "${BATS_TEST_TMPDIR}/not_a_dir" --output "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not a directory"* ]]
}

@test "BT-06 input-dir with no .sintax files aborts with 'No sintax files found'" {
    mkdir -p "${BATS_TEST_TMPDIR}/empty_dir"
    run run_build --input-dir "${BATS_TEST_TMPDIR}/empty_dir" --output "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"No sintax files found"* ]]
}

@test "BT-07 optimistic sibling TSV is produced alongside the filtered one" {
    run run_build --input-dir "${FIXTURE}" --output "${OUT}"
    [ "${status}" -eq 0 ]
    [ -s "${OUT}" ]
    [ -s "${OPT}" ]
}

# --- Happy-path file shared across BT-10..BT-23 tests ------------------------

happy_path_setup() {
    # Build once, cache in BATS_FILE_TMPDIR. Skip if already built.
    HAPPY_OUT="${BATS_FILE_TMPDIR}/sintax.tsv"
    HAPPY_OPT="${BATS_FILE_TMPDIR}/sintax_optimistic.tsv"
    [ -s "${HAPPY_OUT}" ] && return 0
    Rscript --no-save --no-restore "${SCRIPT}" \
        --input-dir "${FIXTURE}" \
        --output    "${HAPPY_OUT}" \
        > /dev/null
}

# ---------------------------------------------------------- BT-10..BT-23

@test "BT-10a filtered header has 6 columns (taxonomy, total, 4 barcodes)" {
    happy_path_setup
    local ncol
    ncol=$(awk -F'\t' 'NR==1{print NF; exit}' "${HAPPY_OUT}")
    [ "${ncol}" -eq 6 ]
}

@test "BT-10b filtered header starts with 'taxonomy\\ttotal'" {
    happy_path_setup
    local header
    header="$(head -n 1 "${HAPPY_OUT}")"
    [[ "${header}" == taxonomy$'\t'total$'\t'* ]]
}

@test "BT-11 filtered: total column equals row-wise sum of barcode columns" {
    happy_path_setup
    local mismatches
    mismatches=$(awk -F'\t' 'NR>1{s=0; for(i=3;i<=NF;i++) s+=$i; if($2!=s) print}' "${HAPPY_OUT}" | wc -l)
    [ "${mismatches}" -eq 0 ]
}

@test "BT-11-opt optimistic: total column equals row-wise sum of barcode columns" {
    happy_path_setup
    local mismatches
    mismatches=$(awk -F'\t' 'NR>1{s=0; for(i=3;i<=NF;i++) s+=$i; if($2!=s) print}' "${HAPPY_OPT}" | wc -l)
    [ "${mismatches}" -eq 0 ]
}

@test "BT-12 rows sorted by total DESC, then taxonomy ASC" {
    happy_path_setup
    local expected actual
    expected=$(tail -n +2 "${HAPPY_OUT}" | awk -F'\t' '{print -$2 "\t" $1}' | sort -k1,1n -k2,2 | awk -F'\t' '{print $2}')
    actual=$(tail -n +2 "${HAPPY_OUT}" | awk -F'\t' '{print $1}')
    [ "${expected}" = "${actual}" ]
}

@test "BT-13 empty barcodes are right-most columns" {
    happy_path_setup
    local last second_last
    last=$(awk -F'\t' 'NR==1{print $NF}' "${HAPPY_OUT}")
    second_last=$(awk -F'\t' 'NR==1{print $(NF-1)}' "${HAPPY_OUT}")
    [[ "${last}"        =~ ^(barcode03|barcode99)$ ]]
    [[ "${second_last}" =~ ^(barcode03|barcode99)$ ]]
}

@test "BT-21 optimistic max(len(taxonomy)) >= filtered max(len(taxonomy))" {
    happy_path_setup
    local maxlen_filt maxlen_opt
    maxlen_filt=$(tail -n +2 "${HAPPY_OUT}" | awk -F'\t' '{print length($1)}' | sort -n | tail -1)
    maxlen_opt=$( tail -n +2 "${HAPPY_OPT}" | awk -F'\t' '{print length($1)}' | sort -n | tail -1)
    [ "${maxlen_opt}" -ge "${maxlen_filt}" ]
}

@test "BT-22 optimistic grand total >= filtered grand total" {
    happy_path_setup
    local tot_filt tot_opt
    tot_filt=$(awk -F'\t' 'NR>1{s+=$2}END{print s+0}' "${HAPPY_OUT}")
    tot_opt=$( awk -F'\t' 'NR>1{s+=$2}END{print s+0}' "${HAPPY_OPT}")
    [ "${tot_opt}" -ge "${tot_filt}" ]
}

@test "BT-23 no probability annotations leak into either taxonomy column" {
    happy_path_setup
    local leaks
    leaks=$( { tail -n +2 "${HAPPY_OUT}" ; tail -n +2 "${HAPPY_OPT}" ; } \
        | awk -F'\t' '{print $1}' \
        | grep -cE '\([0-9]+\.[0-9]+\)' || true)
    [ "${leaks}" -eq 0 ]
}

# Regression: a non-empty .sintax whose filtered (4th) column is blank on
# every row used to make read_tsv guess the column type as logical, so the
# downstream replace_na(taxonomy, "unknown") aborted with:
#   Can't convert `replace` <character> to match type of `data` <logical>.
# Forcing col_types = cols(.default = "c") keeps the column character.
@test "BT-24 all-blank filtered column does not abort and maps to 'unknown'" {
    local dir="${BATS_TEST_TMPDIR}/blank_filtered/fastq_pass/barcode01"
    mkdir -p "${dir}"
    # full_taxonomy present, strand present, filtered taxonomy (4th col) empty
    printf 'read1_b01;length=160\td:Synthetica(0.30),p:Foo(0.20)\t+\t\n' \
        > "${dir}/reads.sintax"
    printf 'read2_b01;length=160\td:Synthetica(0.40),p:Bar(0.10)\t+\t\n' \
        >> "${dir}/reads.sintax"

    run run_build --input-dir "${BATS_TEST_TMPDIR}/blank_filtered/fastq_pass" \
                  --output "${OUT}"
    [ "${status}" -eq 0 ]
    [ -s "${OUT}" ]
    # both reads collapse into a single 'unknown' taxon for barcode01
    local row
    row="$(awk -F'\t' '$1=="unknown"' "${OUT}")"
    [[ "${row}" == unknown$'\t'2$'\t'2 ]]
}
