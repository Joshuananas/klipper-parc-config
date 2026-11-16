#!/bin/bash
# Synchronise le repo partage vers la config Klipper du pad.
# Lance par Moonraker update_manager (install_script) apres chaque update.
set -e
REPO=/home/pi/parc-config
CFG=/home/pi/printer_data/config

rsync -a --exclude='.bak*' "$REPO/macros/" "$CFG/macros/"
rsync -a "$REPO/Klipper-Adaptive-Meshing-Purging/Configuration/" "$CFG/Klipper-Adaptive-Meshing-Purging/Configuration/"
cp -f "$REPO/ups.cfg" "$CFG/ups.cfg"
mkdir -p /home/pi/printer_data/scripts
cp -f "$REPO/host/ups_bridge.py" /home/pi/printer_data/scripts/ups_bridge.py

echo "parc-config deploye dans $CFG"
