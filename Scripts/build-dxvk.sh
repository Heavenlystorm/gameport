#!/bin/bash
# Builds DXVK-macOS 1.10.x with GamePort's patches (Patches/dxvk/*.patch) and installs its D3D10/11
# DLLs as an override of the engine's DXVK renderer.
#
#   Scripts/build-dxvk.sh            build and install
#   Scripts/build-dxvk.sh --revert   remove the override (the engine's own DXVK is used again)
#
# Everything (toolchain, source, build) lives in ~/Downloads/gameport-build; nothing is installed system-wide.
# The override goes to <engine>/renderers/dxvk/, which GamePort checks before the engine's
# frameworks/renderer/dxvk/. The D3D9 path (d9vk) is not touched and not built: DXVK 1.10's d3d9
# headers clash with current mingw-w64 headers (_D3DDEVINFO_RESOURCEMANAGER).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
B="${GAMEPORT_BUILD:-$HOME/Downloads/gameport-build}"
GAMEPORT_HOME="${GAMEPORT_HOME:-$HOME/Library/Application Support/GamePort}"
ENGINE="$GAMEPORT_HOME/engines/x64-crossover26.3-hb20261014"
OVERRIDE="$ENGINE/renderers/dxvk"

DXVK_URL=https://github.com/Gcenx/DXVK-macOS.git
DXVK_COMMIT=8f1e28deed3ad30802f7e1bdff428ec14e6e7817   # 1.10.x, "v1.10.3-20230507-async (macOS)"
LLVM_MINGW=llvm-mingw-20261020-ucrt-macos-universal
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/$LLVM_MINGW.tar.xz
LLVM_MINGW_SHA=e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e
GLSLANG_URL=https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-macos-universal-release.tar.gz
GLSLANG_SHA=4f8c05f2888a73ed0b7b274bc524af9130e09ae94b43c0f3f9ed83cfae852834

if [ "${1:-}" = "--revert" ]; then
    rm -rf "$OVERRIDE"
    echo "✓ Override removed; the engine's own DXVK is used again."
    exit 0
fi
[ -d "$ENGINE" ] || { echo "Engine not installed: $ENGINE (run gameport engine install)"; exit 1; }

fetch() {  # url sha256 file
    [ -f "$3" ] && [ "$(shasum -a 256 "$3" | cut -d' ' -f1)" = "$2" ] && return
    curl -fL --progress-bar -o "$3.part" "$1"
    [ "$(shasum -a 256 "$3.part" | cut -d' ' -f1)" = "$2" ] || { echo "SHA-256 mismatch: $1"; exit 1; }
    mv "$3.part" "$3"
}

mkdir -p "$B/dl" "$B/tools"
echo "• Toolchain"
fetch "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA" "$B/dl/llvm-mingw.tar.xz"
fetch "$GLSLANG_URL" "$GLSLANG_SHA" "$B/dl/glslang.tar.gz"
[ -d "$B/tools/$LLVM_MINGW" ] || tar -xJf "$B/dl/llvm-mingw.tar.xz" -C "$B/tools"
[ -x "$B/tools/glslang/bin/glslangValidator" ] || { mkdir -p "$B/tools/glslang"; tar -xzf "$B/dl/glslang.tar.gz" -C "$B/tools/glslang"; }
[ -x "$B/venv/bin/meson" ] || { python3 -m venv "$B/venv"; "$B/venv/bin/pip" install -q meson ninja; }
T="$B/tools/$LLVM_MINGW/bin"
export PATH="$B/venv/bin:$B/tools/glslang/bin:$T:$PATH"

echo "• Source ($DXVK_COMMIT) + patches"
[ -d "$B/dxvk/.git" ] || git clone -q "$DXVK_URL" "$B/dxvk"
git -C "$B/dxvk" fetch -q origin "$DXVK_COMMIT" 2>/dev/null || true
git -C "$B/dxvk" checkout -q --force "$DXVK_COMMIT"
git -C "$B/dxvk" clean -qfd
for p in "$REPO"/Patches/dxvk/*.patch; do git -C "$B/dxvk" apply "$p"; echo "  applied $(basename "$p")"; done
# Mark the build so `DXVK:` log lines show which DLL is loaded.
sed -i '' 's/#define DXVK_VERSION ".*"/#define DXVK_VERSION "v1.10.3-20230507-async (macOS) + GamePort query fix"/' "$B/dxvk/version.h.in"

build() {  # arch(x86_64|i686) wine-dir
    local arch=$1 family=$1 out="$B/build-$1"
    [ "$arch" = i686 ] && family=x86
    cat > "$B/cross-$arch.txt" <<EOF
[binaries]
c = '$T/$arch-w64-mingw32-clang'
cpp = '$T/$arch-w64-mingw32-clang++'
ar = '$T/$arch-w64-mingw32-ar'
strip = '$T/$arch-w64-mingw32-strip'
windres = '$T/$arch-w64-mingw32-windres'

[built-in options]
# DXVK 1.10 was written against GCC's libstdc++, which includes these transitively; llvm-mingw's libc++ does not.
cpp_args = ['-include', 'algorithm', '-include', 'cstdint', '-Wno-nontrivial-memcall', '-Wno-mismatched-tags']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
    echo "• Building $arch"
    rm -rf "$out"
    local log="$B/build-$arch.log"
    if ! { meson setup --cross-file "$B/cross-$arch.txt" --buildtype release --strip -Denable_d3d9=false "$out" "$B/dxvk" \
           && ninja -C "$out"; } >"$log" 2>&1; then
        tail -40 "$log"; echo "✗ $arch build failed; full log: $log"; exit 1
    fi
    mkdir -p "$B/out/$2"
    for dll in d3d11 d3d10core dxgi; do cp "$(find "$out/src" -name "$dll.dll" | head -1)" "$B/out/$2/"; done
}
build x86_64 x86_64-windows
build i686 i386-windows

echo "• Installing D3D10/11 override → $OVERRIDE"
for dir in x86_64-windows i386-windows; do
    mkdir -p "$OVERRIDE/wine/$dir"
    # Same set as the engine's DXVK: Wine's own dxgi stays. DXVK's d3d11 finds the GPU through it by LUID
    # ("Adapter is not a DXVK adapter" is only a warning). DXVK's dxgi would also load into Steam's web
    # helper, which then crashed in a loop and never started the game (TF2 lab, 27 restarts).
    cp "$B/out/$dir/d3d11.dll" "$B/out/$dir/d3d10core.dll" "$OVERRIDE/wine/$dir/"
    rm -f "$OVERRIDE/wine/$dir/dxgi.dll"
    # Wine only loads overlay DLLs that carry its builtin marker (otherwise it falls back to wined3d).
    python3 -I "$REPO/Scripts/mark-wine-builtin.py" "$OVERRIDE/wine/$dir/"*.dll >/dev/null
done
cp "$B/dxvk/LICENSE" "$OVERRIDE/LICENSE"
echo "DXVK-macOS $DXVK_COMMIT + $(ls "$REPO"/Patches/dxvk | tr '\n' ' ')" > "$OVERRIDE/version"
echo "✓ Done. Test: Scripts/lab-heaven.sh (d3d11-dxvk case). Undo: Scripts/build-dxvk.sh --revert"
echo "  All built DLLs (incl. dxgi): $B/out"
