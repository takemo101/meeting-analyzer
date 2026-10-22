#!/bin/bash
# 単体テスト（Swift Testing）。Command Line Tools だけの環境では、SwiftPM がマクロのプラグインを渡さないため、パスを明示する。
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins/testing"
if [ ! -d "$plugins" ]; then
    echo "error: Swift Testing のマクロプラグインが見つかりません: $plugins" >&2
    exit 1
fi
exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
