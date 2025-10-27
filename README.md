# Audit-WiFi — Sprint 0

Audit-WiFi prépare le terrain pour une plate-forme d'audit WPA/WPA2-PSK. Ce sprint initialise une ossature propre : dépôt git structuré, vérifications d'environnement minimales, journalisation JSON homogène et gestion centralisée d'un unique potfile pour le cracking.

## Prérequis
- Linux ou WSL avec accès aux outils de sécurité courants (hashcat, hcxdumptool, etc.)
- Python 3.10+
- Accès sudo pour l'installation de dépendances système
- Git pour la gestion du dépôt

## Démarrage rapide
1. Vérifier que la machine dispose des dépendances minimales :
   ```bash
   bash scripts/env_check.sh
   ```
2. Lancer un plan d'exécution en mode PSK pour valider la configuration :
   ```bash
   bash scripts/run_plan.sh --profile cpu --mode psk \
     --hash hashes/target.22000 --ssid "SSID_DEMO" --dry-run
   ```
3. Une fois les prérequis confirmés, exécuter sans `--dry-run` pour lancer l'attaque.

## Structure du dépôt
- `config/` — Gabarits de configuration et profils matériels.
- `lists/` — Wordlists et dictionnaires utilisés pour le cracking.
- `rules/` — Règles hashcat personnalisées.
- `scripts/` — Automatisation des vérifications, du lancement de campagnes et de l'analyse.
- `potfile.txt` — Potfile unique pour stocker les couples SSID/mot de passe récupérés.

## Scripts principaux
| Script | Rôle |
| --- | --- |
| `scripts/env_check.sh` | Vérifie la présence des binaires critiques (hashcat, python, tmux) et leur version. |
| `scripts/run_plan.sh` | Orchestration d'une session d'attaque PSK. Gère le profil matériel (`--profile`), le mode (`--mode`), la lecture des hachés (`--hash`) et le SSID cible (`--ssid`). |

Consultez chaque script avec `--help` pour la liste complète des options disponibles.

## Bonnes pratiques
- Conserver `potfile.txt` sous contrôle de version pour éviter les doublons et faciliter l'analyse des mots de passe trouvés.
- Documenter toute modification de configuration dans le journal de sprint ou les commits correspondants.
- Respecter la journalisation JSON pour que les pipelines de collecte puissent exploiter les traces.

## Étapes suivantes
Les sprints suivants étendront la prise en charge des attaques WPA-Enterprise, enrichiront la CI/CD et ajouteront la génération de rapports automatisés.
