#!/bin/bash
# Build an experimental 64-bit Wine D3D12 overlay. Installed engines and profiles stay separate.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${GAMEPORT_BUILD:-$HOME/Downloads/gameport-build}"
revision=4522cc1a8b1347f1ab1b0f7b14a23ed9444d95d1 # upstream v3.1
llvm=llvm-mingw-20261020-ucrt-macos-universal
llvm_sha=e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e
glslang_sha=4f8c05f2888a73ed0b7b274bc524af9130e09ae94b43c0f3f9ed83cfae852834
if [[ $# != 0 ]]; then echo "Usage: Scripts/build-vkd3d-proton.sh" >&2; exit 2; fi
mkdir -p "$build_root/dl"
work="$(mktemp -d "$build_root/vkd3d-proton.XXXXXXXX")"
echo "Building in $work"

fetch() {
    local url=$1 sha=$2 file=$3
    if [[ -f "$file" ]] && [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]]; then return; fi
    curl --fail --location --retry 3 -o "$work/download" "$url"
    [[ "$(shasum -a 256 "$work/download" | cut -d' ' -f1)" = "$sha" ]] || { echo "SHA-256 mismatch: $url" >&2; exit 1; }
    mv "$work/download" "$file"
}
fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/$llvm.tar.xz" "$llvm_sha" "$build_root/dl/$llvm.tar.xz"
fetch "https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-macos-universal-release.tar.gz" "$glslang_sha" "$build_root/dl/glslang-16.6.0.tar.gz"
tar -xJf "$build_root/dl/$llvm.tar.xz" -C "$work"
mkdir "$work/glslang"
tar -xzf "$build_root/dl/glslang-16.6.0.tar.gz" -C "$work/glslang"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" -q install meson ninja
export PATH="$work/venv/bin:$work/glslang/bin:$work/$llvm/bin:$PATH"

git init -q "$work/src"
git -C "$work/src" fetch --quiet --depth 1 https://github.com/HansKristian-Work/vkd3d-proton.git "$revision"
git -C "$work/src" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$work/src" rev-parse HEAD)" = "$revision" ]]
git -C "$work/src" submodule update --init --recursive --depth 1
cat > "$work/clang-cross.txt" <<'CROSS'
[binaries]
c = 'x86_64-w64-mingw32-clang'
cpp = 'x86_64-w64-mingw32-clang++'
widl = 'x86_64-w64-mingw32-widl'
windres = 'x86_64-w64-mingw32-windres'
CROSS
meson setup "$work/build" "$work/src" --cross-file "$work/src/build-win64.txt" --cross-file "$work/clang-cross.txt" \
    --buildtype release --strip --prefix "$work/install"
meson install -C "$work/build"
out="$work/overlay/x86_64-windows"
mkdir -p "$out"
for dll in d3d12 d3d12core; do
    built="$(find "$work/install" -type f -name "$dll.dll")"
    cp "$built" "$out/$dll.dll"
    python3 -I "$repo/Scripts/mark-wine-builtin.py" "$out/$dll.dll"
done
echo "Built vkd3d-proton v3.1 ($revision). For a DXMT/DXVK test profile, append to its environment:"
echo "  WINEDLLPATH_PREPEND+ = $work/overlay"
echo "  WINEDLLOVERRIDES = d3d12,d3d12core=n,b"
echo "Run gameport lab with the game window in front. Remove those two entries to revert."
