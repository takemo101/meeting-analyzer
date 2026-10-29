#!/bin/bash
# 文字起こしの推論の実行環境 transcribe.cpp（ggml。MIT）を、固定した版（commit）で、静的ライブラリにビルドする。
# 出力：build/native/include（C のヘッダ）と build/native/lib（静的ライブラリ）。SwiftPM が、これを使う（Package.swift）。
# すでに同じ版をビルド済みなら、何もしない。必要なもの：git・Command Line Tools。cmake が無ければ、build/native/venv に pip で入れる（PyPI）。
# ネットワーク：ソースの取得（GitHub）と、cmake の取得（無いときだけ）。
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT="5700f127e38dd53c4735ea23ef743b4b538eacd4"
OUT="$PWD/build/native"
STAMP="$OUT/.built-$COMMIT"
if [ -f "$STAMP" ] && [ -f "$OUT/lib/libtranscribe.a" ]; then exit 0; fi

mkdir -p "$OUT"
SRC="$OUT/src"
if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin https://github.com/handy-computer/transcribe.cpp
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]; then
    git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
    git -C "$SRC" checkout -q --force FETCH_HEAD
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "build-native.sh: transcribe.cpp の版が違います" >&2; exit 1; }

CMAKE="$(command -v cmake || true)"
NINJA="$(command -v ninja || true)"
if [ -z "$CMAKE" ]; then
    python3 -m venv "$OUT/venv"
    "$OUT/venv/bin/pip" install -q cmake ninja
    CMAKE="$OUT/venv/bin/cmake"
    NINJA="$OUT/venv/bin/ninja"
fi
GENERATOR=(); [ -n "$NINJA" ] && GENERATOR=(-G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA")

rm -rf "$OUT/cmake" "$OUT/install"
"$CMAKE" -S "$SRC" -B "$OUT/cmake" "${GENERATOR[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
    -DTRANSCRIBE_INSTALL=ON -DCMAKE_INSTALL_PREFIX="$OUT/install" > "$OUT/configure.log" 2>&1 || { tail -20 "$OUT/configure.log" >&2; exit 1; }
"$CMAKE" --build "$OUT/cmake" -j "$(sysctl -n hw.ncpu)" > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log" >&2; exit 1; }
"$CMAKE" --install "$OUT/cmake" > "$OUT/install.log" 2>&1 || { tail -20 "$OUT/install.log" >&2; exit 1; }

rm -rf "$OUT/include" "$OUT/lib"
cp -R "$OUT/install/include" "$OUT/include"
cp -R "$OUT/install/lib" "$OUT/lib"
rm -f "$OUT"/.built-*
touch "$STAMP"
echo "built: $OUT (transcribe.cpp ${COMMIT:0:7})"
