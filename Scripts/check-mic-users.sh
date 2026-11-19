#!/bin/bash
echo "=== 检查系统 CoreAudio 当前激活的输入流进程 ==="
log show --predicate 'subsystem == "com.apple.audio.coreaudiod" and composedMessage contains "recording"' --last 1m 2>/dev/null | tail -n 20 || true

echo "=== 检查 G9NVibe 进程的 AudioQueue 状态 ==="
PID=$(pgrep -x G9N9NVibe || true)
if [ -n "$PID" ]; then
    vmmap $PID | grep -i "AudioToolbox" || true
fi
