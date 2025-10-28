#!/bin/sh
# Convert capture files to Hashcat 22000 format using hcxtools utilities.

usage() {
    cat <<'USAGE'
Usage: convert_capture.sh --in /path/file.pcapng --out /path/target.22000
Options:
  --in PATH    Input capture file (.pcapng)
  --out PATH   Output hash file (.22000)
  --help       Show this help message
USAGE
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

LOG_DIR=logs
LOG_FILE=""

init_log_file() {
    if [ -n "$LOG_FILE" ]; then
        return
    fi
    mkdir -p "$LOG_DIR"
    log_ts=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/convert-${log_ts}.jsonl"
}

log_result() {
    ts=$1
    cmd=$2
    input_path=$3
    output_path=$4
    size=$5
    result=$6
    output_msg=$7
    error_msg=$8

    init_log_file

    esc_cmd=$(json_escape "$cmd")
    esc_input=$(json_escape "$input_path")
    esc_output=$(json_escape "$output_path")
    esc_outmsg=$(json_escape "$output_msg")
    esc_error=$(json_escape "$error_msg")

    printf '{"ts":"%s","cmd":"%s","input":"%s","output":"%s","size":%s,"result":"%s","error":"%s","tool_output":"%s"}\n' \
        "$ts" "$esc_cmd" "$esc_input" "$esc_output" "$size" "$result" "$esc_error" "$esc_outmsg" >> "$LOG_FILE"
}

in_path=""
out_path=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --in)
            shift
            if [ $# -eq 0 ]; then
                printf 'Missing value for --in\n' >&2
                usage >&2
                exit 1
            fi
            in_path="$1"
            ;;
        --out)
            shift
            if [ $# -eq 0 ]; then
                printf 'Missing value for --out\n' >&2
                usage >&2
                exit 1
            fi
            out_path="$1"
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$in_path" ] || [ -z "$out_path" ]; then
    printf 'Both --in and --out must be provided.\n' >&2
    usage >&2
    exit 1
fi

if [ ! -f "$in_path" ]; then
    printf 'Input file not found: %s\n' "$in_path" >&2
    exit 1
fi

if command -v hcxpcapngtool >/dev/null 2>&1; then
    tool_cmd="hcxpcapngtool"
elif command -v hcxtools >/dev/null 2>&1; then
    tool_cmd="hcxtools"
else
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_result "$ts" "" "$in_path" "$out_path" 0 "failure" "" "hcxtools-missing"
    printf "{\"error\":\"hcxtools-missing\"}\\n"
    exit 2
fi

out_dir=$(dirname "$out_path")
if [ ! -d "$out_dir" ]; then
    if ! mkdir -p "$out_dir"; then
        printf 'Unable to create output directory: %s\n' "$out_dir" >&2
        exit 1
    fi
fi

essid_path="${out_path%.*}.essidlist"
rm -f "$out_path" "$essid_path"

primary_cmd="$tool_cmd -o \"$out_path\" -E \"$essid_path\" \"$in_path\""
fallback_cmd="$tool_cmd -o \"$out_path\" \"$in_path\""

conv_status=1
combined_output=""
selected_cmd="$primary_cmd"

# capture command output for diagnostics
tmp_output=$(mktemp)
trap 'rm -f "$tmp_output"' EXIT HUP INT TERM

if "$tool_cmd" -o "$out_path" -E "$essid_path" "$in_path" >"$tmp_output" 2>&1; then
    conv_status=0
    combined_output=$(cat "$tmp_output")
else
    first_status=$?
    first_output=$(cat "$tmp_output")
    if "$tool_cmd" -o "$out_path" "$in_path" >"$tmp_output" 2>&1; then
        conv_status=0
        second_output=$(cat "$tmp_output")
        selected_cmd="$primary_cmd ; fallback: $fallback_cmd"
        combined_output="primary exit $first_status: $first_output\nfallback: $second_output"
    else
        second_status=$?
        second_output=$(cat "$tmp_output")
        selected_cmd="$primary_cmd ; fallback: $fallback_cmd"
        combined_output="primary exit $first_status: $first_output\nfallback exit $second_status: $second_output"
    fi
fi

rm -f "$tmp_output"

if [ $conv_status -ne 0 ] || [ ! -s "$out_path" ]; then
    rm -f "$out_path" "$essid_path"
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_result "$ts" "$selected_cmd" "$in_path" "$out_path" 0 "failure" "$combined_output" "conversion-failed"
    printf "{\"error\":\"conversion-failed\"}\\n"
    exit 3
fi

size=$(wc -c < "$out_path" 2>/dev/null || printf '0')
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log_result "$ts" "$selected_cmd" "$in_path" "$out_path" "$size" "success" "$combined_output" ""

out_json=$(json_escape "$out_path")
printf "{\"result\":\"ok\",\"output\":\"%s\"}\\n" "$out_json"
exit 0
