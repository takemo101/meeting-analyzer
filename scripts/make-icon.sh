#!/bin/bash
# アプリのアイコンを生成して、Resources/AppIcon.icns に置く。生成物はコミットする（ビルドのたびには、作らない）。
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

/usr/bin/swift scripts/make-icon.swift "$work"
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
# 確認用に、大きい版を、build/ に出す（Git 対象外）。
mkdir -p build
cp "$work/AppIcon.iconset/icon_512x512@2x.png" build/AppIcon-preview.png
echo "wrote Resources/AppIcon.icns（確認用の画像：build/AppIcon-preview.png）"
