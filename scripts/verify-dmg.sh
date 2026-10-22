#!/bin/bash
# ビルドした DMG を、公開の前に検査する（ローカルでも、リリースのワークフローでも、同じもの）。
#
#   ./scripts/verify-dmg.sh build/MeetingAnalyzer.dmg [期待する版 X.Y.Z]
#
# 検査：DMG の整合、中身（アプリ・/Applications へのリンク・同梱の skill と拡張）、アプリの版（指定したとき）、
#       arm64 を含むこと、署名の整合。ひとつでも失敗したら、終了コード 1。
# DMG を読み取り専用でマウントして調べ、終わったら必ずデタッチする。
#
# 注意：macOS 標準の bash 3.2 は、EXIT トラップがあると、未定義変数などの致命的なエラーの終了コードを 0 にしてしまう。
# 検査が失敗を握りつぶさないよう、検査はサブシェルで走らせ、後始末は、その終了コードを保存してから行う（EXIT トラップは使わない）。
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <dmg> [version]}"
EXPECTED_VERSION="${2:-}"

fail() { echo "verify-dmg: FAIL: $*" >&2; exit 1; }
ok() { echo "verify-dmg: ok: $*"; }

[ -f "${DMG}" ] || fail "DMG が無い: ${DMG}"
MOUNT="$(mktemp -d)"

checks() {
    hdiutil verify "${DMG}" >/dev/null 2>&1 || fail "hdiutil verify が通らない"
    ok "DMG の整合（hdiutil verify）"

    hdiutil attach "${DMG}" -readonly -nobrowse -noverify -mountpoint "${MOUNT}" -quiet >/dev/null 2>&1 || fail "マウントできない"
    local app="${MOUNT}/MeetingAnalyzer.app"

    [ -d "${app}" ] || fail "MeetingAnalyzer.app が DMG に無い"
    [ -L "${MOUNT}/Applications" ] && [ "$(readlink "${MOUNT}/Applications")" = "/Applications" ] || fail "/Applications へのリンクが無い"
    ok "中身（MeetingAnalyzer.app、/Applications へのリンク）"

    [ -s "${app}/Contents/Resources/SKILL.md" ] || fail "同梱の skill（Resources/SKILL.md）が無い"
    [ -s "${app}/Contents/Resources/meeting-analyzer-pi.js" ] || fail "pi・omp の拡張（Resources/meeting-analyzer-pi.js）が無い"
    [ -s "${app}/Contents/Resources/meeting-analyzer-opencode/server.js" ] && [ -s "${app}/Contents/Resources/meeting-analyzer-opencode/package.json" ] || fail "opencode のプラグイン（Resources/meeting-analyzer-opencode/）が無い"
    [ -s "${app}/Contents/Resources/presets/standard.md" ] || fail "既定のプリセット（Resources/presets/standard.md）が無い"
    [ "$(ls "${app}/Contents/Resources/presets"/*.md | wc -l | tr -d " ")" -ge 6 ] || fail "同梱のプリセットが 6 件に満たない"
    ok "同梱物（skill、pi・omp の拡張、opencode のプラグイン、プリセット）"

    local plist="${app}/Contents/Info.plist"
    if [ -n "${EXPECTED_VERSION}" ]; then
        local short build
        short="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
        build="$(plutil -extract CFBundleVersion raw "${plist}")"
        [ "${short}" = "${EXPECTED_VERSION}" ] || fail "アプリの版 ${short} が、期待する ${EXPECTED_VERSION} と違う"
        [ "${build}" = "${EXPECTED_VERSION}" ] || fail "CFBundleVersion ${build} が、期待する ${EXPECTED_VERSION} と違う"
        ok "アプリの版 ${short}"
    fi

    local archs
    archs="$(lipo -archs "${app}/Contents/MacOS/MeetingAnalyzer")"
    case " ${archs} " in *" arm64 "*) ;; *) fail "arm64 を含まない（${archs}）" ;; esac
    ok "アーキテクチャ（${archs}）"

    # 取り出した版が、`--version`（実行ファイルが持つ版）と一致すること。
    if [ -n "${EXPECTED_VERSION}" ]; then
        local reported
        reported="$("${app}/Contents/MacOS/MeetingAnalyzer" --version)"
        [ "${reported}" = "meeting-analyzer ${EXPECTED_VERSION}" ] || fail "--version が「${reported}」（期待：meeting-analyzer ${EXPECTED_VERSION}）"
        ok "--version（${reported}）"
    fi

    codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail "codesign --verify が通らない"
    ok "署名の整合（codesign --verify --deep --strict）"
}

set +e
( set -e; checks )
rc=$?
set -e

hdiutil detach "${MOUNT}" -quiet >/dev/null 2>&1 || hdiutil detach "${MOUNT}" -force -quiet >/dev/null 2>&1 || true
rmdir "${MOUNT}" 2>/dev/null || true

if [ "${rc}" -ne 0 ]; then
    echo "verify-dmg: FAILED (exit ${rc}): ${DMG}" >&2
    exit "${rc}"
fi
echo "verify-dmg: all checks passed: ${DMG}"
