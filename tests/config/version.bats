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

@test "CFG-01 manifest.version and params.version are in sync" {
    cd "${REPO_ROOT}"
    local properties manifest_version params_version
    properties="$(nextflow config -properties 2>/dev/null)"

    manifest_version="$(grep -E '^manifest\.version=' <<< "${properties}" | cut -d= -f2-)"
    params_version="$(grep -E '^params\.version=' <<< "${properties}" | cut -d= -f2-)"

    # Both must actually be defined.
    [ -n "${manifest_version}" ]
    [ -n "${params_version}" ]

    # And they must agree.
    [ "${manifest_version}" = "${params_version}" ]
}
