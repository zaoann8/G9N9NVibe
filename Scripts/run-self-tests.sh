#!/bin/zsh
# 一键运行 ATVV/ADPCM 协议自测与语音会话状态机自测
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TMP_BIN="/tmp/g9n9n_vibe_protocol_selftest"
MC_DIR="/tmp/g9n9n-module-cache"
mkdir -p "$MC_DIR"

print ">>> [1/2] 运行 ATVV & ADPCM 协议回归测试..."
swiftc -module-cache-path "$MC_DIR" \
  "$ROOT_DIR/Sources/G9N9NVibe/Hardware/ATVV/ADPCMDecoder.swift" \
  "$ROOT_DIR/Sources/G9N9NVibe/Hardware/ATVV/ATVVProtocol.swift" \
  "$ROOT_DIR/SelfTests/main.swift" \
  -o "$TMP_BIN"
"$TMP_BIN"
rm -f "$TMP_BIN"

print ">>> [2/3] 编译 Debug 主程序并运行语音会话与防冲突自测..."
cd "$ROOT_DIR"
CLANG_MODULE_CACHE_PATH="$MC_DIR" SWIFT_MODULECACHE_PATH="$MC_DIR" \
  swift build --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$MC_DIR"
"$ROOT_DIR/.build/debug/G9N9NVibe" --voice-session-self-test

print ">>> [3/3] 运行 CoreAudio 虚拟驱动硬件真实加载与音频闭环自测..."
DRIVER_TEST_BIN="/tmp/g9n9n_vibe_driver_live_test"
swiftc -module-cache-path "$MC_DIR" "$ROOT_DIR/SelfTests/driver_live_test.swift" -o "$DRIVER_TEST_BIN"
"$DRIVER_TEST_BIN"
rm -f "$DRIVER_TEST_BIN"
