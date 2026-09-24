import Foundation

/// 进程入口：同一个可执行文件同时承担 GUI、后台守护进程与命令行调试三种角色。
///
/// 这是「纯 Swift、无 Python」版本的关键设计——Python 版靠
/// `python3 -m syny_auth daemon` 起守护进程，现在改为
/// `<SYNY.app>/Contents/MacOS/SYNY daemon`，由应用自身完成，
/// 因此最终产物里不再需要任何 Python 运行时。
///
///   SYNY            打开菜单栏设置界面（默认）
///   SYNY daemon     前台运行后台认证循环（launchd 托管 / 手动调试）
///   SYNY test       立即执行一次「探测 + 认证」并输出结果
///   SYNY status     查看当前配置与后台服务状态
@main
enum SYNYEntry {

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "daemon":
            DaemonRunner().run()
        case "test":
            exit(CommandLineTools.runTest())
        case "logout":
            exit(CommandLineTools.runLogout())
        case "status":
            exit(CommandLineTools.runStatus())
        case "-h", "--help", "help":
            print(CommandLineTools.usage)
        default:
            // 交给 SwiftUI 的 App 生命周期（菜单栏 popover）
            SYNYApp.main()
        }
    }
}

/// 命令行子命令实现（对齐 Python 版 `python3 -m syny_auth test|status`）。
enum CommandLineTools {

    static let usage = """
    SYNY 校园网自动认证（纯 Swift 版）

    用法：
      SYNY            打开菜单栏设置界面
      SYNY daemon     前台运行后台认证循环（launchd 即以此方式托管）
      SYNY test       立即执行一次「探测 + 认证」并输出结果
      SYNY logout     手动下线（注销门户会话），并说明到底有没有会话可注销
      SYNY status     查看当前配置、校园网判定与后台服务状态
    """

    static func runTest() -> Int32 {
        let config = AppConfig.load()
        guard !config.username.isEmpty else {
            print("尚未配置账号，请先打开 SYNY 设置界面完成配置。")
            return 2
        }
        let result = PortalClient.authenticateOnce(config)
        print((result.0 ? "✅ " : "❌ ") + result.1)
        return result.0 ? 0 : 1
    }

    /// 命令行手动下线。与界面「手动下线」走同一条实现，
    /// 便于在图形界面之外排查上下线问题。
    static func runLogout() -> Int32 {
        let config = AppConfig.load()
        let result = PortalClient.logout(config)
        print((result.0 ? "✅ " : "❌ ") + result.1)
        return result.0 ? 0 : 1
    }

    static func runStatus() -> Int32 {
        let config = AppConfig.load()
        let service = ServiceController.serviceState()
        let modeLabel: String
        switch service.mode {
        case "launchd": modeLabel = "launchd 后台服务"
        case "process": modeLabel = "独立进程"
        default:        modeLabel = "未启用"
        }

        print("账号          : \(config.username.isEmpty ? "(未配置)" : config.username)")
        print("检测间隔      : \(config.checkInterval) 秒")
        print("探测地址      : \(config.captiveURL)")
        print("登录自启      : \(config.autoStart ? "是" : "否")")
        print("记录日志      : \(config.logging ? "是" : "否")")
        print("密码已存钥匙串: \(Keychain.password(username: config.username).isEmpty ? "否" : "是")")
        print("运行方式      : \(modeLabel)")
        print("是否运行中    : \(service.running ? "是" : "否")")
        if let pid = service.pid { print("进程 PID      : \(pid)") }
        // 后台服务「钉」在哪个可执行文件上 —— 这一行是排查
        // 「项目一移动后台认证就没了」的第一现场：只要这里不是 /Applications 下的
        // 路径，项目一动服务就会失效。
        if ServiceController.agentInstalled() {
            let program = ServiceController.agentProgramPath()
            let missing = ServiceController.agentProgramMissing()
            print("服务指向      : \(program.isEmpty ? "(未记录)" : program)"
                + (missing ? "  ⚠️ 该文件已不存在，后台认证无法启动" : ""))
            if !missing && !AppPaths.servicePathIsStable {
                print("              （「应用程序」里暂无 SYNY.app 副本，"
                    + "移动或删除该目录会导致服务失效）")
            }
        }
        let ssid = PortalClient.currentWifiSSID()
        print("当前 WiFi     : \(ssid.isEmpty ? "(名称不可读，可能缺少定位服务授权)" : ssid)")
        // 校园网判定依据 + 门户口径的会话状态。
        // 这两项是排查「为什么没自动认证」「为什么下线没反应」最直接的两个答案。
        print("校园网判定    : \(PortalClient.evaluateCampusAccess(config).reason)")
        let (sessionIndex, sessionNote) = PortalClient.fetchOnlineUserIndex(config, timeout: 4)
        print("门户会话      : \(sessionIndex.isEmpty ? "无" : sessionIndex)"
            + (sessionIndex.isEmpty && !sessionNote.isEmpty ? "（\(sessionNote)）" : ""))
        return 0
    }
}
