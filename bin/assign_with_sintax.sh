#!/bin/bash

set -euo pipefail

## ----------------------------------------------------------- global constants

declare -r MIN_VSEARCH_VERSION="2.31.0"


## ----------------------------------------------------------- global variables

# Note: assign then declare separately (rather than `declare -r X="$(...)"`)
# so the command substitution's exit status is not masked by declare's;
# `|| true` keeps an absent tool (empty value) from tripping `set -e`,
# leaving the friendly diagnostic to check_commands.
CUTADAPT="$(which cutadapt || true)"
VSEARCH="$(which vsearch || true)"
declare -r CUTADAPT VSEARCH


## ------------------------------------------------------------------ functions

# shellcheck source=lib/validation.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/validation.sh"


usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] FASTQ [FASTQ ...]

Assign one barcode's fastq reads to reference taxa with sintax. All the
FASTQ files belong to the same barcode: they are primer-trimmed and fed
to a single vsearch run (the reference is loaded once), producing
<barcode>.sintax and <barcode>.log.

Options:
  -b, --barcode         STR    Barcode name, used for the output files (required)
  -d, --references      FILE   Reference sequences in fasta format (required)
  -f, --forward-primer  STR    Sequence of the forward primer (required)
  -r, --reverse-primer  STR    Sequence of the reverse primer (required)
  -t, --threads         INT    Number of threads for vsearch (default: 1)
      --randseed          INT    Seed for vsearch's random generator; 0 picks a
                                 pseudo-random seed each run (default: 0)
      --discard-untrimmed      Drop reads with no primer found (default)
      --keep-untrimmed         Keep all reads, trim primers where found
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

    require_arg "--barcode"        "${BARCODE}"        || (( errors++ )) || true
    require_arg "--references"     "${REFERENCES}"     || (( errors++ )) || true
    require_arg "--forward-primer" "${FORWARD_PRIMER}" || (( errors++ )) || true
    require_arg "--reverse-primer" "${REVERSE_PRIMER}" || (( errors++ )) || true

    if ! [[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] ; then
        echo "Error: --threads must be a positive integer: ${THREADS}" 1>&2
        (( errors++ )) || true
    fi

    if ! [[ "${RANDSEED}" =~ ^[0-9]+$ ]] ; then
        echo "Error: --randseed must be a non-negative integer: ${RANDSEED}" 1>&2
        (( errors++ )) || true
    fi

    # --- fastq file checks: at least one, each readable

    if (( ${#FASTQ_FILES[@]} == 0 )) ; then
        echo "Error: no fastq files given (expected one or more FASTQ arguments)." 1>&2
        (( errors++ )) || true
    fi
    for fastq in "${FASTQ_FILES[@]}" ; do
        check_readable file "${fastq}" "fastq file" || (( errors++ )) || true
    done

    # --- reference file checks

    if [[ -n "${REFERENCES}" ]] ; then
        if check_readable file "${REFERENCES}" "reference file" ; then
            check_reference_format "${REFERENCES}" || (( errors++ )) || true
        else
            (( errors++ )) || true
        fi
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

    # Primer-presence filter (see DISCARD_UNTRIMMED). When enabled, a
    # read is dropped unless both the forward primer (stage 1) and the
    # reverse-complemented reverse primer (stage 2) are located — strict
    # amplicon filtering. When disabled, the flag is omitted from both
    # stages so every read survives and is merely trimmed where a primer
    # is found.
    local -a discard=()
    [[ "${DISCARD_UNTRIMMED}" == "true" ]] && discard=( --discard-untrimmed )

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
        "${discard[@]}" \
        --fasta \
        "${fastq}" 2>> "${log}" | \
        "${CUTADAPT}" \
            --minimum-length "${min_length}" \
            --error-rate "${error_rate}" \
            --adapter "${anti_primer_r}" \
            --overlap "${min_r}" \
            "${discard[@]}" \
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

    # Note: when multithreading, sintax results are not exactly
    # replicable, even when using a fixed seed for the random generator
    # with --randseed. A non-zero RANDSEED still helps single-threaded
    # runs; RANDSEED=0 (default) lets vsearch pick a pseudo-random seed.

    "${VSEARCH}" \
        --sintax - \
        --dbmask none \
        --db "${REFERENCES}" \
        --sintax_cutoff "${sintax_cutoff}" \
        --randseed "${RANDSEED}" \
        --threads "${THREADS}" \
        --quiet \
        --tabbedout -
}


## ----------------------------------------------------------------------- main

# --- argument parsing

barcode=""
references=""
forward_primer=""
reverse_primer=""
threads=1
randseed=0               # 0 lets vsearch pick a pseudo-random seed
discard_untrimmed=true  # strict amplicon filtering on by default
fastq_files=()

while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -b | --barcode)         barcode="${2}";        shift 2 ;;
        -d | --references)      references="${2}";     shift 2 ;;
        -f | --forward-primer)  forward_primer="${2}"; shift 2 ;;
        -r | --reverse-primer)  reverse_primer="${2}"; shift 2 ;;
        -t | --threads)         threads="${2}";        shift 2 ;;
        --randseed)             randseed="${2}";       shift 2 ;;
        --discard-untrimmed)    discard_untrimmed=true;  shift ;;
        --keep-untrimmed)       discard_untrimmed=false; shift ;;
        -h | --help)            usage                          ;;
        --) shift; break                                       ;;
        -*) echo "Unknown option: ${1}" 1>&2; exit 1           ;;
        *)  fastq_files+=("${1}"); shift                       ;;
    esac
done

# anything after `--` is a positional fastq file too
while [[ $# -gt 0 ]] ; do
    fastq_files+=("${1}"); shift
done

# --- promote to read-only globals

declare -r  BARCODE="${barcode}"
declare -r  REFERENCES="${references}"
declare -r  FORWARD_PRIMER="${forward_primer}"
declare -r  REVERSE_PRIMER="${reverse_primer}"
declare -ri THREADS="${threads}"
declare -r  RANDSEED="${randseed}"
declare -r  DISCARD_UNTRIMMED="${discard_untrimmed}"
declare -ra FASTQ_FILES=("${fastq_files[@]+"${fastq_files[@]}"}")
unset barcode references forward_primer reverse_primer threads randseed discard_untrimmed fastq_files

validate_inputs
check_commands

# Trim primers off every file of this barcode, concatenate the trimmed
# fasta, and run sintax ONCE on the lot. vsearch loads the reference a
# single time per barcode, however many (small) fastq files it holds.
declare -r SINTAX_OUT="${BARCODE}.sintax"
declare -r LOG="${BARCODE}.log"
: > "${LOG}"  # truncate; trim_primers appends each file's cutadapt log

{
    for FASTQ in "${FASTQ_FILES[@]}" ; do
        trim_primers "${FASTQ}" "${LOG}"
    done
} | \
    append_read_length | \
    taxonomic_assignment_with_sintax > "${SINTAX_OUT}"

exit 0
