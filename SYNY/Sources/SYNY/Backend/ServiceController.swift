import Foundation

/// 后台服务管理（launchd + 独立进程回退），`core.py` 服务部分的 Swift 移植。
///
/// 两种运行方式，与 Python 版一致：
///   - **launchd 托管**（首选）：注册 LaunchAgent，登录自启、异常退出自动拉起；
///   - **独立进程**（回退）：某些受限环境会拒绝 `launchctl bootstrap`，
///     此时改用脱离终端的守护进程，关掉设置窗口后仍能继续自动认证。
///
/// 注意：从 Python 版升级过来时，旧的服务定义里 `ProgramArguments` 指向
/// `python3 -m syny_auth daemon`，因此首次启用会**覆盖**旧 plist 并重新注册，
/// 之后由 Swift 版自己的可执行文件承担守护进程。
enum ServiceController {

    // MARK: - launchd 服务定义

    private static func plistPayload(_ config: AppConfig) -> [String: Any] {
        // 未开启日志记录时，把守护进程的标准输出丢弃，避免 launchd 自行落盘产生日志
        let outPath = config.logging ? AppPaths.logPath : "/dev/null"
        return [
            "Label": AppPaths.label,
            // 必须用**稳定落点**（见 AppPaths.serviceExecutablePath）：
            // 早期版本直接写 AppPaths.executablePath，等于把服务钉死在「当前运行的
            // 那个副本」上——在项目目录里启用后台认证，项目一移动服务就静默失效。
            "ProgramArguments": [AppPaths.serviceExecutablePath, "daemon"],
            "EnvironmentVariables": ["SYNY_DAEMON": "1"],
            "WorkingDirectory": AppPaths.supportDir,
            "RunAtLoad": config.autoStart,
            // 仅当异常退出时才被 launchd 拉起；正常退出（如尚未配置账号）不再重启，避免空转
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": outPath,
            "StandardErrorPath": outPath,
        ]
    }

    static func agentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.plistPath)
    }

    /// 返回 (loaded, running, pid)。
    ///
    /// 注意：`launchctl print` 对「已加载但进程已退出」的任务同样返回 0，
    /// 因此必须额外解析 state / pid 才能判断是否真的在跑。
    static func agentState() -> (loaded: Bool, running: Bool, pid: Int?) {
        let target = "gui/\(getuid())/\(AppPaths.label)"
        let result = Shell.capture("/bin/launchctl", ["print", target], timeout: 10)
        guard result.ok else { return (false, false, nil) }

        let pid = Regex.firstGroup("\\bpid = (\\d+)", in: result.out).flatMap { Int($0) }
        let state = Regex.firstGroup("\\bstate = (\\w+)", in: result.out) ?? ""
        let running = pid != nil && (state == "running" || state.isEmpty)
        return (true, running, pid)
    }

    static func agentLoaded() -> Bool { agentState().loaded }
    static func agentRunning() -> Bool { agentState().running }
    static func agentPID() -> Int? { agentState().pid }

    // MARK: - 服务落点健康检查（防「项目一移动就静默失效」）

    /// 读取已注册服务实际指向的可执行文件路径（plist 中 `ProgramArguments` 的第一项）。
    static func agentProgramPath() -> String {
        guard let data = FileManager.default.contents(atPath: AppPaths.plistPath),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let args = dict["ProgramArguments"] as? [String],
              let first = args.first else { return "" }
        return first
    }

    /// 服务定义是否已成「死链」—— plist 在，但它指向的可执行文件已经不存在。
    ///
    /// 这正是「项目一移动、后台认证就没了」的直接判据。过去这里**完全静默**：
    /// 用户只看到「服务没在跑」，既没有报错也没有线索，只能靠翻 plist 才发现。
    static func agentProgramMissing() -> Bool {
        guard agentInstalled() else { return false }
        let path = agentProgramPath()
        guard !path.isEmpty else { return true }
        return !FileManager.default.isExecutableFile(atPath: path)
    }

    /// 启动时自检并尽量自愈。返回一句可供界面展示的说明；无需处理时返回空串。
    ///
    /// 修复策略：失效的旧落点 → 若「应用程序」里有可用副本就自动改指过去；
    /// 否则保留失效定义但**明确告知**用户（不再静默）。
    @discardableResult
    static func repairAgentIfBroken() -> String {
        guard agentProgramMissing() else { return "" }
        let stale = agentProgramPath()
        let shown = stale.isEmpty ? "(未记录)" : stale

        if AppPaths.hasInstalledCopy, installAgent() {
            let message = "后台服务原先指向的程序已不存在（\(shown)），"
                + "已自动改指到 \(AppPaths.serviceExecutablePath)。"
            Log.write("后台服务落点自愈：\(message)", level: "WARN")
            return message
        }

        let message = "后台服务指向的程序已不存在（\(shown)），自动认证已无法启动。\n"
            + "请把 SYNY.app 放进「应用程序」文件夹，再从那里打开本应用并重新点"
            + "「保存并启用后台认证」。"
        Log.write("后台服务落点失效且无法自动修复：\(message)", level: "ERROR")
        return message
    }

    /// 仅把服务从 launchd 卸载，不删除 plist 文件。
    private static func bootout() {
        let target = "gui/\(getuid())/\(AppPaths.label)"
        Shell.capture("/bin/launchctl", ["bootout", target], timeout: 15)
        Shell.capture("/bin/launchctl", ["unload", "-w", AppPaths.plistPath], timeout: 15)
    }

    static func installAgent() -> Bool {
        AppPaths.ensureSupportDir()
        try? FileManager.default.createDirectory(
            atPath: (AppPaths.plistPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        // 先卸载旧实例（保留旧 plist 供 launchctl 识别），再写入新的服务定义
        bootout()

        let payload = plistPayload(AppConfig.load())
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: payload, format: .xml, options: 0) else {
            Log.write("后台服务定义生成失败：配置无法序列化为 plist", level: "ERROR")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: AppPaths.plistPath))
        } catch {
            Log.write("后台服务定义写入失败：\(error.localizedDescription)", level: "ERROR")
            return false
        }

        let target = "gui/\(getuid())"
        // 必须**先 enable 再 bootstrap**：
        // `bootout()` 末尾的 `launchctl unload -w` 会往覆盖库里写一条
        // Disabled=true；而带禁用标记的服务用 bootstrap 加载时会直接返回
        // `Bootstrap failed: 5: Input/output error`（报错信息完全不提示真实原因，
        // 极难排查）。把顺序反过来，这个问题就永远不会出现。
        Shell.capture("/bin/launchctl", ["enable", "gui/\(getuid())/\(AppPaths.label)"],
                      timeout: 10)

        var messages: [String] = []
        var result = Shell.capture("/bin/launchctl",
                                   ["bootstrap", target, AppPaths.plistPath], timeout: 20)
        messages.append(result.err.trimmingCharacters(in: .whitespacesAndNewlines))

        if !result.ok {
            // 兼容旧版 launchctl；注意 load 即使失败也返回 0，必须看 stderr 并复核状态
            result = Shell.capture("/bin/launchctl",
                                   ["load", "-w", AppPaths.plistPath], timeout: 20)
            messages.append(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !result.ok {
            let detail = messages.filter { !$0.isEmpty }.joined(separator: "；")
            Log.write("后台服务注册失败：\(detail.isEmpty ? "未知错误" : detail)", level: "ERROR")
            return false
        }

        Shell.capture("/bin/launchctl", ["enable", "gui/\(getuid())/\(AppPaths.label)"],
                      timeout: 10)

        // 复核：launchctl 的返回码不可靠，以实际加载状态为准
        guard agentLoaded() else {
            let detail = messages.filter { !$0.isEmpty }.joined(separator: "；")
            Log.write("后台服务注册未生效：\(detail.isEmpty ? "服务未出现在 launchd 中" : detail)",
                      level: "ERROR")
            return false
        }

        let program = AppPaths.serviceExecutablePath
        if AppPaths.servicePathIsStable {
            Log.write("后台服务已安装并启动（指向 \(program)）")
        } else {
            // 兜底落点：必须说清楚，否则项目一挪走就又是一次「服务莫名失效」
            Log.write("后台服务已安装并启动（指向 \(program)）；"
                + "「应用程序」里暂无 SYNY.app 副本，服务仍与当前目录绑定，"
                + "移动或删除该目录会导致后台认证失效。", level: "WARN")
        }
        return true
    }

    static func uninstallAgent(quiet: Bool = false) {
        bootout()
        try? FileManager.default.removeItem(atPath: AppPaths.plistPath)
        if !quiet { Log.write("后台服务已停止并移除") }
    }

    @discardableResult
    static func restartAgent() -> Bool {
        let target = "gui/\(getuid())/\(AppPaths.label)"
        let result = Shell.capture("/bin/launchctl", ["kickstart", "-k", target], timeout: 15)
        guard result.ok else { return installAgent() }
        Log.write("后台服务已重启")
        return true
    }

    // MARK: - 独立进程模式
    //
    // 部分环境（如受限的虚拟机 / 沙箱）会拒绝 launchctl bootstrap，此时改用
    // 「脱离终端的独立守护进程」，同样能实现窗口关闭后继续自动认证。

    private static func readPIDFile() -> pid_t? {
        guard let text = try? String(contentsOfFile: AppPaths.pidPath, encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func pidAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// 返回独立守护进程 PID；进程已不存在则返回 nil。
    static func daemonPID() -> pid_t? {
        guard let pid = readPIDFile(), pidAlive(pid) else { return nil }
        return pid
    }

    /// 直接拉起一个脱离终端的守护进程。返回 (ok, message)。
    static func spawnDaemon() -> (Bool, String) {
        let config = AppConfig.load()
        guard !config.username.isEmpty else { return (false, "尚未配置校园网账号") }
        stopDaemon()
        AppPaths.ensureSupportDir()

        var env = ProcessInfo.processInfo.environment
        env["SYNY_DAEMON"] = "1"
        env["SYNY_STANDALONE"] = "1"   // 让子进程自行 setsid，脱离父进程会话

        let sink = config.logging ? AppPaths.logPath : "/dev/null"
        guard let pid = Shell.spawnDetached(AppPaths.executablePath, ["daemon"],
                                            env: env,
                                            currentDirectory: AppPaths.supportDir,
                                            stdoutPath: sink) else {
            return (false, "守护进程启动失败：无法创建子进程")
        }

        Thread.sleep(forTimeInterval: 1.5)
        if let running = daemonPID() {
            return (true, "后台认证已启动（独立进程模式，PID \(running))")
        }
        _ = pid
        return (false, "守护进程启动后立即退出，请检查账号与密码是否正确")
    }

    /// 终止独立守护进程。返回是否真的结束了某个进程。
    @discardableResult
    static func stopDaemon(timeout: TimeInterval = 5) -> Bool {
        var stopped = false
        if let pid = readPIDFile(), pidAlive(pid) {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline && pidAlive(pid) {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if pidAlive(pid) { kill(pid, SIGKILL) }
            stopped = true
        }
        try? FileManager.default.removeItem(atPath: AppPaths.pidPath)
        return stopped
    }

    // MARK: - 统一的服务控制接口

    /// 返回 (mode, running, pid)。mode ∈ {"launchd", "process", "stopped"}。
    static func serviceState() -> (mode: String, running: Bool, pid: Int?) {
        let agent = agentState()
        if agent.loaded {
            return ("launchd", agent.running, agent.pid)
        }
        if let pid = daemonPID() {
            return ("process", true, Int(pid))
        }
        return ("stopped", false, nil)
    }

    /// 优先 launchd 托管；失败则回退到独立进程模式。返回 (ok, message)。
    static func startService() -> (Bool, String) {
        // 临时隔离状态下路径每次都变，注册了也会在重启后失效——直接给出可执行的指引
        if AppPaths.isTranslocated {
            Log.write("应用处于临时隔离状态，已拒绝注册后台服务", level: "ERROR")
            return (false, "检测到 SYNY 仍在「临时隔离」状态下运行（通常是从下载目录直接打开）。\n"
                + "请把 SYNY.app 拖到「应用程序」文件夹后再打开本应用，"
                + "否则后台认证服务在重启电脑后会失效。")
        }

        if installAgent() {
            setEnabled(true)
            return (true, "后台认证已启用（登录自启，异常退出会自动重启）")
        }
        let (ok, message) = spawnDaemon()
        if ok {
            setEnabled(true)
            return (true, "本机无法注册 launchd 服务，已改用独立进程模式运行："
                + "关闭窗口后仍会自动认证，但重启电脑后需重新打开本应用。")
        }
        return (false, message)
    }

    static func stopService() {
        setEnabled(false)
        uninstallAgent(quiet: true)
        stopDaemon()
        Log.write("后台服务已停止")
    }

    /// 日志开关变化后需要重写服务定义（输出目标变了）。
    static func refreshAgentIfNeeded(loggingChanged: Bool) {
        if loggingChanged && agentLoaded() { _ = installAgent() }
    }

    private static func setEnabled(_ flag: Bool) {
        AppConfig.save(["enabled": flag])
    }
}
