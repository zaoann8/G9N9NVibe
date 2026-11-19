#!/bin/zsh
# 编译自研 MIT 虚拟驱动 + Release 主程序，组装完整单包 G9N9N-Vibe.app（内置驱动，开包即用）
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="G9NVibe"
BUNDLE_ID="io.github.g9n9n-vibe"
DIST_BUILD="$ROOT_DIR/dist/build"
APP_BUNDLE="$DIST_BUILD/$APP_NAME.app"

print ">>> [1/4] 编译纯 C 自研 MIT 音频驱动..."
"$ROOT_DIR/DriverSource/build-driver.sh"

print ">>> [2/4] 编译 Release 主程序 (-Osize 极致瘦身)..."
MC_DIR="/tmp/g9n9n-module-cache"
mkdir -p "$MC_DIR"
cd "$ROOT_DIR"
if [[ "${BUILD_UNIVERSAL:-0}" == "1" ]]; then
  print "    构建双架构 Universal 二进制 (arm64 + x86_64)..."
  CLANG_MODULE_CACHE_PATH="$MC_DIR" SWIFT_MODULECACHE_PATH="$MC_DIR" \
    swift build -c release --disable-sandbox --arch arm64 --arch x86_64 \
    -Xswiftc -module-cache-path -Xswiftc "$MC_DIR"
  BIN_SRC="$ROOT_DIR/.build/apple/Products/Release/G9N9NVibe"
else
  CLANG_MODULE_CACHE_PATH="$MC_DIR" SWIFT_MODULECACHE_PATH="$MC_DIR" \
    swift build -c release --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$MC_DIR"
  BIN_SRC="$ROOT_DIR/.build/release/G9N9NVibe"
fi

DRIVER_SRC="$ROOT_DIR/DriverSource/build/G9N9NVibeMic.driver"
ICON_SRC="$ROOT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$ICON_SRC" ]]; then
  print ">>> [2.5/4] 生成博朗瓷白硬件面板标准 AppIcon.icns..."
  CLANG_MODULE_CACHE_PATH="$MC_DIR" SWIFT_MODULECACHE_PATH="$MC_DIR" \
    swiftc -module-cache-path "$MC_DIR" -framework AppKit -framework CoreGraphics \
    "$ROOT_DIR/Scripts/generate-app-icon.swift" -o /tmp/generate-app-icon
  /tmp/generate-app-icon "$ICON_SRC" "$ROOT_DIR/Resources/AppIcon.png"
fi

print ">>> [3/4] 组装 $APP_BUNDLE ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Driver"

cp "$BIN_SRC" "$APP_BUNDLE/Contents/MacOS/G9NVibe"
strip -x "$APP_BUNDLE/Contents/MacOS/G9NVibe"
ln -sf G9NVibe "$APP_BUNDLE/Contents/MacOS/G9N9NVibe"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ditto "$DRIVER_SRC" "$APP_BUNDLE/Contents/Resources/Driver/G9N9NVibeMic.driver"

print ">>> [4/4] 固化 Designated Requirement 签名（确保覆盖更新不丢失系统权限）..."
codesign --force --deep --sign - \
  --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" \
  --timestamp=none \
  "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
print "✅ 已生成应用包: $APP_BUNDLE"
print "   主程序大小: $(du -sh "$APP_BUNDLE/Contents/MacOS/G9NVibe" | awk '{print $1}')"
print "   整体包大小: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
