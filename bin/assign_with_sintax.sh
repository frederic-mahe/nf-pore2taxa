#!/bin/bash

set -euo pipefail

## ----------------------------------------------------------- global constants

declare -r MIN_VSEARCH_VERSION="2.31.0"

# posix-egrep regex matching every fastq extension we support:
# .fastq, .fastq.gz, .fastq.bz2, .fastq.xz
declare -r FASTQ_REGEX='.*\.fastq(|\.(bz2|gz|xz))$'


## ----------------------------------------------------------- global variables

declare -r CUTADAPT="$(which cutadapt)"
declare -r VSEARCH="$(which vsearch)"


## ------------------------------------------------------------------ functions

# shellcheck source=lib/validation.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/validation.sh"


usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Assign fastq reads to reference taxa with the sintax method.

Options:
  -i, --input-dir       DIR    Input directory containing fastq files (required)
  -d, --references      FILE   Reference sequences in fasta format (required)
  -f, --forward-primer  STR    Sequence of the forward primer (required)
  -r, --reverse-primer  STR    Sequence of the reverse primer (required)
  -t, --threads         INT    Number of threads for vsearch (default: 1)
  -h, --help                   Show this help message and exit
EOF
    exit 0
}


check_readable() {
    # kind: "dir" or "file"
    local -r kind="${1}" path="${2}" label="${3}"
    local flag="-f"
    [[ "${kind}" == "dir" ]] && flag="-d"
    if ! test "${flag}" "${path}" ; then
        echo "Error: ${label} not found: ${path}" 1>&2
        return 1
    fi
    if [[ ! -r "${path}" ]] ; then
        echo "Error: ${label} is not readable: ${path}" 1>&2
        return 1
    fi
}


require_arg() {
    local -r name="${1}" value="${2}"
    if [[ -z "${value}" ]] ; then
        echo "Error: ${name} is required." 1>&2
        return 1
    fi
}


validate_inputs() {
    local -i errors=0

    # Note: arithmetic expressions in bash return exit code 1 when the
    # result is zero, which would trigger set -e when the first
    # increment goes from 0 to 1. The pattern "|| true" suppresses
    # that.

    # --- required arguments

    require_arg "--input-dir"      "${INPUT_DIR}"      || (( errors++ )) || true
    require_arg "--references"     "${REFERENCES}"     || (( errors++ )) || true
    require_arg "--forward-primer" "${FORWARD_PRIMER}" || (( errors++ )) || true
    require_arg "--reverse-primer" "${REVERSE_PRIMER}" || (( errors++ )) || true

    if ! [[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] ; then
        echo "Error: --threads must be a positive integer: ${THREADS}" 1>&2
        (( errors++ )) || true
    fi

    # --- input directory checks

    if [[ -n "${INPUT_DIR}" ]] ; then
        if check_readable dir "${INPUT_DIR}" "input directory" ; then
            local -i fastq_count
            fastq_count=$(find "${INPUT_DIR}" \
                -type f \
                -regextype posix-egrep \
                -regex "${FASTQ_REGEX}" | wc -l)
            if (( fastq_count == 0 )) ; then
                echo "Error: no fastq files (.fastq[.gz|.bz2|.xz]) found in: ${INPUT_DIR}" 1>&2
                (( errors++ )) || true
            fi
        else
            (( errors++ )) || true
        fi
    fi

    # --- reference file checks

    if [[ -n "${REFERENCES}" ]] ; then
        check_readable file "${REFERENCES}" "reference file" || (( errors++ )) || true
    fi

    # --- primer checks: IUPAC alphabet + minimum length

    local -r iupac_re='^[ACGTURYKMBDHVSWNIacgturykmdbdhvswni]+$'
    local -ir min_primer_len=10
    for PRIMER in "${FORWARD_PRIMER}" "${REVERSE_PRIMER}" ; do
        [[ -z "${PRIMER}" ]] && continue
        if ! [[ "${PRIMER}" =~ ${iupac_re} ]] ; then
            echo "Error: primer contains non-IUPAC characters: ${PRIMER}" 1>&2
            (( errors++ )) || true
        fi
        if (( ${#PRIMER} < min_primer_len )) ; then
            echo "Warning: primer is unusually short (${#PRIMER} bp): ${PRIMER}" 1>&2
        fi
    done

    if (( errors > 0 )) ; then
        echo "Run '$(basename "$0") --help' for usage." 1>&2
        exit 1
    fi
}


check_commands() {
    local -a missing=()
    local -a tools=( file "${CUTADAPT}" "${VSEARCH}" )
    for cmd in "${tools[@]}" ; do
        command -v "${cmd}" > /dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )) ; then
        echo "Error: required command(s) not found in PATH: ${missing[*]}" 1>&2
        exit 1
    fi

    # vsearch --version writes "vsearch vX.Y.Z_..." to stderr
    local vsearch_version
    vsearch_version=$("${VSEARCH}" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | tr -d 'v')
    if [[ -z "${vsearch_version}" ]] ; then
        echo "Error: could not parse vsearch version from '${VSEARCH} --version'" 1>&2
        exit 1
    fi
    # sort -V -C exits 0 iff input is in ascending version order
    if ! printf '%s\n%s\n' "${MIN_VSEARCH_VERSION}" "${vsearch_version}" | sort -V -C ; then
        echo "Error: vsearch ${vsearch_version} is older than required ${MIN_VSEARCH_VERSION}" 1>&2
        exit 1
    fi
}


trim_extension() {
    local -r sample="${1}"
    # Note: remove right-most .fastq and .(bz2|gz|xz) if any
    sed -r 's/[.](gz|bz2|xz)$// ; s/[.]fastq$//' <<< "${sample}"
}


reverse_complement() {
    # reverse-complement a DNA/RNA IUPAC string
    # Note: N and I are their own complements, no need to include them
    [[ -z "${1}" ]] && { echo "Error: empty string" 1>&2 ; exit 1 ; }
    local -r nucleotides="acgturykmbdhvswACGTURYKMBDHVSW"
    local -r complements="tgcaayrmkvhdbswTGCAAYRMKVHDBSW"

    tr "${nucleotides}" "${complements}" <<< "${1}" | rev
}


trim_primers() {
    local -r fastq="${1}"
    local -r log="${2}"
    local -ir min_length=32
    local -r error_rate="0.2"
    local -r anti_primer_r="$(reverse_complement "${REVERSE_PRIMER}")"
    local -ir min_f=$(( ${#FORWARD_PRIMER} * 2 / 3 ))
    local -ir min_r=$(( ${#REVERSE_PRIMER} * 2 / 3 ))

    # Note: cutadapt adds ' rc' at the end of reverse-complemented
    # reads, use --rename="{id}" to keep only header before the first
    # whitespace
    # Note: cutadapt replaces I (inosine) with N

    "${CUTADAPT}" \
        --minimum-length "${min_length}" \
        --error-rate "${error_rate}" \
        --revcomp \
        --rename="{id}" \
        --front "${FORWARD_PRIMER};rightmost" \
        --overlap "${min_f}" \
        --discard-untrimmed \
        --fasta \
        "${fastq}" 2> "${log}" | \
        "${CUTADAPT}" \
            --minimum-length "${min_length}" \
            --error-rate "${error_rate}" \
            --adapter "${anti_primer_r}" \
            --overlap "${min_r}" \
            --fasta \
            -  2>> "${log}"
}


append_read_length() {
    # add ";length=n" to read headers
    "${VSEARCH}" \
        --fastx_filter - \
        --quiet \
        --lengthout \
        --fastaout -
}


taxonomic_assignment_with_sintax() {
    local -r sintax_cutoff=0.9
    # local -ri randseed=42

    # Note: when multithreading, sintax results are not exactly
    # replicable, even when using a fix seed for the random generator
    # with --randseed "${randseed}"

    "${VSEARCH}" \
        --sintax - \
        --dbmask none \
        --db "${REFERENCES}" \
        --sintax_cutoff "${sintax_cutoff}" \
        --threads "${THREADS}" \
        --quiet \
        --tabbedout -
}


## ----------------------------------------------------------------------- main

# --- argument parsing

input_dir=""
references=""
forward_primer=""
reverse_primer=""
threads=1

while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -i | --input-dir)       input_dir="${2}";      shift 2 ;;
        -d | --references)      references="${2}";     shift 2 ;;
        -f | --forward-primer)  forward_primer="${2}"; shift 2 ;;
        -r | --reverse-primer)  reverse_primer="${2}"; shift 2 ;;
        -t | --threads)         threads="${2}";        shift 2 ;;
        -h | --help)            usage                          ;;
        --) shift; break                                       ;;
        *) echo "Unknown option: ${1}" 1>&2; exit 1            ;;
    esac
done

# positional arguments (after --): not accepted
if [[ $# -gt 0 ]] ; then
    echo "Error: unexpected positional arguments: $*" 1>&2
    exit 1
fi

# --- promote to read-only globals

declare -r INPUT_DIR="${input_dir}"
declare -r REFERENCES="${references}"
declare -r FORWARD_PRIMER="${forward_primer}"
declare -r REVERSE_PRIMER="${reverse_primer}"
declare -ri THREADS="${threads}"
unset input_dir references forward_primer reverse_primer threads

validate_inputs
check_commands


find \
    "${INPUT_DIR}" \
    -type f \
    -regextype posix-egrep \
    -regex "${FASTQ_REGEX}" | \
    while read -r FASTQ ; do
        echo "${FASTQ}"
        SAMPLE_NAME="$(trim_extension "${FASTQ}")"
        LOG="${SAMPLE_NAME}.log"
        TABLE="${SAMPLE_NAME}.sintax"
        trim_primers "${FASTQ}" "${LOG}" | \
            append_read_length | \
            taxonomic_assignment_with_sintax > "${TABLE}"
        unset SAMPLE_NAME LOG TABLE
    done

exit 0
