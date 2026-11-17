#!/bin/bash
# parc-sync.sh — synchronise le repo partage puis applique deploy.sh si changement.
# Appele par parc-sync.timer (systemd) toutes les 5 min.
# Ne redemarre Klipper que si aucune impression n'est en cours.
REPO=/home/pi/parc-config
LOG="logger -t parc-sync"

cd "$REPO" || exit 1
git fetch origin -q 2>/dev/null || exit 0
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
MARKER=/home/pi/printer_data/config/.parc_deployed
DEPLOYED=$(cat "$MARKER" 2>/dev/null)

if [ "$LOCAL" != "$REMOTE" ]; then
    $LOG "mise a jour $LOCAL -> $REMOTE"
    git pull --ff-only -q origin main || { $LOG "pull echoue"; exit 1; }
    LOCAL=$(git rev-parse HEAD)
fi

# Rien a deployer si ce commit a deja ete applique
[ "$LOCAL" = "$DEPLOYED" ] && exit 0

# Reprise sur coupure en attente/en cours : ne JAMAIS deployer ni
# redemarrer — la sequence POWER_RESUME_PRINT est longue et hors print SD.
if grep -q 'power_loss_active = 1' /home/pi/printer_data/config/variables.cfg 2>/dev/null; then
    $LOG "power_loss_active=1 - deploy+restart reports"
    exit 0
fi

if bash "$REPO/host/deploy.sh"; then
    echo "$LOCAL" > "$MARKER"
    $LOG "deploy.sh applique ($LOCAL)"
else
    $LOG "deploy.sh en ECHEC ($LOCAL) - klipper non redemarre"
    exit 1
fi

# Redemarrage Klipper seulement si machine vraiment inactive : print_stats
# 'standby' ne suffit pas — POWER_RESUME_PRINT et autres longues macros
# tournent hors print SD mais gardent les heaters actifs.
state=$(curl -s --max-time 5 'http://localhost:7125/printer/objects/query?print_stats&extruder&heater_bed' \
  | python3 -c 'import json,sys
s=json.load(sys.stdin)["result"]["status"]
busy = s["print_stats"]["state"] not in ("standby","complete","cancelled","error") \
    or s["extruder"]["target"] > 0 or s["heater_bed"]["target"] > 0
print("busy" if busy else "idle")' 2>/dev/null)
if [ "$state" = "idle" ]; then
    sudo -n systemctl restart klipper && $LOG "klipper redemarre (etat=$state)"
else
    $LOG "klipper NON redemarre (machine active: $state) - pris en charge au prochain boot"
fi
