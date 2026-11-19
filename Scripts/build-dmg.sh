#!/bin/zsh
# 生成小白开包即用单文件 DMG（内置 Applications 快捷方式）
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
APP_NAME="G9NVibe"
APP_BUNDLE="$ROOT_DIR/dist/build/$APP_NAME.app"
STAGE_DIR="$ROOT_DIR/dist/dmg-stage"
DMG_OUT="$ROOT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

"$ROOT_DIR/Scripts/package-app.sh"

rm -rf "$STAGE_DIR" "$DMG_OUT"
mkdir -p "$STAGE_DIR"

ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_OUT"

rm -rf "$STAGE_DIR"
# 同步生成通用最新别名 DMG，便于发布永远无需固定版本号的永久直链
cp -f "$DMG_OUT" "$ROOT_DIR/dist/${APP_NAME}.dmg"
print "✅ 单文件小白 DMG 已生成: $DMG_OUT"
print "   通用最新别名 DMG: $ROOT_DIR/dist/${APP_NAME}.dmg"
print "   DMG 大小: $(du -h "$DMG_OUT" | awk '{print $1}')"
shasum -a 256 "$DMG_OUT"
