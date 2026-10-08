#!/bin/bash
# Convenience wrapper around clip: names the output after a date and a
# title, then writes a loudness-normalized copy alongside it.
#
# Source this file to use it:  . clp.sh

# pull in clip() if it isn't already defined
if ! declare -F clip >/dev/null; then
    . "$(dirname "${BASH_SOURCE[0]}")/vidutils.sh"
fi

export date=20260804

# clp src start stop [start stop ...] title
function clp {
    local src="$1"
    shift
    local args=("$@")
    local n=${#args[@]}
    if (( n < 3 || (n - 1) % 2 != 0 )); then
        echo "usage: clp src start stop [start stop ...] title" >&2
        return 1
    fi
    local title="${args[n-1]}"
    local segments=("${args[@]:0:n-1}")

    clip "$src" "${segments[@]}" "${date}_${title}.mp4" || return 1
    normalizeaudio.sh "${date}_${title}.mp4" "${date}_${title}.norm.mp4"
}
