import Foundation

/// 前端与后端之间的桥接层（`api.py` 的 Swift 移植）。
///
/// 保持与 Python 版**完全相同的调用协议**：请求是一个字典，形如
/// `["op": "status"]`；响应统一为
/// `["ok": true|false, "message": "...", "data": {...}]`。
///
/// 这样前端（AppModel / 各种 Decodable 模型）不需要做任何改动，
/// 而实现已经从「起一个 python3 子进程」变成进程内的原生 Swift 调用。
enum BackendBridge {

    /// 可被前端修改的配置项（与 `AppConfig.keys` 对齐，enabled 由服务层维护）。
    private static let editableKeys = [
        "username", "check_interval", "captive_url", "portal_hint",
        "auto_start", "notify", "logging", "only_syny_wifi",
    ]

    static let version = "2.0.0"

    // MARK: - 响应信封

    private static func ok(_ data: [String: Any]? = nil, message: String = "") -> [String: Any] {
        ["ok": true, "message": message, "data": data ?? [:]]
    }

    private static func error(_ message: String, data: [String: Any]? = nil) -> [String: Any] {
        ["ok": false, "message": message, "data": data ?? [:]]
    }

    // MARK: - 统一入口

    /// 执行一次操作。所有网络 / 钥匙串 / launchd 操作都是阻塞的，
    /// 调用方（AppModel）已在后台队列中调用，不会卡住界面。
    static func call(_ request: [String: Any]) -> [String: Any] {
        let op = JSONValue.string(request["op"], default: "status")
        switch op {
        case "ping":         return opPing()
        case "status":       return opStatus()
        case "get_password": return opGetPassword(request)
        case "save":         return opSave(request)
        case "start":        return opStart()
        case "stop":         return opStop()
        case "test":         return opTest()
        case "logout":       return opLogout()
        case "set_logging":  return opSetLogging(request)
        case "log":          return opLog()
        case "clear_log":    return opClearLog()
        case "open_log":     return opOpenLog()
        default:             return error("未知操作：\(op)")
        }
    }

    // MARK: - 各操作实现

    private static func opPing() -> [String: Any] {
        ok(["version": version])
    }

    private static func opStatus() -> [String: Any] {
        let config = AppConfig.load()
        let service = ServiceController.serviceState()
        let hasPassword = config.username.isEmpty
            ? false
            : !Keychain.password(username: config.username).isEmpty
        let wifiStatus = PortalClient.wifiStatus()
        var serviceInfo: [String: Any] = ["mode": service.mode, "running": service.running]
        serviceInfo["pid"] = service.pid ?? NSNull()
        return ok([
            "config": config.publicDictionary,
            "has_password": hasPassword,
            "service": serviceInfo,
            "wifi": [
                "ssid": wifiStatus.ssid,
                "is_syny": PortalClient.evaluateCampusAccess(config).isOnCampus,
                "has_wifi_interface": wifiStatus.hasWifiInterface,
                "wifi_has_address": wifiStatus.wifiHasAddress,
                "name_is_redacted": wifiStatus.nameIsRedacted
            ],
            "log_tail": Log.readTail(200),
        ])
    }

    private static func opGetPassword(_ request: [String: Any]) -> [String: Any] {
        var username = JSONValue.string(request["username"]).trimmingCharacters(in: .whitespaces)
        if username.isEmpty { username = AppConfig.load().username }
        guard !username.isEmpty else { return ok(["password": ""]) }
        return ok(["password": Keychain.password(username: username)])
    }

    private static func opSave(_ request: [String: Any]) -> [String: Any] {
        let incoming = (request["config"] as? [String: Any]) ?? [:]
        let password = JSONValue.string(request["password"])
        let username = JSONValue.string(incoming["username"]).trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return error("请填写校园网账号。") }

        let interval = JSONValue.int(incoming["check_interval"], default: 30)
        guard interval >= 5 else { return error("检测间隔不能小于 5 秒。") }

        let captive = JSONValue.string(incoming["captive_url"]).trimmingCharacters(in: .whitespaces)
        guard captive.hasPrefix("http") else {
            return error("探测地址需以 http:// 或 https:// 开头。")
        }
        let portal = JSONValue.string(incoming["portal_hint"]).trimmingCharacters(in: .whitespaces)
        if !portal.isEmpty && !portal.hasPrefix("http") {
            return error("认证门户地址需以 http:// 或 https:// 开头。")
        }

        // 密码只有非空时才写，避免把回填的掩码/空值覆盖掉钥匙串
        if !password.isEmpty {
            guard Keychain.setPassword(username: username, password: password) else {
                return error("密码写入系统钥匙串失败，请重试。")
            }
        }

        var updates: [String: Any] = [:]
        for key in editableKeys where incoming[key] != nil { updates[key] = incoming[key] }
        updates["username"] = username
        updates["check_interval"] = interval
        updates["captive_url"] = captive
        updates["portal_hint"] = portal
        AppConfig.save(updates)
        return ok(AppConfig.load().publicDictionary, message: "已保存。")
    }

    private static func opStart() -> [String: Any] {
        let result = ServiceController.startService()
        return result.0 ? ok(message: result.1) : error(result.1)
    }

    private static func opStop() -> [String: Any] {
        ServiceController.stopService()
        return ok(message: "后台认证已停止。")
    }

    private static func opTest() -> [String: Any] {
        let config = AppConfig.load()
        guard !config.username.isEmpty else { return error("尚未配置账号。") }
        let learned = PortalClient.learnPortalWhileOnline(config)
        let result = PortalClient.authenticateOnce(config)
        var message = result.1
        if !learned.isEmpty && !result.0 {
            message += "（已预学习门户地址，下次断网可自动复用）"
        }
        return result.0 ? ok(message: message) : error(message)
    }

    private static func opLogout() -> [String: Any] {
        let config = AppConfig.load()
        Log.write("收到「手动下线」请求（界面触发）")
        let result = PortalClient.logout(config)
        var message = result.1
        if result.0 && ServiceController.serviceState().running {
            ServiceController.stopService()
            message += "\n\n后台自动认证已暂停，恢复请点「保存并启用后台认证」。"
        }
        Log.write("「手动下线」结束：\(result.0 ? "成功" : "失败") — \(String(message.prefix(160)))",
                  level: result.0 ? "INFO" : "WARN")
        return result.0 ? ok(message: message) : error(message)
    }

    private static func opSetLogging(_ request: [String: Any]) -> [String: Any] {
        let enabled = JSONValue.bool(request["value"], default: false)
        let before = AppConfig.load().logging
        AppConfig.save(["logging": enabled])
        // 日志开关影响守护进程输出目标，服务已注册时重写服务定义
        ServiceController.refreshAgentIfNeeded(loggingChanged: enabled != before)
        Log.write("日志记录已\(enabled ? "开启" : "关闭")")
        return ok(["logging": enabled], message: "日志记录已\(enabled ? "开启" : "关闭")。")
    }

    private static func opLog() -> [String: Any] {
        var content: String
        if Log.enabled {
            let tail = Log.readTail(200)
            content = tail.isEmpty ? "(暂无日志内容)" : tail
        } else {
            content = "日志记录未开启（默认关闭，不写入任何日志文件）。\n"
                + "如需排查认证问题，请打开「记录运行日志」。"
            if FileManager.default.fileExists(atPath: AppPaths.logPath) {
                content += "\n\n—— 以下为关闭日志前记录的历史内容 ——\n" + Log.readTail(60)
            }
        }
        return ok(["logging": Log.enabled, "content": content])
    }

    private static func opClearLog() -> [String: Any] {
        Log.clear()
        return ok(message: "日志已清空。")
    }

    private static func opOpenLog() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: AppPaths.logPath) else {
            return error("尚未记录任何日志。日志默认不记录，打开「运行日志」开关后才会生成日志文件。")
        }
        let result = Shell.capture("/usr/bin/open", ["-R", AppPaths.logPath], timeout: 10)
        return result.ok ? ok(message: "已在访达中显示日志文件。") : error("无法打开日志文件。")
    }

    // MARK: - 便于前端复用的解码工具（沿用 PythonBridge 的原有语义）

    /// 把 data 字段重新序列化后解码为具体类型。
    static func decode<T: Decodable>(_ type: T.Type, from data: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(data),
              let raw = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return try? JSONDecoder().decode(T.self, from: raw)
    }

    /// 把响应的 data 字典解码为具体类型。
    static func decode<T: Decodable>(_ type: T.Type, response: [String: Any]) -> T? {
        guard let data = response["data"] as? [String: Any] else { return nil }
        return decode(type, from: data)
    }

    static func message(_ response: [String: Any]) -> String {
        JSONValue.string(response["message"])
    }

    static func isOK(_ response: [String: Any]) -> Bool {
        JSONValue.bool(response["ok"], default: false)
    }
}
