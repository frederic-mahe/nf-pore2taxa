#!/usr/bin/env bash
#
# coverage-gate.sh
#
# Audits the SPECIFICATIONS.md <-> COVERAGE.md <-> tests/ triangle:
#
#   1. every ID declared in tests/SPECIFICATIONS.md has a row in
#      tests/COVERAGE.md
#   2. every ID cited from a test file is declared in SPECIFICATIONS.md
#   3. every ID in COVERAGE.md is declared in SPECIFICATIONS.md
#   4. every COVERAGE.md row marked `done` is really cited by a test
#
# Why bother: the spec/coverage mapping is maintained by hand, and it had
# already drifted before this gate existed — BT-24 was asserted by two test
# files without being declared at all, and OBS-02 still described a helper
# removed in v1.4.0. Check (4) is the one that keeps `done` honest, since a
# status column nobody verifies decays into decoration.
#
# Run from anywhere in the repository:
#   bash tests/coverage-gate.sh
#
# Needs nothing but grep/sed/sort — no Nextflow, no tools, so it is the
# cheapest job in CI.
#
# Exit status: 0 when the triangle closes, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SPEC_FILE="${REPO_ROOT}/tests/SPECIFICATIONS.md"
readonly COVERAGE_FILE="${REPO_ROOT}/tests/COVERAGE.md"
readonly TESTS_DIR="${REPO_ROOT}/tests"

# An ID is FAM-NN, where FAM is 2-3 upper-case letters. Tests cite variants
# with a lower-case suffix (WF-12a, CFG-06h); those roll up to the base ID,
# which is what SPECIFICATIONS.md declares.
readonly ID_RE='[A-Z]{2,3}-[0-9]{2}'

for f in "${SPEC_FILE}" "${COVERAGE_FILE}" ; do
    if [[ ! -r "${f}" ]] ; then
        echo "coverage-gate: cannot read ${f}" 1>&2
        exit 1
    fi
done

# IDs declared in SPECIFICATIONS.md: the first cell of a table row. A struck
# ID (~~SX-20~~) is a retired behaviour and needs no coverage.
declared_ids() {
    grep --only-matching --extended-regexp "^\| *${ID_RE}" "${SPEC_FILE}" \
        | grep --only-matching --extended-regexp "${ID_RE}" \
        | sort --unique
}

retired_ids() {
    grep --only-matching --extended-regexp "^\| *~~${ID_RE}~~" "${SPEC_FILE}" \
        | grep --only-matching --extended-regexp "${ID_RE}" \
        | sort --unique
}

# IDs with a row in COVERAGE.md (first cell, backticked), excluding the
# "Removed" section's retired ones.
covered_ids() {
    sed -n '/^## Removed/q;p' "${COVERAGE_FILE}" \
        | grep --only-matching --extended-regexp "^\| \`${ID_RE}\`" \
        | grep --only-matching --extended-regexp "${ID_RE}" \
        | sort --unique
}

# IDs cited anywhere in a test file, rolled up to the base ID.
cited_ids() {
    grep --recursive --no-filename --only-matching --extended-regexp \
        --include='*.bats' --include='*.nf.test' --include='test_*.py' \
        "${ID_RE}" "${TESTS_DIR}" 2> /dev/null \
        | sort --unique
}

# IDs whose COVERAGE.md row says `done`.
claimed_done_ids() {
    grep --extended-regexp "^\| \`${ID_RE}\`.*\| done \|" "${COVERAGE_FILE}" \
        | grep --only-matching --extended-regexp "${ID_RE}" \
        | sort --unique
}

report() {
    # $1 = message, remaining stdin = offending IDs
    local -r message="${1}"
    echo "coverage-gate: ${message}"
    sed 's/^/  /'
}

status=0

declared="$(declared_ids)"
retired="$(retired_ids)"
covered="$(covered_ids)"
cited="$(cited_ids)"
claimed="$(claimed_done_ids)"

# Declared IDs exclude the retired ones.
live_declared="$(comm -23 <(printf '%s\n' "${declared}") <(printf '%s\n' "${retired}"))"

# (1) declared but not in COVERAGE.md
missing="$(comm -23 <(printf '%s\n' "${live_declared}") <(printf '%s\n' "${covered}"))"
if [[ -n "${missing}" ]] ; then
    report "declared in SPECIFICATIONS.md but missing from COVERAGE.md:" \
        <<< "${missing}"
    status=1
fi

# (2) cited by a test but not declared
undeclared="$(comm -23 <(printf '%s\n' "${cited}") <(printf '%s\n' "${declared}"))"
if [[ -n "${undeclared}" ]] ; then
    report "cited from tests/ but not declared in SPECIFICATIONS.md:" \
        <<< "${undeclared}"
    status=1
fi

# (3) in COVERAGE.md but not declared
stale="$(comm -23 <(printf '%s\n' "${covered}") <(printf '%s\n' "${declared}"))"
if [[ -n "${stale}" ]] ; then
    report "listed in COVERAGE.md but not declared in SPECIFICATIONS.md:" \
        <<< "${stale}"
    status=1
fi

# (4) claimed done but no test cites it
unbacked="$(comm -23 <(printf '%s\n' "${claimed}") <(printf '%s\n' "${cited}"))"
if [[ -n "${unbacked}" ]] ; then
    report "marked 'done' in COVERAGE.md but no test cites them:" \
        <<< "${unbacked}"
    status=1
fi

if (( status == 0 )) ; then
    printf 'coverage-gate: OK (%s specs; %s done, %s TODO, %s n/a, %s retired)\n' \
        "$(printf '%s\n' "${live_declared}" | grep -c .)" \
        "$(printf '%s\n' "${claimed}" | grep -c .)" \
        "$(grep -cE "^\| \`${ID_RE}\`.*\| TODO \|" "${COVERAGE_FILE}" || true)" \
        "$(grep -cE "^\| \`${ID_RE}\`.*\| n/a \|" "${COVERAGE_FILE}" || true)" \
        "$(printf '%s\n' "${retired}" | grep -c .)"
fi

exit "${status}"
