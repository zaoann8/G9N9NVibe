#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DIST_APP="$ROOT_DIR/dist/build/G9NVibe.app"
DEST_APP="/Applications/G9NVibe.app"

echo ">>> [1/4] 清理正在运行的旧实例..."
killall G9NVibe 2>/dev/null || true
killall G9N9NVibe 2>/dev/null || true
sleep 0.5

echo ">>> [2/4] 安装最新双进程解耦版本到 /Applications/ ..."
rm -rf "$DEST_APP"
ditto "$DIST_APP" "$DEST_APP"

echo ">>> [3/4] 清除隔离属性并刷新 LaunchServices 注册表..."
xattr -cr "$DEST_APP" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_APP" || true

echo ">>> [4/4] 启动全新 G9NVibe..."
open "$DEST_APP"
echo "✅ 安装并启动成功！"
