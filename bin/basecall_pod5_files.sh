#!/bin/bash

set -euo pipefail

## ----------------------------------------------------------- global constants

declare -r DEFAULT_MODELS_SUBDIR="models"
declare -r DEFAULT_MODEL="sup@v5.2.0"
declare -r DEFAULT_KIT_NAME="EXP-PBC096"
declare -r DEFAULT_DEVICE="cuda:0"

# Flowcell/chemistry prefix prepended to a short model name (speed@version).
# r10.4.1 = flowcell, e8.2 = adaptor, 400bps = translocation speed. Pass a
# FULL dorado model name to --model to target different chemistry.
declare -r MODEL_PREFIX="dna_r10.4.1_e8.2_400bps_"


## ------------------------------------------------------------------ functions

# shellcheck source=lib/validation.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/validation.sh"


usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Basecall Nanopore pod5 files using dorado.

Options:
  -i, --input-dir   DIR    Input directory containing pod5 files (required)
  -o, --output-dir  DIR    Output directory for basecalled files (required)
  -m, --model       MODEL  Basecalling model, either a short name
                           (fast|hac|sup@vX.Y.Z, prefixed with
                           ${MODEL_PREFIX} automatically)
                           or a full dorado model name for other chemistry
                           (default: ${DEFAULT_MODEL})
  -k, --kit-name    KIT    Sequencing kit name
                           (default: ${DEFAULT_KIT_NAME})
  -d, --device      DEV    Compute device: cpu, cuda:0, cuda:all, cuda:0,1,
                           metal, auto (default: ${DEFAULT_DEVICE})
      --models-dir  DIR    Where the basecalling model lives. If it already
                           holds the model, no download is attempted, so a
                           cached directory can be supplied
                           (default: <output-dir>/${DEFAULT_MODELS_SUBDIR})
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
    require_arg "--input-dir"  "${INPUT_DIR}"  || (( errors++ )) || true
    require_arg "--output-dir" "${OUTPUT_DIR}" || (( errors++ )) || true

    # input directory must exist and be readable
    if [[ -n "${INPUT_DIR}" ]] ; then
        check_readable dir "${INPUT_DIR}" "input directory" || (( errors++ )) || true
    fi

    # model: either the short form <speed>@v<version> (fast / high accuracy
    # / super accuracy), which gets MODEL_PREFIX prepended, or a full dorado
    # model name so other flowcells and chemistries can be targeted.
    if [[ ! "${MODEL}" =~ ^(fast|hac|sup)@v[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
       [[ ! "${MODEL}" =~ ^[a-z]+_[a-z0-9._]+_(fast|hac|sup)@v[0-9]+\.[0-9]+\.[0-9]+$ ]] ; then
        echo "Error: unrecognised model format: ${MODEL}" 1>&2
        echo "       Expected fast|hac|sup@v<X.Y.Z> (e.g. sup@v5.2.0)," 1>&2
        echo "       or a full dorado model name (e.g." 1>&2
        echo "       dna_r10.4.1_e8.2_400bps_sup@v5.2.0)" 1>&2
        (( errors++ )) || true
    fi

    # device: what dorado accepts for --device.
    if [[ ! "${DEVICE}" =~ ^(cpu|auto|metal|cuda:(all|[0-9]+(,[0-9]+)*))$ ]] ; then
        echo "Error: unrecognised device: ${DEVICE}" 1>&2
        echo "       Expected cpu, auto, metal, cuda:all, cuda:0 or cuda:0,1" 1>&2
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


full_model_name() {
    # A short name (sup@v5.2.0) gets the flowcell/chemistry prefix; a full
    # name is already complete and is passed through untouched.
    if [[ "${MODEL}" =~ ^(fast|hac|sup)@ ]] ; then
        printf '%s%s\n' "${MODEL_PREFIX}" "${MODEL}"
    else
        printf '%s\n' "${MODEL}"
    fi
}


download_model() {
    local -r model_dir="${MODELS_DIR}"
    local model
    model="$(full_model_name)"

    # Skip the download when the model is already there. Previously the
    # model was fetched into the output directory and then deleted by
    # clean_up, so every run re-downloaded ~1 GB and every run needed
    # network. With a cached --models-dir (the pipeline supplies one via a
    # storeDir process) this becomes a no-op after the first fetch.
    if [[ -d "${model_dir}/${model}" ]] ; then
        echo "Model already present, skipping download: ${model_dir}/${model}" 1>&2
        return 0
    fi

    [[ -d "${model_dir}" ]] || \
        mkdir -p "${model_dir}"
    dorado \
        download \
        --model "${model}" \
        --models-directory "${model_dir}"
}


basecall() {
    local -r model_dir="${MODELS_DIR}"
    # Passed as given (short or full): dorado resolves either against
    # --models-directory, and keeping the user's spelling avoids changing
    # what works today for the default short form.
    local -r model="${MODEL}"
    local -ri batchsize=96
    local -r kit_name="${KIT_NAME}"  # extension kit used alongside SQK-LSK114
    dorado \
        basecaller \
        --models-directory "${model_dir}" \
        --device "${DEVICE}" \
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
    # Scoped to OUTPUT_DIR, not the current directory. Under Nextflow the
    # two are the same (--output-dir "./" inside the task dir), but a
    # standalone `--output-dir /elsewhere` used to compress every .fastq
    # under whatever directory the caller happened to be standing in.
    find \
        "${OUTPUT_DIR}" \
        -name "*.fastq" \
        -type f \
        -exec pigz '{}' \;
}


clean_up() {
    # Everything here is scoped to OUTPUT_DIR. It used to walk `.`, which is
    # the same thing under Nextflow (--output-dir "./" inside the task dir)
    # but destructive for anyone running the script by hand from elsewhere:
    # it moved and deleted directories in the caller's current directory.
    #
    # Fish out the fastq_pass directory, skipping it when it is already at
    # the top of OUTPUT_DIR: moving a directory onto itself is an error
    # ("are the same file" / "not empty"), which under `-exec` makes find
    # exit non-zero and `set -e` abort the whole script — reachable in the
    # pipeline's own layout, where dorado writes fastq_pass straight into
    # the output directory.
    local found
    while IFS= read -r found ; do
        [[ "${found}" == "${OUTPUT_DIR}/fastq_pass" ]] && continue
        mv "${found}" "${OUTPUT_DIR}/"
    done < <(find "${OUTPUT_DIR}" -type d -name "fastq_pass" -prune)

    # Remove everything else, except the model directory: deleting that is
    # what used to force a fresh ~1 GB download on every run.
    local models_basename
    models_basename="$(basename "${MODELS_DIR}")"
    find \
        "${OUTPUT_DIR}" \
        -maxdepth 1 \
        -mindepth 1 \
        -type d \
        ! -name "fastq_pass" \
        ! -name "${models_basename}" \
        -exec rm -rf '{}' \;
}


## ----------------------------------------------------------------------- main

# --- argument parsing

input_dir=""
output_dir=""
model=""
kit_name=""
device=""
models_dir=""

while [[ $# -gt 0 ]] ; do
    case "${1}" in
        -i | --input-dir)    input_dir="${2}";  shift 2 ;;
        -o | --output-dir)   output_dir="${2}"; shift 2 ;;
        -m | --model)        model="${2}";      shift 2 ;;
        -k | --kit-name)     kit_name="${2}";   shift 2 ;;
        -d | --device)       device="${2}";     shift 2 ;;
        --models-dir)        models_dir="${2}"; shift 2 ;;
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
declare -r DEVICE="${device:-${DEFAULT_DEVICE}}"
declare -r MODELS_DIR="${models_dir:-${OUTPUT_DIR}/${DEFAULT_MODELS_SUBDIR}}"
unset input_dir output_dir model kit_name device models_dir

validate_inputs
check_commands
create_output_folder
download_model
basecall
compress_fastq
clean_up

exit 0
