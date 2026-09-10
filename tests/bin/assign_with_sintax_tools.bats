#!/usr/bin/env bats
#
# SX-17 / SX-18 / SX-19: external-tool usability, failure reporting, and
# the --fastq-list interface of bin/assign_with_sintax.sh.
#
# Scope: these tests deliberately do NOT use the real cutadapt/vsearch.
# They need tools that misbehave in specific ways (a launcher that cannot
# import its own module, a cutadapt that dies mid-trim), which is exactly
# what the real tools will not do, so each test builds a stub bin/
# directory and puts it first on PATH. The script resolves both tools
# with `which` at startup, so a prepended directory is all it takes.
#
# Run with:
#   bats tests/bin/assign_with_sintax_tools.bats
#
# Background (v1.13.x). A user's large run died with `exit status 1` and an
# empty `.command.err`, which Nextflow renders as a report with no
# `Command error:` section at all — nothing to go on. The cause was a
# pipx-installed cutadapt whose virtualenv had lost its interpreter:
# `command -v cutadapt` succeeded, so `check_commands` waved it through,
# and the traceback then went to <barcode>.log because trim_primers sends
# cutadapt's stderr there. SX-17 catches it at startup, SX-18 makes the
# runtime case reportable.

bats_require_minimum_version 1.5.0

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export SCRIPT="${REPO_ROOT}/bin/assign_with_sintax.sh"
    export FIXDIR="${REPO_ROOT}/tests/fixtures/fastq_dir/fastq_pass"
    export REFS="${REPO_ROOT}/tests/fixtures/references.fasta"
}

setup() {
    cd "${BATS_TEST_TMPDIR}" || return 1
    STUBS="${BATS_TEST_TMPDIR}/stubs"
    mkdir -p "${STUBS}"
    export CUTADAPT_STUB_LOG="${BATS_TEST_TMPDIR}/cutadapt_calls.txt"
}

# A cutadapt stub. Modes:
#   ok            usable; records the fastq path it was handed
#   broken        every invocation fails, --version included (the pipx case)
#   fails-at-trim --version works, trimming does not (a corrupt fastq)
make_cutadapt() {
    local -r mode="${1}"
    cat > "${STUBS}/cutadapt" <<STUB
#!/usr/bin/env bash
mode="${mode}"
STUB
    cat >> "${STUBS}/cutadapt" <<'STUB'
if [[ "${mode}" != "broken" && "${1:-}" == "--version" ]] ; then
    echo "5.2"
    exit 0
fi
if [[ "${mode}" == "broken" || "${mode}" == "fails-at-trim" ]] ; then
    if [[ "${mode}" == "broken" ]] ; then
        echo "Traceback (most recent call last):" 1>&2
        echo "  File \"${0}\", line 3, in <module>" 1>&2
        echo "    from cutadapt.cli import main_cli" 1>&2
        echo "ModuleNotFoundError: No module named 'cutadapt'" 1>&2
    else
        echo "cutadapt: error: unexpected end of gzip file" 1>&2
    fi
    exit 1
fi
# Usable: the last argument is the input, `-` meaning stdin.
last="${!#}"
if [[ "${last}" == "-" ]] ; then
    cat > /dev/null
elif [[ -n "${CUTADAPT_STUB_LOG:-}" ]] ; then
    printf '%s\n' "${last}" >> "${CUTADAPT_STUB_LOG}"
fi
exit 0
STUB
    chmod +x "${STUBS}/cutadapt"
}

# A vsearch stub. Modes: ok | broken (as above). The real script only ever
# feeds it stdin (--fastx_filter -, --sintax -), so draining is enough.
make_vsearch() {
    local -r mode="${1}"
    cat > "${STUBS}/vsearch" <<STUB
#!/usr/bin/env bash
mode="${mode}"
STUB
    cat >> "${STUBS}/vsearch" <<'STUB'
if [[ "${mode}" == "broken" ]] ; then
    echo "vsearch: error: cannot execute binary file" 1>&2
    exit 1
fi
if [[ "${1:-}" == "--version" ]] ; then
    echo "vsearch v2.31.0_linux_x86_64" 1>&2
    exit 0
fi
cat > /dev/null
exit 0
STUB
    chmod +x "${STUBS}/vsearch"
}

# The script under test, with the stubs first on PATH.
run_script() {
    PATH="${STUBS}:${PATH}" run --separate-stderr bash "${SCRIPT}" \
        --barcode bc -d "${REFS}" \
        -f GTACACACCGCCCGTCG -r CGCCTSCSCTTANTDATATGC -t 1 "$@"
}

reads() { echo "${FIXDIR}/barcode01/reads.fastq.gz" ; }

# --------------------------------------------------------------------- SX-17

@test "SX-17a a cutadapt that cannot run is rejected at startup, not mid-run" {
    make_cutadapt broken
    make_vsearch ok
    run_script "$(reads)"
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"cutadapt"* ]]
    [[ "${stderr}" == *"not usable"* ]]
    # The tool's own words, so the cause is in the report.
    [[ "${stderr}" == *"ModuleNotFoundError"* ]]
    # Aborted before any work: no output file, and no trimming attempted.
    [ ! -e "bc.sintax" ]
    [ ! -e "${CUTADAPT_STUB_LOG}" ]
}

@test "SX-17b a vsearch that cannot run is rejected at startup" {
    make_cutadapt ok
    make_vsearch broken
    run_script "$(reads)"
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"vsearch"* ]]
    [[ "${stderr}" == *"not usable"* ]]
    [ ! -e "bc.sintax" ]
}

@test "SX-17c usable tools still pass the check" {
    # Guards against the check rejecting a healthy install: the stubs
    # answer --version the way the real tools do (cutadapt on stdout,
    # vsearch on stderr).
    make_cutadapt ok
    make_vsearch ok
    run_script "$(reads)"
    [ "${status}" -eq 0 ]
    [ -e "bc.sintax" ]
}

# --------------------------------------------------------------------- SX-18

@test "SX-18a a cutadapt failure while trimming names the file on stderr" {
    make_cutadapt fails-at-trim
    make_vsearch ok
    run_script "$(reads)"
    [ "${status}" -ne 0 ]
    # This is the whole point: a non-empty stderr, so Nextflow prints a
    # `Command error:` section instead of a bare exit status.
    [ -n "${stderr}" ]
    [[ "${stderr}" == *"reads.fastq.gz"* ]]
    [[ "${stderr}" == *"unexpected end of gzip file"* ]]
}

@test "SX-18b the same failure is still recorded in <barcode>.log" {
    make_cutadapt fails-at-trim
    make_vsearch ok
    run_script "$(reads)"
    [ "${status}" -ne 0 ]
    # The log stays the complete trimming report; stderr is additional.
    [ -s "bc.log" ]
    run grep -c "unexpected end of gzip file" "bc.log"
    [ "${status}" -eq 0 ]
}

# --------------------------------------------------------------------- SX-19

@test "SX-19a --fastq-list feeds every listed file to cutadapt" {
    make_cutadapt ok
    make_vsearch ok
    zcat "${FIXDIR}/barcode01/reads.fastq.gz" > "a.fastq"
    zcat "${FIXDIR}/barcode02/reads.fastq.gz" > "b.fastq"
    printf '%s\n%s\n' "a.fastq" "b.fastq" > "list.txt"
    run_script --fastq-list "list.txt"
    [ "${status}" -eq 0 ]
    run sort "${CUTADAPT_STUB_LOG}"
    [ "${output}" = "a.fastq"$'\n'"b.fastq" ]
}

@test "SX-19b --fastq-list combines with positional files, blank lines ignored" {
    make_cutadapt ok
    make_vsearch ok
    zcat "${FIXDIR}/barcode01/reads.fastq.gz" > "a.fastq"
    zcat "${FIXDIR}/barcode02/reads.fastq.gz" > "b.fastq"
    printf '%s\n\n' "a.fastq" > "list.txt"
    run_script --fastq-list "list.txt" "b.fastq"
    [ "${status}" -eq 0 ]
    run sort "${CUTADAPT_STUB_LOG}"
    [ "${output}" = "a.fastq"$'\n'"b.fastq" ]
}

@test "SX-19c a listed file that does not exist yields the usual clear error" {
    make_cutadapt ok
    make_vsearch ok
    printf '%s\n' "absent.fastq" > "list.txt"
    run_script --fastq-list "list.txt"
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"absent.fastq"* ]]
}

@test "SX-19d an unreadable --fastq-list file is itself an error" {
    make_cutadapt ok
    make_vsearch ok
    run_script --fastq-list "no_such_list.txt"
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"no_such_list.txt"* ]]
}
