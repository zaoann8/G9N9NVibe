#!/bin/bash
set -e

echo "=== [1/4] 退出旧实例并覆盖安装最新 G9NVibe.app ==="
killall G9NVibe 2>/dev/null || true
killall G9N9NVibe 2>/dev/null || true
sleep 1

rm -rf /Applications/G9NVibe.app
cp -R /Users/zaoan/Documents/谷歌遥控器/G9N9N-Vibe/dist/build/G9NVibe.app /Applications/G9NVibe.app

echo "=== [2/4] 启动最新 G9NVibe.app ==="
open /Applications/G9NVibe.app
sleep 2

PID=$(pgrep -x G9N9NVibe || pgrep -x G9NVibe || pgrep -f G9NVibe.app/Contents/MacOS || true)
if [ -z "$PID" ]; then
    echo "❌ 未找到 G9NVibe 进程！"
    exit 1
fi

echo "✅ 进程已启动，PID: $PID"

echo "=== [3/4] 采集待机物理内存足迹 (footprint) ==="
footprint $PID | head -n 30 || true

echo "=== [4/4] 采集 vmmap 内存分类摘要 ==="
vmmap --summary $PID | grep -E "(TOTAL|IOAccelerator|STACK|MALLOC|CoreGraphics|WebKit|SwiftUI)" || true

echo "=== 检查系统中所有与 G9N 相关的进程及内存 ==="
ps aux | grep -i G9N | grep -v grep || true
