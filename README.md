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
`host/parc-sync.timer` ré-applique `deploy.sh` toutes les ~5 min si un nouveau commit arrive (et ne redémarre Klipper que machine réellement inactive : pas de print, pas de chauffe, pas de reprise `power_loss_active=1`).

## Onduleur (NUT, générique)

L'abstraction matérielle est **NUT**, pas un modèle précis — tout UPS visible
via `upsc` fonctionne (Eaton `usbhid-ups`, Voltronic/générique `nutdrv_qx` /
`blazer_usb`, réseau `snmp-ups`, etc.).

- `host/ups_bridge.py` auto-détecte le 1er UPS déclaré via `upsc -l`
  (re-détection périodique si injoignable) ; un nom peut être passé en
  argument comme hint.
- Les champs optionnels (`battery.runtime`, `ups.load`, …) non rapportés par
  le modèle valent `-1` = « indisponible » : seuils `low`/`crit` et
  `UPS_POWER_BUDGET` se dégradent proprement au lieu de fausser.
- Sans UPS : `NO_UPS`/`NOCOMM` → réactions UPS inertes, reprise sur coupure
  et checkpoints (30 s) fonctionnent quand même.
- Config par machine : `/etc/nut/ups.conf` + `nut.conf` MODE + `upsd.users`
  selon le driver du modèle branché (voir notice affichée par
  `install_parc.sh`).

**Topologie maître/esclave (plusieurs machines sur le même UPS)** :
- Le maître (UPS branché en USB) : `nut.conf MODE=netserver`,
  `upsd.conf LISTEN 0.0.0.0 3493`, un compte `upsmon slave` partageable
  par tout le parc dans `upsd.users`.
- Les esclaves : `MODE=netclient` + `MONITOR <ups>@<maitre>.local 1 <user>
  <pass> slave` dans `upsmon.conf` ; bridge avec `eaton@<maitre>.local`.
- **Toujours le hostname mDNS (`<maitre>.local`), jamais d'IP en dur** :
  l'IP DHCP peut changer. Prerequis : `libnss-mdns` installe + avahi sur
  toutes les machines (fait sur SWX21/22/23).
