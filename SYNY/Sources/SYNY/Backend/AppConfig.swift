import Foundation

/// 应用配置（与 Python 版 `core.DEFAULT_CONFIG` 一一对应）。
///
/// 明文 JSON 只存账号与各类开关；密码走系统钥匙串，永不落盘。
struct AppConfig {

    // 与 DEFAULT_CONFIG 同序，保存时按此顺序写盘
    static let keys = [
        "username", "check_interval", "captive_url", "portal_hint",
        "auto_start", "notify", "logging", "only_syny_wifi", "enabled",
    ]

    /// 默认连通性探测地址：`http://captive.apple.com/hotspot-detect.html`。
    ///
    /// 为什么选它：这与 **macOS 自带登录页（CNA）使用的探测地址完全相同**。
    /// 本软件的全部意义就是「抢在系统弹出登录页之前把认证做完」，那么判据就该
    /// 和系统保持一致 —— 我们看到 `Success`，系统那次探测也会通过，两边不会打架。
    ///
    /// 形态是 **200 + 正文一句 `Success`**（实测 68 字节），不是 204；
    /// 且必须用 `http://`（用 https 就看不到门户插进来的 302 劫持了）。
    ///
    /// ⚠️ 换这个常量时务必同步检查 `PortalClient.probe` 的判定逻辑与
    /// `probeContentMarker`，否则新探针会被一律判成「未联网」，
    /// 每轮白跑一轮认证。204 型探针（如 `…/generate_204`）依然受支持。
    static let defaultCaptiveURL = "http://captive.apple.com/hotspot-detect.html"

    /// 历史版本的默认探测地址。加载旧配置时自动迁移到 `defaultCaptiveURL`，
    /// 否则改默认值对老用户不生效（配置里存的仍是旧地址）。
    ///
    /// 只放**真正当过默认值**的地址：放进来就意味着用户手工填写它也会被改掉。
    /// 其它 204 型探针（vivo / 华为 / 微软）只是 `PortalClient.fallbackProbes`
    /// 里的备选，用户可以自由指定，别拦。
    static let legacyCaptiveURLs: Set<String> = [
        "http://www.google.cn/generate_204",
        "http://connect.rom.miui.com/generate_204",
    ]

    // 校园网账号
    var username = ""
    // 检测间隔（秒）
    var checkInterval = 30
    // 连通性探测地址（默认 Apple 捕获探测页：200 + "Success"，与 macOS 登录页同源）
    var captiveURL = "http://captive.apple.com/hotspot-detect.html"
    // 校园网认证门户地址：自动识别失败时作为兜底线索
    var portalHint = "http://172.16.100.201/eportal/index.jsp"
    // 登录时自动拉起后台服务
    var autoStart = true
    // 认证成功/失败时发系统通知
    var notify = true
    // 是否记录运行日志（默认关闭：不手动开启就不写任何日志文件）
    var logging = false
    // 仅当连接名称含 syny 的 WiFi 时才认证
    var onlySynyWifi = true
    // 用户是否已主动启用后台认证
    var enabled = false

    // MARK: - 读写

    static func load() -> AppConfig {
        var config = AppConfig()
        if let data = FileManager.default.contents(atPath: AppPaths.configPath),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            config.apply(dict)
        }
        config.checkInterval = max(5, config.checkInterval)
        // 旧配置里残留的旧默认探测地址自动迁移（仅当用户没改成自定义地址时）
        if Self.legacyCaptiveURLs.contains(config.captiveURL) {
            config.captiveURL = Self.defaultCaptiveURL
        }
        return config
    }

    /// 把字典里认识的键合并进来（未知键忽略，与 Python 版过滤逻辑一致）。
    mutating func apply(_ dict: [String: Any]) {
        let filtered = dict.filter { Self.keys.contains($0.key) }
        guard !filtered.isEmpty else { return }
        username = JSONValue.string(filtered["username"], default: username)
        checkInterval = JSONValue.int(filtered["check_interval"], default: checkInterval)
        captiveURL = JSONValue.string(filtered["captive_url"], default: captiveURL)
        portalHint = JSONValue.string(filtered["portal_hint"], default: portalHint)
        autoStart = JSONValue.bool(filtered["auto_start"], default: autoStart)
        notify = JSONValue.bool(filtered["notify"], default: notify)
        logging = JSONValue.bool(filtered["logging"], default: logging)
        onlySynyWifi = JSONValue.bool(filtered["only_syny_wifi"], default: onlySynyWifi)
        enabled = JSONValue.bool(filtered["enabled"], default: enabled)
    }

    var dictionary: [String: Any] {
        [
            "username": username,
            "check_interval": checkInterval,
            "captive_url": captiveURL,
            "portal_hint": portalHint,
            "auto_start": autoStart,
            "notify": notify,
            "logging": logging,
            "only_syny_wifi": onlySynyWifi,
            "enabled": enabled,
        ]
    }

    /// 把 updates 合并进现有配置后落盘（未提到的项保持不变）。
    static func save(_ updates: [String: Any]) {
        AppPaths.ensureSupportDir()
        var config = AppConfig.load()
        config.apply(updates)

        var payload: [String: Any] = [:]
        let dict = config.dictionary
        for key in Self.keys { payload[key] = dict[key] }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted]) else { return }
        writeAtomically(data, to: AppPaths.configPath)
    }

    /// 先写临时文件再 rename —— 与 Python 版 `os.replace` 等价，
    /// 避免守护进程正在读配置时读到半截内容。
    static func writeAtomically(_ data: Data, to path: String) {
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return
        }
        let renamed = tmp.withCString { source in
            path.withCString { destination in rename(source, destination) }
        }
        if renamed != 0 {
            try? data.write(to: URL(fileURLWithPath: path))
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }

    // MARK: - 供前端读取的公开字段（与 Python `_public_config` 一致）
    var publicDictionary: [String: Any] {
        [
            "username": username,
            "check_interval": checkInterval,
            "captive_url": captiveURL,
            "portal_hint": portalHint,
            "auto_start": autoStart,
            "notify": notify,
            "logging": logging,
            "only_syny_wifi": onlySynyWifi,
            "enabled": enabled,
        ]
    }
}
