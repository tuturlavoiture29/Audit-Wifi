# audit-wifi — Sprint 0

Objectif Sprint 0 : ossature propre (repo, CI minimale, journalisation JSON, potfile unique) pour lancer PSK S1→S2 au Sprint 1.

## Démarrage rapide
```bash
bash scripts/env_check.sh
bash scripts/run_plan.sh --profile cpu --mode psk \
  --hash hashes/target.22000 --ssid "SSID_DEMO" --dry-run
