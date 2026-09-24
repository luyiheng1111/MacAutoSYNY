#!/bin/sh
# 【已弃用】Tkinter 旧版构建脚本。
#   - 推荐（纯 Swift、无 Python 依赖）：./scripts/build-swift.sh
#   - 过渡（SwiftUI 前端 + Python 后端）：./scripts/build-app.sh
# 本脚本保留仅供回退对比：产物改名为 SYNY-Tkinter.app，避免覆盖原生版 SYNY.app。
#
#   ./build.sh              仅构建到当前目录（SYNY-Tkinter.app）
#   ./build.sh --install    构建并安装到 /Applications
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$ROOT/SYNY-Tkinter.app"
PY="${PYTHON:-python3}"

echo "==> 1/4 生成图标"
"$PY" "$ROOT/tools/make_icon.py"

echo "==> 2/4 组装应用包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp -R "$ROOT/src/syny_auth" "$APP/Contents/Resources/syny_auth"
find "$APP/Contents/Resources" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
[ -f "$BUILD/icon.icns" ] && cp "$BUILD/icon.icns" "$APP/Contents/Resources/icon.icns"

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
    <key>CFBundleIdentifier</key><string>com.syny.auth</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>10.15</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于在校园网认证成功或失败时发送系统通知。</string>
</dict>
</plist>
PLIST

echo "==> 3/4 写入启动器"
cat > "$APP/Contents/MacOS/SYNY" <<'LAUNCHER'
#!/bin/sh
# SYNY 启动器：为 GUI 挑选一个「能在当前会话真正创建 Tk 窗口」的 Python。
#
# 背景：macOS 上「窗口打开了却一片空白」多与 Tk 版本相关——系统自带的 Tk 8.5
# 在较新 macOS 上属于已弃用组合，容易画不出内容；而 WorkBuddy 自带的 managed
# Python 虽带更新的 Tk（9.x），却是 portable（非 framework）构建，未必能在 GUI
# 会话里创建原生窗口。仅看「是否 import tkinter」无法分辨，故这里改为**实测**：
# 让每个候选解释器真的创建一个隐藏的 Tk 窗口（withdraw + update + destroy），
# 成功的才算合格，最后取「合格且 Tk 版本最高」者。
HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$HERE/../Resources"
export PYTHONUNBUFFERED=1

# 实测：能否在当前会话创建 Tk 窗口；成功则打印 TkVersion，失败退出非 0
PROBE='import sys
try:
    import tkinter as tk
    r = tk.Tk(); r.withdraw(); r.update(); r.destroy()
except Exception:
    sys.exit(1)
print(tk.TkVersion)'

CANDIDATES="/usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3"
for wb in "$HOME"/.workbuddy/binaries/python/versions/*/bin/python3; do
    CANDIDATES="$CANDIDATES $wb"
done

best=""; bestver=""
for p in $CANDIDATES; do
    [ -x "$p" ] || continue
    v=$("$p" -c "$PROBE" 2>/dev/null) || continue
    [ -n "$v" ] || continue
    # 取 Tk 版本最高者；版本相同则保留先出现的（系统 Python 在列表靠前）
    if [ -z "$bestver" ] || [ "$(printf '%s\n%s\n' "$bestver" "$v" | sort -g | tail -1)" = "$v" ]; then
        best="$p"; bestver="$v"
    fi
done

if [ -z "$best" ]; then
    osascript -e 'display alert "SYNY" message "未找到可用的 Python 3（需带 tkinter 且能在当前会话创建窗口，例如系统 /usr/bin/python3 或 python.org / Homebrew 版 Python）。请安装后再试。" as critical' >/dev/null 2>&1
    exit 1
fi

exec "$best" -m syny_auth gui
LAUNCHER
chmod +x "$APP/Contents/MacOS/SYNY"

# 本地构建的应用做一个临时签名，避免 Gatekeeper 直接拦截
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
touch "$APP"

echo "==> 4/4 完成：$APP"

if [ "$1" = "--install" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/SYNY.app"
    cp -R "$APP" "/Applications/SYNY.app"
    echo "已完成：/Applications/SYNY.app"
fi
