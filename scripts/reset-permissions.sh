#!/bin/bash
# このアプリのマイク・画面収録の許可を、取り消す（次の「開始」で、OS の許可の確認が、もう一度出る）。
# 設定の一覧ではオンに見えるのに、「許可されていません」と出るとき（入れ直しで、許可が無効になったとき）に使う。
# 許可は bundle ID に紐づくので、INSTALL_DIR を変えた検証用のコピーでも、本物の許可が取り消される。
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/install-lib.sh
. scripts/install-lib.sh
reset_permissions
