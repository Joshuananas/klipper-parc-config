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
[ "$LOCAL" = "$REMOTE" ] && exit 0

$LOG "mise a jour $LOCAL -> $REMOTE"
git pull --ff-only -q origin main || { $LOG "pull echoue"; exit 1; }
bash "$REPO/host/deploy.sh" && $LOG "deploy.sh applique"

# Redemarrage Klipper seulement hors impression (les macros sont relues au boot)
state=$(curl -s --max-time 5 'http://localhost:7125/printer/objects/query?print_stats' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null)
if [ "$state" = "standby" ] || [ "$state" = "complete" ] || [ "$state" = "cancelled" ] || [ -z "$state" ]; then
    sudo -n systemctl restart klipper && $LOG "klipper redemarre (etat=$state)"
else
    $LOG "klipper NON redemarre (impression: $state) - pris en charge au prochain boot"
fi
