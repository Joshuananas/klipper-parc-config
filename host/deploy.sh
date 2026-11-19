#!/bin/bash
# Synchronise le repo partage vers la config Klipper du pad.
# Lance par Moonraker update_manager (install_script) apres chaque update.
# Verifie aussi que les dependances logicielles requises par les macros
# sont presentes (clone si absent, jamais de maj forcee).
set -e
REPO=/home/pi/parc-config
CFG=/home/pi/printer_data/config
HOME_PI=/home/pi

# --- 1. Fichiers config partages -----------------------------------------
rsync -a --exclude='.bak*' "$REPO/macros/" "$CFG/macros/"
rsync -a "$REPO/Klipper-Adaptive-Meshing-Purging/Configuration/" "$CFG/Klipper-Adaptive-Meshing-Purging/Configuration/"
cp -f "$REPO/ups.cfg" "$CFG/ups.cfg"
mkdir -p /home/pi/printer_data/scripts
cp -f "$REPO/host/ups_bridge.py" /home/pi/printer_data/scripts/ups_bridge.py
mkdir -p "$CFG/scripts"
rsync -a --chmod=+x "$REPO/scripts/" "$CFG/scripts/"

# --- 2. Dependances logicielles ------------------------------------------
# led_effect : requis par toutes les macros LED (led_control/led_centralized)
if [ ! -d "$HOME_PI/klipper-led_effect" ]; then
    git clone https://github.com/julianschill/klipper-led_effect.git "$HOME_PI/klipper-led_effect" || true
fi
if [ -d "$HOME_PI/klipper-led_effect" ] && [ ! -e "$HOME_PI/klipper/klippy/extras/led_effect.py" ]; then
    ln -sf "$HOME_PI/klipper-led_effect/src/led_effect.py" "$HOME_PI/klipper/klippy/extras/led_effect.py" || \
    cp -f "$HOME_PI/klipper-led_effect/src/led_effect.py" "$HOME_PI/klipper/klippy/extras/led_effect.py" || true
fi

# moonraker-timelapse : macros timelapse
if [ ! -d "$HOME_PI/moonraker-timelapse" ]; then
    git clone https://github.com/mainsail-crew/moonraker-timelapse.git "$HOME_PI/moonraker-timelapse" || true
fi

# KAMP : corps du projet (sur ce parc : installe dans le dossier config)
if [ ! -d "$CFG/Klipper-Adaptive-Meshing-Purging" ] && [ ! -d "$HOME_PI/Klipper-Adaptive-Meshing-Purging" ]; then
    git clone https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git "$CFG/Klipper-Adaptive-Meshing-Purging" || true
fi

# gcode_shell_command : requis par YUMI_PLR (plr.sh)
if [ ! -f "$HOME_PI/klipper/klippy/extras/gcode_shell_command.py" ] && [ -f "$HOME_PI/YUMI_PLR/gcode_shell_command.py" ]; then
    cp -f "$REPO/host/gcode_shell_command.py" "$HOME_PI/klipper/klippy/extras/gcode_shell_command.py" || true
fi

# --- 3. Gcodes de test livres avec le parc --------------------------------
# Installes dans le dossier gcodes de chaque machine ; jamais ecrases si
# le fichier existe deja (modifie localement ou pas).
mkdir -p "$HOME_PI/printer_data/gcodes"
for g in "$REPO"/gcodes/*.gcode; do
    [ -e "$g" ] || continue
    dst="$HOME_PI/printer_data/gcodes/$(basename "$g")"
    [ -f "$dst" ] || cp "$g" "$dst"
done

# --- 4. Mise a jour hebdomadaire automatique ------------------------------
# parc-upgrade.timer : apt full-upgrade + update_manager Moonraker (systeme
# et composants klipper/mainsail/etc). Idempotent : reecrit a chaque deploy
# pour propager les changements (script, units, sudoers).
chmod +x "$REPO/host/parc-upgrade.sh"
sudo cp "$REPO/host/parc-upgrade.service" "$REPO/host/parc-upgrade.timer" /etc/systemd/system/
echo 'pi ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl restart moonraker, /usr/bin/systemctl restart klipper, /usr/sbin/shutdown, /usr/sbin/rpi-eeprom-update' \
    | sudo tee /etc/sudoers.d/parc-upgrade >/dev/null
sudo chmod 440 /etc/sudoers.d/parc-upgrade
# --- 5. Nom du capteur de temperature hote adapte a la carte ---------------
# Les bundles utilisent un nom generique ; on le remplace par le vrai modele
# de carte lu dans le device tree (RPi4, RPi5, OrangePi, YumiPad, hostname...).
board=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)
case "$board" in
    *"Raspberry Pi 5"*) sname=RPi5 ;;
    *"Raspberry Pi 4"*) sname=RPi4 ;;
    *"Raspberry Pi 3"*) sname=RPi3 ;;
    *"Raspberry Pi"*)   sname=RPi ;;
    "")                 sname=$(hostname) ;;
    *)                  sname=$(echo "$board" | tr -cd 'A-Za-z0-9' | cut -c1-16) ;;
esac
for f in "$CFG/host_extras.cfg" "$CFG/smartpad_extras.cfg"; do
    [ -f "$f" ] && sed -i -E "s/\[temperature_sensor (SmartPi|HostBoard)\]/[temperature_sensor $sname]/" "$f"
done

# --- 6. Appairage parc : annonce mDNS _parc-node._tcp ----------------------
# Chaque noeud publie nom/role/serie UPS -> decouverte automatique des
# membres du parc (parc-peers.sh pour lister, parc-ups-map.sh pour tester
# quel onduleur alimente quelle machine).
chmod +x "$REPO/host/parc-pair.sh" "$REPO/host/parc-peers.sh" "$REPO/host/parc-ups-map.sh"
sudo cp "$REPO/host/parc-pair.service" "$REPO/host/parc-pair.timer" /etc/systemd/system/
sudo bash "$REPO/host/wifi-portable.sh"
mkdir -p "$HOME_PI/bin"
sudo install -m 755 "$REPO/host/wifi-watchdog.sh" "$HOME_PI/bin/.wifi-watchdog.sh.new"
sudo mv "$HOME_PI/bin/.wifi-watchdog.sh.new" "$HOME_PI/bin/wifi-watchdog.sh"
sudo install -m 644 "$REPO/host/wifi-watchdog.service" "$REPO/host/wifi-watchdog.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now parc-pair.timer parc-upgrade.timer wifi-watchdog.timer

echo "parc-config deploye dans $CFG"
