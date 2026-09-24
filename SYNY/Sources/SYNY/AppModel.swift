import Foundation
import SwiftUI

/// 应用状态与动作：所有后端调用都丢到后台队列，回到主线程更新 UI。
///
/// 后端已是进程内的原生 Swift（`BackendBridge`），不再起 Python 子进程；
/// 但调用仍是阻塞式的（网络 / launchd / 钥匙串），因此保留后台队列的调度方式。
@MainActor
final class AppModel: ObservableObject {

    enum MessageKind { case neutral, ok, error, warn }

    // MARK: 表单
    @Published var username = ""
    @Published var password = ""
    @Published var checkInterval = "30"
    @Published var captiveURL = "http://connect.rom.miui.com/generate_204"
    @Published var portalHint = ""
    @Published var autoStart = true
    @Published var notify = true
    @Published var onlySynyWifi = true
    @Published var logging = false

    // MARK: 状态
    @Published var hasPassword = false
    @Published var serviceMode = "stopped"   // launchd / process / stopped
    @Published var serviceRunning = false
    @Published var wifiSSID = ""
    @Published var wifiIsSyny = false
    @Published var wifiHasInterface = false
    @Published var wifiHasAddress = false
    @Published var wifiNameIsRedacted = false
    @Published var logContent = "(暂无日志内容)"

    // MARK: 界面
    @Published var message = "正在检测…"
    @Published var messageKind: MessageKind = .neutral
    @Published var busy = false
    @Published var advancedOpen = false
    @Published var showPassword = false

    // MARK: 面板尺寸（界面偏好，存 UserDefaults）
    // 目标：底部不留多余空白——面板高度 = 内容自然高度，且不超过用户设定的上限；
    // 内容超过上限时面板内部滚动。
    static let panelWidth: CGFloat = 400
    static let panelMinHeight: CGFloat = 220
    static let panelDefaultMaxHeight: CGFloat = 560

    /// 内容自然高度（由面板视图用 GeometryReader 回填）。
    @Published var panelContentHeight: CGFloat = 0
    /// 用户自定义的面板高度上限（持久化）。
    @Published var panelMaxHeight: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "syny.panelMaxHeight") as? Double
        return CGFloat(saved ?? Double(AppModel.panelDefaultMaxHeight))
    }()

    /// popover 实际采用的尺寸高度：内容自然高度，并夹在 [min, max] 之间。
    var panelPreferredHeight: CGFloat {
        guard panelContentHeight > 0 else { return panelMaxHeight }
        return min(max(panelContentHeight, Self.panelMinHeight), panelMaxHeight)
    }

    func setPanelMaxHeight(_ height: CGFloat) {
        panelMaxHeight = min(max(height, 320), 900)
        UserDefaults.standard.set(Double(panelMaxHeight), forKey: "syny.panelMaxHeight")
    }

    private var didLoadForm = false
    private var started = false
    private var timer: Timer?
    private var lastOpAt = Date.distantPast
    private let work = DispatchQueue(label: "com.syny.backend", qos: .userInitiated)

    // MARK: - 生命周期
    func bootstrap() {
        guard !started else { return }
        started = true
        refresh()
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 状态刷新
    func refresh() {
        guard !busy else { return }
        work.async { [weak self] in
            let response = BackendBridge.call(["op": "status"])
            let payload = BackendBridge.decode(StatusPayload.self, response: response)
            DispatchQueue.main.async {
                guard let self else { return }
                if let payload {
                    self.apply(payload)
                } else {
                    self.setMessage(BackendBridge.message(response), kind: .error)
                }
            }
        }
    }

    private func apply(_ payload: StatusPayload) {
        hasPassword = payload.hasPassword
        serviceMode = payload.service.mode
        serviceRunning = payload.service.running
        wifiSSID = payload.wifi.ssid
        wifiIsSyny = payload.wifi.isSyny
        logging = payload.config.logging
        logContent = payload.logTail.isEmpty ? "(暂无日志内容)" : payload.logTail

        if !didLoadForm {
            username = payload.config.username
            checkInterval = String(payload.config.checkInterval)
            captiveURL = payload.config.captiveURL
            portalHint = payload.config.portalHint
            autoStart = payload.config.autoStart
            notify = payload.config.notify
            onlySynyWifi = payload.config.onlySynyWifi
            didLoadForm = true
            loadPassword()
        }

        // 操作结果在若干秒内保持显示，不被周期刷新覆盖
        if Date().timeIntervalSince(lastOpAt) > 5 {
            let (text, kind) = statusPill()
            setMessage(text, kind: kind)
        }
    }

    private func statusPill() -> (String, MessageKind) {
        switch serviceMode {
        case "launchd":
            return serviceRunning
                ? ("后台认证运行中（后台服务）", .ok)
                : ("服务已注册未运行", .warn)
        case "process":
            return ("后台认证运行中（独立进程）", .ok)
        default:
            return ("后台认证未启用", .neutral)
        }
    }

    // MARK: - 密码回填
    func loadPassword() {
        let name = username
        guard !name.isEmpty else { return }
        work.async { [weak self] in
            let response = BackendBridge.call(["op": "get_password", "username": name])
            let value = (response["data"] as? [String: Any])?["password"] as? String ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasPassword = !value.isEmpty
                if !value.isEmpty && self.password.isEmpty { self.password = value }
            }
        }
    }

    // MARK: - 动作
    func saveAndEnable() {
        let save = saveRequest()
        busy = true
        setMessage("正在保存并启用…", kind: .neutral)
        work.async { [weak self] in
            let saveResponse = BackendBridge.call(save)
            guard BackendBridge.isOK(saveResponse) else {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.setMessage(BackendBridge.message(saveResponse), kind: .error)
                }
                return
            }
            let startResponse = BackendBridge.call(["op": "start"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.lastOpAt = Date()
                let ok = BackendBridge.isOK(startResponse)
                self.setMessage(BackendBridge.message(startResponse), kind: ok ? .ok : .error)
                self.refresh()
            }
        }
    }

    func saveOnly() {
        perform(saveRequest(), busyText: "正在保存…")
    }

    func testAuth() {
        perform(["op": "test"], busyText: "正在测试认证，请稍候…")
    }

    func startService() {
        perform(["op": "start"], busyText: "正在启用后台认证…")
    }

    func stopService() {
        perform(["op": "stop"], busyText: "正在停止后台认证…")
    }

    func repairService() {
        perform(["op": "start"], busyText: "正在重新注册后台服务…")
    }

    func logout() {
        perform(["op": "logout"], busyText: "正在下线…")
    }

    func toggleLogging() {
        perform(["op": "set_logging", "value": logging], busyText: "正在切换日志…")
    }

    func clearLog() {
        perform(["op": "clear_log"], busyText: "正在清空日志…")
    }

    func openLog() {
        perform(["op": "open_log"], busyText: "正在打开日志…")
    }

    func refreshLog() {
        if busy { return }
        work.async { [weak self] in
            let response = BackendBridge.call(["op": "log"])
            let content = (response["data"] as? [String: Any])?["content"] as? String ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.logContent = content.isEmpty ? "(暂无日志内容)" : content
            }
        }
    }

    // MARK: - 通用执行
    private func perform(_ request: [String: Any], busyText: String,
                         onSuccess: (([String: Any]) -> Void)? = nil) {
        if busy { return }
        busy = true
        setMessage(busyText, kind: .neutral)
        work.async { [weak self] in
            let response = BackendBridge.call(request)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                let ok = BackendBridge.isOK(response)
                let text = BackendBridge.message(response)
                self.setMessage(text.isEmpty ? (ok ? "完成" : "操作失败") : text,
                                kind: ok ? .ok : .error)
                if ok {
                    self.lastOpAt = Date()
                    onSuccess?(response)
                    if request["op"] as? String == "log" {
                        self.logContent = (response["data"] as? [String: Any])?["content"] as? String ?? self.logContent
                    }
                }
                self.refresh()
            }
        }
    }

    private func saveRequest() -> [String: Any] {
        [
            "op": "save",
            "password": password,
            "config": [
                "username": username,
                "check_interval": Int(checkInterval) ?? 30,
                "captive_url": captiveURL,
                "portal_hint": portalHint,
                "auto_start": autoStart,
                "notify": notify,
                "logging": logging,
                "only_syny_wifi": onlySynyWifi,
            ],
        ]
    }

    func setMessage(_ text: String, kind: MessageKind) {
        message = text
        messageKind = kind
    }
}
