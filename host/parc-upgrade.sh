#!/bin/bash
# parc-upgrade.sh — mise a jour du systeme et de TOUS les composants Klipper
# via l'API update_manager de Moonraker (klipper, moonraker, mainsail,
# mainsail-config, crowsnest, sonar, timelapse, led_effect, parc-config...).
# Lance par parc-upgrade.timer (hebdomadaire + 10 min apres chaque boot).
# Ne tourne que si l'imprimante est inactive et sans reprise sur coupure.
# Ordre : apt -> moonraker (se met a jour lui-meme en premier, redemarre)
#         -> composants dans l'ordre fixe -> klipper en dernier.
# Chaque echec est loggue (journalctl -t parc-upgrade) sans stopper les autres.
LOG="logger -t parc-upgrade"
MR=http://localhost:7125

# --- Gardes-fous ----------------------------------------------------------
if grep -q 'power_loss_active = 1' /home/pi/printer_data/config/variables.cfg 2>/dev/null; then
    $LOG "power_loss_active=1 - upgrade reportee"
    exit 0
fi
busy_state() {
    local st
    st=$(curl -s --max-time 5 "$MR/printer/objects/query?print_stats&extruder&heater_bed" \
      | python3 -c 'import json,sys
s=json.load(sys.stdin)["result"]["status"]
busy = s["print_stats"]["state"] not in ("standby","complete","cancelled","error") \
    or s["extruder"]["target"] > 0 or s["heater_bed"]["target"] > 0
print("busy" if busy else "idle")' 2>/dev/null)
    # Reponse vide (moonraker en restart) : attendre et reessayer une fois
    if [ -z "$st" ]; then
        sleep 5
        st=$(curl -s --max-time 5 "$MR/printer/objects/query?print_stats&extruder&heater_bed" \
          | python3 -c 'import json,sys
s=json.load(sys.stdin)["result"]["status"]
busy = s["print_stats"]["state"] not in ("standby","complete","cancelled","error") \
    or s["extruder"]["target"] > 0 or s["heater_bed"]["target"] > 0
print("busy" if busy else "idle")' 2>/dev/null)
    fi
    echo "${st:-unknown}"
}
[ "$(busy_state)" = "idle" ] || { $LOG "imprimante active ou API muette - reportee"; exit 0; }

# --- Helpers --------------------------------------------------------------
wait_api() {  # attend que moonraker reponde (max ~90 s)
    for _ in $(seq 1 30); do
        curl -s -m 3 "$MR/server/info" >/dev/null 2>&1 && return 0
        sleep 3
    done
    return 1
}
needs_update() {  # $1 = nom composant
    curl -s -m 5 "$MR/machine/update/status" | python3 -c "
import json,sys
v=json.load(sys.stdin)['result']['version_info'].get('$1')
if not v: sys.exit(1)
sys.exit(0 if v.get('version') != v.get('remote_version') else 1)"
}
wait_not_busy() {  # attend la fin de l'update courant (max ~10 min)
    for _ in $(seq 1 120); do
        b=$(curl -s -m 5 "$MR/machine/update/status" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["busy"])' 2>/dev/null)
        [ "$b" = "False" ] && return 0
        sleep 5
    done
    return 1
}
update_one() {  # $1 = nom composant ; code retour 0 ok/deja a jour, 1 echec
    needs_update "$1" || { $LOG "$1 : deja a jour"; return 0; }
    $LOG "$1 : mise a jour lancee"
    # moonraker/klipper ont leur endpoint propre ; les autres passent par /client/
    case "$1" in
        moonraker|klipper|system) ep="$MR/machine/update/$1" ;;
        *) ep="$MR/machine/update/client?name=$1" ;;
    esac
    curl -s -m 10 -X POST "$ep" >/dev/null 2>&1
    if ! wait_not_busy; then
        $LOG "$1 : ECHEC (timeout update)"
        return 1
    fi
    if needs_update "$1"; then
        $LOG "$1 : ECHEC (toujours en retard apres update)"
        return 1
    fi
    $LOG "$1 : a jour"
    return 0
}

wait_api || { $LOG "moonraker injoignable - abandon"; exit 1; }
$LOG "debut upgrade"

# --- 1. Systeme (apt full-upgrade : suit les changements de dependances,
#         kernel/firmware inclus ; laisse 'upgrade' simple des paquets retenus)
sudo -n apt-get update -qq \
    && sudo -n apt-get full-upgrade -y -qq \
         -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    && $LOG "apt full-upgrade OK" || $LOG "apt full-upgrade ECHEC"

# Firmware eeprom du Raspberry Pi (present seulement sur les vrais Pi ;
# absent sur YumiPad/Armbian/Orange Pi -> ignore silencieusement)
if command -v rpi-eeprom-update >/dev/null 2>&1; then
    sudo -n rpi-eeprom-update -a >/dev/null 2>&1 \
        && $LOG "rpi-eeprom verifie/applique" || $LOG "rpi-eeprom echec/ignore"
fi

# --- 2. Moonraker d'abord (il se redemarre lui-meme) ----------------------
FAILED=""
if update_one moonraker; then :; else FAILED="$FAILED moonraker"; fi
wait_api || { $LOG "moonraker ne revient pas apres update - stop"; exit 1; }

# --- 3. Composants, ordre fixe ; klipper en dernier -----------------------
DONE=1
for c in mainsail-config mainsail crowsnest sonar timelapse \
         led_effect Klipper-Adaptive-Meshing-Purging parc-config klipper; do
    if [ "$(busy_state)" != "idle" ]; then
        $LOG "imprimante redevenue active ou API muette - suite reportee"
        DONE=0
        break
    fi
    update_one "$c" || FAILED="$FAILED $c"
done

# --- 4. Bilan -------------------------------------------------------------
if [ "$DONE" = "0" ]; then
    $LOG "upgrade INTERROMPUE (imprimante active) - echecs eventuels :$FAILED"
elif [ -n "$FAILED" ]; then
    $LOG "upgrade terminee AVEC ECHECS :$FAILED"
else
    $LOG "upgrade terminee - tout a jour"
fi

# --- 5. Reboot si le systeme le demande (kernel/firmware installe) --------
if [ -f /var/run/reboot-required ] && [ "$(busy_state)" = "idle" ]; then
    $LOG "reboot-required detecte - redemarrage dans 1 min (machine idle)"
    sudo -n /usr/sbin/shutdown -r +1 "parc-upgrade: reboot post-upgrade" \
        && $LOG "reboot programme" || $LOG "reboot IMPOSSIBLE (sudo) - a faire a la main"
elif [ -f /var/run/reboot-required ]; then
    $LOG "reboot-required detecte mais machine active - reboot a la main requis"
fi
