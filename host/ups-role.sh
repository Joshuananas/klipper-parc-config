#!/bin/bash
# ups-role.sh — role NUT automatique par pad (maitre/esclave/none).
# Lance par ups-role.timer (root) toutes les 60s et au boot.
#
# Logique :
#   - lsusb montre un UPS connu -> role MAITRE : ecrit nut.conf
#     netserver + ups.conf [ups] (driver selon VID:PID), upsd ecoute
#     le LAN, annonce avahi _nut._tcp (TXT: password slave + serial).
#   - pas d'UPS local -> role ESCLAVE : decouvre le(s) maitre(s) via
#     avahi-browse _nut._tcp, ecrit upsmon.conf MONITOR ups@<hote>.local.
#   - debrancher l'USB d'un pad et le brancher ailleurs fait basculer
#     les roles tout seuls (failover).
#
# Multi-UPS : chaque pad avec un UPS est maitre de SON onduleur sous le
# nom NUT uniforme 'ups'. Differenciation par le hostname
# (ups@swx22.local). Un pad sans UPS choisit parmi les maitres via
# /etc/nut/parc-ups-pref (hostname par ligne) puis premier trouve.
set -u
NUT=/etc/nut
ROLE_FILE=$NUT/parc-role
AVAHI_SVC=/etc/avahi/services/nut.service
BRIDGE_UNIT=/etc/systemd/system/ups_bridge.service
LOG="logger -t ups-role"

# VID:PID -> driver NUT (table extensible ; usbhid-ups couvre Eaton/APC/
# CyberPower, nutdrv_qx/blazer les generiques Voltronic & clones)
declare -A DRIVERS=(
  ["0463"]="usbhid-ups"   # MGE/Eaton
  ["051d"]="usbhid-ups"   # APC
  ["0764"]="usbhid-ups"   # CyberPower
  ["050d"]="usbhid-ups"   # Belkin
  ["10af"]="usbhid-ups"   # Liebert
  ["06da"]="usbhid-ups"   # Phoenixtec/Liebert
  ["0665"]="nutdrv_qx"    # Cypress/Voltronic
  ["0925"]="nutdrv_qx"    # Richcomm/generique
)

detect_usb_ups() {
    # retourne "vid:pid driver" ou rien
    local pat vp vid drv
    pat=$(IFS='|'; echo "${!DRIVERS[*]}")   # "0463|051d|..."
    vp=$(lsusb 2>/dev/null | grep -oiE "($pat):[0-9a-f]{4}" | head -1)
    [ -n "$vp" ] || return 1
    vid=${vp%%:*}
    drv=${DRIVERS[$vid]:-usbhid-ups}
    echo "$vp $drv"
    return 0
}

ensure_pkg() {
    dpkg -s "$1" >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null; }
}

restart_if() {
    systemctl is-active "$1" >/dev/null 2>&1 || systemctl start "$1" 2>/dev/null || true
}

# ---------- role MAITRE ----------
be_master() {
    local vp=$1 drv=$2
    local vid=${vp%%:*} pid=${vp##*:}
    local cur; cur=$(cat "$ROLE_FILE" 2>/dev/null)
    if [ "$cur" != "master:$vp" ]; then
        $LOG "bascule MAITRE (UPS USB $vp driver $drv)"
        cat > "$NUT/nut.conf" <<EOF
MODE=netserver
EOF
        cat > "$NUT/ups.conf" <<EOF
[ups]
    driver = $drv
    port = auto
    desc = "UPS parc ($(lsusb -d "$vp" | sed 's/.*: //'))"
    vendorid = $vid
    productid = $pid
    offdelay = 60
    ondelay = 70
EOF
        cat > "$NUT/upsd.conf" <<EOF
LISTEN 0.0.0.0 3493
EOF
        # mot de passe slave partage : genere une fois, publie via avahi TXT
        if [ ! -s "$NUT/parc-secret" ]; then
            head -c 24 /dev/urandom | md5sum | cut -d' ' -f1 > "$NUT/parc-secret"
        fi
        chmod 640 "$NUT/parc-secret"; chown root:nut "$NUT/parc-secret" 2>/dev/null || true
        local pass; pass=$(cat "$NUT/parc-secret")
        cat > "$NUT/upsd.users" <<EOF
[monuser]
    password = $pass
    upsmon master
[slave]
    password = $pass
    upsmon slave
EOF
        chmod 640 "$NUT/upsd.users"; chown root:nut "$NUT/upsd.users" 2>/dev/null || true
        cat > "$NUT/upsmon.conf" <<EOF
MONITOR ups@localhost 1 monuser $pass master
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5
NOTIFYFLAG ONLINE SYSLOG+WALL
NOTIFYFLAG ONBATT SYSLOG+WALL
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG FSD SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD SYSLOG+WALL
NOTIFYFLAG NOCOMM SYSLOG+WALL
EOF
        chmod 640 "$NUT/upsmon.conf"; chown root:nut "$NUT/upsmon.conf" 2>/dev/null || true
        # annonce avahi : les esclaves trouvent maitre + mot de passe seuls
        mkdir -p "$(dirname "$AVAHI_SVC")"
        cat > "$AVAHI_SVC" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">NUT UPS %h</name>
  <service>
    <type>_nut._tcp</type>
    <port>3493</port>
    <txt-record>secret=$pass</txt-record>
  </service>
</service-group>
EOF
        echo "master:$vp" > "$ROLE_FILE"
        systemctl enable --now nut-driver@ups nut-server nut-monitor avahi-daemon 2>/dev/null || \
          { systemctl restart nut-driver nut-server nut-monitor 2>/dev/null || true; }
        configure_bridge "ups@localhost"
    fi
}

# ---------- role ESCLAVE ----------
be_slave() {
    local master=$1 pass=$2
    local cur; cur=$(cat "$ROLE_FILE" 2>/dev/null)
    if [ "$cur" != "slave:$master" ]; then
        $LOG "bascule ESCLAVE de $master"
        cat > "$NUT/nut.conf" <<EOF
MODE=netclient
EOF
        rm -f "$NUT/ups.conf" "$NUT/upsd.conf" "$AVAHI_SVC"
        cat > "$NUT/upsmon.conf" <<EOF
MONITOR ups@$master 1 slave $pass slave
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
NOTIFYFLAG ONLINE SYSLOG+WALL
NOTIFYFLAG ONBATT SYSLOG+WALL
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYFLAG FSD SYSLOG+WALL+EXEC
NOTIFYFLAG COMOK SYSLOG+WALL
NOTIFYFLAG COMBAD SYSLOG+WALL
EOF
        chmod 640 "$NUT/upsmon.conf"; chown root:nut "$NUT/upsmon.conf" 2>/dev/null || true
        echo "slave:$master" > "$ROLE_FILE"
        systemctl enable --now nut-monitor 2>/dev/null || systemctl restart nut-monitor
        configure_bridge "ups@$master"
    fi
}

# ---------- role NONE ----------
be_none() {
    local cur; cur=$(cat "$ROLE_FILE" 2>/dev/null)
    if [ "$cur" != "none" ]; then
        $LOG "aucun UPS local ni maitre LAN -> role NONE (bridge NO_UPS)"
        cat > "$NUT/nut.conf" <<EOF
MODE=none
EOF
        rm -f "$NUT/ups.conf" "$NUT/upsd.conf" "$AVAHI_SVC"
        echo none > "$ROLE_FILE"
    fi
}

configure_bridge() {
    # reecrit l'ExecStart du service bridge avec le bon nom d'UPS
    local target=$1
    if [ -f "$BRIDGE_UNIT" ]; then
        sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 /home/pi/printer_data/scripts/ups_bridge.py $target|" "$BRIDGE_UNIT"
        systemctl daemon-reload
        systemctl restart ups_bridge 2>/dev/null || true
    fi
}

# ---------- decouverte LAN ----------
discover_master() {
    # affiche "hostname secret" du maitre prefere (parc-ups-pref puis 1er)
    local -a hosts=()
    local line f secret
    while read -r line; do
        f=(${line//;/ })
        [ "${f[0]:-}" = "=" ] || continue
        local host=${f[6]:-}
        host=${host%.}
        [ -n "$host" ] || continue
        secret=$(echo "$line" | grep -oE 'secret=[A-Za-z0-9]+' | cut -d= -f2)
        hosts+=("$host $secret")
    done < <(avahi-browse -trp _nut._tcp 2>/dev/null)
    [ ${#hosts[@]:-0} -eq 0 ] && return 1
    local pref host
    if [ -s "$NUT/parc-ups-pref" ]; then
        while read -r pref; do
            for host in "${hosts[@]}"; do
                [ "${host%% *}" = "$pref" ] && { echo "$host"; return 0; }
            done
        done < "$NUT/parc-ups-pref"
    fi
    echo "${hosts[0]}"
    return 0
}

# ---------- main ----------
ensure_pkg nut-client
ensure_pkg avahi-utils

if vp=$(detect_usb_ups); then
    ensure_pkg nut
    be_master $vp
else
    if master=$(discover_master); then
        be_slave $master
    else
        be_none
    fi
fi
