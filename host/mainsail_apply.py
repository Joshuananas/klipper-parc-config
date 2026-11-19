#!/usr/bin/env python3
# Applique la disposition Mainsail par defaut du parc (groupes de macros,
# presets de temperatures). N'ecrit une cle que si elle est absente dans la
# base Moonraker -> la personnalisation ulterieure de l'utilisateur est
# preservee.
import json, urllib.request, pathlib

BASE = "http://127.0.0.1:7125"
DEFAULTS = pathlib.Path(__file__).with_name("mainsail_defaults.json")

def get(key):
    try:
        url = f"{BASE}/server/database/item?namespace=mainsail&key={key}"
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.load(r)["result"]["value"]
    except Exception:
        return None

def post(key, value):
    req = urllib.request.Request(
        f"{BASE}/server/database/item?namespace=mainsail&key={key}",
        data=json.dumps({"value": value}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=5)
        print(f"mainsail-defaults: {key} applique")
    except Exception as e:
        print(f"mainsail-defaults: echec {key}: {e}")

for key, value in json.load(open(DEFAULTS, encoding="utf-8")).items():
    if get(key) is None:
        post(key, value)

# Le capteur de temperature hote (SmartPi/RPi4/...) n'a jamais de couleur
# epinglee : la palette automatique l'harmonise avec le reste du parc.
ds = get("view.tempchart.datasetSettings")
if isinstance(ds, dict) and any(k.startswith("temperature_sensor ") for k in ds):
    ds = {k: v for k, v in ds.items() if not k.startswith("temperature_sensor ")}
    post("view.tempchart.datasetSettings", ds)
