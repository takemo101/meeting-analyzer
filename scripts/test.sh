#!/bin/bash
# 単体テスト（Swift Testing）。Command Line Tools だけの環境では、SwiftPM がマクロのプラグインを渡さないため、パスを明示する。
set -euo pipefail
cd "$(dirname "$0")/.."

# 文字起こしの推論の実行環境（transcribe.cpp）。ビルド済みなら、何もしない。
./scripts/build-native.sh

plugins="$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins/testing"
if [ ! -d "$plugins" ]; then
    echo "error: Swift Testing のマクロプラグインが見つかりません: $plugins" >&2
    exit 1
fi
exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
