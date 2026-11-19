#!/bin/bash
# parc-ups-map.sh — test de coupure correle : determine quelles machines
# sont alimentees par LE MEME onduleur.
#
# Principe : on loggue 1x/seconde l'etat des maitres NUT du LAN (ONBATT
# ou pas) et la joignabilite des noeuds. L'utilisateur coupe l'entree
# secteur d'UN onduleur ~10s puis rebranche. Les noeuds qui disparaissent
# ensemble (ou dont le maitre passe ONBATT) sont sur cet onduleur.
#
# Usage : bash parc-ups-map.sh [duree_s]   (defaut 60)
DUR=${1:-60}
LOG=/tmp/parc-ups-map.log
echo "=== parc-ups-map : $DUR s. Coupez l'ENTREE secteur d'un onduleur"
echo "    ~10 s maintenant, puis rebranchez. Log: $LOG ==="
{
echo "t,master,status,node_alive"
end=$((SECONDS + DUR))
while [ $SECONDS -lt $end ]; do
    t=$(date +%T.%3N)
    # statut de chaque maitre _nut._tcp trouve
    for m in $(avahi-browse -rp _nut._tcp 2>/dev/null | awk -F';' '/^=/{gsub(/\.$/,"",$7); print $7}' | sort -u); do
        st=$(upsc "ups@$m" ups.status 2>/dev/null || echo "?")
        echo "$t,$m,$st"
    done
    # joignabilite de chaque noeud parc
    for n in $(avahi-browse -rp _parc-node._tcp 2>/dev/null | awk -F';' '/^=/{gsub(/\.$/,"",$7); print $7}' | sort -u); do
        ping -c1 -W1 "$n" >/dev/null 2>&1 && alive=1 || alive=0
        echo "$t,$n,-,$alive"
    done
    sleep 1
done
} > "$LOG"
echo "=== resume ==="
echo "Maitres passes ONBATT :"
grep ',OB' "$LOG" | cut -d, -f1,2 | head -3
echo "Noeuds ayant perdu le reseau (instant de chute) :"
awk -F, '$4=="0"{print $2" des "$1}' "$LOG" | sort | head -20
