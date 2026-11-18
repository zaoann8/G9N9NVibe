#!/bin/zsh
# 编译原生纯 C MIT 音频驱动（生成 Apple Silicon + Intel 通用二进制 .driver）
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE="$BUILD_DIR/G9N9NVibeMic.driver"
MACOS_DIR="$BUNDLE/Contents/MacOS"
BIN_PATH="$MACOS_DIR/G9N9NVibeMic"

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR"

SDK_PATH="$(xcrun --show-sdk-path)"
CFLAGS=(
  -O2 -Wall -Wextra -Werror
  -bundle
  -isysroot "$SDK_PATH"
  -mmacosx-version-min=12.0
  -framework CoreAudio
  -framework CoreFoundation
)

clang "${CFLAGS[@]}" -arch arm64 "$SCRIPT_DIR/G9N9NVibeMic.c" -o "$BUILD_DIR/driver_arm64"
clang "${CFLAGS[@]}" -arch x86_64 "$SCRIPT_DIR/G9N9NVibeMic.c" -o "$BUILD_DIR/driver_x86_64"
lipo -create "$BUILD_DIR/driver_arm64" "$BUILD_DIR/driver_x86_64" -output "$BIN_PATH"
rm -f "$BUILD_DIR/driver_arm64" "$BUILD_DIR/driver_x86_64"
strip -x "$BIN_PATH"

cp "$SCRIPT_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$BUNDLE"

print "已编译原生驱动: $BUNDLE"
print "支持架构: $(lipo -archs "$BIN_PATH")"
print "二进制大小: $(du -h "$BIN_PATH" | awk '{print $1}')"
