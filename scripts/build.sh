#!/bin/bash
# build/MeetingAnalyzer.app を作る（Apple silicon。ad-hoc 署名）。
set -euo pipefail
cd "$(dirname "$0")/.."

# 文字起こしの推論の実行環境（transcribe.cpp。C のヘッダと静的ライブラリ）。ビルド済みなら、何もしない。
./scripts/build-native.sh
swift build -c release --arch arm64

APP=build/MeetingAnalyzer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/MeetingAnalyzer" "$APP/Contents/MacOS/MeetingAnalyzer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# アプリのアイコン（scripts/make-icon.sh で生成してコミットしたもの）。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# エージェントへ渡す skill を、同梱する（`meeting-analyzer claude` が、システムプロンプトへ足す）。
cp skills/meeting-analyzer/SKILL.md "$APP/Contents/Resources/SKILL.md"
# pi・omp に、字幕を押し込む拡張（`meeting-analyzer pi|omp` が、-e で渡す）。
cp integrations/pi/meeting-analyzer.js "$APP/Contents/Resources/meeting-analyzer-pi.js"
# opencode に、字幕を押し込むプラグイン（`meeting-analyzer opencode` が、その起動だけに載せる）。ディレクトリ（package.json + server.js）。
cp -R integrations/opencode "$APP/Contents/Resources/meeting-analyzer-opencode"
# 文字起こしの推論の実行環境（transcribe.cpp・ggml）のライセンス（MIT）。静的に取り込んでいるので、同梱する（SPEC §3.12）。
mkdir -p "$APP/Contents/Resources/licenses"
cp build/native/src/LICENSE "$APP/Contents/Resources/licenses/transcribe.cpp-LICENSE"
cp build/native/src/THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/licenses/transcribe.cpp-THIRD-PARTY-LICENSES.md"
# 声による話者の分離（SPEC §3.14）：モデルの出典・CC-BY-4.0 の表示（このリポジトリの `Resources/licenses/`）と、FluidAudio（Apache-2.0）・その fastcluster・vbx のライセンス（SwiftPM が取り込んだもの）。
cp Resources/licenses/voice-separation-NOTICE.md "$APP/Contents/Resources/licenses/voice-separation-NOTICE.md"
FLUID=.build/checkouts/FluidAudio
cp "$FLUID/LICENSE" "$APP/Contents/Resources/licenses/FluidAudio-LICENSE"
cp "$FLUID/ThirdPartyLicenses/fastcluster-LICENSE.md" "$APP/Contents/Resources/licenses/FluidAudio-fastcluster-LICENSE.md"
cp "$FLUID/ThirdPartyLicenses/vbx-LICENSE.md" "$APP/Contents/Resources/licenses/FluidAudio-vbx-LICENSE.md"
# 分析のプリセット（解説・提案・サマリーの出し方。メニューで選ぶ。SPEC §3.11）。自分のプリセットは、データの置き場所の presets/ に置く。
cp -R presets "$APP/Contents/Resources/presets"
# プリセットを作る・直すための skill（エージェントの skill フォルダへ、コピーして使う。docs/presets.md）。
mkdir -p "$APP/Contents/Resources/skills"
cp -R skills/meeting-analyzer-presets "$APP/Contents/Resources/skills/meeting-analyzer-presets"
# アクターの一覧（ACTOR.md）を、プロジェクトの資料から作る skill（同上。docs/actors.md）。
cp -R skills/meeting-analyzer-actors "$APP/Contents/Resources/skills/meeting-analyzer-actors"
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
    # 同じ ID で ad-hoc 署名した別のコードも、同じ許可を得る。Developer ID の署名をしない配布（DMG）も、更新のたびに許可が無効にならないよう、同じ方式にしている）。
    codesign --force --sign - -r="designated => identifier \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")\"" "$APP"
fi

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/MeetingAnalyzer"
