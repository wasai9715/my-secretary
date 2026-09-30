#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
# Launch within the .app bundle so UserNotifications sees a valid bundle identifier.
# The test path opens, closes, and reopens the same management window, exiting
# with a nonzero code if the window would be released while still referenced.
"$PWD/dist/MySecretary.app/Contents/MacOS/MySecretary" --check-management-window
printf '管理窗口关闭并重开：通过\n'
"$PWD/dist/MySecretary.app/Contents/MacOS/MySecretary" --check-management-drag
printf '管理窗口原生标题栏可拖动：通过\n'
"$PWD/dist/MySecretary.app/Contents/MacOS/MySecretary" --check-management-escape
printf '管理页面 Escape 关闭：通过\n'
