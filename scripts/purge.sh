#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: purge.sh --path <directory> --older-days <days> [--dry-run] [--confirm]

Options:
  --path         Directory to purge files from.
  --older-days   Purge files older than the specified number of days.
  --dry-run      Show the actions that would be taken without moving any files.
  --confirm      Required to perform the purge (skipped for --dry-run).
  -h, --help     Show this help message and exit.
USAGE
}

path=""
older_days=""
dry_run=false
confirm=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || { echo "Missing value for --path" >&2; exit 1; }
      path="$2"
      shift 2
      ;;
    --older-days)
      [[ $# -ge 2 ]] || { echo "Missing value for --older-days" >&2; exit 1; }
      older_days="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --confirm)
      confirm=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$path" || -z "$older_days" ]]; then
  echo "--path and --older-days are required." >&2
  usage >&2
  exit 1
fi

if ! [[ "$older_days" =~ ^[0-9]+$ ]]; then
  echo "--older-days must be a non-negative integer." >&2
  exit 1
fi

if [[ ! -d "$path" ]]; then
  echo "The path '$path' does not exist or is not a directory." >&2
  exit 1
fi

path_abs="$(realpath "$path")"
archive_root="$path_abs/archive"
journal_path="$path_abs/purge-journal.jsonl"
run_timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
archive_batch_dir="$archive_root/$run_timestamp"

if [[ "$dry_run" == false && "$confirm" == false ]]; then
  echo "This operation moves files irreversibly. Re-run with --confirm to proceed." >&2
  exit 1
fi

removed_by="$(whoami)"

mapfile -d '' -t files_to_purge < <(find "$path_abs" \
  \( -path "$archive_root" -o -path "$archive_root/*" -o -path "$journal_path" \) -prune -o \
  -type f -mtime +"$older_days" -print0)

if [[ ${#files_to_purge[@]} -eq 0 ]]; then
  echo "No files older than $older_days days found in $path_abs."
  exit 0
fi

if [[ "$dry_run" == true ]]; then
  echo "Dry run: the following files would be moved to $archive_batch_dir:"
else
  mkdir -p "$archive_batch_dir"
fi

files_processed=0

for file in "${files_to_purge[@]}"; do
  rel_path="${file#"$path_abs/"}"
  target_path="$archive_batch_dir/$rel_path"
  entry_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  sha="$(sha256sum "$file" | awk '{print $1}')"

  if [[ "$dry_run" == true ]]; then
    echo "- $file -> $target_path (sha256: $sha)"
  else
    mkdir -p "$(dirname "$target_path")"
    mv "$file" "$target_path"
    json_line=$(ORIGINAL_PATH="$file" ARCHIVED_PATH="$target_path" \
      ENTRY_TIMESTAMP="$entry_timestamp" SHA256="$sha" REMOVED_BY="$removed_by" python3 - <<'PY'
import json, os
print(json.dumps({
    "original_path": os.environ["ORIGINAL_PATH"],
    "archived_path": os.environ["ARCHIVED_PATH"],
    "timestamp": os.environ["ENTRY_TIMESTAMP"],
    "sha256": os.environ["SHA256"],
    "removed_by": os.environ["REMOVED_BY"]
}))
PY
)
    printf '%s\n' "$json_line" >> "$journal_path"
  fi
  ((++files_processed))
done

if [[ "$dry_run" == true ]]; then
  echo "Total files that would be processed: $files_processed"
else
  echo "Moved $files_processed files to $archive_batch_dir"
  echo "Journal updated at $journal_path"
fi
