#!/bin/bash

require_arg() {
    local -r name="${1}" value="${2}"
    if [[ -z "${value}" ]] ; then
        echo "Error: ${name} is required." 1>&2
        return 1
    fi
}


check_readable() {
    # kind: "dir" or "file"
    local -r kind="${1}"
    local -r path="${2}"
    local -r label="${3}"

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


check_reference_format() {
    # Sniff the first FASTA header of a sintax reference database and
    # verify it carries a `tax=` taxonomy annotation, so a swapped or
    # mis-formatted file aborts at startup rather than producing empty or
    # wrong assignments mid-run. Mirrors nf-metabarcoding's [S73] check,
    # restricted to the sintax format vsearch --sintax expects:
    #
    #   >id;tax=d:Domain,p:Phylum,...;
    #
    # Only the first line is read (the rest is left for vsearch). A path
    # that is absent is not sniffed (presence is enforced by check_readable);
    # gzip (.gz) is transparently decompressed; bzip2 (.bz2) is skipped with
    # a warning (vsearch reads it at runtime). Returns 0 when the reference
    # is valid (or unsniffable), 1 on a format mismatch.
    local -r path="${1}"

    # Presence is handled by check_readable; nothing to sniff if absent.
    [[ -e "${path}" ]] || return 0

    if [[ "${path}" == *.bz2 ]] ; then
        echo "Warning: reference file is bzip2-compressed; skipping the startup format check: ${path}" 1>&2
        return 0
    fi

    local header
    if [[ "${path}" == *.gz ]] ; then
        header=$(gzip -cd -- "${path}" 2> /dev/null | head -n 1)
    else
        header=$(head -n 1 -- "${path}")
    fi

    if [[ "${header}" != ">"* ]] ; then
        echo "Error: reference file does not look like FASTA (first line is not a '>' header): ${path}" 1>&2
        return 1
    fi
    if [[ "${header}" != *"tax="* ]] ; then
        echo "Error: reference file must be sintax-formatted (header '>id;tax=d:...,p:...;'); its first header carries no 'tax=' annotation: ${header}" 1>&2
        return 1
    fi
}
