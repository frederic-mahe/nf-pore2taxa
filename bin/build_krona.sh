#!/bin/bash
#
# Build interactive Krona HTML charts from occurrence tables.
#
# For each occurrence TSV given, this produces one HTML holding a per-sample
# dataset (one dataset per non-empty barcode column): build_krona.py converts
# the table to ktImportText text files, then ktImportText assembles the HTML.
# The taxonomy hierarchy comes straight from the table's `taxonomy` column.

set -euo pipefail

## ----------------------------------------------------------- global variables

# Locate build_krona.py next to this script (works both when Nextflow stages
# bin/ into the task dir and when invoked directly from the repo).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_DIR

# Assign then declare separately (see assign_with_sintax.sh): `|| true`
# keeps an absent tool from tripping `set -e`, leaving the friendly
# diagnostic to check_commands.
KTIMPORTTEXT="$(which ktImportText || true)"
declare -r KTIMPORTTEXT


## ------------------------------------------------------------------ functions

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] TSV [TSV ...]

Build an interactive Krona HTML from one or more occurrence tables (as
written by build_occurrence_table.py). Each table yields one HTML with a
per-sample dataset (one dataset per non-empty barcode column).

Output name: krona.html for a normal table, and krona_optimistic.html for a
table whose filename contains "_optimistic".

Options:
  -h, --help    Show this help message and exit
EOF
    exit 0
}


check_commands() {
    if ! command -v "${KTIMPORTTEXT}" > /dev/null 2>&1 ; then
        echo "Error: ktImportText (KronaTools) not found in PATH." 1>&2
        exit 1
    fi
    if ! command -v python3 > /dev/null 2>&1 ; then
        echo "Error: python3 not found in PATH." 1>&2
        exit 1
    fi
}


html_name_for() {
    # Derive the output HTML name from the input TSV filename.
    local -r tsv="${1}"
    if [[ "$(basename "${tsv}")" == *_optimistic* ]] ; then
        echo "krona_optimistic.html"
    else
        echo "krona.html"
    fi
}


build_one() {
    local -r tsv="${1}"
    local html kt_dir
    html="$(html_name_for "${tsv}")"
    kt_dir="$(mktemp -d ./krona_inputs.XXXXXX)"

    python3 "${SCRIPT_DIR}/build_krona.py" --input "${tsv}" --output-dir "${kt_dir}"

    # Assemble "file,label" arguments so each dataset is labelled by its
    # barcode (the file stem); ktImportText groups them into one HTML.
    local -a datasets=()
    local f bc
    for f in "${kt_dir}"/*.txt ; do
        [[ -e "${f}" ]] || continue
        bc="$(basename "${f}" .txt)"
        datasets+=( "${f},${bc}" )
    done

    if (( ${#datasets[@]} == 0 )) ; then
        echo "Warning: no non-empty barcodes in ${tsv}; skipping ${html}." 1>&2
        return 0
    fi

    "${KTIMPORTTEXT}" "${datasets[@]}" -o "${html}"
}


## ----------------------------------------------------------------------- main

tsv_files=()
while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -h | --help) usage                                 ;;
        --) shift; break                                   ;;
        -*) echo "Unknown option: ${1}" 1>&2; exit 1       ;;
        *)  tsv_files+=("${1}"); shift                     ;;
    esac
done
while [[ $# -gt 0 ]] ; do tsv_files+=("${1}"); shift ; done

declare -ra TSV_FILES=("${tsv_files[@]+"${tsv_files[@]}"}")

if (( ${#TSV_FILES[@]} == 0 )) ; then
    echo "Error: no occurrence TSV given. Run '$(basename "$0") --help' for usage." 1>&2
    exit 1
fi

check_commands

for TSV in "${TSV_FILES[@]}" ; do
    build_one "${TSV}"
done

exit 0
