#!/usr/bin/env bash
set -euo pipefail

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
results_path=${AUDIT_WIFI_RESULTS_DIR:-"$root_dir/reports"}
mkdir -p "$results_path"

declare -a summary_lines=()
add_summary() {
  summary_lines+=("$1")
}

hashcat_ok=false
if have_cmd hashcat; then
  if hashcat -I >/dev/null 2>&1; then
    hashcat_ok=true
    add_summary "hashcat: OK"
  else
    add_summary "hashcat: FAIL (hashcat -I)"
  fi
else
  add_summary "hashcat: not found"
fi

hcxtools_ok=false
if have_cmd hcxpcapngtool; then
  hcxtools_ok=true
  add_summary "hcxtools (hcxpcapngtool): OK"
else
  add_summary "hcxtools (hcxpcapngtool): not found"
fi

aircrack_ok=false
if have_cmd aircrack-ng; then
  aircrack_ok=true
  add_summary "aircrack-ng: OK"
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

if df -Pk "$results_path" >/dev/null 2>&1; then
  disk_kb=$(df -Pk "$results_path" | awk 'NR==2 {print $4}')
else
  disk_kb=0
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

uname_out=$(uname -s 2>/dev/null || echo unknown)
is_windows=false
case "$uname_out" in
  *MINGW*|*MSYS*|*CYGWIN*|*Windows*) is_windows=true ;;
  *) is_windows=false ;;
esac

if $is_windows; then
  if have_cmd powershell.exe || have_cmd powershell; then
    add_summary "PowerShell: OK"
  else
    add_summary "PowerShell: not found"
  fi
else
  add_summary "PowerShell check skipped (not Windows)"
fi

printf 'Audit-WiFi doctor summary (results: %s)\n' "$results_path"
for line in "${summary_lines[@]}"; do
  printf ' - %s\n' "$line"
done

core_ok=true
for flag in "$hashcat_ok" "$hcxtools_ok" "$aircrack_ok" "$disk_ok"; do
  if [ "$flag" != "true" ]; then
    core_ok=false
    break
  fi
done

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

echo "$json"

if [ "$core_ok" = true ]; then
  exit 0
else
  exit 1
fi
