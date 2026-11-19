#!/bin/bash
# parc-peers.sh — liste les machines du parc visibles via _parc-node._tcp.
# Usage : bash parc-peers.sh
avahi-browse -trp _parc-node._tcp 2>/dev/null | awk -F';' '
/^=/ {
    host=""; role=""; serial=""; model=""
    n=split($0, a, ";")
    # champ 7 = hostname resolu ; les TXT sont en champ 9+
    for (i=9; i<=n; i++) {
        gsub(/"/,"",a[i])
        if (a[i] ~ /^host=/)       host=substr(a[i],6)
        if (a[i] ~ /^role=/)       role=substr(a[i],6)
        if (a[i] ~ /^ups_serial=/) serial=substr(a[i],12)
        if (a[i] ~ /^ups_model=/)  model=substr(a[i],11)
    }
    printf "%-10s role=%-7s ups_serial=%-15s model=%s\n", host, role, serial, model
}' | sort -u
