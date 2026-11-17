#!/bin/bash
# Bootstrap parc Klipper sur une machine vierge (Raspberry/Yumipad).
# Usage : curl -s https://raw.githubusercontent.com/Joshuananas/klipper-parc-config/main/host/install_parc.sh | bash
# Prerequis : Klipper + Moonraker installes, user pi, printer_data present.
set -e
REPO_URL=https://github.com/Joshuananas/klipper-parc-config.git
REPO=/home/pi/parc-config
CFG=/home/pi/printer_data/config
MC=$CFG/moonraker.conf
PC=$CFG/printer.cfg

echo "== 1/5 dependances =="
sudo apt-get install -y git rsync || true

echo "== 2/5 clone repo =="
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" pull --ff-only
else
    git clone "$REPO_URL" "$REPO"
fi
chmod +x "$REPO/host/deploy.sh"

echo "== 3/5 section update_manager =="
if ! grep -q 'update_manager parc-config' "$MC"; then
    cat >> "$MC" <<EOF

[update_manager parc-config]
type: git_repo
path: $REPO
origin: $REPO_URL
primary_branch: main
managed_services: klipper
install_script: host/deploy.sh
EOF
    echo "moonraker.conf : section ajoutee"
else
    echo "moonraker.conf : deja present"
fi

echo "== 4/5 includes printer.cfg =="
add_include() {
    # insere avant le bloc SAVE_CONFIG (#*# <---------------------- SAVE_CONFIG)
    grep -qF "$1" "$PC" && return 0
    python3 - "$1" <<'PYEOF'
import sys
inc = sys.argv[1]
lines = open('/home/pi/printer_data/config/printer.cfg').read().split('\n')
for i, l in enumerate(lines):
    if l.startswith('#*#') and 'SAVE_CONFIG' in l:
        lines.insert(i, inc)
        break
else:
    lines.append(inc)
open('/home/pi/printer_data/config/printer.cfg', 'w').write('\n'.join(lines))
print('printer.cfg : ' + inc)
PYEOF
}
add_include '[include ups.cfg]'
add_include '[include macros/utilities/slicer_channel.cfg]'
add_include '[include macros/utilities/user_prompts.cfg]'
if [ -d /home/pi/moonraker-timelapse ]; then
    add_include '[include /home/pi/moonraker-timelapse/klipper_macro/timelapse.cfg]'
fi

echo "== 5/5 deploiement des fichiers partages =="
bash "$REPO/host/deploy.sh"

echo "== onduleur : role NUT automatique (failover) =="
# ups-role.timer decide seul du role : maitre si un UPS USB est branche
# (n'importe quel pad), esclave du maitre annonce via avahi sinon.
# Le bridge suit (detect_ups : upsc -l local puis avahi _nut._tcp).
sudo apt-get install -y nut-client avahi-utils libnss-mdns
sudo cp "$REPO/host/ups-role.sh" /usr/local/bin/ups-role.sh
sudo chmod +x /usr/local/bin/ups-role.sh
sudo cp "$REPO/host/ups-role.service" "$REPO/host/ups-role.timer" /etc/systemd/system/
sudo cp "$REPO/host/ups_bridge.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ups-role.timer ups_bridge.service
sudo /usr/local/bin/ups-role.sh || true
echo "role NUT: $(cat /etc/nut/parc-role 2>/dev/null || echo none)"

echo "== sync automatique (parc-sync.timer) =="
chmod +x "$REPO/host/parc-sync.sh"
sudo cp "$REPO/host/parc-sync.service" "$REPO/host/parc-sync.timer" /etc/systemd/system/
echo 'pi ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart klipper' | sudo tee /etc/sudoers.d/parc-sync >/dev/null
sudo chmod 440 /etc/sudoers.d/parc-sync
sudo systemctl daemon-reload
sudo systemctl enable --now parc-sync.timer

echo "== restart moonraker + klipper =="
sudo systemctl restart moonraker klipper
echo "Termine : ouvre Mainsail > Machine > parc-config pour les mises a jour."
