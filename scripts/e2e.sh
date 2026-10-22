#!/bin/bash
# native E2E を、使っているアプリに影響しない形で実行する。
# build/MeetingAnalyzer.app の bundle ID だけを変えた検証用コピー（build/MeetingAnalyzerE2E.app）を作って、それに対して実行する。
# データの置き場所と、ブリッジのトークンの置き場所は、ハーネスが検証用の一時ディレクトリへ向ける（普段の記録・トークンには触れない）。
# 前提: node（偽のブリッジ）、say と日本語の声 Kyoko、ja_JP のオンデバイス認識。足りなければ、該当のケースは blocked になる。
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/MeetingAnalyzer.app ] || ./scripts/build.sh

COPY=build/MeetingAnalyzerE2E.app
rm -rf "$COPY"
cp -R build/MeetingAnalyzer.app "$COPY"
plutil -replace CFBundleIdentifier -string dev.takemo101.meeting-analyzer.e2e "$COPY/Contents/Info.plist"
codesign --force --sign - "$COPY" >/dev/null 2>&1 || { echo "e2e.sh: codesign of $COPY failed" >&2; exit 1; }

exec /usr/bin/swift scripts/native-e2e.swift "$PWD/$COPY/Contents/MacOS/MeetingAnalyzer" --artifacts "$PWD/build/native-e2e"
