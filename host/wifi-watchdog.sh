#!/bin/bash
set -u
exec 9>/run/parc-wifi-watchdog.lock
flock -n 9 || exit 0
log() { logger -t wifi-watchdog -- "$*"; }
recover_dhcp() {
    if systemctl is-active --quiet NetworkManager; then
        nmcli --wait 15 device connect "$IF" >/dev/null 2>&1 || true
    else
        systemctl restart wpa_supplicant
        systemctl restart dhcpcd 2>/dev/null || true
    fi
}
usb_device() {
    local path
    path=$(readlink -f "/sys/class/net/$1/device") || return 1
    path=${path%/*}
    [ -f "$path/idVendor" ] || return 1
    basename "$path"
}
rebind() {
    local dev=$1
    [[ "$dev" =~ ^[0-9]+-[0-9.]+$ ]] || return 1
    [ -f "/sys/bus/usb/devices/$dev/idVendor" ] || return 1
    log "rebind USB $dev"
    printf '%s' "$dev" > /sys/bus/usb/drivers/usb/unbind || return 1
    sleep 3
    printf '%s' "$dev" > /sys/bus/usb/drivers/usb/bind || return 1
    sleep 15
}
IF=''
for path in /sys/class/net/*; do
    [ -d "$path/wireless" ] || continue
    IF=${path##*/}
    break
done
if [ -z "$IF" ]; then
    log 'Aucune interface Wi-Fi; recherche des interfaces USB liees a rtl8xxxu'
    for driver in /sys/bus/usb/drivers/rtl8xxxu/*:*; do
        [ -L "$driver" ] || continue
        dev=${driver##*/}
        rebind "${dev%%:*}" || log "echec rebind ${dev%%:*}"
    done
    exit 0
fi
GW=$(ip -4 route show default dev "$IF" | awk 'NR==1{print $3}')
if [ -n "$GW" ] && ping -I "$IF" -c 2 -W 4 "$GW" >/dev/null 2>&1; then
    exit 0
fi
log "lien Wi-Fi indisponible ($IF); reconnexion ciblee"
recover_dhcp
sleep 15
GW=$(ip -4 route show default dev "$IF" | awk 'NR==1{print $3}')
if [ -n "$GW" ] && ping -I "$IF" -c 2 -W 4 "$GW" >/dev/null 2>&1; then
    log 'Wi-Fi retabli apres reconnexion'
    exit 0
fi
DEV=$(usb_device "$IF") || { log "peripherique USB non identifie pour $IF; aucune reinitialisation"; exit 1; }
rebind "$DEV" || { log "echec rebind $DEV"; exit 1; }
IF=''
for path in /sys/class/net/*; do
    [ -d "$path/wireless" ] || continue
    candidate=${path##*/}
    actual=$(usb_device "$candidate") || continue
    [ "$actual" = "$DEV" ] || continue
    IF=$candidate
    break
done
[ -n "$IF" ] || { log 'Interface Wi-Fi toujours absente apres rebind'; exit 1; }
recover_dhcp
sleep 15
GW=$(ip -4 route show default dev "$IF" | awk 'NR==1{print $3}')
if [ -n "$GW" ] && ping -I "$IF" -c 2 -W 4 "$GW" >/dev/null 2>&1; then
    log 'Wi-Fi retabli apres rebind'
else
    log 'ECHEC: Wi-Fi indisponible apres rebind'
    exit 1
fi
