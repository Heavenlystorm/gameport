#!/bin/bash
# Runs one lab measurement of a profile on KosmicKrisp instead of MoltenVK, then puts the profile back.
# Needs: KosmicKrisp + the shim in <engine>/renderers/kosmickrisp (see README.md in this folder).
# Usage: Tools/kosmickrisp-shim/try.sh <profile> [renderer, default dxmt] [seconds, default 150]
# With dxmt, Steam's window draws through DXMT (Metal) and D3D9 games go through DXVK's d3d9 to Vulkan, so
# only the game touches KosmicKrisp. TF2 (D3D9) measured 246 FPS this way on MoltenVK.
set -euo pipefail
cd "$(dirname "$0")/../.."
ID="${1:?profile}"; RENDERER="${2:-dxmt}"; SECONDS_="${3:-150}"
HOME_DIR="${GAMEPORT_HOME:-$HOME/Library/Application Support/GamePort}"
KK="$HOME_DIR/engines/x64-crossover26.3-hb20261014/renderers/kosmickrisp"
PROFILE="$HOME_DIR/profiles/$ID/profile.json"
LOG="$HOME_DIR/profiles/$ID/logs/game.log"
[ -f "$KK/libMoltenVK.dylib" ] && [ -e "$KK/libMoltenVK-engine.dylib" ] && [ -f "$KK/libvulkan_kosmickrisp.dylib" ] || { echo "error: KosmicKrisp or the shim is missing in $KK (run Tools/kosmickrisp-shim/install.sh)"; exit 1; }
LAB="$HOME_DIR/profiles/$ID/lab"
mkdir -p "$LAB/kosmickrisp"
MARK="$(mktemp)"
cp "$PROFILE" "$PROFILE.kk-backup"
# KosmicKrisp runs are experiments: they go to lab/kosmickrisp/, where they never count as the profile's evidence.
finish() {
    mv "$PROFILE.kk-backup" "$PROFILE"; echo "profile restored"
    find "$LAB" -maxdepth 1 -type f -newer "$MARK" -exec mv {} "$LAB/kosmickrisp/" \;
    rm -f "$MARK"
}
trap finish EXIT
python3 -I - "$PROFILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); env = d.setdefault("environment", {})
d["vulkanDriver"] = "kosmickrisp"  # GamePort sets CX_LIBVULKAN for the shim (see WineRunner.environment)
env["DXVK_LOG_LEVEL"] = "debug"   # DXVK's adapter and device choices
env["WINEDEBUG"] = "fixme-all,fixme+vulkan,warn+vulkan"  # why Wine's Vulkan layer refuses something
json.dump(d, open(p, "w"), indent=2)
PY
.build/debug/gameport lab "$ID" "$RENDERER" "$SECONDS_"
echo "--- driver lines from this run ---"
# gameport starts game.log afresh for every launch, so the whole file is this run's.
grep -E "kosmickrisp-shim|Device name|Driver version|Vulkan:|Game: |page fault|assert|DxvkError|(err|warn|fixme):vulkan:|Unhandled|err: " "$LOG" \
    | grep -vE " extensions:|Extension \".*\" is not supported" | sort | uniq -c || true
# The crashing thread's own Vulkan messages, last 40 before it stopped.
GAME_TID=$(grep -o "Unhandled exception .*(thread [0-9a-f]*)" "$LOG" | tail -1 | sed -E 's/.*thread ([0-9a-f]+)\)/\1/')
[ -n "$GAME_TID" ] && { echo "--- last Vulkan calls of thread $GAME_TID ---"; grep "^$GAME_TID:" "$LOG" | grep -v "is not supported" | tail -40 | cut -c1-220; }
for kind in instance device; do
    if grep -m1 -o "kosmickrisp-shim: [0-9]* $kind extensions:.*" "$LOG" > "$LAB/kosmickrisp/$kind-extensions.txt"; then
        echo "KosmicKrisp's $kind extensions: $LAB/kosmickrisp/$kind-extensions.txt"
    else
        rm -f "$LAB/kosmickrisp/$kind-extensions.txt"
    fi
done
