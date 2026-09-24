#!/bin/sh
# 构建纯 Swift 版 SYNY.app —— 完全不含 Python，Mac 用户开箱即用。
#
#   ./scripts/build-swift.sh              构建到项目根目录 SYNY.app
#   ./scripts/build-swift.sh --install    构建并安装到 /Applications
#   ./scripts/build-swift.sh --debug      用 debug 配置构建（更快）
#   ./scripts/build-swift.sh --skip-icon  跳过图标生成（沿用已有的 build/icon.icns）
#
# 这是纯 Swift 版构建：后端逻辑、后台守护进程、JSON 桥接层全部用 Swift 实现，
#   应用包内不再带任何 Python 代码，运行时不依赖 python3（旧版 build-app.sh / build.sh 已删除）。
#
# 产物结构：
#   SYNY.app/Contents/MacOS/SYNY    唯一的可执行文件（GUI / daemon / test / status）
#   SYNY.app/Contents/Resources/icon.icns
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SYNY.app"
SRC="$ROOT/SYNY"

CONFIG="release"
SKIP_ICON=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug)     CONFIG="debug" ;;
        --skip-icon) SKIP_ICON=1 ;;
        --install)   INSTALL=1 ;;
        *) echo "未知参数：$arg"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- #
echo "==> 1/5 生成图标（纯 Swift，无 Python）"
if [ "$SKIP_ICON" = "1" ]; then
    echo "    已按参数跳过"
elif [ -f "$ROOT/build/icon.icns" ]; then
    # 图标已存在则跳过：iconset 每次重建较慢，需要刷新时先 `rm -rf build/` 再构建
    echo "    已存在 build/icon.icns，跳过（需重建请先 rm -rf build/）"
else
    swift build -c release --package-path "$SRC" --disable-sandbox --product icongen
    "$SRC/.build/release/icongen" "$ROOT/build"
fi

# ---------------------------------------------------------------- #
echo "==> 2/5 编译 Swift 主程序（$CONFIG）"
swift build -c "$CONFIG" --package-path "$SRC" --disable-sandbox --product SYNY
BIN="$SRC/.build/$CONFIG/SYNY"
[ -x "$BIN" ] || { echo "未找到可执行文件：$BIN"; exit 1; }

# ---------------------------------------------------------------- #
echo "==> 3/5 组装应用包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SYNY"
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
    <key>CFBundleShortVersionString</key><string>2.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于在校园网认证成功或失败时发送系统通知。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>用于连接校园网认证门户（内网地址）完成自动登录。</string>
    <!-- 校园网认证门户、连通性探针均为 http（无 TLS）的内网/公网地址，
         必须放开 App Transport Security，否则原生网络请求会被系统直接拦截。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- #
echo "==> 4/5 临时签名（避免 Gatekeeper 直接拦截）"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
touch "$APP"

# ---------------------------------------------------------------- #
echo "==> 5/5 校验：确认包内不含 Python 依赖"
if find "$APP" -name '*.py' -o -name '__pycache__' | grep -q .; then
    echo "    ⚠️  包内仍存在 Python 文件，请检查构建流程"
else
    echo "    ✅ 未发现任何 Python 文件"
fi
echo "    可执行文件：$(du -h "$APP/Contents/MacOS/SYNY" | cut -f1)"
echo "完成：$APP"

if [ "$INSTALL" = "1" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/SYNY.app"
    cp -R "$APP" "/Applications/SYNY.app"
    echo "已完成：/Applications/SYNY.app"
fi
