#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="${XDG_DATA_HOME:-$HOME/.local/share}/freedigi"
desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$app_dir" "$desktop_dir"
for file in freedigi freedigi-service freedigi.png LICENSE NOTICE THIRD_PARTY_NOTICES.txt README.md 70-freedigi.rules; do
  install -m 644 "$source_dir/$file" "$app_dir/$file"
done
chmod 755 "$app_dir/freedigi" "$app_dir/freedigi-service"
# Escape paths according to the desktop-entry Exec string rules.
python3 - "$app_dir" "$desktop_dir/freedigi.desktop" <<'PY'
import pathlib,sys
base=pathlib.Path(sys.argv[1])
def quoted(s):
    return '"'+str(s).replace('\\','\\\\').replace('"','\\"').replace('`','\\`').replace('$','\\$').replace('%','%%')+'"'
pathlib.Path(sys.argv[2]).write_text('[Desktop Entry]\nType=Application\nName=FreeDigi\nComment=Controller configuration, based on ControlLab\nExec='+quoted(base/'freedigi')+'\nIcon='+str(base/'freedigi.png')+'\nTerminal=false\nCategories=Utility;Settings;\n')
PY
printf 'Installed FreeDigi in %s\nLaunch it from your applications menu.\n' "$app_dir"
printf 'For controller permissions, follow the udev instructions in README.md.\n'
