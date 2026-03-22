#!/bin/bash
# functions to include for clipping:

function clipfast {
    file=$1
    start=$2
    end=$3
    name=$4
    ffmpeg -y \
           -ss "$start" -to "$end" \
           -i "$file" \
           -c copy \
           "$name"
}
function clipslow {
    file=$1
    start=$2
    end=$3
    name=$4
    # ffmpeg -y \
        #        -hwaccel cuda \
        #        -i "$file" \
        #        -ss "$start" -to "$end" \
        #        -c:v h264_nvenc \
        #        "$name"
    ffmpeg -y \
           -hwaccel cuda \
           -i "$file" \
           -ss "$start" -to "$end" \
           -c:v h264_nvenc \
           -preset p3 \
           -cq 19 \
           -rc vbr \
           -b:v 5M \
           -maxrate 10M \
           -bufsize 20M \
           "$name"
}
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
function clip() {
    local file="$1"
    local start="$2"
    local start_sec=$(timestamp_to_seconds "$2")
    local end="$3"
    local end_sec=$(timestamp_to_seconds "$3")
    local name="$4"

    local keyframe_seek
    keyframe_seek=$(get_nearest_keyframe "$file" "$start")

    echo keyframe_seek = $keyframe_seek

    # Calculate offset from keyframe_seek to start, ensure >= 0
    local offset
    offset=$(awk -v s="$start_sec" -v k="$keyframe_seek" 'BEGIN { d = s - k; print (d < 0) ? 0 : d }')

    # Calculate duration
    local duration
    duration=$(awk -v s="$start_sec" -v e="$end_sec" 'BEGIN { print (e - s) }')
    # pure CPU: very slow
    # 
    # ffmpeg -y \
        #        -ss "$keyframe_seek" -i "$file" \
        #        -ss "$offset" -t "$duration" \
        #        -c:v libx264 \
        #        -movflags +faststart \
        #        "$name"
    
    # pure GPU: fast but not quite as fast as CPU+GPU, low CPU use,
    # some artifacts compared to CPU
    # 
    # ffmpeg -y -hwaccel cuda \
        #        -ss "$keyframe_seek" -i "$file" \
        #        -ss "$offset" \
        #        -t "$duration" \
        #        -c:v h264_nvenc \
        #        -movflags +faststart \
        #        "$name"

    # (POSSIBLY) BEST BY ALL METRICS: cpu decode, gpu encode
    #
    # This fixes the sync issue, has low CPU use, full GPU encoding,
    # and is actually faster than the pure GPU version.
    ffmpeg -y \
           -ss "$keyframe_seek" -i "$file" \
           -ss "$offset" -t "$duration" \
           -c:v h264_nvenc \
           -movflags +faststart \
           "$name"
}

function crop {
    ffmpeg -y -i "$1" -c:a copy -vf "crop=494:530:0:0" "$2"
}
function crop2 {
    echo "crop=$3:$4:0:0"
    ffmpeg -y -i "$1" -c:a copy -vf "crop=$3:$4:0:0" "$2"
}

