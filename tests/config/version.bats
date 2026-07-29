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
