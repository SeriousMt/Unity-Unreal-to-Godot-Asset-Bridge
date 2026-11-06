#!/usr/bin/env bash
# Builds ab-ooz, the optional Oodle (Kraken) decompressor Asset Bridge uses for
# UE5-saved Unreal content. It downloads powzix/ooz (GPL-3.0-or-later) at a
# pinned commit, swaps its Windows-only header for compat.h and drops its
# Windows main(). The resulting binary is GPL-3.0-or-later and runs as a
# separate program; the Asset Bridge addon itself does not link it.
#
#   tools/ooz-helper/build.sh [ooz source dir]
#
# Output: addons/asset_bridge/unreal/bin/ab-ooz  (x86-64 Linux/macOS, needs g++ or clang++)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$(dirname "$here")")"
OOZ_COMMIT=0503806
out_dir="$repo/addons/asset_bridge/unreal/bin"
work="$(mktemp -d "${TMPDIR:-/tmp}/ab-ooz.XXXXXX")"
trap 'rm -rf "$work"' EXIT

src="${1:-}"
if [[ -z "$src" ]]; then
  git clone -q https://github.com/powzix/ooz.git "$work/ooz"
  git -C "$work/ooz" checkout -q "$OOZ_COMMIT"
  src="$work/ooz"
fi

mkdir -p "$work/build"
for f in kraken.cpp lzna.cpp bitknit.cpp; do
  sed 's/#include "stdafx.h"/#include "compat.h"/' "$src/$f" > "$work/build/$f"
done
# Keep the decoder, drop the DLL loader and command line tool at the end of kraken.cpp.
cut_line="$(grep -n 'typedef int WINAPI OodLZ_CompressFunc' "$work/build/kraken.cpp" | cut -d: -f1)"
head -n "$((cut_line - 1))" "$work/build/kraken.cpp" > "$work/build/kraken_dec.cpp"
cp "$here/compat.h" "$here/main.cpp" "$work/build/"

CXX="${CXX:-$(command -v g++ || command -v clang++)}"
mkdir -p "$out_dir"
"$CXX" -O2 -msse4.1 -w -fpermissive -o "$out_dir/ab-ooz" \
  "$work/build/main.cpp" "$work/build/kraken_dec.cpp" "$work/build/lzna.cpp" "$work/build/bitknit.cpp"
echo "built $out_dir/ab-ooz"
