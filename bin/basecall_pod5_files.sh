#!/bin/bash

set -euo pipefail

## ----------------------------------------------------------- global constants

declare -r MODEL_DIR="models"
declare -r DEFAULT_MODEL="sup@v5.2.0"
declare -r DEFAULT_KIT_NAME="EXP-PBC096"


## ------------------------------------------------------------------ functions

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Basecall Nanopore pod5 files using dorado.

Options:
  -i, --input-dir   DIR    Input directory containing pod5 files (required)
  -o, --output-dir  DIR    Output directory for basecalled files (required)
  -m, --model       MODEL  Basecalling model
                           (default: ${DEFAULT_MODEL})
  -k, --kit-name    KIT    Sequencing kit name
                           (default: ${DEFAULT_KIT_NAME})
  -h, --help               Show this help message and exit
EOF
    exit 0
}


validate_inputs() {
    local -i errors=0

    # Note: arithmetic expressions in bash return exit code 1 when the
    # result is zero, which would trigger set -e when the first
    # increment goes from 0 to 1. The pattern "|| true" suppresses
    # that.

    # required arguments
    if [[ -z "${INPUT_DIR}" ]] ; then
        echo "Error: --input-dir is required." 1>&2
        (( errors++ )) || true
    fi
    if [[ -z "${OUTPUT_DIR}" ]] ; then
        echo "Error: --output-dir is required." 1>&2
        (( errors++ )) || true
    fi

    # input directory must exist
    if [[ -n "${INPUT_DIR}" && ! -d "${INPUT_DIR}" ]] ; then
        echo "Error: input directory not found: ${INPUT_DIR}" 1>&2
        (( errors++ )) || true
    fi

    # model must match expected dorado format: <speed>@v<version>
    # speed: fast, high accuracy, super accuracy
    if [[ ! "${MODEL}" =~ ^(fast|hac|sup)@v[0-9]+\.[0-9]+\.[0-9]+$ ]] ; then
        echo "Error: unrecognised model format: ${MODEL}" 1>&2
        echo "       Expected format: fast|hac|sup@v<X.Y.Z> (e.g. sup@v5.2.0)" 1>&2
        (( errors++ )) || true
    fi

    # kit name: ONT kits follow patterns like SQK-LSK114 or EXP-PBC096
    if [[ ! "${KIT_NAME}" =~ ^[A-Z]{3}-[A-Z]{3}[0-9]{3}$ ]] ; then
        echo "Error: unrecognised kit name format: ${KIT_NAME}" 1>&2
        echo "       Expected format: XXX-XXX000 (e.g. EXP-PBC096, SQK-LSK114)" 1>&2
        (( errors++ )) || true
    fi

    if (( errors > 0 )) ; then
        echo "Run '$(basename "$0") --help' for usage." 1>&2
        exit 1
    fi
}


check_commands() {
    local -a missing=()
    for cmd in dorado pigz ; do
        command -v "${cmd}" > /dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )) ; then
        echo "Error: required command(s) not found in PATH: ${missing[*]}" 1>&2
        exit 1
    fi
}


create_output_folder() {
    [[ -d "${OUTPUT_DIR}" ]] || \
        mkdir -p "${OUTPUT_DIR}"
}


download_model() {
    local -r model_dir="${OUTPUT_DIR}/${MODEL_DIR}"
    local -r model="dna_r10.4.1_e8.2_400bps_${MODEL}"
    # flowcell version: r10.4.1
    # adaptor: e8.2
    # e stands for engine (motor protein)
    [[ -d "${model_dir}" ]] || \
        mkdir -p "${model_dir}"
    dorado \
        download \
        --model "${model}" \
        --models-directory "${model_dir}"
}


basecall() {
    local -r model_dir="${OUTPUT_DIR}/${MODEL_DIR}"
    local -r model="${MODEL}"
    local -ri batchsize=96
    local -r kit_name="${KIT_NAME}"  # extension kit used alongside SQK-LSK114
    dorado \
        basecaller \
        --models-directory "${model_dir}" \
        --device cuda:0 \
        --batchsize "${batchsize}" \
        --kit-name "${kit_name}" \
        --recursive \
        --output-dir "${OUTPUT_DIR}" \
        --no-trim \
        --emit-fastq \
        "${model}" \
        "${INPUT_DIR}"
}


compress_fastq() {
    find \
        . \
        -name "*.fastq" \
        -type f \
        -exec pigz '{}' \;
}


clean_up() {
    # fish out the fastq_pass directory
    find \
        . \
        -name "fastq_pass" \
        -type d \
        -exec mv '{}' . \;
    # remove everything else
    find \
        . \
        -maxdepth 1 \
        -mindepth 1 \
        -type d \
        ! -name "fastq_pass" \
        -exec echo rm -rf '{}' \;
}


## ----------------------------------------------------------------------- main

# --- argument parsing

input_dir=""
output_dir=""
model=""
kit_name=""

while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -i | --input-dir)    input_dir="${2}";  shift 2 ;;
        -o | --output-dir)   output_dir="${2}"; shift 2 ;;
        -m | --model)        model="${2}";      shift 2 ;;
        -k | --kit-name)     kit_name="${2}";   shift 2 ;;
        -h | --help)         usage                      ;;
        --) shift; break                                ;;
        *) echo "Unknown option: ${1}" 1>&2; exit 1     ;;
    esac
done

# positional arguments (after --): not accepted
if [[ $# -gt 0 ]] ; then
    echo "Error: unexpected positional arguments: $*" 1>&2
    exit 1
fi


# --- promote to read-only globals

declare -r INPUT_DIR="${input_dir}"
declare -r OUTPUT_DIR="${output_dir%/}"  # trim final '/', if any
declare -r MODEL="${model:-${DEFAULT_MODEL}}"
declare -r KIT_NAME="${kit_name:-${DEFAULT_KIT_NAME}}"
unset input_dir output_dir model kit_name

validate_inputs
create_output_folder
check_commands
download_model
basecall
compress_fastq
clean_up

exit 0
