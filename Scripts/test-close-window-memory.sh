#!/bin/bash
set -e

PID=$(pgrep -x G9N9NVibe || true)
if [ -z "$PID" ]; then
    echo "未找到运行中的 G9N9NVibe 进程"
    exit 1
fi

echo "=== [1] 当前开窗状态内存 ==="
footprint $PID | head -n 15

echo "=== [2] 通过 AppleScript 关闭主控制台窗口 (Cmd+W) ==="
osascript -e '
tell application "G9NVibe" to activate
tell application "System Events"
    keystroke "w" using {command down}
end tell
' 2>/dev/null || true

sleep 2

echo "=== [3] 关窗后后台常驻内存 ==="
footprint $PID | head -n 25
ps -o pid,rss,vsz,comm -p $PID

echo "=== [4] vmmap 分析已释放脏页与保留区域 ==="
vmmap --summary $PID | grep -E "(TOTAL|IOAccelerator|STACK|MALLOC|CoreGraphics|WebKit|SwiftUI)" || true
