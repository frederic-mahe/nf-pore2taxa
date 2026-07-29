#!/usr/bin/env bats
#
# Config-level invariants on nextflow.config.
#
# Run with:
#   bats tests/config/version.bats
#
# Requires `nextflow` on PATH; resolves the config exactly as the
# pipeline would, rather than grepping the file, so the assertions hold
# regardless of formatting.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
}

# ------------------------------------------------------------------- CFG-01
#
# Until v1.7.1 this compared manifest.version with params.version — but
# nothing in any .nf or .config ever read params.version, so it pinned a
# dead value while the live duplicate (CITATION.cff) went unchecked. The
# param is gone; the citation metadata is what must not drift, because a
# release that bumps one and not the other ships a citation disagreeing
# with the workflow manifest.

@test "CFG-01 manifest.version and CITATION.cff version are in sync" {
    cd "${REPO_ROOT}"
    local properties manifest_version citation_version
    properties="$(nextflow config -properties 2>/dev/null)"

    manifest_version="$(grep -E '^manifest\.version=' <<< "${properties}" | cut -d= -f2-)"
    citation_version="$(sed -nE 's/^version:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' CITATION.cff)"

    # Both must actually be defined.
    [ -n "${manifest_version}" ]
    [ -n "${citation_version}" ]

    # And they must agree.
    [ "${manifest_version}" = "${citation_version}" ]
}

@test "CFG-01b the dead params.version is gone" {
    cd "${REPO_ROOT}"
    local properties
    properties="$(nextflow config -properties 2>/dev/null)"
    # Nothing reads it; re-adding it would resurrect an invariant that
    # tests itself rather than anything the pipeline uses.
    run ! grep -qE '^params\.version=' <<< "${properties}"
}

# ------------------------------------------------------------------- CFG-05

@test "CFG-05a manifest declares a minimum Nextflow version" {
    cd "${REPO_ROOT}"
    run nextflow config -properties
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"manifest.nextflowVersion="* ]]
}

@test "CFG-05b the declared floor is high enough for process.resourceLimits" {
    # The resource ceiling (CFG-04) is built on process.resourceLimits,
    # added in Nextflow 24.04. On an older Nextflow the directive is
    # ignored *silently* — an unknown directive is not an error — so every
    # request would go through unclamped and the "requirement exceeds
    # available" failure would come back with no diagnostic. Lowering this
    # floor therefore breaks CFG-04 invisibly; this test is the guard.
    # -flat, not -properties: the latter is Java-properties format, which
    # escapes '=' in a value ('>\=24.04.0') and would defeat the match.
    cd "${REPO_ROOT}"
    local declared major minor
    declared="$(nextflow config -flat 2>/dev/null \
                | sed -nE "s/^manifest\.nextflowVersion = '>=([0-9]+)\.([0-9]+).*/\1 \2/p")"
    [ -n "${declared}" ]  # must be a '>=X.Y' form for this check to mean anything
    major="${declared% *}"
    minor="${declared#* }"
    # >= 24.04
    [ "${major}" -gt 24 ] || { [ "${major}" -eq 24 ] && [ "${minor#0}" -ge 4 ]; }
}

@test "CFG-05c manifest declares the default branch" {
    # So `nextflow run frederic-mahe/nf-pore2taxa` resolves the intended
    # branch rather than guessing.
    cd "${REPO_ROOT}"
    run nextflow config -properties
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"manifest.defaultBranch=main"* ]]
}
