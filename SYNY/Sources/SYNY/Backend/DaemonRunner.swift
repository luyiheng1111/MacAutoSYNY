import Foundation

/// 进程级停止标志（供信号处理器写入，主循环读取）。
private var daemonStopFlag: sig_atomic_t = 0

/// 信号处理器必须是 C 函数指针形式，不能捕获上下文。
private func daemonSignalHandler(_ signal: Int32) {
    daemonStopFlag = 1
}

/// 后台守护进程：周期探测网络，断线时自动认证（`daemon.py` 的 Swift 移植）。
///
/// 由 launchd 托管（KeepAlive=SuccessfulExit:false），登录后常驻运行、异常退出
/// 会被自动拉起。手动调试可直接运行：`SYNY daemon`
final class DaemonRunner {

    private var lastState: String?          // online / offline
    private var wifiGuard: String?          // "syny" / "skip"
    private var beats = 0
    private var lastFailNotify = Date.distantPast
    private var lastFailMessage = ""
    private let lock = NSLock()
    /// 网络路径监视器：让「发现断网」从轮询变成事件驱动（见该类型注释）。
    private let pathMonitor = PathMonitor()

    private var stopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return daemonStopFlag != 0
    }

    // MARK: - 主循环

    func run() {
        // 独立进程模式：脱离父进程会话，避免设置界面退出时被一并回收
        if ProcessInfo.processInfo.environment["SYNY_STANDALONE"] == "1" {
            _ = setsid()
        }

        AppPaths.ensureSupportDir()
        signal(SIGTERM, daemonSignalHandler)
        signal(SIGINT, daemonSignalHandler)
        signal(SIGHUP, SIG_IGN)

        let config = AppConfig.load()
        guard !config.username.isEmpty else {
            Log.write("未配置校园网账号，后台服务退出（配置账号后会自动重新启用）", level: "ERROR")
            return
        }

        try? "\(getpid())".write(toFile: AppPaths.pidPath, atomically: true, encoding: .utf8)
        Log.write("后台服务启动 pid=\(getpid()) 账号=\(config.username) 间隔=\(config.checkInterval)s")

        // 事件驱动：网络路径一变就立刻进入下一轮，抢在 macOS 弹出
        // 「系统默认登录页」之前完成认证。
        pathMonitor.start()

        while !stopping {
            // 每轮热加载配置，界面上改完立即生效
            let current = AppConfig.load()
            tick(current)
            // 不再死等 check_interval：期间网络有变化会被立刻唤醒
            pathMonitor.waitForChange(upTo: current.checkInterval)
        }

        try? FileManager.default.removeItem(atPath: AppPaths.pidPath)
        Log.write("后台服务已退出")
    }

    /// 分片睡眠，便于及时响应终止信号。
    private func sleep(seconds: Int) {
        for _ in 0..<max(1, seconds) {
            if stopping { return }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// 失败通知限频：10 分钟内最多一次，避免刷屏。
    private func notifyFailure(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastFailNotify) >= 600 else { return }
        lastFailNotify = now
        Notifier.notify(title: AppPaths.appTitle, message: message, subtitle: "认证失败")
    }

    // MARK: - 单轮检测

    private func tick(_ config: AppConfig) {
        // 校园网守卫：不在校园网时完全不探测、不认证，避免在非校园网
        // （家庭 / 其他 WiFi）环境下后台反复测试连接、触发 captive 弹窗。
        //
        // 判定口径由 PortalClient.evaluateCampusAccess 统一给出：
        // SSID 可读时按「名称含 syny」，SSID 被系统脱敏时降级为「校园门户 TCP 可达」。
        // verdict.reason 就是判定依据原文，直接写进日志，避免再拼一遍文案
        // （旧写法会把「暂不认证」的原因拼成半截句子，说不清到底卡在哪一步）。
        let verdict = PortalClient.evaluateCampusAccess(config)
        if config.onlySynyWifi && !verdict.isOnCampus {
            if wifiGuard != "skip" {
                Log.write("暂不认证：\(verdict.reason)，后台认证已暂停")
                wifiGuard = "skip"
            }
            lastState = nil
            return
        }
        if wifiGuard == "skip" {
            Log.write("恢复后台认证：\(verdict.reason)")
            wifiGuard = "syny"
        }

        let probed = PortalClient.probe(config)
        var online = probed.online

        if online {
            beats += 1
            lastFailMessage = ""
            // 趁门户服务器可达，顺手刷新缓存的门户参数（wlanuserip 可能已变），
            // 这样下次断网时即便 DNS 失效也能直接复用，无需再看到 captive 页面。
            if beats % 4 == 1 {
                let learned = PortalClient.learnPortalWhileOnline(config)
                if !learned.isEmpty && lastState != "online" {
                    Log.write("已预学习门户地址：\(learned)")
                }
                // 同时抓取 userIndex（已在线时门户会 302 到 success.jsp?userIndex=...），
                // 这样即便本次登录不是由本软件发起，手动下线也能用
                PortalClient.captureUserIndexIfOnline(config)
            }
            // 交叉校验：探测域名可能被放行（返回 204）但实则仍在 captive，
            // 此时直接问门户是否还需登录，避免误判在线而放任认证页弹出。
            if beats % 4 == 1 && PortalClient.portalNeedsLogin(config) {
                Log.write("门户仍要求登录（探测域名被放行），判定为离线并尝试认证")
                online = false
            }
            if online {
                if lastState != "online" {
                    Log.write("网络正常：\(probed.detail)")
                    // 首次判定在线时，顺手搞清楚「是谁让这台机器上得了网」：
                    // 若门户口径显示本机根本没有认证会话，说明放行来自校园网侧
                    // （免认证 / MAC 白名单），并不是本软件登录所得 —— 这样用户
                    // 看到「手动下线没反应」时就知道原因，而不是怀疑软件坏了。
                    if PortalClient.fetchOnlineUserIndex(config, timeout: 4).0.isEmpty {
                        Log.write("提示：门户口径显示本机无认证会话，当前联网由校园网侧放行"
                            + "（免认证 / MAC 白名单），非本软件登录所得，门户注销不会断网")
                    }
                } else if beats % 20 == 0 {
                    Log.write("心跳：网络正常（已连续 \(beats) 次）")
                }
                lastState = "online"
                return
            }
        }

        // 未联网时一律继续尝试认证：无论是识别到认证页，还是探测本身失败
        // （DNS 解析不了、连接超时）。旧版在探测失败时直接放弃，导致断网后
        // 浏览器弹出认证页而自动认证毫无反应。
        Log.write("未联网（\(probed.detail.isEmpty ? (probed.portal.isEmpty ? "原因未知" : probed.portal) : probed.detail)），尝试自动认证...")

        var result = PortalClient.authenticate(config)
        if result.ok {
            if result.attempted {
                Log.write("认证成功：\(result.message)")
                if lastState != "online" && config.notify {
                    Notifier.notify(title: AppPaths.appTitle, message: "校园网认证成功",
                                    subtitle: result.message)
                }
            } else {
                Log.write("网络已恢复：\(result.message)")
            }
            lastFailMessage = ""
            lastState = "online"
            return
        }

        // 本轮根本没机会发起认证（链路尚未就绪）——这不是「认证失败」，
        // 不该记 WARN、更不该弹失败通知。安静等链路事件，就绪后立刻重来。
        guard result.attempted else {
            lastFailMessage = ""
            lastState = "offline"
            return
        }

        // 失败后快速重试两次：刚断线时门户可能尚未就绪，
        // 立刻放弃会白等一个完整检测周期。
        var message = result.message
        for _ in 0..<2 {
            if stopping { break }
            // 用「等网络变化」代替死睡 3 秒：链路一变立刻重试，
            // 而不是白睡满 —— 抢认证就抢在这几秒上。
            pathMonitor.waitForChange(upTo: 3)
            if stopping { return }
            result = PortalClient.authenticate(config)
            message = result.message
            if result.ok {
                Log.write("认证成功（重试）：\(result.message)")
                if config.notify {
                    Notifier.notify(title: AppPaths.appTitle, message: "校园网认证成功",
                                    subtitle: result.message)
                }
                lastFailMessage = ""
                lastState = "online"
                return
            }
            if !result.attempted { break }
        }

        // 失败日志按内容去重，避免每轮刷同一条
        if message != lastFailMessage {
            Log.write("认证未通过：\(message)", level: "WARN")
            lastFailMessage = message
        }
        if config.notify { notifyFailure(message) }
        lastState = "offline"
    }
}
