#!/bin/bash
set -e

PID=$(pgrep -x G9N9NVibe || true)
if [ -z "$PID" ]; then
    echo "未找到运行中的 G9N9NVibe 进程"
    exit 1
fi

echo "=== [1] 当前待机内存状态 (PID: $PID) ==="
footprint $PID | head -n 15
ps -o pid,rss,vsz,comm -p $PID

echo "=== [2] 通过菜单模拟点击触发录音（或触发测试会话）==="
# 通过 AppleScript 发送右 Option 键或直接触发模拟
osascript -e 'tell application "System Events" to key code 61' 2>/dev/null || true
sleep 1

echo "=== [3] 录音中 1 秒内存状态 ==="
footprint $PID | head -n 15
ps -o pid,rss,vsz,comm -p $PID
vmmap --summary $PID | grep -E "(TOTAL|IOAccelerator|CoreGraphics|MALLOC_)" | head -n 20

sleep 2

echo "=== [4] 录音中 3 秒内存状态 ==="
footprint $PID | head -n 15

# 再次按下结束录音
osascript -e 'tell application "System Events" to key code 61' 2>/dev/null || true
sleep 1

echo "=== [5] 录音停止后内存状态 ==="
footprint $PID | head -n 15
ps -o pid,rss,vsz,comm -p $PID
