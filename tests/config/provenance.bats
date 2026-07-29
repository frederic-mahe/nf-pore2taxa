#!/usr/bin/env bats
#
# PRV-05..PRV-08: the provenance artefacts, end to end.
#
# Run with:
#   bats tests/config/provenance.bats
#
# Every run must be able to explain itself. One directory beside the
# occurrence tables holds what software ran (software_versions.yml), with
# what settings (params.json), and what the execution actually cost
# (Nextflow's report / timeline / trace / DAG). Two labs comparing tables
# can then diff those files instead of guessing.
#
# The reports are config-level (report/timeline/trace/dag scopes) and the
# two YAML/JSON files are processes, so this needs a real run: cutadapt
# and vsearch, and it skips without them.
#
# pipeline_info/ is deliberately the same layout `--outdir` will adopt, so
# that release re-roots the directory rather than relocating files.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    for tool in nextflow cutadapt vsearch ; do
        command -v "${tool}" > /dev/null 2>&1 || skip "${tool} not in PATH"
    done

    FIXTURES="${REPO_ROOT}/tests/fixtures"
    DATA="${BATS_TEST_TMPDIR}/data"
    mkdir -p "${DATA}"
    cp -r "${FIXTURES}/fastq_pass" "${DATA}/" 2> /dev/null \
        || cp -r "${FIXTURES}/fastq_dir/fastq_pass" "${DATA}/"

    RESULTS="${BATS_TEST_TMPDIR}/results"
    INFO="${RESULTS}/pipeline_info"
}

pipeline() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${DATA}" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${RESULTS}/sintax.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        --max_cpus 2 \
        "$@"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
}

# As above but WITHOUT --sintax_references, so the deprecated alias is the
# only reference supplied. Note it must be omitted, not emptied: Nextflow
# parses `--sintax_references ''` as a *flag*, discarding the empty value
# and setting the param to the string 'true' — which then fails as a
# missing file path.
pipeline_via_alias() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    run nextflow run "${REPO_ROOT}/main.nf" \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${DATA}" \
        --sintax_silva "${FIXTURES}/references.fasta" \
        --results_table "${RESULTS}/sintax.tsv" \
        --primer_f "GTACACACCGCCCGTCG" \
        --primer_r "CGCCTSCSCTTANTDATATGC" \
        --max_cpus 2
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
}

# ------------------------------------------------------------------- PRV-05

@test "PRV-05 all four execution reports are written without being asked for" {
    # On by default: provenance you have to remember to enable is
    # provenance you will not have.
    pipeline
    for artefact in execution_report.html execution_timeline.html \
                    execution_trace.txt pipeline_dag.html ; do
        [ -s "${INFO}/${artefact}" ] || {
            echo "missing or empty: pipeline_info/${artefact}"; return 1
        }
    done
}

@test "PRV-05b the trace carries requested vs observed resources" {
    # The v1.8.0 ceiling clamps requests silently, so this is how a lab
    # sees whether a step was given too little (or far too much).
    pipeline
    run head -1 "${INFO}/execution_trace.txt"
    for column in cpus memory realtime peak_rss ; do
        [[ "${output}" == *"${column}"* ]] || {
            echo "trace has no '${column}' column: ${output}"; return 1
        }
    done
}

@test "PRV-05c a re-run refreshes the reports in place, not errors" {
    # overwrite = true. Without it Nextflow aborts at the END of the second
    # run because the report file already exists — after all the work.
    pipeline
    pipeline
    [ -s "${INFO}/execution_report.html" ]
}

# ------------------------------------------------------------------- PRV-06

@test "PRV-06 software_versions.yml records the tools that ran" {
    pipeline
    [ -s "${INFO}/software_versions.yml" ]
    run cat "${INFO}/software_versions.yml"
    for key in vsearch cutadapt python nf-pore2taxa nextflow ; do
        [[ "${output}" == *"${key}:"* ]] || {
            echo "no '${key}' in software_versions.yml: ${output}"; return 1
        }
    done
    # A real version for the tool whose output shapes the tables.
    [[ "${output}" =~ vsearch:\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "PRV-06b no dorado line when basecalling did not run" {
    # Recording a version for a tool that never executed would be a false
    # claim about how the data was produced.
    pipeline
    run cat "${INFO}/software_versions.yml"
    [[ "${output}" != *"dorado"* ]]
}

# ------------------------------------------------------------------- PRV-07

@test "PRV-07 params.json records the effective configuration" {
    pipeline --subsample 3 --randseed 7
    [ -s "${INFO}/params.json" ]

    # Valid JSON, and the values are the ones that were in force.
    run python3 -c "
import json, sys
d = json.load(open('${INFO}/params.json'))
p = d['params']
assert p['subsample'] in (3, '3'), p['subsample']
assert p['randseed'] in (7, '7'), p['randseed']
assert p['skip_basecall'] is True, p['skip_basecall']
assert p['primer_f'] == 'GTACACACCGCCCGTCG', p['primer_f']
assert p['max_cpus'] in (2, '2'), p['max_cpus']
assert d['pipeline'].startswith('nf-pore2taxa '), d['pipeline']
assert d['nextflow'], d['nextflow']
print('ok')
"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
}

@test "PRV-07b booleans are recorded as booleans, not as CLI strings" {
    # A CLI --krona false arrives as the *string* 'false', which is truthy
    # in Groovy. params.json must record the effective value, or it would
    # document the opposite of what the run did.
    pipeline --krona false --discard_untrimmed false
    run python3 -c "
import json
p = json.load(open('${INFO}/params.json'))['params']
assert p['krona'] is False, repr(p['krona'])
assert p['discard_untrimmed'] is False, repr(p['discard_untrimmed'])
print('ok')
"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
}

@test "PRV-07c the deprecated alias is recorded as the path actually used" {
    # sintax_silva is honoured but deprecated; the record must show the
    # reference that was really read, not an empty canonical param.
    pipeline_via_alias
    run python3 -c "
import json
p = json.load(open('${INFO}/params.json'))['params']
assert p['sintax_references'].endswith('references.fasta'), p['sintax_references']
print('ok')
"
    [ "${status}" -eq 0 ] || { echo "${output}" ; return 1 ; }
}

# ------------------------------------------------------------------- PRV-08

@test "PRV-08 provenance sits beside the tables, not among them" {
    # The layout --outdir will adopt in v1.11.0.
    pipeline
    [ -s "${RESULTS}/sintax.tsv" ]
    [ -d "${INFO}" ]
    # The results directory itself holds only analysis outputs; no
    # metadata is interleaved with them.
    [ -s "${RESULTS}/sintax_optimistic.tsv" ]
    for metadata in software_versions.yml params.json \
                    execution_report.html execution_trace.txt ; do
        [ ! -e "${RESULTS}/${metadata}" ] || {
            echo "metadata leaked into the results dir: ${metadata}"; return 1
        }
    done
}

@test "PRV-08b the provenance files do not defeat -resume" {
    # params.json omits the session id and command line precisely so this
    # holds: an unchanged re-run must re-execute nothing.
    pipeline
    pipeline -resume
    [[ "${output}" == *"completed=0"* ]]
}
