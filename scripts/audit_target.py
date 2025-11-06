#!/usr/bin/env python3
"""Interactive helper to audit a single WPA-PSK target.

The goal is to produce a temporary plan for :mod:`run_plan.py` without forcing
the operator to edit YAML manually.  The script checks that prerequisite files
exist, generates a minimal plan tailored to the provided target identifier, and
invokes the existing orchestration wrapper.  At the end of the run it prints a
small summary (using ``hashcat --show`` when available) so the operator knows
whether a password was recovered.
"""
from __future__ import annotations

import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parents[1]
HASHES_DIR = REPO_ROOT / "hashes"
WORDLISTS_DIR = REPO_ROOT / "wordlists" / "targets"
LISTS_DIR = REPO_ROOT / "lists"
RULES_DIR = REPO_ROOT / "rules"
PLANS_DIR = REPO_ROOT / ".plans"
RESULTS_DIR = REPO_ROOT / "results"
LOGS_DIR = REPO_ROOT / "logs"
POTFILE_PATH = REPO_ROOT / "potfile.txt"


def prompt(message: str, *, default: Optional[str] = None) -> str:
    """Prompt the user and return the response (or default when empty)."""

    if default and "[" not in message:
        prompt_text = f"{message} [{default}] "
    else:
        prompt_text = f"{message} "
    try:
        response = input(prompt_text)
    except EOFError:  # pragma: no cover - interactive fallback
        response = ""
    response = response.strip()
    if not response and default is not None:
        return default
    return response


def ensure_directories() -> None:
    """Create directories required by the workflow."""

    for path in (HASHES_DIR, WORDLISTS_DIR, LISTS_DIR, RULES_DIR, PLANS_DIR, RESULTS_DIR, LOGS_DIR):
        path.mkdir(parents=True, exist_ok=True)


def parse_hash_info(hash_path: Path) -> Tuple[Optional[str], Optional[str]]:
    """Attempt to extract the BSSID and SSID from a 22000 hash file."""

    try:
        first_line = hash_path.read_text(encoding="utf-8", errors="ignore").splitlines()[0]
    except (IndexError, FileNotFoundError):
        return None, None

    parts = first_line.split("*")
    if len(parts) < 5 or parts[0] != "WPA":
        return None, None

    bssid_hex = parts[2].strip()
    essid_hex = parts[4].strip()

    bssid = None
    if len(bssid_hex) == 12:
        try:
            bssid = ":".join(bssid_hex[i : i + 2] for i in range(0, 12, 2)).lower()
        except ValueError:
            bssid = None

    ssid = None
    if essid_hex:
        try:
            ssid_bytes = bytes.fromhex(essid_hex)
            ssid = ssid_bytes.decode("utf-8", errors="ignore") or None
        except ValueError:
            ssid = None

    return bssid, ssid


def convert_capture(target_id: str, hash_path: Path) -> bool:
    """Optionally convert a capture file into a Hashcat 22000 hash."""

    capture_default = REPO_ROOT / "captures" / f"{target_id}.pcapng"
    print(f"Aucun hash trouvé pour '{target_id}'.")
    choice = prompt("Convertir un fichier .pcapng en hash 22000 ? (y/N)", default="N").lower()
    if choice not in {"y", "yes"}:
        return False

    capture_input = prompt("Chemin du fichier .pcapng", default=str(capture_default))
    capture_path = Path(capture_input).expanduser().resolve()
    if not capture_path.exists():
        print(f"Fichier de capture introuvable: {capture_path}")
        return False

    hash_path.parent.mkdir(parents=True, exist_ok=True)
    convert_script = REPO_ROOT / "scripts" / "convert_capture.sh"
    cmd = [str(convert_script), "--in", str(capture_path), "--out", str(hash_path)]
    print("Conversion en cours...")
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    if result.returncode != 0:
        print("La conversion a échoué. Consultez les logs pour plus de détails.")
        return False

    if not hash_path.exists():
        print("Le fichier hash attendu n'a pas été généré.")
        return False

    print(f"Hash généré: {hash_path}")
    return True


def build_hashcat_command(
    stage_name: str,
    hash_path: Path,
    attack_mode: str,
    args: Tuple[str, ...],
    *,
    target_id: str,
    skip_message: Optional[str] = None,
    required_files: Tuple[Path, ...] = (),
) -> str:
    """Create a shell command string that runs hashcat with project defaults."""

    session_name = f"{target_id}-{stage_name}"
    outfile = RESULTS_DIR / target_id / f"{stage_name}.out"
    logfile = LOGS_DIR / f"hashcat-{target_id}-{stage_name}.log"

    base_args = [
        "hashcat",
        "-m",
        "22000",
        "--session",
        session_name,
        "--status",
        "--status-timer",
        "30",
        "--potfile-path",
        str(POTFILE_PATH.relative_to(REPO_ROOT)),
        "--logfile-path",
        str(logfile.relative_to(REPO_ROOT)),
        "--outfile",
        str(outfile.relative_to(REPO_ROOT)),
        "--outfile-format",
        "2,3,4,5",
        "--outfile-autohex-disable",
        "-a",
        attack_mode,
        str(hash_path.relative_to(REPO_ROOT)),
    ]
    base_args.extend(args)

    command = " ".join(shlex.quote(str(arg)) for arg in base_args)

    if required_files:
        tests = " && ".join(
            f"[ -f {shlex.quote(str(path.relative_to(REPO_ROOT)))} ]" for path in required_files
        )
        command = f"if {tests}; then {command};"
        if skip_message:
            command += f" else echo {shlex.quote(skip_message)} >&2; fi"
        else:
            command += " else exit 0; fi"
    return command


def create_plan(
    target_id: str,
    hash_path: Path,
    bssid: str,
    ssid: str,
    channel: str,
    time_window: str,
    wordlist_path: Path,
) -> dict[str, object]:
    """Build the in-memory representation of the plan."""

    rules_lite = RULES_DIR / "rules-fr-lite.rule"
    numbers_suffix = LISTS_DIR / "numbers_suf.txt"
    smart_top = LISTS_DIR / "smart-top.txt"

    stages = []

    dict_args = [str(wordlist_path.relative_to(REPO_ROOT))]
    if rules_lite.exists():
        dict_args.extend(["-r", str(rules_lite.relative_to(REPO_ROOT))])
    stage1 = {
        "name": "S1-dict-lite",
        "cmd": build_hashcat_command(
            "S1-dict-lite",
            hash_path,
            "0",
            tuple(dict_args),
            target_id=target_id,
            skip_message="Wordlist ciblée introuvable, étape ignorée.",
            required_files=(wordlist_path,),
        ),
    }
    stages.append(stage1)

    stage2 = {
        "name": "S2-combinator",
        "cmd": build_hashcat_command(
            "S2-combinator",
            hash_path,
            "1",
            (
                str(wordlist_path.relative_to(REPO_ROOT)),
                str(numbers_suffix.relative_to(REPO_ROOT)),
            ),
            target_id=target_id,
            skip_message="Wordlist ciblée ou numbers_suf.txt introuvable, étape combinator ignorée.",
            required_files=(wordlist_path, numbers_suffix),
        ),
    }
    stages.append(stage2)

    stage3 = {
        "name": "S3-smart-top",
        "cmd": build_hashcat_command(
            "S3-smart-top",
            hash_path,
            "0",
            (str(smart_top.relative_to(REPO_ROOT)),),
            target_id=target_id,
            skip_message="Liste smart-top introuvable, étape ignorée.",
            required_files=(smart_top,),
        ),
    }
    stages.append(stage3)

    plan = {
        "version": "1.0",
        "targets": [
            {
                "name": target_id,
                "BSSID": bssid,
                "SSID": ssid,
                "canal": channel,
                "timestamp-window": time_window,
                "stages": stages,
            }
        ],
    }
    return plan


def run_plan(plan_path: Path) -> int:
    """Invoke the run_plan.sh helper with the generated plan."""

    cmd = [
        str(REPO_ROOT / "scripts" / "run_plan.sh"),
        "--config",
        str(REPO_ROOT / "config" / "config.yaml"),
        "--plan",
        str(plan_path),
    ]
    print("\nLancement de run_plan.sh...")
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    if result.returncode != 0:
        print("run_plan.sh s'est terminé avec un code d'erreur.")
    return result.returncode


def show_summary(hash_path: Path) -> None:
    """Display a short summary based on hashcat --show output."""

    hashcat = shutil.which("hashcat")
    if hashcat is None:
        print("hashcat introuvable dans le PATH, impossible de générer un résumé.")
        return

    cmd = [
        hashcat,
        "--show",
        "-m",
        "22000",
        str(hash_path),
        "--potfile-path",
        str(POTFILE_PATH),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = result.stdout.strip()
    print("\n=== Résumé ===")
    if result.returncode != 0:
        print("Impossible de vérifier les résultats (hashcat --show a échoué).");
        if result.stderr:
            print(result.stderr.strip())
        return

    if output:
        print("Mot de passe trouvé !")
        print(output)
    else:
        print("Aucun mot de passe trouvé pour le moment.")


def main() -> int:
    ensure_directories()

    target_id = prompt(
        "Nom de la cible (par ex. le nom du fichier dans hashes/, sans .hc22000. Exemple : livbag) :"
    ).strip()
    if not target_id:
        print("Aucune cible fournie, arrêt.")
        return 1

    hash_path = HASHES_DIR / f"{target_id}.hc22000"
    if not hash_path.exists():
        if not convert_capture(target_id, hash_path):
            print(
                "Impossible de poursuivre sans hash 22000. "
                "Assurez-vous d'avoir un fichier dans hashes/<cible>.hc22000."
            )
            return 1

    wordlist_path = WORDLISTS_DIR / f"{target_id}.txt"
    if not wordlist_path.exists():
        print(
            "⚠️ Wordlist manquante : "
            f"{WORDLISTS_DIR.relative_to(REPO_ROOT) / f'{target_id}.txt'}\n"
            "→ Pour la générer, utilisez :\n"
            "   scripts/build_target_wordlist.sh --src raw/ --out "
            f"wordlists/targets/{target_id}.txt\n"
            "Vous pouvez continuer sans, mais les attaques ciblées ne fonctionneront pas."
        )

    bssid, ssid = parse_hash_info(hash_path)

    if not bssid:
        bssid = prompt(
            "BSSID [00:00:00:00:00:00] (laissez vide pour utiliser une valeur factice)",
            default="00:00:00:00:00:00",
        )
    if not ssid:
        ssid = prompt("SSID", default=target_id)

    channel = prompt(
        "Canal Wi-Fi [1] (laissez vide si inconnu)",
        default="1",
    )
    time_window = prompt(
        "Fenêtre temporelle [auto] (auto = utiliser timestamp du hash)",
        default="auto",
    )

    plan = create_plan(target_id, hash_path, bssid, ssid, channel, time_window, wordlist_path)

    target_results_dir = RESULTS_DIR / target_id
    target_results_dir.mkdir(parents=True, exist_ok=True)

    plan_path = PLANS_DIR / f"{target_id}.yml"
    plan_path.write_text(json.dumps(plan, indent=2), encoding="utf-8")
    print(f"Plan écrit dans {plan_path}")

    rc = run_plan(plan_path)
    print(
        f"\n✅ Audit lancé pour la cible '{target_id}'\n"
        f"→ Résultats dans : results/{target_id}/\n"
        f"→ Potfile : results/{target_id}/hashcat.potfile\n"
        f"→ Journal : results/{target_id}/logs.jsonl\n\n"
        f"Lancez `tail -f results/{target_id}/logs.jsonl` pour suivre l'audit en direct."
    )
    if rc == 0:
        show_summary(hash_path)
    else:
        print("Exécution interrompue. Consultez les logs pour plus de détails.")
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:  # pragma: no cover - interactive convenience
        print("\nInterruption utilisateur.")
        sys.exit(1)
