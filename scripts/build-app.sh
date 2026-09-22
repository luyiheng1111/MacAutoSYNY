#!/bin/sh
# 构建原生 SYNY.app —— SwiftUI 前端（SwiftPM）+ Python 后端（src/syny_auth）
#
#   ./scripts/build-app.sh              构建到项目根目录 SYNY.app
#   ./scripts/build-app.sh --install    构建并安装到 /Applications
#   ./scripts/build-app.sh --debug      用 debug 配置构建（更快）
#
# 产物结构：
#   SYNY.app/Contents/MacOS/SYNY            SwiftUI 可执行文件
#   SYNY.app/Contents/Resources/syny_auth   Python 后端包（前端以子进程调用）
#   SYNY.app/Contents/Resources/icon.icns   应用图标
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SYNY.app"
SRC="$ROOT/SYNY"
PY="${PYTHON:-python3}"

CONFIG="release"
for arg in "$@"; do
    [ "$arg" = "--debug" ] && CONFIG="debug"
done

echo "==> 1/5 生成图标"
# 图标已存在则跳过：make_icon 每次会重建 iconset（批量删除），无谓且慢。
# 需要重新生成图标时：先 `rm build/icon.icns` 再构建。
if [ -f "$ROOT/build/icon.icns" ]; then
    echo "    已存在 build/icon.icns，跳过"
else
    "$PY" "$ROOT/tools/make_icon.py" >/dev/null
fi

echo "==> 2/5 编译 SwiftUI 前端（$CONFIG）"
cd "$SRC"
swift build -c "$CONFIG" --disable-sandbox
BIN="$SRC/.build/$CONFIG/SYNY"
[ -x "$BIN" ] || { echo "未找到可执行文件：$BIN"; exit 1; }

echo "==> 3/5 组装应用包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SYNY"

# Python 后端（纯标准库）
cp -R "$ROOT/src/syny_auth" "$APP/Contents/Resources/syny_auth"
find "$APP/Contents/Resources" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

[ -f "$ROOT/build/icon.icns" ] && cp "$ROOT/build/icon.icns" "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>SYNY 校园网自动认证</string>
    <key>CFBundleName</key><string>SYNY</string>
    <key>CFBundleExecutable</key><string>SYNY</string>
    <key>CFBundleIconFile</key><string>icon</string>
    <key>CFBundleIdentifier</key><string>com.syny.auth.native</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于在校园网认证成功或失败时发送系统通知。</string>
</dict>
</plist>
PLIST

echo "==> 4/5 临时签名（避免 Gatekeeper 直接拦截）"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
touch "$APP"

echo "==> 5/5 完成：$APP"

if [ "$1" = "--install" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/SYNY.app"
    cp -R "$APP" "/Applications/SYNY.app"
    echo "已完成：/Applications/SYNY.app"
fi
