#!/usr/bin/env bats
#
# BC-01..BC-07, BC-10, BC-11: bin/basecall_pod5_files.sh.
#
# Run with:
#   bats tests/bin/basecall_cli.bats
#
# The real dorado needs a GPU and a ~1 GB model download, so it can never
# run here. tests/stubs/dorado records the argv it was called with and
# fabricates the expected outputs, which covers everything that is ours:
# that the model, kit and device reach the tool, that a cached model is not
# re-downloaded, and that the script confines itself to --output-dir.
#
# Until v1.11.0 the model, kit and device were hardcoded in this script and
# not exposed as pipeline parameters at all, so a lab with a different
# sequencing kit could not use basecalling. BC-07 pins the defaults; BC-09
# pins that each is overridable.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/basecall_pod5_files.sh"
    STUBS="${REPO_ROOT}/tests/stubs"

    IN="${BATS_TEST_TMPDIR}/pod5"
    OUT="${BATS_TEST_TMPDIR}/out"
    MODELS="${BATS_TEST_TMPDIR}/models"
    mkdir -p "${IN}" "${OUT}"
    touch "${IN}/reads.pod5"

    export DORADO_STUB_LOG="${BATS_TEST_TMPDIR}/dorado.log"
    # pigz is needed by compress_fastq; skip rather than fail misleadingly.
    command -v pigz > /dev/null 2>&1 || skip "pigz not in PATH"
}

# Run the script with the stubbed dorado on PATH.
basecall() {
    run env PATH="${STUBS}:${PATH}" bash "${SCRIPT}" "$@"
}

# The argv of the Nth stub invocation (1-based).
stub_call() {
    sed -n "${1}p" "${DORADO_STUB_LOG}"
}

# ------------------------------------------------------------- BC-01..BC-06

@test "BC-01 --help exits 0 and prints the usage block" {
    basecall --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage:"* ]]
    [[ "${output}" == *"--input-dir"* ]]
    [[ "${output}" == *"--device"* ]]
    [[ "${output}" == *"--models-dir"* ]]
}

@test "BC-02 a missing --input-dir is an error" {
    basecall --output-dir "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--input-dir is required"* ]]
}

@test "BC-02b a missing --output-dir is an error" {
    basecall --input-dir "${IN}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--output-dir is required"* ]]
}

@test "BC-03 an --input-dir that does not exist is an error" {
    basecall --input-dir "${BATS_TEST_TMPDIR}/__absent__" --output-dir "${OUT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"input directory not found"* ]]
}

@test "BC-04 an unrecognised --model is rejected" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --model bogus
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unrecognised model format"* ]]
    # The message must show both accepted forms.
    [[ "${output}" == *"sup@v5.2.0"* ]]
    [[ "${output}" == *"dna_r10.4.1"* ]]
}

@test "BC-04b a full dorado model name is accepted for other chemistry" {
    # The flowcell/chemistry prefix was hardcoded, so only r10.4.1/e8.2
    # could ever be basecalled. A full name passes through untouched.
    basecall --input-dir "${IN}" --output-dir "${OUT}" \
        --models-dir "${MODELS}" --model dna_r9.4.1_e8_hac@v3.3.0
    [ "${status}" -eq 0 ]
    [[ "$(stub_call 1)" == "download --model dna_r9.4.1_e8_hac@v3.3.0"* ]]
    # ...and reaches the basecaller as written, not re-prefixed.
    [[ "$(stub_call 2)" == *"dna_r9.4.1_e8_hac@v3.3.0"* ]]
    [[ "$(stub_call 2)" != *"dna_r10.4.1_e8.2_400bps_dna_r9"* ]]
}

@test "BC-05 an unrecognised --kit-name is rejected" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --kit-name nonsense
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unrecognised kit name"* ]]
}

@test "BC-06 an unknown flag exits non-zero" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --nope
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown option:"* ]]
}

@test "BC-06b an unrecognised --device is rejected" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --device gpu9
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unrecognised device"* ]]
}

# ------------------------------------------------------------------- BC-07

@test "BC-07 the defaults are sup@v5.2.0 on EXP-PBC096 and cuda:0" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --models-dir "${MODELS}"
    [ "${status}" -eq 0 ]

    # The short model name is prefixed with the flowcell/chemistry for the
    # download...
    [[ "$(stub_call 1)" == *"--model dna_r10.4.1_e8.2_400bps_sup@v5.2.0"* ]]
    # ...and passed to the basecaller as given, which dorado resolves
    # against --models-directory.
    [[ "$(stub_call 2)" == *"--kit-name EXP-PBC096"* ]]
    [[ "$(stub_call 2)" == *"--device cuda:0"* ]]
    [[ "$(stub_call 2)" == *"sup@v5.2.0"* ]]
}

# ------------------------------------------------------------------- BC-09

@test "BC-09 model, kit and device are each overridable" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --models-dir "${MODELS}" \
        --model hac@v4.3.0 --kit-name SQK-LSK114 --device cuda:all
    [ "${status}" -eq 0 ]
    [[ "$(stub_call 2)" == *"--kit-name SQK-LSK114"* ]]
    [[ "$(stub_call 2)" == *"--device cuda:all"* ]]
    [[ "$(stub_call 2)" == *"hac@v4.3.0"* ]]
}

@test "BC-09b cpu is a valid device, so a GPU-less machine can basecall" {
    basecall --input-dir "${IN}" --output-dir "${OUT}" --models-dir "${MODELS}" \
        --device cpu
    [ "${status}" -eq 0 ]
    [[ "$(stub_call 2)" == *"--device cpu"* ]]
}

# ------------------------------------------------------------------- BC-10

@test "BC-10 a cached model is not downloaded again" {
    # The model used to be fetched into the output directory and then deleted
    # by clean_up, so every run re-downloaded ~1 GB and every run needed
    # network. With the model already in --models-dir the download is skipped.
    mkdir -p "${MODELS}/dna_r10.4.1_e8.2_400bps_sup@v5.2.0"
    basecall --input-dir "${IN}" --output-dir "${OUT}" --models-dir "${MODELS}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Model already present, skipping download"* ]]
    # Only the basecaller was invoked; no download at all.
    run grep -c '^download' "${DORADO_STUB_LOG}"
    [ "${output}" = "0" ]
}

@test "BC-10b the model directory survives clean_up" {
    # clean_up deletes every other top-level directory in the output dir;
    # deleting the model is what forced the re-download.
    basecall --input-dir "${IN}" --output-dir "${OUT}" \
        --models-dir "${OUT}/models"
    [ "${status}" -eq 0 ]
    [ -d "${OUT}/models/dna_r10.4.1_e8.2_400bps_sup@v5.2.0" ]
    [ -d "${OUT}/fastq_pass" ]
}

# ------------------------------------------------------------------- BC-11

@test "BC-11 the script confines itself to --output-dir" {
    # clean_up and compress_fastq used to walk `.` — the CALLER's directory —
    # moving and deleting directories there. Under Nextflow the two are the
    # same, so this was invisible; run by hand from anywhere else it was
    # destructive. Verified by planting a decoy the old code would have eaten.
    local -r bystander="${BATS_TEST_TMPDIR}/bystander"
    mkdir -p "${bystander}/fastq_pass/barcode99" "${bystander}/keep_me"
    echo "precious" > "${bystander}/fastq_pass/barcode99/reads.fastq"
    echo "precious" > "${bystander}/keep_me/data.txt"

    cd "${bystander}" || return 1
    run env PATH="${STUBS}:${PATH}" bash "${SCRIPT}" \
        --input-dir "${IN}" --output-dir "${OUT}" --models-dir "${MODELS}"
    [ "${status}" -eq 0 ]

    # Nothing in the caller's directory was moved, compressed or removed.
    [ -f "${bystander}/fastq_pass/barcode99/reads.fastq" ]
    [ -f "${bystander}/keep_me/data.txt" ]
    [ "$(cat "${bystander}/keep_me/data.txt")" = "precious" ]
}

@test "BC-11b fastq_pass already at the top of output-dir is not moved onto itself" {
    # `mv ./fastq_pass .` is an error, and under `-exec` it made find exit
    # non-zero, which `set -e` turned into an aborted run. This is the
    # pipeline's own layout (--output-dir "./").
    cd "${OUT}" || return 1
    run env PATH="${STUBS}:${PATH}" bash "${SCRIPT}" \
        --input-dir "${IN}" --output-dir "./" --models-dir "${MODELS}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"same file"* ]]
    [ -d "${OUT}/fastq_pass" ]
}

# ------------------------------------------------------------------- BC-12

@test "BC-12 the Groovy and bash model-prefix logic agree" {
    # full_model_name() exists in both bin/basecall_pod5_files.sh (which
    # decides where to look for the model) and modules/local/functions.nf
    # (which decides where to download it). A mismatch means fetching to one
    # path and looking in another — a silent re-download at best.
    local bash_prefix nf_prefix
    bash_prefix="$(sed -nE 's/^declare -r MODEL_PREFIX="(.*)"$/\1/p' "${SCRIPT}")"
    nf_prefix="$(sed -nE "s/^    '(dna_[^']*)'\$/\1/p" \
                 "${REPO_ROOT}/modules/local/functions.nf")"
    [ -n "${bash_prefix}" ]
    [ -n "${nf_prefix}" ]
    [ "${bash_prefix}" = "${nf_prefix}" ]
}
