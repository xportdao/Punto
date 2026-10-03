#!/bin/zsh
# Builds Punto, replaces /Applications/Punto.app and relaunches it.
set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/Punto.app"
target_app="/Applications/Punto.app"

"$project_dir/scripts/build-app.sh"

if pgrep -x Punto >/dev/null; then
    pkill -x Punto || true
    for _ in {1..20}; do
        pgrep -x Punto >/dev/null || break
        sleep 0.25
    done
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"
codesign --verify --strict "$target_app"
codesign -d -r- "$target_app" 2>&1 | grep '^designated'

open "$target_app"
echo "Installed and launched $target_app"
