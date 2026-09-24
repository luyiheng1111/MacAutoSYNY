// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SYNY",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 主程序：菜单栏设置界面 + 后台守护进程 + 命令行子命令（同一个可执行文件）
        .executableTarget(
            name: "SYNY",
            path: "Sources/SYNY"
        ),
        // 构建期工具：生成应用图标（CoreGraphics + iconutil）。
        // 独立成 target 是为了让整个构建链路也不依赖 Python——
        // 原来的 tools/make_icon.py 只是构建期脚本，但会挡住「零 Python」的目标。
        .executableTarget(
            name: "icongen",
            path: "Sources/IconGen"
        ),
    ]
)
