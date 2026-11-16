# klipper-parc-config

Configuration Klipper de référence pour le parc d'imprimantes (SWX21/22/23, Geniusy).

Contenu **partagé uniquement** — aucun fichier machine-spécifique :
- `macros/` : bibliothèque de macros commune (purge, pause/resume, start/end, UPS, sécurité…)
- `Klipper-Adaptive-Meshing-Purging/Configuration/` : réglages KAMP (mesh adaptatif)
- `ups.cfg` : contrat + watchdog onduleur (`_UPS_DATA`, `UPS_POWER_BUDGET`, reprise auto)
- `host/ups_bridge.py` : pont NUT → Klipper

## Exclus volontairement

`printer.cfg`, `machine/*_hardware.cfg`, `variables.cfg`, `moonraker.conf`, secrets, sauvegardes.

## Sur chaque pad

```
[update_manager parc-config]
type: git_repo
origin: <URL du repo privé>
path: /home/pi/parc-config
primary_branch: main
managed_services: klipper
install_script: /home/pi/parc-config/host/deploy.sh
```

`host/deploy.sh` synchronise le contenu du repo vers `~/printer_data/config/` après chaque update Mainsail.
