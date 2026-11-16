#!/bin/bash
# auto_resume.sh — cree RESUME_<fichier> a partir du checkpoint power_loss_*.
# Appele par [gcode_shell_command auto_resume] (power_loss_recovery.cfg V4).
# Lit les variables persistantes Klipper (variables.cfg) : fichier source,
# position octet, temperatures et fan sauvegardes au dernier checkpoint couche.

VARS=/home/pi/printer_data/config/variables.cfg
GCODES=/home/pi/printer_data/gcodes

read_var() {
  python3 - "$1" <<'PYEOF'
import sys, ast, configparser
cfg = configparser.ConfigParser()
cfg.read('/home/pi/printer_data/config/variables.cfg')
key = sys.argv[1]
for sec in cfg.sections():
    if cfg.has_option(sec, key):
        try:
            sys.stdout.write(str(ast.literal_eval(cfg.get(sec, key))))
        except (ValueError, SyntaxError):
            sys.stdout.write(cfg.get(sec, key))
        break
PYEOF
}

filename=$(read_var power_loss_filename)
filepath=$(read_var power_loss_filepath)
position=$(read_var power_loss_file_position)
ext_temp=$(read_var power_loss_extruder)
bed_temp=$(read_var power_loss_bed)
fan_speed=$(read_var power_loss_fan)
z_pos=$(read_var power_loss_z)

# chemin source : filepath sauvegarde, sinon fallback gcodes/<filename>
src="${filepath:-$GCODES/$filename}"
[ -f "$src" ] || src="$GCODES/$filename"
[ -f "$src" ] || { echo "auto_resume: source introuvable ($filename)" >&2; exit 1; }

out="$GCODES/RESUME_$filename"

# position octet valide ?
size=$(stat -c %s "$src")
if [ -z "$position" ] || [ "$position" -le 0 ] || [ "$position" -ge "$size" ]; then
  echo "auto_resume: position invalide ($position / $size)" >&2
  exit 1
fi

# 1) en-tete : signature slicer + miniatures jusqu'au dernier "; thumbnail end"
thumb_end=$(grep -n '; thumbnail end' "$src" | tail -1 | cut -d: -f1)
if [ -n "$thumb_end" ]; then
  head -n "$thumb_end" "$src" > "$out"
else
  : > "$out"
fi

# 2) marqueur + retour aux frontieres de commande (byte exact peut couper une ligne)
{
  echo "; === RESUME AUTO (power loss) ==="
  echo "; reprise a ${position}/${size} bytes, Z=${z_pos}"
  echo "M118 Reprise apres coupure (Z=${z_pos})"
} >> "$out"

# 3) temperatures depuis le checkpoint (plus fiable que scanner le fichier)
[ -n "$bed_temp" ] && [ "$bed_temp" != "0" ] && { echo "M140 S${bed_temp}"; echo "M190 S${bed_temp}"; } >> "$out"
[ -n "$ext_temp" ] && [ "$ext_temp" != "0" ] && { echo "M104 S${ext_temp}"; echo "M109 S${ext_temp}"; } >> "$out"

# 4) mode E : si le fichier est en absolu (M82, pas de M83), restaurer la
#    position E en cherchant la derniere commande E avant la coupure.
if grep -q 'M83' "$src"; then
  echo 'M83' >> "$out"
else
  last_e=$(head -c "$position" "$src" | grep -oE 'E[-0-9.]+' | tail -1 | cut -c2-)
  [ -n "$last_e" ] && echo "G92 E${last_e}" >> "$out"
fi

# 5) ventilateur sauvegarde (0..1 -> 0..255)
if [ -n "$fan_speed" ]; then
  fan255=$(python3 -c "print(int(round(float('$fan_speed')*255)))" 2>/dev/null)
  [ -n "$fan255" ] && echo "M106 S${fan255}" >> "$out"
fi

# 6) contenu depuis la position sauvegardee (aligne sur le debut de ligne suivant)
tail -c +"$position" "$src" | tail -n +2 >> "$out"

echo "auto_resume: $out cree ($(stat -c %s "$out") octets)"
