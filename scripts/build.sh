#!/bin/bash
# build/MeetingAnalyzer.app を作る（Apple silicon。ad-hoc 署名）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64

APP=build/MeetingAnalyzer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/MeetingAnalyzer" "$APP/Contents/MacOS/MeetingAnalyzer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# エージェントへ渡す skill を、同梱する（`meeting-analyzer claude` が、システムプロンプトへ足す）。
cp skills/meeting-analyzer/SKILL.md "$APP/Contents/Resources/SKILL.md"
# VERSION=X.Y.Z を渡すと、アプリの版にする（署名の前に書き換える）。未指定なら、Info.plist のまま。
if [ -n "${VERSION:-}" ]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build.sh: VERSION は X.Y.Z の形で指定してください: $VERSION" >&2; exit 1; }
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
# SIGN_IDENTITY 未指定なら ad-hoc 署名（手元用）。Developer ID を指定すると Hardened Runtime つきで署名する。
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    # ad-hoc 署名は、既定では、署名の識別（指定要件）が実行ファイルのハッシュ（cdhash）になり、ビルドのたびに変わる。
    # マイク・画面収録の許可は、この要件に紐づくので、入れ直すたびに、設定ではオンに見えても、無効になる。
    # そこで、指定要件を bundle ID だけにして、ビルドが変わっても、同じアプリとして扱われるようにする（手元の開発用。
    # 同じ ID で ad-hoc 署名した別のコードも、同じ許可を得るので、配布物には使わない）。
    codesign --force --sign - -r="designated => identifier \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")\"" "$APP"
fi

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/MeetingAnalyzer"
