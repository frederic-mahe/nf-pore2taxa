#!/bin/bash

set -euo pipefail

## ----------------------------------------------------------- global constants



## ----------------------------------------------------------- global variables

declare -r CUTADAPT="${HOME}/.local/bin/cutadapt"
declare -r VSEARCH="${HOME}/Documents/src/vsearch/bin/vsearch"


## ------------------------------------------------------------------ functions

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Assign fastq reads to reference taxa with the sintax method.

Options:
  -i, --input-dir       DIR    Input directory containing fastq files (required)
  -d, --references      FILE   Reference sequences in fasta format (required)
  -f, --forward-primer  STR    Sequence of the forward primer (required)
  -r, --reverse-primer  STR    Sequence of the reverse primer (required)
  -h, --help                   Show this help message and exit
EOF
    exit 0
}


validate_inputs() {
    local -i errors=0

    # Note: arithmetic expressions in bash return exit code 1 when the
    # result is zero, which would trigger set -e when the first
    # increment goes from 0 to 1. The pattern "|| true" suppresses
    # that.
    
    # --- required arguments

    if [[ -z "${INPUT_DIR}" ]] ; then
        echo "Error: --input-dir is required." 1>&2
        (( errors++ )) || true
    fi
    if [[ -z "${REFERENCES}" ]] ; then
        echo "Error: --references is required." 1>&2
        (( errors++ )) || true
    fi
    if [[ -z "${FORWARD_PRIMER}" ]] ; then
        echo "Error: --forward-primer is required." 1>&2
        (( errors++ )) || true
    fi
    if [[ -z "${REVERSE_PRIMER}" ]] ; then
        echo "Error: --reverse-primer is required." 1>&2
        (( errors++ )) || true
    fi    
    
    # --- input directory checks

    if [[ -n "${INPUT_DIR}" ]] ; then
        if [[ ! -d "${INPUT_DIR}" ]] ; then
            echo "Error: input directory not found: ${INPUT_DIR}" 1>&2
            (( errors++ )) || true
        elif [[ ! -r "${INPUT_DIR}" ]] ; then
            echo "Error: input directory is not readable: ${INPUT_DIR}" 1>&2
            (( errors++ )) || true
        else
            # check that at least one fastq.gz file is present
            local -i fastq_count
            fastq_count=$(find "${INPUT_DIR}" -name "*.fastq.gz" -type f | wc -l)
            if (( fastq_count == 0 )) ; then
                echo "Error: no *.fastq.gz files found in: ${INPUT_DIR}" 1>&2
                (( errors++ )) || true
            fi
        fi
    fi

    # --- reference file checks

    if [[ -n "${REFERENCES}" ]] ; then
        if [[ ! -f "${REFERENCES}" ]] ; then
            echo "Error: reference file not found: ${REFERENCES}" 1>&2
            (( errors++ )) || true
        elif [[ ! -r "${REFERENCES}" ]] ; then
            echo "Error: reference file is not readable: ${REFERENCES}" 1>&2
            (( errors++ )) || true
        else
            # accept plain fasta or compressed fasta (gzip, bzip2)
            local magic
            magic=$(file --brief --mime-type "${REFERENCES}")
            case "${magic}" in
                text/plain | application/gzip | application/x-gzip | application/x-bzip2)
                    # all good, do nothing
                    ;;
                *)
                    echo "Error: reference file does not appear to be fasta, gzip, or bzip2: ${REFERENCES}" 1>&2
                    (( errors++ )) || true
                    ;;
            esac
        fi
    fi

    # --- primer sequence checks (IUPAC DNA alphabet only + N)

    local -r iupac_re='^[ACGTURYKMBDHVSWNacgturykmdbdhvswn]+$'
    for PRIMER in "${FORWARD_PRIMER}" "${REVERSE_PRIMER}" ; do
        if [[ -n "${PRIMER}" && ! "${PRIMER}" =~ ${iupac_re} ]] ; then
            echo "Error: primer contains non-IUPAC characters: ${PRIMER}" 1>&2
            (( errors++ )) || true
        fi
    done

    # --- sanity-check primer lengths (very short primers are likely mistakes)

    local -ir min_primer_len=10
    for PRIMER in "${FORWARD_PRIMER}" "${REVERSE_PRIMER}" ; do
        if [[ -n "${PRIMER}" ]] && (( ${#PRIMER} < min_primer_len )) ; then
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
}


convert_fastq_to_fasta() {
    local -r fastq="${1}"
    local -ir encoding=33

    # Note: use SHA1 values as sequence names

    "${VSEARCH}" \
        --fastq_filter "${fastq}" \
        --fastq_ascii "${encoding}" \
        --fastq_qmax 93 \
        --quiet \
        --relabel_sha1 \
        --fasta_width 0 \
        --fastaout -
}


reverse_complement() {
    # reverse-complement a DNA/RNA IUPAC string
    # note: N is its own complement, no need to include it
    [[ -z "${1}" ]] && { echo "Error: empty string" 1>&2 ; exit 1 ; }
    local -r nucleotides="acgturykmbdhvswACGTURYKMBDHVSW"
    local -r complements="tgcaayrmkvhdbswTGCAAYRMKVHDBSW"

    tr "${nucleotides}" "${complements}" <<< "${1}" | rev
}


trim_primers() {
    local -r log="${1}"
    local -ir min_length=32
    local -r error_rate="0.2"
    local -r cutadapt_options="--minimum-length ${min_length} --error-rate ${error_rate}"
    local -r anti_primer_r="$(reverse_complement "${REVERSE_PRIMER}")"
    local -ir min_f=$(( ${#FORWARD_PRIMER} * 2 / 3 ))
    local -ir min_r=$(( ${#REVERSE_PRIMER} * 2 / 3 ))

    # Note: cutadapt adds ' rc' at the end of reverse-complemented
    # reads, use --rename="{header}" to prevent that

    "${CUTADAPT}" \
        ${cutadapt_options} \
        --revcomp \
        --rename="{header}" \
        --front "${FORWARD_PRIMER};rightmost" \
        --overlap "${min_f}" \
        --discard-untrimmed \
        - 2> "${log}" | \
        "${CUTADAPT}" \
            ${cutadapt_options} \
            --adapter "${anti_primer_r}" \
            --overlap "${min_r}" \
            -  2>> "${log}"
}


taxonomic_assignment_with_sintax() {
    local -r sintax_cutoff=0.9
    local -ri randseed=42

    # Note: when multithreading, sintax results are not exactly
    # replicable, even when using a fix seed for the random generator

    "${VSEARCH}" \
        --sintax - \
        --randseed "${randseed}" \
        --dbmask none \
        --db "${REFERENCES}" \
        --sintax_cutoff "${sintax_cutoff}" \
        --quiet \
        --tabbedout -
}


## ----------------------------------------------------------------------- main

# --- argument parsing

input_dir=""
references=""
forward_primer=""
reverse_primer=""

while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -i | --input-dir)       input_dir="${2}";      shift 2 ;;
        -d | --references)      references="${2}";     shift 2 ;;
        -f | --forward-primer)  forward_primer="${2}"; shift 2 ;;
        -r | --reverse-primer)  reverse_primer="${2}"; shift 2 ;;
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
unset input_dir references forward_primer reverse_primer


find "${INPUT_DIR}" -name "*.fastq.gz" -type f | \
    while read -r FASTQ ; do
        echo "${FASTQ}"
        LOG="${FASTQ/\.fastq\.gz/.log}"
        TABLE="${FASTQ/\.fastq\.gz/.sintax}"
        convert_fastq_to_fasta "${FASTQ}" | \
            trim_primers "${LOG}" | \
            taxonomic_assignment_with_sintax > "${TABLE}"
        unset LOG TABLE
    done

exit 0
