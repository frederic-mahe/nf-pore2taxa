#!/usr/bin/env bash
#
# STB-01..STB-04: the whole pipeline runs under `nextflow -stub-run` with NO
# bioinformatics tool installed.
#
# Two layers:
#   1. static  — every tool-invoking process declares a `stub:`
#   2. dynamic — `-profile demo -stub-run` with cutadapt, vsearch,
#                ktImportText and dorado all shadowed by stubs that exit 1,
#                so a process that fell through to its real script dies
#
# Why this earns its place: it validates the channel topology — discovery,
# the per-barcode fan-out, the gather into BUILD_TABLE, the optional KRONA
# branch, the provenance tasks — in seconds, with no tools, no GPU and no
# data. That makes it the fastest possible "is my install sane?" check for a
# new lab, and the fastest signal in CI that a wiring change broke the graph.
#
# python3 is deliberately left intact: DISCOVER_BARCODES, BUILD_TABLE and
# DUMP_PARAMS are stdlib-only and are EXEMPT from the stub requirement (see
# STUB_EXEMPT below). Letting them run for real is what makes this more than
# a graph traversal — discovery really walks the demo tree and really drives
# the fan-out, and the table builder really counts what the SINTAX stubs
# emitted.
#
# Run from anywhere in the repository:
#   bash tests/check-stub-run.sh
#
# Needs Nextflow and python3, nothing else.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}"

# Processes that legitimately have no `stub:`.
#
# All three are pure standard-library Python with no external tool, and all
# three are more useful running for real: DISCOVER_BARCODES bootstraps the
# per-barcode channel from the filesystem (stub it and the fan-out has width
# zero, so the topology is not tested at all), BUILD_TABLE is the code most
# worth exercising, and DUMP_PARAMS is a quoted heredoc.
readonly -a STUB_EXEMPT=(
    DISCOVER_BARCODES
    BUILD_TABLE
    DUMP_PARAMS
)

# Tools that must not be reachable during the dynamic layer.
readonly -a SHADOWED=(cutadapt vsearch ktImportText dorado)

fail=0

is_exempt() {
    local -r name="${1}"
    local e
    for e in "${STUB_EXEMPT[@]}" ; do
        [[ "${e}" == "${name}" ]] && return 0
    done
    return 1
}

# ---- layer 1: every tool-invoking process declares a stub ------------------

# STB-01
echo "===== layer 1: stub: declarations ====="

while IFS= read -r module ; do
    # A module file may hold more than one process (modules/provenance.nf,
    # modules/basecall.nf), so check each declaration and the block that
    # follows it rather than the file as a whole.
    while IFS= read -r name ; do
        [[ -z "${name}" ]] && continue
        if is_exempt "${name}" ; then
            printf '  exempt  %-18s (%s)\n' "${name}" "${module#"${REPO_ROOT}"/}"
            continue
        fi
        # The process's own body: from its `process NAME {` line to the next
        # one, or end of file.
        if awk -v want="${name}" '
                $1 == "process" && $2 == want { inproc = 1 ; next }
                inproc && $1 == "process"     { exit }
                inproc                        { print }
            ' "${module}" | grep -qE '^[[:space:]]*stub:' ; then
            printf '  OK      %-18s declares stub:\n' "${name}"
        else
            printf '  FAIL    %-18s (%s) declares no stub:\n' \
                "${name}" "${module#"${REPO_ROOT}"/}"
            fail=1
        fi
    done < <(sed -nE 's/^process[[:space:]]+([A-Za-z0-9_]+).*/\1/p' "${module}")
done < <(grep -rl '^process ' "${REPO_ROOT}/modules" --include='*.nf' | sort)

echo

# ---- layer 2: a tool-free -stub-run of the demo topology -------------------

# STB-02
echo "===== layer 2: -profile demo -stub-run, no tools installed ====="

sandbox="$(mktemp -d)"
readonly sandbox
trap 'rm -rf "${sandbox}"' EXIT

# Shadow every external tool with a stub that fails loudly: if a real script
# runs, it calls one of these and the task dies. A stub that merely exited 0
# would let a fallthrough pass silently, which is the whole thing this guards.
for tool in "${SHADOWED[@]}" ; do
    printf '#!/bin/sh\necho "FAIL: the real %s was invoked under -stub-run" >&2\nexit 1\n' \
        "${tool}" > "${sandbox}/${tool}"
    chmod +x "${sandbox}/${tool}"
done

log="${sandbox}/stub-run.log"

# --krona true so the optional KRONA branch is part of the graph under test;
# the demo profile leaves it off so a real demo run needs only the pipeline's
# core dependencies.
if PATH="${sandbox}:${PATH}" nextflow run main.nf \
        -profile demo -stub-run \
        --outdir "${sandbox}/demo_results" \
        --krona true \
        -work-dir "${sandbox}/work" > "${log}" 2>&1 ; then
    echo "  OK      the pipeline completed with no tool installed"
else
    echo "  FAIL    -profile demo -stub-run did not complete"
    grep -iE 'FAIL: the real|ERROR|Caused by|terminated' "${log}" \
        | head -n 8 | sed 's/^/          /'
    fail=1
fi

# STB-03: no real tool may have been reached, even if the run succeeded.
if grep -q 'FAIL: the real' "${log}" 2>/dev/null ; then
    echo "  FAIL    a process fell through to a real tool:"
    grep -o 'FAIL: the real [a-zA-Z]*' "${log}" | sort -u | sed 's/^/          /'
    fail=1
else
    echo "  OK      no process reached a real tool"
fi

# STB-04: the placeholder artefacts must really be published. A run that
# completes without producing its declared outputs would be a graph that
# executes and delivers nothing.
for artefact in \
        sintax.tsv \
        sintax_optimistic.tsv \
        krona.html \
        per_barcode/barcode01.sintax \
        pipeline_info/software_versions.yml \
        pipeline_info/params.json ; do
    if [[ -e "${sandbox}/demo_results/${artefact}" ]] ; then
        echo "  OK      published ${artefact}"
    else
        echo "  FAIL    not published: ${artefact}"
        fail=1
    fi
done

# BUILD_TABLE ran for real over the SINTAX stubs' output, so the table is a
# real table rather than a touched file — the point of exempting it.
table="${sandbox}/demo_results/sintax.tsv"
if [[ -s "${table}" ]] && head -n 1 "${table}" | grep -q $'^taxonomy\ttotal' ; then
    echo "  OK      the table has a real header (BUILD_TABLE ran for real)"
else
    echo "  FAIL    the table is empty or malformed:"
    head -n 2 "${table}" 2>/dev/null | sed 's/^/          /'
    fail=1
fi

echo
if (( fail != 0 )) ; then
    echo "stub-run: FAILED"
    exit 1
fi
echo "stub-run: OK"
