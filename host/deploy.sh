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

# --- 3. Mise a jour hebdomadaire automatique ------------------------------
# parc-upgrade.timer : apt upgrade + pull des composants (led_effect, KAMP,
# timelapse, moonraker, klipper). Idempotent : installe une fois par machine.
if [ ! -f /etc/systemd/system/parc-upgrade.timer ]; then
    chmod +x "$REPO/host/parc-upgrade.sh"
    sudo cp "$REPO/host/parc-upgrade.service" "$REPO/host/parc-upgrade.timer" /etc/systemd/system/
    echo 'pi ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl restart moonraker, /usr/bin/systemctl restart klipper' \
        | sudo tee /etc/sudoers.d/parc-upgrade >/dev/null
    sudo chmod 440 /etc/sudoers.d/parc-upgrade
    sudo systemctl daemon-reload
    sudo systemctl enable --now parc-upgrade.timer
fi

echo "parc-config deploye dans $CFG"
