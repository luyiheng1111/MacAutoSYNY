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
}
