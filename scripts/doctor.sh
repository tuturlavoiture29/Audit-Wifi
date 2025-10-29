#!/usr/bin/env bash
set -euo pipefail

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
results_path=${AUDIT_WIFI_RESULTS_DIR:-"$root_dir/reports"}
mkdir -p "$results_path"

declare -a output_lines=()
log() {
  local line="$1"
  echo "$line"
  output_lines+=("$line")
}

add_blank() {
  log ""
}

declare -a summary_lines=()
add_summary() {
  summary_lines+=("$1")
}

uname_out=$(uname -s 2>/dev/null || echo unknown)
is_windows=false
case "$uname_out" in
  *MINGW*|*MSYS*|*CYGWIN*|*Windows*) is_windows=true ;;
  *) is_windows=false ;;
esac

# Convert potential Windows style paths to POSIX paths if possible
to_posix_path() {
  local candidate="$1"
  if have_cmd cygpath; then
    local converted
    if converted=$(cygpath "$candidate" 2>/dev/null); then
      printf '%s' "$converted"
      return 0
    fi
  fi
  case "$candidate" in
    [A-Za-z]:\\*)
      local drive rest
      drive=${candidate:0:1}
      rest=${candidate:2}
      rest=${rest//\\/\/}
      rest=${rest#/}
      printf '/%s/%s' "${drive,,}" "$rest"
      return 0
      ;;
    [A-Za-z]:/*)
      local drive rest
      drive=${candidate:0:1}
      rest=${candidate:2}
      rest=${rest//\\/\/}
      rest=${rest#/}
      printf '/%s/%s' "${drive,,}" "$rest"
      return 0
      ;;
  esac
  printf '%s' "$candidate"
}

resolve_hashcat() {
  local cmd
  if cmd=$(command -v hashcat 2>/dev/null); then
    printf '%s' "$cmd"
    return 0
  fi
  if cmd=$(command -v hashcat.exe 2>/dev/null); then
    printf '%s' "$cmd"
    return 0
  fi
  local candidate
  for candidate in "$HOME/bin/hashcat" \
    "/c/Tools/hashcat/hashcat.exe" \
    "C:/Tools/hashcat/hashcat.exe" \
    "C:\\Tools\\hashcat\\hashcat.exe"; do
    local posix
    posix=$(to_posix_path "$candidate")
    if [ -x "$posix" ]; then
      printf '%s' "$posix"
      return 0
    fi
  done
  return 1
}

resolve_aircrack() {
  local cmd
  if cmd=$(command -v aircrack-ng 2>/dev/null); then
    printf '%s' "$cmd"
    return 0
  fi
  if cmd=$(command -v aircrack-ng.exe 2>/dev/null); then
    printf '%s' "$cmd"
    return 0
  fi
  local candidate
  for candidate in "/c/Tools/aircrack-ng/bin/aircrack-ng.exe" \
    "C:/Tools/aircrack-ng/bin/aircrack-ng.exe" \
    "C:\\Tools\\aircrack-ng\\bin\\aircrack-ng.exe"; do
    local posix
    posix=$(to_posix_path "$candidate")
    if [ -x "$posix" ]; then
      printf '%s' "$posix"
      return 0
    fi
  done
  return 1
}

ts=$(date +%Y%m%d-%H%M%S)
report_path="$results_path/doctor-$ts.txt"

hashcat_ok=false
hashcat_path=""
hashcat_version=""
hashcat_gpu_info=""
if hashcat_path=$(resolve_hashcat); then
  add_summary "hashcat: found at $hashcat_path"
  if hashcat_version=$("$hashcat_path" -V 2>&1); then
    add_summary "hashcat version: $hashcat_version"
  else
    add_summary "hashcat version: failed"
    hashcat_version=""
  fi
  if hashcat_gpu_info=$("$hashcat_path" -I 2>&1); then
    hashcat_ok=true
    add_summary "hashcat diagnostic: OK"
  else
    add_summary "hashcat diagnostic: FAIL (hashcat -I)"
    hashcat_gpu_info=""
  fi
else
  add_summary "hashcat: not found"
fi

hashcat_logged=false
if [ -n "$hashcat_version" ]; then
  add_blank
  log "hashcat version: $hashcat_version"
  hashcat_logged=true
fi
if [ -n "$hashcat_gpu_info" ]; then
  if [ "$hashcat_logged" = false ]; then
    add_blank
    hashcat_logged=true
  fi
  log "hashcat GPU info:"
  gpu_lines=$(printf '%s\n' "$hashcat_gpu_info" | awk '
    /^Device #[0-9]+/ {capture=1}
    capture && NF==0 {capture=0; print ""; next}
    capture {print}
  ')
  if [ -z "$gpu_lines" ]; then
    gpu_lines="$hashcat_gpu_info"
  fi
  while IFS= read -r line; do
    log "  $line"
  done <<< "$gpu_lines"
fi

hcxtools_ok=false
version_output=""
if have_cmd hcxpcapngtool; then
  hcxtools_ok=true
  version_output=$(hcxpcapngtool --version 2>&1 || true)
  add_summary "hcxpcapngtool: OK"
  if [ -n "$version_output" ]; then
    add_blank
    log "hcxpcapngtool --version:"
    while IFS= read -r line; do
      log "  $line"
    done <<< "$version_output"
  fi
else
  add_summary "hcxpcapngtool: not found"
fi

aircrack_ok=false
aircrack_path=""
if aircrack_path=$(resolve_aircrack); then
  aircrack_ok=true
  aircrack_version=$("$aircrack_path" --help 2>&1 | head -n1 || true)
  add_summary "aircrack-ng: found at $aircrack_path"
  if [ -n "$aircrack_version" ]; then
    add_blank
    log "aircrack-ng version: $aircrack_version"
  fi
else
  add_summary "aircrack-ng: not found"
fi

cuda_state="null"
cuda_message="CUDA tools: not present"
if have_cmd nvidia-smi; then
  if nvidia-smi >/dev/null 2>&1; then
    cuda_state="true"
    cuda_message="CUDA tools: OK"
  else
    cuda_state="false"
    cuda_message="CUDA tools: nvidia-smi failed"
  fi
else
  cuda_state="false"
fi
add_summary "$cuda_message"

disk_kb=0
if df -Pk "$results_path" >/dev/null 2>&1; then
  disk_kb=$(df -Pk "$results_path" | awk 'NR==2 {print $4}')
fi

disk_gb=$(awk -v kb="$disk_kb" 'BEGIN {printf "%.2f", kb/1048576}')
min_disk_gb=${MIN_RESULTS_GB:-5}
if awk -v have="$disk_gb" -v need="$min_disk_gb" 'BEGIN {exit !(have >= need)}'; then
  disk_ok=true
  add_summary "Disk space: ${disk_gb} GiB free (>= ${min_disk_gb} GiB)"
else
  disk_ok=false
  add_summary "Disk space: ${disk_gb} GiB free (< ${min_disk_gb} GiB)"
fi

if $is_windows; then
  if have_cmd powershell.exe || have_cmd powershell; then
    add_summary "PowerShell: OK"
  else
    add_summary "PowerShell: not found"
  fi
else
  add_summary "PowerShell check skipped (not Windows)"
fi

add_blank
log "Audit-WiFi doctor summary (results: $results_path)"
for line in "${summary_lines[@]}"; do
  log " - $line"

done

core_ok=$hashcat_ok

json=$(python3 - "$core_ok" "$hashcat_ok" "$hcxtools_ok" "$aircrack_ok" "$cuda_state" "$disk_gb" <<'PY'
import json
import sys

core_ok, hashcat_ok, hcxtools_ok, aircrack_ok, cuda_state, disk_gb = sys.argv[1:7]

def to_bool(value):
    return value.lower() == 'true'

cuda = None if cuda_state.lower() == 'null' else to_bool(cuda_state)

payload = {
    "ok": to_bool(core_ok),
    "checks": {
        "hashcat": to_bool(hashcat_ok),
        "hcxtools": to_bool(hcxtools_ok),
        "aircrack": to_bool(aircrack_ok),
        "cuda": cuda,
        "disk_gb": float(disk_gb),
    },
}

print(json.dumps(payload))
PY
)

log ""
log "$json"

printf '%s\n' "${output_lines[@]}" > "$report_path"

if [ "$hashcat_ok" = true ]; then
  exit 0
else
  exit 1
fi
