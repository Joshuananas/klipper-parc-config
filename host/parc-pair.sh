#!/bin/bash
# parc-pair.sh — annonce mDNS du noeud parc (_parc-node._tcp) + appairage.
# Lance par parc-pair.timer toutes les 60s : chaque machine du parc annonce
# son nom, son role NUT et le serie de l'UPS qu'elle sert (si maitre).
# Resultat : n'importe quelle machine ajoutee au LAN devient visible et
# s'appaire d'elle-meme (esclave du maitre decouvert par ups-role.sh).
set -u
NUT=/etc/nut
SVC=/etc/avahi/services/parc-node.service
ROLE=$(cat "$NUT/parc-role" 2>/dev/null || echo none)
HOST=$(hostname)

serial=""; model=""
case "$ROLE" in
    master:*)
        serial=$(upsc ups@localhost device.serial 2>/dev/null)
        model=$(upsc ups@localhost device.model 2>/dev/null) ;;
    slave:*)
        serial=$(upsc "ups@${ROLE#slave:}" device.serial 2>/dev/null) ;;
esac

cat > "$SVC.tmp" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Parc %h</name>
  <service>
    <type>_parc-node._tcp</type>
    <port>22</port>
    <txt-record>host=$HOST</txt-record>
    <txt-record>role=${ROLE%%:*}</txt-record>
    <txt-record>ups_serial=$serial</txt-record>
    <txt-record>ups_model=$model</txt-record>
  </service>
</service-group>
EOF
if ! cmp -s "$SVC.tmp" "$SVC" 2>/dev/null; then
    mv "$SVC.tmp" "$SVC"
    chmod 644 "$SVC"
    logger -t parc-pair "annonce noeud: role=$ROLE serial=$serial"
else
    rm -f "$SVC.tmp"
fi
