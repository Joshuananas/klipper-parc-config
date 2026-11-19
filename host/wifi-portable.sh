#!/bin/bash
set -euo pipefail
if ! command -v nmcli >/dev/null || ! systemctl is-active --quiet NetworkManager; then
    exit 0
fi
[ "$(id -u)" -eq 0 ] || { echo 'wifi-portable: root required' >&2; exit 1; }
while IFS=: read -r uuid type; do
    [ "$type" = 802-11-wireless ] || continue
    mode=$(nmcli -g 802-11-wireless.mode connection show uuid "$uuid")
    [ "$mode" = infrastructure ] || [ -z "$mode" ] || continue
    iface=$(nmcli -g connection.interface-name connection show uuid "$uuid")
    mac=$(nmcli -g 802-11-wireless.mac-address connection show uuid "$uuid")
    [ -n "$iface$mac" ] || continue
    backup=$(mktemp -d /root/parc-wifi-backup.XXXXXXXX)
    chmod 700 "$backup"
    cp -a /etc/NetworkManager/system-connections/. "$backup/"
    nmcli connection modify uuid "$uuid" connection.interface-name '' 802-11-wireless.mac-address ''
    logger -t wifi-portable "profile $uuid: adapter binding removed; backup $backup; no reconnect requested"
done < <(nmcli -t -f UUID,TYPE connection show)
