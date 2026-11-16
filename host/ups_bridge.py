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

UPS_NAME = sys.argv[1] if len(sys.argv) > 1 else "eaton@localhost"
MOONRAKER = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:7125"
POLL_S = 5
FAIL_GRACE = 6  # polls consecutifs en echec avant de declarer NO_COMM

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
            time.sleep(POLL_S)
            continue

        fails = 0
        if last_present is not True:
            last_present = True
        set_var("ups_present", 1)
        for kvar, (knut, _default) in VARS.items():
            raw = data.get(knut)
            if raw is None:
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
