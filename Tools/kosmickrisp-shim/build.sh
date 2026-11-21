#!/bin/bash
# Builds the x86_64 libMoltenVK.dylib shim with Apple's own clang (Xcode / Command Line Tools).
# Usage: Tools/kosmickrisp-shim/build.sh <output folder>  (normally <engine>/renderers/kosmickrisp)
set -euo pipefail
out="${1:?output folder}"
mkdir -p "$out"
clang -arch x86_64 -mmacosx-version-min=26.0 -dynamiclib -O2 -fvisibility=hidden \
    -install_name @rpath/libgameport_vulkan_shim.dylib -o "$out/libMoltenVK.dylib" "$(dirname "$0")/shim.c"
codesign --force --sign - "$out/libMoltenVK.dylib"
# The engine's real MoltenVK under another leaf name, for every process that is not the game (see shim.c).
ln -sfn ../../frameworks/libMoltenVK.dylib "$out/libMoltenVK-engine.dylib"
echo "built $out/libMoltenVK.dylib"
