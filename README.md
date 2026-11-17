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

**Failover automatique du maître** (`host/ups-role.sh` + `ups-role.timer`,
tous les ~60 s, root) :
- Un UPS USB present -> `master:<VID>:<PID>` : `nut.conf netserver`,
  `ups.conf [ups]` avec le driver choisi selon le VID (`usbhid-ups`,
  `nutdrv_qx`, `blazer_usb`...), `upsd LISTEN 0.0.0.0`, mot de passe slave
  genere aleatoirement, annonce Avahi `_nut._tcp` (TXT `secret=<mdp>`,
  `serial=`).
- Pas d'UPS USB -> `slave:<maitre>.local` : decouverte du maître par
  `avahi-browse _nut._tcp` — **seuls les services annoncant le secret parc
  sont acceptes** (les NUT etrangers du LAN sont ignores) — puis
  `upsmon.conf` et `ups_bridge` sont reecrits vers `<maitre>.local`.
- Aucun maître visible -> `none` (bridge pousse `NO_UPS`).
- Consequence : **l'UPS suit le cable** — debrancher l'USB d'un pad et le
  rebrancher sur un autre fait basculer tout le parc tout seul (~2 min).
  Teste SWX21 -> 22 -> 23 -> 21.
- Multi-UPS : chaque pad avec un UPS est maître du sien ; un esclave qui
  voit plusieurs maîtres tranche via `/etc/nut/parc-ups-pref` (hostname).

## Canal slicer -> Klipper (OrcaSlicer)

Le contrat existe dans le start G-code des profils (SWX21/22/23/GENIUSY) :

```gcode
PRINT_START MATERIAL=[filament_type] BED_SURFACE=COOL|ENG|SMOOTH|PEI ...
```

`PRINT_START` appelle `SET_MATERIAL`/`SET_SURFACE`
(`macros/utilities/slicer_channel.cfg`) : les valeurs sont persistees et
capturees par les checkpoints power-loss. `SET_SURFACE` marque
`cold_release=1` pour toute plaque non rigide (PEI, Ziflex/SMOOTH, COOL,
inconnu) -> a la reprise, si le lit a refroidi sous 60 % de la cible,
`POWER_RESUME_PRINT` avertit que la piece a pu se decoller avant de bouger.

Appel manuel possible : `SET_SURFACE TYPE=ziflex_hightemp`,
`SET_MATERIAL NAME=PETG`.

## Prompts utilisateur (`macros/utilities/user_prompts.cfg`)

`NOTIFY TYPE= MSG= COPY=` (console + M117 + commande copiable),
`CONFIRM MSG=` (notification + M0 -> RESUME), `CHOICE TITLE= OPTIONS=`,
`INPUT_NUMBER` (resultats dans `_USER_INPUT.choice`/`.value`), `PROGRESS`.
Aucun de ces prompts ne declenche de mouvement ou de reprise automatique :
ils pausent et attendent une action humaine explicite.
