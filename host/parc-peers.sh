#!/bin/bash
# parc-peers.sh — liste les machines du parc visibles via _parc-node._tcp.
# Usage : bash parc-peers.sh
printf "%-10s %-8s %-18s %s\n" HOST ROLE UPS_SERIAL UPS_MODEL
avahi-browse -trp _parc-node._tcp 2>/dev/null | grep '^=' | while IFS=';' read -r _ iface proto name type domain host addr port txt; do
    h=$(echo "$txt" | grep -o 'host=[^" ]*' | cut -d= -f2)
    r=$(echo "$txt" | grep -o 'role=[^" ]*' | cut -d= -f2)
    s=$(echo "$txt" | grep -o 'ups_serial=[^" ]*' | cut -d= -f2)
    m=$(echo "$txt" | grep -o 'ups_model=[^" ]*' | cut -d= -f2)
    printf "%-10s %-8s %-18s %s\n" "${h:-$name}" "${r:-?}" "${s:--}" "${m:--}"
done | sort -u
