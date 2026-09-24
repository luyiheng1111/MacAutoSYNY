#!/bin/sh
# 打包 SYNY 安装盘（DMG）—— 拖拽安装 + 内附《安装说明》。
#
#   ./scripts/build-dmg.sh              构建 app（如需）并打包到 dist/SYNY-<版本>.dmg
#   ./scripts/build-dmg.sh --skip-build 跳过 app 构建，直接用现有 SYNY.app 打包
#   ./scripts/build-dmg.sh --open       打包完成后自动打开 DMG 供预览
#   ./scripts/build-dmg.sh --relayout   改用 Finder 重新生成窗口布局模板
#                                       （需要「自动化 → 访达」权限；正常构建不需要）
#
# 安装盘内容：
#   SYNY.app                  应用本体
#   应用程序 -> /Applications  「拖到这里」的落点（符号链接）
#   安装说明.txt               面向第一次安装、不熟悉 macOS 安全验证的使用者
#   .background/…              Finder 窗口背景图（2x，Retina 下不糊）
#   .DS_Store                  窗口尺寸 / 图标位置 / 背景图引用
#
# 关于窗口布局：Finder 的 AppleScript「set bounds」在不同 macOS 版本上行为
# 不一致（实测会把 600x420 存成 920x464），且需要「自动化」权限。因此默认
# 直接复用 packaging/dmg_layout.DS_Store 这份已验证的模板，再用 icongen
# 原地改写其中的窗口尺寸字段 —— 构建过程零 Finder 依赖、结果可复现。
#
# 依赖：hdiutil、icongen（Swift 图标/布局生成器，随构建产出）
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SYNY.app"
SRC="$ROOT/SYNY"
DIST="$ROOT/dist"
PACKAGING="$ROOT/packaging"

VOLNAME="SYNY"                       # 卷名（挂载点 /Volumes/SYNY）
GUIDE="安装说明.txt"
LAYOUT_TEMPLATE="$PACKAGING/dmg_layout.DS_Store"

# 尺寸约定，必须与 IconGen/main.swift 里的常量保持一致：
#   设计区（= 窗口内容区）600 x 420
#   窗口外框 = 内容区 + 标题栏/状态栏（实测 44pt）
#   背景图 = 600 x 476（底部多留 56pt 渐变，吸收不同 macOS 的装饰高度差异）
WIN_W=600
WIN_CONTENT_H=420
CHROME_H=44
WIN_H=$((WIN_CONTENT_H + CHROME_H))
WIN_POINTS="${WIN_W}x${WIN_H}"

# 图标坐标（Finder 坐标，原点在内容区左上）：
# 左「安装说明」/ 中「SYNY」/ 右「应用程序」
GUIDE_XY="95, 200"
APP_XY="262, 200"
APPS_XY="497, 200"

SKIP_BUILD=0
OPEN_AFTER=0
RELAYOUT=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --open)       OPEN_AFTER=1 ;;
        --relayout)   RELAYOUT=1 ;;
        *) echo "未知参数：$arg"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- #
echo "==> 1/7 准备应用本体"
if [ "$SKIP_BUILD" = "1" ] && [ -d "$APP" ]; then
    echo "    按参数跳过构建，沿用现有 $APP"
else
    "$ROOT/scripts/build-swift.sh"
fi
[ -d "$APP" ] || { echo "未找到 $APP，请先运行 scripts/build-swift.sh"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
FINAL_DMG="$DIST/SYNY-${VERSION}.dmg"

# ---------------------------------------------------------------- #
echo "==> 2/7 生成 DMG 背景图（2x / 144dpi，设计区 ${WIN_W}x${WIN_CONTENT_H} + 底部余量）"
swift build -c release --package-path "$SRC" --disable-sandbox --product icongen
ICONGEN="$SRC/.build/release/icongen"

STAGE="$(mktemp -d /tmp/syny_dmg_stage.XXXXXX)"
RW_DMG="$(mktemp -u /tmp/syny_rw.XXXXXX).dmg"
MOUNT="/Volumes/$VOLNAME"
cleanup() {
    # 任一步失败都要把已挂载的卷摘掉，否则下次构建会撞名字
    if [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; fi
    rm -rf "$STAGE" "$RW_DMG"
}
trap cleanup EXIT

mkdir -p "$STAGE/.background"
"$ICONGEN" --dmg-background "$STAGE/.background/dmg_background.png" --scale 2 --dpi 144

echo "==> 3/7 布置安装盘内容"
cp -R "$APP" "$STAGE/SYNY.app"
ln -s /Applications "$STAGE/应用程序"
[ -f "$PACKAGING/$GUIDE" ] && cp "$PACKAGING/$GUIDE" "$STAGE/$GUIDE"

# 卷图标（可选，SetFile 来自 Xcode 命令行工具）
if [ -f "$ROOT/build/icon.icns" ]; then
    cp "$ROOT/build/icon.icns" "$STAGE/.VolumeIcon.icns"
fi

echo "==> 4/7 写入窗口布局（外框 ${WIN_POINTS}）"
if [ "$RELAYOUT" = "1" ] && [ -x "$ROOT/scripts/relayout-dmg.sh" ]; then
    echo "    --relayout：用 Finder 重新生成布局"
    "$ROOT/scripts/relayout-dmg.sh" "$STAGE" "$VOLNAME" "$WIN_W" "$WIN_H" \
        "$GUIDE_XY" "$APP_XY" "$APPS_XY" \
        || echo "    ⚠️  Finder 布局生成失败，回退到模板"
fi
if [ ! -f "$STAGE/.DS_Store" ]; then
    if [ -f "$LAYOUT_TEMPLATE" ]; then
        cp "$LAYOUT_TEMPLATE" "$STAGE/.DS_Store"
        echo "    已套用布局模板 packaging/dmg_layout.DS_Store"
    else
        echo "    ⚠️  缺少布局模板，安装盘将以 Finder 默认外观打开"
    fi
fi
# 无论来源如何，都把窗口尺寸改写成设计值（原地替换，保持字节长度）
if [ -f "$STAGE/.DS_Store" ]; then
    "$ICONGEN" --patch-dmg-layout "$STAGE/.DS_Store" "$WIN_POINTS" \
        || echo "    ⚠️  窗口尺寸改写失败，可能沿用模板内的原尺寸"
fi

echo "==> 5/7 创建可读写 DMG 映像"
mkdir -p "$DIST"
# HFS+ 文件系统：.DS_Store 与自定义背景图在 HFS+ 上的兼容性最好
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

# 挂载一次并设置卷图标，同时验证 DMG 可正常挂载
hdiutil attach "$RW_DMG" -noautoopen -mountpoint "$MOUNT" >/dev/null
if [ -f "$ROOT/build/icon.icns" ] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT"
fi

echo "==> 6/7 卸载并压缩为只读 DMG"
hdiutil detach "$MOUNT" >/dev/null
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"

# 临时签名 DMG：接收方下载后仍会过 Gatekeeper，但至少包本身是完整的
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$FINAL_DMG" >/dev/null 2>&1 || true
fi

echo "==> 7/7 校验产物"
if hdiutil verify "$FINAL_DMG" >/dev/null 2>&1; then
    echo "    ✅ DMG 校验通过"
else
    echo "    ⚠️  DMG 校验未通过，请重试构建"
fi
echo "    产物：$FINAL_DMG  ($(du -h "$FINAL_DMG" | cut -f1))"

if [ "$OPEN_AFTER" = "1" ]; then
    open "$FINAL_DMG"
fi
