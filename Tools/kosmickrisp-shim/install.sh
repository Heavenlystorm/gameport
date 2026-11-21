#!/bin/bash
# Installs KosmicKrisp (Sikarugir's build of Mesa's Vulkan-on-Metal driver, pinned by SHA-256) and GamePort's shim
# into an engine's renderers/kosmickrisp. Afterwards: gameport vulkan <profile> kosmickrisp
# Usage: Tools/kosmickrisp-shim/install.sh [engine id]
set -euo pipefail
cd "$(dirname "$0")/../.."
HOME_DIR="${GAMEPORT_HOME:-$HOME/Library/Application Support/GamePort}"
ENGINE="${1:-x64-crossover26.3-hb20261014}"
DEST="$HOME_DIR/engines/$ENGINE/renderers/kosmickrisp"
URL="https://github.com/Sikarugir-App/mesa-kosmickrisp/releases/download/20261029/kosmickrisp-x86_64.zip"
SHA256="5c55c95bfeae56e2ed8dc9ebbf85c702813ae67638f0b544310fd186bb0fc93b"
CACHE="$HOME/Downloads/gameport-build/kk"
ZIP="$CACHE/kosmickrisp-x86_64.zip"

[ -d "$HOME_DIR/engines/$ENGINE" ] || { echo "error: engine $ENGINE is not installed"; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo "error: KosmicKrisp needs macOS 26 or later"; exit 1; }
command -v clang >/dev/null || { echo "error: the shim is built with clang; install Xcode or its Command Line Tools"; exit 1; }

mkdir -p "$CACHE"
if [ ! -f "$ZIP" ] || [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$SHA256" ]; then
    echo "Downloading $URL"
    curl -fL -o "$ZIP.part" "$URL"
    mv "$ZIP.part" "$ZIP"
fi
[ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" = "$SHA256" ] || { echo "error: SHA-256 mismatch for $ZIP"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q -o "$ZIP" -d "$TMP"
LIB="$(find "$TMP" -name libvulkan_kosmickrisp.dylib | head -1)"
[ -n "$LIB" ] || { echo "error: libvulkan_kosmickrisp.dylib is not in the archive"; exit 1; }
mkdir -p "$DEST"
cp "$LIB" "$DEST/libvulkan_kosmickrisp.dylib"
Tools/kosmickrisp-shim/build.sh "$DEST"
echo "✓ KosmicKrisp installed in $DEST"
echo "  Use it for a game: .build/debug/gameport vulkan <profile> kosmickrisp"
