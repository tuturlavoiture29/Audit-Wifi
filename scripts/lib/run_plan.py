#!/usr/bin/env python3
"""Execute plan.yml against configured targets with resume and logging support."""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Tuple

try:  # pragma: no cover - optional dependency
    import yaml  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - optional dependency
    yaml = None


class RunPlanError(Exception):
    """Base class for execution errors."""

    def __init__(self, message: str, *, code: int = 1, extra: Dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.extra = extra or {}


class StageExecutionError(RunPlanError):
    """Raised when a stage command fails."""


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Execute plan with logging and resume support")
    parser.add_argument("--config", default="config/config.yaml", help="Path to config YAML")
    parser.add_argument("--plan", default="plan.yml", help="Path to plan YAML")
    parser.add_argument("--resume", action="store_true", help="Resume from previous run state")
    parser.add_argument("--safe-mode", action="store_true", help="Skip active actions")
    return parser.parse_args(list(argv))


def resolve_path(base: Path, candidate: str) -> Path:
    path = Path(candidate)
    if not path.is_absolute():
        path = (base / candidate).resolve()
    return path


def load_yaml(path: Path) -> Any:
    if not path.exists():
        raise RunPlanError(f"YAML file not found: {path}")
    with path.open("r", encoding="utf-8") as handle:
        text = handle.read()
    if yaml is not None:
        return yaml.safe_load(text) or {}
    return simple_yaml_load(text)


def simple_yaml_load(text: str) -> Any:
    tokens = tokenize_yaml(text)
    if not tokens:
        return {}
    value, index = parse_yaml_block(tokens, 0, tokens[0][0])
    if index != len(tokens):
        # consume remaining blocks if present at root
        remainder: Dict[str, Any] = {}
        if isinstance(value, dict):
            remainder.update(value)
        elif value is not None:
            return value
        while index < len(tokens):
            chunk, index = parse_yaml_block(tokens, index, tokens[index][0])
            if isinstance(chunk, dict):
                remainder.update(chunk)
        return remainder
    return value


def tokenize_yaml(text: str) -> List[Tuple[int, str]]:
    tokens: List[Tuple[int, str]] = []
    for raw_line in text.splitlines():
        stripped_comment = raw_line.split("#", 1)[0].rstrip("\n")
        stripped = stripped_comment.rstrip()
        if not stripped.strip():
            continue
        indent = len(stripped_comment) - len(stripped_comment.lstrip(" "))
        tokens.append((indent, stripped.strip()))
    return tokens


def parse_yaml_block(tokens: List[Tuple[int, str]], index: int, indent: int) -> Tuple[Any, int]:
    if index >= len(tokens):
        return {}, index
    current_indent, content = tokens[index]
    if current_indent < indent:
        return {}, index
    if content.startswith("- "):
        return parse_yaml_list(tokens, index, indent)
    return parse_yaml_dict(tokens, index, indent)


def parse_yaml_list(tokens: List[Tuple[int, str]], index: int, indent: int) -> Tuple[List[Any], int]:
    result: List[Any] = []
    while index < len(tokens):
        current_indent, content = tokens[index]
        if current_indent < indent or not content.startswith("- "):
            break
        item_content = content[2:].strip()
        index += 1
        pending_key: str | None = None
        inline_has_value = False
        if item_content:
            if (
                has_unquoted_colon(item_content)
                and not item_content.startswith("{")
                and not item_content.startswith("[")
            ):
                key, value_part = item_content.split(":", 1)
                pending_key = key.strip()
                value_part = value_part.strip()
                if value_part:
                    value: Any = {pending_key: parse_scalar(value_part)}
                    inline_has_value = True
                else:
                    value = {pending_key: None}
            else:
                value = parse_scalar(item_content)
        else:
            value = None

        if index < len(tokens):
            next_indent, _ = tokens[index]
            if next_indent > current_indent:
                nested, index = parse_yaml_block(tokens, index, next_indent)
                if pending_key and not inline_has_value:
                    if not isinstance(value, dict):
                        value = {}
                    value[pending_key] = nested
                elif isinstance(value, dict) and isinstance(nested, dict):
                    value.update(nested)
                elif value is None:
                    value = nested
                elif nested is not None:
                    value = nested
        result.append(value)
    return result, index


def parse_yaml_dict(tokens: List[Tuple[int, str]], index: int, indent: int) -> Tuple[Dict[str, Any], int]:
    result: Dict[str, Any] = {}
    while index < len(tokens):
        current_indent, content = tokens[index]
        if current_indent < indent or content.startswith("- "):
            break
        if ":" not in content:
            raise RunPlanError(f"Unable to parse line: {content}")
        key, value_part = content.split(":", 1)
        key = key.strip()
        value_part = value_part.strip()
        index += 1
        if value_part:
            value = parse_scalar(value_part)
        else:
            if index < len(tokens):
                next_indent, _ = tokens[index]
                if next_indent > current_indent:
                    value, index = parse_yaml_block(tokens, index, next_indent)
                else:
                    value = None
            else:
                value = None
        result[key] = value
    return result, index


def parse_scalar(value: str) -> Any:
    if not value:
        return ""
    if value[0] in {'"', "'"} and value[-1:] == value[0]:
        inner = value[1:-1]
        if value[0] == '"':
            return bytes(inner, "utf-8").decode("unicode_escape")
        return inner.replace("''", "'")
    lowered = value.lower()
    if lowered in {"true", "yes", "on"}:
        return True
    if lowered in {"false", "no", "off"}:
        return False
    if lowered in {"null", "none", "~"}:
        return None
    try:
        if any(ch in value for ch in ".eE"):
            return float(value)
        return int(value)
    except ValueError:
        pass
    if (value.startswith("[") and value.endswith("]")) or (
        value.startswith("{") and value.endswith("}")
    ):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def has_unquoted_colon(text: str) -> bool:
    in_single = False
    in_double = False
    for ch in text:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == ":" and not in_single and not in_double:
            return True
    return False


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def iso_now() -> str:
    return _dt.datetime.utcnow().isoformat() + "Z"


def compute_target_id(target: Dict[str, Any]) -> str:
    bssid = str(target.get("BSSID") or target.get("bssid") or "").strip()
    ssid = str(target.get("SSID") or target.get("ssid") or "").strip()
    canal = str(target.get("canal") or target.get("channel") or "").strip()
    window = str(
        target.get("timestamp-window")
        or target.get("timestamp_window")
        or target.get("window")
        or ""
    ).strip()
    if not all([bssid, ssid, canal, window]):
        raise RunPlanError(
            "Target missing one of required fields (BSSID, SSID, canal, timestamp-window)",
            extra={"target": target},
        )
    digest = hashlib.sha1(f"{bssid}|{ssid}|{canal}|{window}".encode("utf-8")).hexdigest()
    return digest


def gather_versions(repo_root: Path, plan_data: Dict[str, Any]) -> Dict[str, Any]:
    versions: Dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
    }
    try:
        git_rev = (
            subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo_root, text=True)
            .strip()
        )
        versions["git"] = git_rev
    except Exception:  # pragma: no cover - best effort only
        pass
    plan_version = plan_data.get("version")
    if plan_version:
        versions["plan"] = plan_version
    return versions


def read_status(path: Path) -> Dict[str, Any]:
    if path.exists():
        with path.open("r", encoding="utf-8") as handle:
            try:
                return json.load(handle)
            except json.JSONDecodeError:
                return {}
    return {}


def write_status(path: Path, data: Dict[str, Any]) -> None:
    ensure_dir(path.parent)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
    tmp.replace(path)


def write_jsonl(path: Path, payload: Dict[str, Any]) -> None:
    ensure_dir(path.parent)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def stage_list(target: Dict[str, Any]) -> List[Dict[str, Any]]:
    stages = target.get("stages")
    if stages is None:
        raise RunPlanError("Target is missing 'stages' definition", extra={"target": target})
    if isinstance(stages, dict):
        out: List[Dict[str, Any]] = []
        for name, details in stages.items():
            if isinstance(details, dict):
                entry = {"name": name, **details}
            else:
                entry = {"name": name, "cmd": str(details)}
            out.append(entry)
        return out
    if isinstance(stages, list):
        normalized: List[Dict[str, Any]] = []
        for idx, stage in enumerate(stages):
            if isinstance(stage, str):
                normalized.append({"name": stage, "cmd": stage})
            elif isinstance(stage, dict):
                if "name" not in stage:
                    raise RunPlanError(
                        "Each stage dictionary must include a 'name' field",
                        extra={"stage": stage, "index": idx},
                    )
                normalized.append(stage)
            else:
                raise RunPlanError("Invalid stage entry", extra={"stage": stage, "index": idx})
        return normalized
    raise RunPlanError("Unsupported stage format", extra={"stages": stages})


def normalize_cmd(stage: Dict[str, Any]) -> str:
    cmd = stage.get("cmd")
    if cmd is None:
        raise RunPlanError("Stage is missing 'cmd' attribute", extra={"stage": stage})
    return str(cmd)


def remove_lock(lock_path: Path) -> None:
    try:
        if lock_path.is_dir():
            lock_path.rmdir()
        elif lock_path.exists():
            lock_path.unlink()
    except Exception:
        pass


def acquire_lock(lock_path: Path) -> None:
    try:
        lock_path.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        raise RunPlanError(
            f"Target lock already present: {lock_path}",
            extra={"lock": str(lock_path)},
        )


def log_stage_event(
    log_path: Path,
    stage_name: str,
    target_id: str,
    cmd: str,
    versions: Dict[str, Any],
    **extra: Any,
) -> None:
    payload = {
        "ts": iso_now(),
        "stage": stage_name,
        "target_id": target_id,
        "cmd": cmd,
        "versions": versions,
    }
    payload.update(extra)
    write_jsonl(log_path, payload)


def update_status(
    status_path: Path,
    stage_name: str,
    state: str,
    status: Dict[str, Any],
    *,
    reason: str | None = None,
) -> Dict[str, Any]:
    completed: List[str] = list(status.get("completed", []))
    skipped: List[str] = list(status.get("skipped", []))
    errors: Dict[str, Any] = status.get("errors", {})

    if state == "completed":
        if stage_name not in completed:
            completed.append(stage_name)
        if stage_name in skipped:
            skipped.remove(stage_name)
        errors.pop(stage_name, None)
        status_state = "in_progress"
    elif state == "skipped":
        if stage_name not in skipped:
            skipped.append(stage_name)
        errors.pop(stage_name, None)
        status_state = "in_progress"
    elif state == "error":
        errors[stage_name] = {"ts": iso_now(), "reason": reason or ""}
        status_state = "error"
    else:
        status_state = status.get("state", "pending")

    status.update(
        {
            "completed": completed,
            "skipped": skipped,
            "errors": errors,
            "last_stage": stage_name,
            "state": status_state,
            "updated_at": iso_now(),
        }
    )
    write_status(status_path, status)
    return status


def run_stage(
    repo_root: Path,
    stage: Dict[str, Any],
    target_id: str,
    status_path: Path,
    status: Dict[str, Any],
    log_path: Path,
    versions: Dict[str, Any],
    safe_mode: bool,
) -> None:
    stage_name = str(stage["name"])
    cmd = normalize_cmd(stage)
    active = bool(stage.get("active", False))
    already_completed = stage_name in status.get("completed", [])
    already_skipped = stage_name in status.get("skipped", [])

    if already_completed or already_skipped:
        return

    if safe_mode and active:
        log_stage_event(
            log_path,
            stage_name,
            target_id,
            cmd,
            versions,
            event="skipped",
            skipped=True,
            reason="safe-mode",
        )
        update_status(status_path, stage_name, "skipped", status, reason="safe-mode")
        return

    log_stage_event(log_path, stage_name, target_id, cmd, versions, event="start")

    result = subprocess.run(
        cmd,
        shell=True,
        cwd=repo_root,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        log_stage_event(
            log_path,
            stage_name,
            target_id,
            cmd,
            versions,
            event="error",
            returncode=result.returncode,
            stdout=result.stdout,
            stderr=result.stderr,
        )
        update_status(status_path, stage_name, "error", status, reason="stage failed")
        raise StageExecutionError(
            f"Stage '{stage_name}' failed with exit code {result.returncode}",
            extra={
                "target_id": target_id,
                "stage": stage_name,
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            },
        )

    log_stage_event(
        log_path,
        stage_name,
        target_id,
        cmd,
        versions,
        event="completed",
        returncode=result.returncode,
    )
    update_status(status_path, stage_name, "completed", status)


def finalize_status(status_path: Path, status: Dict[str, Any]) -> None:
    if status.get("state") != "error":
        status.update({"state": "completed", "completed_at": iso_now()})
        write_status(status_path, status)


def process_target(
    repo_root: Path,
    target: Dict[str, Any],
    *,
    status_dir: Path,
    log_path: Path,
    locks_dir: Path,
    versions: Dict[str, Any],
    resume: bool,
    safe_mode: bool,
) -> None:
    target_id = compute_target_id(target)
    lock_path = locks_dir / f"{target_id}.lock"

    acquire_lock(lock_path)
    try:
        status_path = status_dir / f"{target_id}.json"
        if not resume and status_path.exists():
            status_path.unlink()
        status = read_status(status_path)
        stages = stage_list(target)
        for stage in stages:
            run_stage(
                repo_root,
                stage,
                target_id,
                status_path,
                status,
                log_path,
                versions,
                safe_mode,
            )
            status = read_status(status_path)
        finalize_status(status_path, status)
    finally:
        remove_lock(lock_path)


def run(argv: Iterable[str]) -> int:
    args = parse_args(argv)

    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[2]

    config_path = resolve_path(repo_root, args.config)
    plan_path = resolve_path(repo_root, args.plan)

    config_data = load_yaml(config_path)
    plan_data = load_yaml(plan_path)

    logging_cfg = config_data.get("logging", {}) if isinstance(config_data, dict) else {}
    jsonl_dir = logging_cfg.get("jsonl_dir", "logs")
    logs_path = resolve_path(repo_root, jsonl_dir)
    ensure_dir(logs_path)
    log_file = logs_path / "run_plan.events.jsonl"

    status_dir = resolve_path(repo_root, ".status")
    ensure_dir(status_dir)
    locks_dir = resolve_path(repo_root, "locks")
    ensure_dir(locks_dir)

    targets = plan_data.get("targets") if isinstance(plan_data, dict) else None
    if not targets:
        raise RunPlanError("No targets defined in plan.yml")
    if not isinstance(targets, list):
        raise RunPlanError("'targets' must be a list", extra={"targets": targets})

    versions = gather_versions(repo_root, plan_data if isinstance(plan_data, dict) else {})

    errors: List[RunPlanError] = []
    for target in targets:
        try:
            if not isinstance(target, dict):
                raise RunPlanError("Each target must be a mapping", extra={"target": target})
            process_target(
                repo_root,
                target,
                status_dir=status_dir,
                log_path=log_file,
                locks_dir=locks_dir,
                versions=versions,
                resume=args.resume,
                safe_mode=args.safe_mode,
            )
        except RunPlanError as exc:
            errors.append(exc)
            err_payload = {
                "ts": iso_now(),
                "event": "error",
                "message": str(exc),
                "extra": exc.extra,
            }
            write_jsonl(log_file, err_payload)
            print(json.dumps(err_payload, ensure_ascii=False), file=sys.stderr)
        except Exception as exc:  # pragma: no cover - defensive
            err = RunPlanError(str(exc))
            errors.append(err)
            err_payload = {
                "ts": iso_now(),
                "event": "error",
                "message": str(exc),
            }
            write_jsonl(log_file, err_payload)
            print(json.dumps(err_payload, ensure_ascii=False), file=sys.stderr)

    if errors:
        return max(error.code for error in errors)
    return 0


def emit_terminal_error(exc: RunPlanError | Exception) -> int:
    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[2]
    logs_dir = repo_root / "logs"
    ensure_dir(logs_dir)
    error_log = logs_dir / "run_plan.errors.jsonl"
    payload = {
        "ts": iso_now(),
        "event": "error",
        "message": str(exc),
    }
    if isinstance(exc, RunPlanError):
        payload["extra"] = exc.extra
    write_jsonl(error_log, payload)
    print(json.dumps(payload, ensure_ascii=False), file=sys.stderr)
    return exc.code if isinstance(exc, RunPlanError) else 1


def main() -> int:
    try:
        return run(sys.argv[1:])
    except RunPlanError as exc:
        return emit_terminal_error(exc)
    except Exception as exc:  # pragma: no cover - defensive
        return emit_terminal_error(exc)


if __name__ == "__main__":
    sys.exit(main())
