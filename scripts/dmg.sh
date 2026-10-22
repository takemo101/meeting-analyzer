#!/bin/bash
# build/MeetingAnalyzer.dmg を作る（MeetingAnalyzer.app と /Applications へのショートカット入り。Apple silicon。ad-hoc 署名）。
#
#   ./scripts/dmg.sh                    Info.plist の版のまま
#   VERSION=X.Y.Z ./scripts/dmg.sh      アプリの版を X.Y.Z にして作る（リリースのワークフローが使う）
#
# 署名は ad-hoc のまま（Developer ID の署名・公証はしない）。他の Mac で開くと、Gatekeeper の警告が出る（リリースの説明に、外し方を書く）。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

APP=build/MeetingAnalyzer.app
DMG=build/MeetingAnalyzer.dmg
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname MeetingAnalyzer -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "built: $DMG"
