#!/usr/bin/env bats
#
# CFG-06: the startup run summary, and the randseed reproducibility
# warning it carries.
#
# Run with:
#   bats tests/config/summary.bats
#
# Nextflow's own header reports the pipeline version, profile and work
# directory; what it never reports is the effective *parameters*. Until
# versions.yml lands, this block is the pipeline's only provenance record —
# the thing a lab reads six months later to answer "what did this table
# come from?". So its content is worth pinning.
#
# The randseed warning exists because vsearch sintax is order-dependent
# across threads: a fixed seed does NOT make a multithreaded run
# replayable. Warning only in the README would leave a user believing they
# had reproducibility they do not have. It must fire on the EFFECTIVE
# thread count, so `--max_cpus 1` — which genuinely does make a seeded run
# replayable — must NOT warn.
#
# Every case here aborts on a deliberately missing reference, which happens
# after the summary is printed, so none of them need cutadapt/vsearch.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"
}

# Valid parameters except the reference, which is missing so the run stops
# just after the summary. Extra flags are appended.
run_summary() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${FIXTURES}/fastq_dir" \
        --sintax_references "${FIXTURES}/__does_not_exist__.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        "$@"
}

# ------------------------------------------------------------------- CFG-06

@test "CFG-06a the summary names the pipeline and its version" {
    run_summary
    [[ "${output}" == *"nf-pore2taxa"* ]]
    # The manifest version, whatever it currently is (CFG-01 pins that it
    # agrees with CITATION.cff).
    local version
    version="$(cd "${REPO_ROOT}" && nextflow config -properties 2>/dev/null \
               | sed -nE 's/^manifest\.version=(.*)$/\1/p')"
    [ -n "${version}" ]
    [[ "${output}" == *"nf-pore2taxa ${version}"* ]]
}

@test "CFG-06b the summary reports every result-affecting parameter" {
    run_summary
    local key
    for key in mode fastq_dir sintax_references results_table primer_f \
               primer_r discard_untrimmed subsample randseed krona \
               publish_mode cleanup ; do
        [[ "${output}" == *"${key}"* ]] || {
            echo "missing '${key}' from the run summary"; return 1
        }
    done
    # And the resolved ceiling, with the thread count actually in force.
    [[ "${output}" == *"resource ceiling"* ]]
    [[ "${output}" == *"thread(s)"* ]]
}

@test "CFG-06c the summary distinguishes the two input modes" {
    run_summary
    [[ "${output}" == *"reuse existing fastq"* ]]
    # pod5_dir is irrelevant when skipping, so it is not listed.
    [[ "${output}" != *"pod5_dir"* ]]
}

@test "CFG-06d the summary spells out what discard_untrimmed does" {
    # 'true' alone does not say which way the filter points.
    run_summary
    [[ "${output}" == *"strict amplicon filtering"* ]]

    run_summary --discard_untrimmed false
    [[ "${output}" == *"keep every read"* ]]
}

@test "CFG-06e randseed = 0 is labelled as pseudo-random, and does not warn" {
    run_summary
    [[ "${output}" == *"pseudo-random each run"* ]]
    [[ "${output}" != *"not exactly reproducible"* ]]
}

@test "CFG-06f a fixed randseed on multiple threads warns" {
    run_summary --randseed 42
    [[ "${output}" == *"randseed = 42 is set"* ]]
    [[ "${output}" == *"not exactly reproducible above one thread"* ]]
    # The warning must be actionable, not just discouraging.
    [[ "${output}" == *"--max_cpus 1"* ]]
}

@test "CFG-06g a fixed randseed with a single thread does NOT warn" {
    # --max_cpus 1 clamps SINTAX to one thread, which genuinely makes a
    # seeded run replayable. Warning here would train users to ignore it.
    run_summary --randseed 42 --max_cpus 1
    [[ "${output}" == *"randseed"* ]]
    [[ "${output}" != *"not exactly reproducible"* ]]
    [[ "${output}" == *"SINTAX gets 1 thread(s)"* ]]
}

@test "CFG-06h the summary reflects an overridden ceiling" {
    run_summary --max_cpus 3
    [[ "${output}" == *"3 cpus"* ]]
    # SINTAX asks for 20, so the clamp is visible in the thread count.
    [[ "${output}" == *"SINTAX gets 3 thread(s)"* ]]
}
