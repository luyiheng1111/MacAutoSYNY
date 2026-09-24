#!/bin/sh
# 构建纯 Swift 版 SYNY.app —— 完全不含 Python，Mac 用户开箱即用。
#
#   ./scripts/build-swift.sh              构建到项目根目录 SYNY.app
#   ./scripts/build-swift.sh --install    构建、装到 /Applications，并把已注册的
#                                         后台服务改指到 /Applications 后重启
#   ./scripts/build-swift.sh --debug      用 debug 配置构建（更快）
#   ./scripts/build-swift.sh --skip-icon  跳过图标生成（沿用已有的 build/icon.icns）
#
# 这是纯 Swift 版构建：后端逻辑、后台守护进程、JSON 桥接层全部用 Swift 实现，
#   应用包内不再带任何 Python 代码，运行时不依赖 python3（旧版 build-app.sh / build.sh 已删除）。
#
# 产物结构：
#   SYNY.app/Contents/MacOS/SYNY    唯一的可执行文件（GUI / daemon / test / status）
#   SYNY.app/Contents/Resources/icon.icns
#   SYNY.app/Contents/Resources/wifi-guide/step*.png   首次启动「改 Wi-Fi 设置」教学截图
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

# 教学截图随包分发：首次启动弹出的「改 Wi-Fi 设置」教学窗口直接读
# Contents/Resources/wifi-guide/*.png（见 WifiGuideView.GuideAssets）。
# 截图缺失不会让构建失败——窗口会降级成一段占位说明——但那样教学就只剩文字，
# 所以这里明确告警，避免「图没打进去」这种问题被静默带进安装包。
GUIDE_SRC="$ROOT/docs/wifi-guide"
GUIDE_DST="$APP/Contents/Resources/wifi-guide"
mkdir -p "$GUIDE_DST"
if [ -d "$GUIDE_SRC" ]; then
    cp "$GUIDE_SRC"/*.png "$GUIDE_DST"/ 2>/dev/null || true
fi
GUIDE_COUNT="$(ls "$GUIDE_DST" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$GUIDE_COUNT" = "0" ]; then
    echo "    ⚠️  未找到教学截图（$GUIDE_SRC/*.png），教学窗口将只显示文字说明"
else
    echo "    教学截图：$GUIDE_COUNT 张"
fi

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
    <key>CFBundleShortVersionString</key><string>2.2.1</string>
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

# 后台服务现在指向 /Applications 里的副本（与项目目录解耦，项目移动也不会失效）。
# 因此只构建不安装时，服务用的仍是旧版——这里必须说清楚，否则就成了
# 「我改了代码重新构建，怎么行为没变」的新谜题。
if [ "$INSTALL" != "1" ] && [ -d "/Applications/SYNY.app" ]; then
    echo
    echo "    注意：/Applications 里已有 SYNY.app，后台服务正指向它；"
    echo "          若要让后台认证用上本次构建，请改用 --install 重新安装。"
fi

if [ "$INSTALL" = "1" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/SYNY.app"
    cp -R "$APP" "/Applications/SYNY.app"
    echo "    已完成：/Applications/SYNY.app"

    # 后台服务（LaunchAgent）的 ProgramArguments 是绝对路径，一旦注册就会一直
    # 指向当初那个副本。若不在这里把它改指到 /Applications，就会出现
    # 「项目一移动，后台认证静默失效」——本机已实际踩过两次。
    PLIST="$HOME/Library/LaunchAgents/com.syny.auth.plist"
    PROGRAM="/Applications/SYNY.app/Contents/MacOS/SYNY"
    if [ -f "$PLIST" ]; then
        echo "==> 同步后台服务的落点"
        /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $PROGRAM" "$PLIST" 2>/dev/null \
            || echo "    （写入失败，服务定义可能为旧格式，可在界面重新启用后台认证）"
        UID_NUM="$(id -u)"
        launchctl bootout "gui/$UID_NUM/com.syny.auth" 2>/dev/null || true
        # 必须先 enable：`launchctl unload -w`（应用内 bootout 会调用）会留下
        # Disabled=true 覆盖记录，带禁用标记的服务 bootstrap 会直接报
        # 「Bootstrap failed: 5: Input/output error」，且报错完全不提示真因。
        launchctl enable "gui/$UID_NUM/com.syny.auth" 2>/dev/null || true
        launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
            || launchctl load -w "$PLIST" 2>/dev/null || true
        launchctl enable "gui/$UID_NUM/com.syny.auth" 2>/dev/null || true
        echo "    后台服务已改指到 $PROGRAM 并重启"
    else
        echo "==> 尚未启用后台服务，跳过落点同步"
        echo "    打开 /Applications/SYNY.app 点「保存并启用后台认证」即可。"
    fi
fi
