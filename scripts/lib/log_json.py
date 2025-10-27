#!/usr/bin/env python3
"""Append one JSON line to a file. Usage: log_json.py --file path key=value ..."""
from __future__ import annotations
import argparse, json, sys, datetime

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--file", required=True)
    p.add_argument("kv", nargs="*")
    args = p.parse_args()

    record = {k: v for k, v in (kv.split("=", 1) for kv in args.kv)}
    record.setdefault("ts", datetime.datetime.utcnow().isoformat() + "Z")
    line = json.dumps(record, ensure_ascii=False)
    with open(args.file, "a", encoding="utf-8") as f:
        f.write(line + "\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
