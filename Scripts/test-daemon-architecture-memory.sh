#!/bin/zsh
set -e

ROOT_DIR="${0:A:h:h}"
APP_BIN="$ROOT_DIR/dist/build/G9NVibe.app/Contents/MacOS/G9N9NVibe"

echo "=== [1/4] 清理旧有进程 ==="
killall -9 G9N9NVibe 2>/dev/null || true
sleep 1

echo "=== [2/4] 单独启动后台守护引擎 (G9NDaemon) ==="
"$APP_BIN" --daemon >/tmp/g9n_daemon_test.log 2>&1 &
DAEMON_PID=$!
sleep 2

echo "守护进程 PID: $DAEMON_PID"
if ! kill -0 $DAEMON_PID 2>/dev/null; then
  echo "❌ 守护进程未能成功启动，查看日志:"
  cat /tmp/g9n_daemon_test.log
  exit 1
fi

echo "--- 守护进程 (G9NDaemon) 常驻内存实测 ---"
footprint $DAEMON_PID | grep -E "Footprint|MALLOC|AppKit" | head -10 || true

echo "=== [3/4] 启动前台控制台并连上守护进程 ==="
"$APP_BIN" >/tmp/g9n_console_test.log 2>&1 &
CONSOLE_PID=$!
sleep 3

echo "前台控制台 PID: $CONSOLE_PID"
echo "--- 前台控制台打开时内存实测 ---"
footprint $CONSOLE_PID | grep -E "Footprint" || true

echo "=== [4/4] 模拟关窗退出前台控制台 ==="
kill -TERM $CONSOLE_PID 2>/dev/null || true
sleep 1.5

echo "验证前台进程是否已彻底消亡:"
if kill -0 $CONSOLE_PID 2>/dev/null; then
  echo "⚠️ 前台进程仍在"
else
  echo "✅ 前台进程已彻底退出，内存 100% 归还内核 (0MB)！"
fi

echo "--- 关窗后后台守护引擎 (G9NDaemon) 存活与内存 ---"
footprint $DAEMON_PID | grep -E "Footprint" || true

echo "清理测试守护进程..."
kill -TERM $DAEMON_PID 2>/dev/null || true
echo "=== 测试完成 ==="
