import Foundation

/// 全应用使用的固定路径与标识。
///
/// 与 Python 版 `core.py` 完全一致：配置 / 日志 / 缓存仍放在
/// `~/Library/Application Support/SYNYAuth`，因此新旧两版可以共享同一份配置，
/// 互相之间无需迁移数据。
enum AppPaths {

    static let appTitle = "SYNY 校园网自动认证"
    static let label = "com.syny.auth"
    static let keychainService = "SYNYAuth"
    static let bundleIdentifier = "com.syny.auth.native"

    /// 配置 / 日志 / 缓存目录（与 Python 版保持同一路径，便于平滑替换）
    static var supportDir: String {
        NSHomeDirectory() + "/Library/Application Support/SYNYAuth"
    }

    static var configPath: String { supportDir + "/config.json" }
    static var logPath: String { supportDir + "/auth.log" }
    static var pidPath: String { supportDir + "/daemon.pid" }
    /// 最近一次成功认证所用的门户主机与参数，供网络异常时重建认证地址
    static var portalCachePath: String { supportDir + "/portal_cache.json" }
    /// 最近一次登录得到的会话标识 userIndex（手动下线需要）
    static var sessionPath: String { supportDir + "/session.json" }

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    /// 当前可执行文件的绝对路径。
    ///
    /// launchd 的 `ProgramArguments` 必须是绝对路径，因此注册后台服务时用它。
    /// 从 .app 包内启动时拿到的是 `SYNY.app/Contents/MacOS/SYNY`；
    /// 直接用 `swift run` 调试时则是 .build 下的二进制。
    static var executablePath: String {
        if let url = Bundle.main.executableURL { return url.path }
        return CommandLine.arguments.first ?? ""
    }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true)
    }

    /// 应用是否正以「临时隔离（App Translocation）」方式运行。
    ///
    /// 从下载目录直接双击一个带 quarantine 标记的 .app 时，系统会把它挂载到
    /// `/private/var/folders/.../AppTranslocation/...` 下运行，该路径每次启动都变。
    /// 此时注册进 launchd 的服务定义会在下次重启后失效，所以必须提前拦住用户。
    static var isTranslocated: Bool {
        executablePath.contains("/AppTranslocation/")
    }

    /// 「应用程序」文件夹里的候选安装位置（按优先级）。
    ///
    /// `/Applications` 是 DMG 安装说明引导的标准位置；`~/Applications` 供
    /// 不想写系统目录的用户使用。两者都视为「稳定位置」。
    static var installedAppRoots: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// 稳定落点上的可执行文件路径（不存在则返回空串）。
    static var installedExecutablePath: String {
        for root in installedAppRoots {
            let path = root + "/SYNY.app/Contents/MacOS/SYNY"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ""
    }

    /// 是否存在可用的「稳定安装副本」。
    static var hasInstalledCopy: Bool { !installedExecutablePath.isEmpty }

    /// 后台服务（LaunchAgent）应当指向的可执行文件路径 —— 必须是**稳定**的。
    ///
    /// 为什么不能直接用 `executablePath`：那只是「此刻正在运行的那个副本」。
    /// 在项目目录里点「启用后台认证」，plist 就被永久写成项目里的路径；项目一旦
    /// 移动 / 改名 / 删除，launchd 每次拉起都找不到程序，服务**静默失效**
    /// （本机已实际踩过两次：一次指向被删的 worktree，一次指向项目目录）。
    ///
    /// 因此注册服务时按「安装位置优先」挑选：
    ///   1. `/Applications/SYNY.app`   —— DMG 安装的标准位置
    ///   2. `~/Applications/SYNY.app`  —— 无需管理员权限的用户级位置
    ///   3. 当前可执行文件               —— 前两者都不存在时的开发期兜底
    ///
    /// 只有第 3 种才会把服务绑到项目目录上，界面与日志会显式提示这一点。
    static var serviceExecutablePath: String {
        let installed = installedExecutablePath
        return installed.isEmpty ? executablePath : installed
    }

    /// 服务落点是否已与项目目录解耦（false 表示正处于「开发期兜底」）。
    static var servicePathIsStable: Bool { hasInstalledCopy }
}
