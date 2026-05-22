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
