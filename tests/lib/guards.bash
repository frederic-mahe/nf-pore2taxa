# Shared tool guards for the bats suites.
#
# Load from a test file in tests/bin/ or tests/config/:
#
#   load "${BATS_TEST_DIRNAME}/../lib/guards.bash"
#
# then `require_tools cutadapt vsearch` skips the current test — or, called
# from setup_file, the whole file — unless every named tool is both present
# and able to run.
#
# Why the second half matters. `command -v` only asks whether a file
# exists, and both halves of this suite's tool surface can be present and
# broken at the same time:
#
#   - a pipx or `pip install --user` console script whose virtualenv has
#     lost its interpreter (cutadapt, after a Python minor-version upgrade)
#     satisfies `command -v` and then fails on every invocation. This cost
#     a 96-barcode production run, which died with a bare `exit status 1`
#     and an empty `.command.err`; SX-17 is the in-script counterpart of
#     this guard.
#   - a KronaTools whose lib/KronaTools.pm was left mode 0600 by a botched
#     extraction resolves fine through its symlinked wrapper and dies at
#     BEGIN with `Permission denied`, exit 13. Five tests in this suite
#     failed rather than skipped because of it.
#
# A guard that cannot tell "absent" from "broken" reports the wrong thing
# in both cases, so this runs each tool once. The two messages are kept
# distinct on purpose: "not in PATH" is a missing dependency, "not usable"
# is an installation to repair.

# The cheapest invocation that reaches a tool's real entry point and exits
# 0 when it is healthy. Most tools answer `--version`; the exceptions get a
# branch of their own, with the reason.
tool_usable() {
    case "${1}" in
        # One dash. `nextflow --version` exits 1.
        nextflow)
            nextflow -version > /dev/null 2>&1
            ;;
        # No version flag at all. With no arguments the script prints usage
        # and exits 0 (KronaTools scripts/ImportText.pl line 55), and it
        # still executes the `use KronaTools` in its BEGIN block on the way
        # there — which is exactly where a broken install dies.
        ktImportText)
            ktImportText > /dev/null 2>&1
            ;;
        *)
            "${1}" --version > /dev/null 2>&1
            ;;
    esac
}

require_tools() {
    local tool
    for tool in "$@" ; do
        command -v "${tool}" > /dev/null 2>&1 \
            || skip "${tool} not in PATH"
        tool_usable "${tool}" \
            || skip "${tool} not usable"
    done
}
