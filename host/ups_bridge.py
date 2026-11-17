#!/usr/bin/env python3
"""ups_bridge - pont NUT -> variables Klipper (_UPS_DATA).

Lit `upsc <ups>@<host>` toutes les POLL_S secondes et pousse les valeurs dans
la macro Klipper _UPS_DATA via l'API Moonraker (gcode script).

Volontairement sans etat : Klipper/save_variables est la seule source de
verite. Aucun fichier d'etat parallele.

Usage: ups_bridge.py [ups_name] [moonraker_url]
"""
import json
import subprocess
import sys
import time
import urllib.request

MOONRAKER = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:7125"
POLL_S = 5
FAIL_GRACE = 6  # polls consecutifs en echec avant de declarer NO_COMM


def detect_ups():
    """Auto-detecte l'UPS : local d'abord (upsc -l), puis LAN via avahi
    (_nut._tcp annonce par ups-role.sh sur le(s) maitre(s)).

    Ordre de choix LAN : fichier de preference /etc/nut/parc-ups-pref
    (un hostname par ligne) puis premier service trouve.
    Retourne "<nom>@<hote>" ou None si rien n'est trouve.
    """
    try:
        out = subprocess.run(
            ["upsc", "-l"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0:
            for line in out.stdout.splitlines():
                name = line.split(":")[0].strip()
                if name:
                    return name if "@" in name else name + "@localhost"
    except Exception:
        pass
    # Fallback LAN : maitre(s) annonce(s) par avahi _nut._tcp
    try:
        out = subprocess.run(
            ["avahi-browse", "-trp", "_nut._tcp"],
            capture_output=True, text=True, timeout=15,
        )
        if out.returncode == 0:
            hosts = []
            for line in out.stdout.splitlines():
                # format: =;eth0;IPv4;nom;_nut._tcp;local;host;ip;port;txt...
                f = line.split(";")
                # ignorer les services _nut._tcp etrangers : seuls les
                # maitres du parc annoncent le secret en TXT
                if f[0] == "=" and len(f) > 6 and "secret=" in line:
                    hosts.append(f[6].rstrip("."))
            if hosts:
                pref = []
                try:
                    pref = [l.strip() for l in open("/etc/nut/parc-ups-pref") if l.strip()]
                except Exception:
                    pass
                hosts.sort(key=lambda h: pref.index(h) if h in pref else 99)
                return "ups@" + hosts[0]
    except Exception:
        pass
    return None


UPS_NAME = sys.argv[1] if len(sys.argv) > 1 else (detect_ups() or "ups@localhost")

VARS = {
    "ups_status": ("ups.status", "NOCOMM"),
    "battery_charge": ("battery.charge", 0.0),
    "runtime_s": ("battery.runtime", 0),
    "load_pct": ("ups.load", 0.0),
    "input_voltage": ("input.voltage", 0.0),
}
MACRO = "_UPS_DATA"


def read_ups():
    """Retourne un dict des variables NUT ou None si l'UPS est injoignable."""
    try:
        out = subprocess.run(
            ["upsc", UPS_NAME], capture_output=True, text=True, timeout=10
        )
        if out.returncode != 0:
            return None
        return dict(
            line.split(": ", 1) for line in out.stdout.strip().splitlines() if ": " in line
        )
    except Exception:
        return None


def set_var(name, value):
    # Les strings exigent la double protection shlex+literal : VALUE='"OL"'
    if isinstance(value, str):
        gcode = (
            f"SET_GCODE_VARIABLE MACRO={MACRO} VARIABLE={name} "
            f"VALUE='\"{value}\"'"
        )
    else:
        gcode = f"SET_GCODE_VARIABLE MACRO={MACRO} VARIABLE={name} VALUE={value}"
    body = json.dumps({"script": gcode}).encode()
    req = urllib.request.Request(
        MOONRAKER + "/printer/gcode/script",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass  # Klipper occupe/absent : on reessaie au prochain cycle


def num(v, cast):
    try:
        return cast(float(v))
    except (TypeError, ValueError):
        return cast(0)


def main():
    global UPS_NAME
    fails = 0
    last_present = None
    while True:
        data = read_ups()
        if data is None:
            fails += 1
            if fails >= FAIL_GRACE and last_present is not False:
                set_var("ups_present", 0)
                set_var("ups_status", "NOCOMM")
                last_present = False
            # Re-detection : l'UPS peut avoir ete branche/configure apres
            # le demarrage, ou le nom passe en argv (service historique)
            # peut etre stale -> upsc -l reste la source de verite.
            if fails % 60 == 0:
                new_name = detect_ups()
                if new_name and new_name != UPS_NAME:
                    UPS_NAME = new_name
            time.sleep(POLL_S)
            continue

        fails = 0
        if last_present is not True:
            last_present = True
        set_var("ups_present", 1)
        for kvar, (knut, _default) in VARS.items():
            raw = data.get(knut)
            if raw is None:
                # Champ non expose par ce modele : -1 = indisponible, les
                # macros bornent leurs comparaisons avec `>= 0`.
                if kvar != "ups_status":
                    set_var(kvar, -1.0)
                continue
            if kvar == "ups_status":
                set_var(kvar, raw.split()[0])  # "OL CHRG" -> "OL"
            elif kvar in ("runtime_s",):
                set_var(kvar, num(raw, int))
            else:
                set_var(kvar, num(raw, float))
        time.sleep(POLL_S)


if __name__ == "__main__":
    main()
