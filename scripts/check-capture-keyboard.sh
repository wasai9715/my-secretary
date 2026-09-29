#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
"$PWD/dist/MySecretary.app/Contents/MacOS/MySecretary" --check-capture-keyboard
printf '录入浮层默认聚焦、输入框内与空白处 Esc 退出：通过\n'
