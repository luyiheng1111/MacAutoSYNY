#!/bin/sh
# 【辅助脚本，正常构建用不到】用 Finder 重新生成 DMG 窗口布局。
#
#   scripts/relayout-dmg.sh <暂存目录> <卷名> <宽> <高> \
#                           "<安装说明坐标>" "<SYNY坐标>" "<应用程序坐标>" [--save-template]
#
# 什么时候需要它：调整了背景图布局（图标落点/窗口尺寸）之后，想用 Finder 原生
# 方式重新算一遍图标位置和背景图别名，再写回 packaging/dmg_layout.DS_Store。
#
# 为什么默认不用它：AppleScript 的「set bounds」在不同 macOS 版本上行为不一致，
# 而且需要「自动化 → 访达」权限；无权限时会直接报错。
#   macOS 14+ 授权路径：系统设置 → 隐私与安全性 → 自动化 → 勾选对应终端 App 的「访达」
set -e

STAGE="$1"
VOLNAME="$2"
WIN_W="$3"
WIN_H="$4"
GUIDE_XY="$5"
APP_XY="$6"
APPS_XY="$7"
SAVE_TEMPLATE=0
[ "$8" = "--save-template" ] && SAVE_TEMPLATE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOUNT="/Volumes/$VOLNAME"
TMP_DMG="$(mktemp -u /tmp/syny_relayout.XXXXXX).dmg"

cleanup() {
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    rm -f "$TMP_DMG"
}
trap cleanup EXIT

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -ov "$TMP_DMG" >/dev/null
hdiutil attach "$TMP_DMG" -noautoopen -mountpoint "$MOUNT" >/dev/null

LAYOUT="$(mktemp /tmp/syny_layout.XXXXXX).applescript"
cat > "$LAYOUT" <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {360, 120, $((360 + WIN_W)), $((120 + WIN_H))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:dmg_background.png"
        set position of item "SYNY.app" of container window to {$APP_XY}
        set position of item "应用程序" of container window to {$APPS_XY}
        set position of item "安装说明.txt" of container window to {$GUIDE_XY}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

if ! osascript "$LAYOUT"; then
    rm -f "$LAYOUT"
    echo "Finder 布局脚本执行失败（多半是缺少「自动化 → 访达」权限）"
    exit 1
fi
rm -f "$LAYOUT"

sync
sleep 1
if [ -f "$MOUNT/.DS_Store" ]; then
    cp "$MOUNT/.DS_Store" "$STAGE/.DS_Store"
    echo "已生成 $STAGE/.DS_Store"
    if [ "$SAVE_TEMPLATE" = "1" ]; then
        cp "$MOUNT/.DS_Store" "$ROOT/packaging/dmg_layout.DS_Store"
        echo "已更新模板 packaging/dmg_layout.DS_Store"
    fi
else
    echo "未找到 .DS_Store，布局未落盘"
    exit 1
fi
