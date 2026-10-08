#!/bin/bash
# functions to include for clipping:
function timestamp_to_seconds() {
    local ts="$1"
    IFS=: read -r h m s <<< "$ts"
    # If s is empty (timestamp is MM:SS), shift variables
    if [[ -z "$s" ]]; then
        s=$m
        m=$h
        h=0
    fi
    echo "$(awk -v h="$h" -v m="$m" -v s="$s" 'BEGIN { print h*3600 + m*60 + s }')"
}

get_nearest_keyframe() {
    local input="$1"
    local target_time=$(timestamp_to_seconds "$2")
    local nearest="0"
    local preroll=10 # seconds
    local search_start=$(awk -v x="$target_time" -v y="$preroll" 'BEGIN {r = x - y; print (r < 0 ? 0 : r)}')

    # special case for 0:
    # Use awk for floating-point comparison
    if awk -v x="$target_time" 'BEGIN {exit !(x <= 0)}'; then
        echo "0"
        return
    fi

    # experimental version:
    # ffprobe -read_intervals $search_start -v warning -err_detect ignore_err -select_streams v:0 -show_packets -print_format csv "$input" 

    ffprobe -read_intervals $search_start -v error -select_streams v:0 -show_packets -print_format csv "$input" |
        awk -F, -v t="$target_time" '
        $1 == "packet" && $NF ~ /K/ {
            ts = $5 + 0  # ensure numeric
            if (ts <= t) {
                nearest = ts
            } else {
                exit
            }
        }
        END {
            print nearest
        }
    '
}

get_video_bitrate() {
    local input="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$input"
}

# Cut a single segment.  mode is "copy" (stream copy) or "encode"
# (nvenc, preserving source bitrate).
function _clip_segment() {
    local mode="$1"
    local file="$2"
    local start="$3"
    local end="$4"
    local name="$5"

    local start_sec=$(timestamp_to_seconds "$start")
    local end_sec=$(timestamp_to_seconds "$end")

    local keyframe_seek
    keyframe_seek=$(get_nearest_keyframe "$file" "$start")

    echo keyframe_seek = $keyframe_seek

    # Calculate offset from keyframe_seek to start, ensure >= 0
    local offset
    offset=$(awk -v s="$start_sec" -v k="$keyframe_seek" 'BEGIN { d = s - k; print (d < 0) ? 0 : d }')

    # Calculate duration
    local duration
    duration=$(awk -v s="$start_sec" -v e="$end_sec" 'BEGIN { print (e - s) }')

    if [[ "$mode" == "copy" ]]; then
        ffmpeg -y \
               -ss "$keyframe_seek" -i "$file" \
               -ss "$offset" -t "$duration" \
               -c:v copy -c:a copy \
               -movflags +faststart \
               "$name"
        return
    fi

    # Read source bitrate to preserve quality
    local bitrate
    bitrate=$(get_video_bitrate "$file")

    # Build encoding options
    local bitrate_opts=()
    if [[ -n "$bitrate" && "$bitrate" != "N/A" ]]; then
        bitrate_opts=(-b:v "$bitrate")
        echo "source bitrate = $bitrate"
    fi

    # cpu decode, gpu encode — preserving source bitrate
    ffmpeg -y \
           -ss "$keyframe_seek" -i "$file" \
           -ss "$offset" -t "$duration" \
           -c:v h264_nvenc -preset p4 "${bitrate_opts[@]}" \
           -movflags +faststart \
           "$name"
}

# Cut one or more segments and, if there is more than one, concatenate
# them into a single output.  Usage:
#   _clip_multi MODE file start end [start end ...] output
function _clip_multi() {
    local mode="$1"
    shift
    local file="$1"
    shift

    # last argument is the output name, the rest are start/end pairs
    local args=("$@")
    local nargs=${#args[@]}
    if (( nargs < 3 || (nargs - 1) % 2 != 0 )); then
        echo "usage: ${FUNCNAME[1]} file start end [start end ...] output" >&2
        return 1
    fi
    local name="${args[nargs-1]}"
    local pairs=("${args[@]:0:nargs-1}")
    local nsegs=$(( (nargs - 1) / 2 ))

    # single segment: cut straight to the output, no temp files
    if (( nsegs == 1 )); then
        _clip_segment "$mode" "$file" "${pairs[0]}" "${pairs[1]}" "$name"
        return
    fi

    local ext="${name##*.}"
    [[ "$ext" == "$name" ]] && ext="mp4"

    local tmpdir
    tmpdir=$(mktemp -d) || return 1

    local listfile="$tmpdir/segments.txt"
    : > "$listfile"

    local i part
    for (( i = 0; i < nsegs; i++ )); do
        part=$(printf '%s/seg%03d.%s' "$tmpdir" "$i" "$ext")
        echo "segment $((i+1))/$nsegs: ${pairs[2*i]} -> ${pairs[2*i+1]}"
        if ! _clip_segment "$mode" "$file" "${pairs[2*i]}" "${pairs[2*i+1]}" "$part"; then
            rm -rf "$tmpdir"
            return 1
        fi
        printf "file '%s'\n" "$part" >> "$listfile"
    done

    # all segments share the source's codec/resolution/timebase, so a
    # stream copy concat is enough — no second re-encode
    ffmpeg -y -f concat -safe 0 -i "$listfile" \
           -c copy -movflags +faststart \
           "$name"
    local status=$?

    rm -rf "$tmpdir"
    return $status
}

# clipcopy file start end [start end ...] output
function clipcopy() {
    _clip_multi copy "$@"
}

# clip file start end [start end ...] output
function clip() {
    _clip_multi encode "$@"
}


function crop {
    # Usage: crop input output left right top bottom
    local input="$1"
    local output="$2"
    local left="${3:-0}"
    local right="${4:-0}"
    local top="${5:-0}"
    local bottom="${6:-0}"
    local vf="crop=iw-${left}-${right}:ih-${top}-${bottom}:${left}:${top}"
    echo "crop filter: $vf"
    ffmpeg -y -i "$input" -c:a copy -vf "$vf" "$output"
}
