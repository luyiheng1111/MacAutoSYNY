import AppKit
import SwiftUI

extension Notification.Name {
    /// 菜单栏面板请求打开「Wi-Fi 设置教学」窗口。
    ///
    /// 用通知而不是直接 new 窗口，是为了让 popover 的收起动作留在
    /// `AppDelegate` 里统一处理——面板是 `.transient` 的，开新窗口时若不主动收起，
    /// 会残留一个失去焦点的空壳挂在状态栏下。
    static let synyShowWifiGuide = Notification.Name("com.syny.showWifiGuide")

    /// 用户在教学窗口里点过「我知道了」。
    ///
    /// 面板据此把常驻提示卡收起来：有了这条通知，点完立刻生效，
    /// 不必让面板每 8 秒去轮询一次 `UserDefaults`。
    static let synyWifiGuideAcknowledged = Notification.Name("com.syny.wifiGuideAcknowledged")
}

/// 教学相关的持久化状态（`UserDefaults`）。
///
/// 单独拎出来是因为有**两个**消费方：教学窗口（是否自动弹过、写入已确认），
/// 以及菜单栏面板（据「已确认」决定还要不要在主区域显示常驻提示卡）。
/// 键名散在两边，就会出现「改了写入端、忘了读的一侧」这种静默错位。
enum WifiGuideState {
    /// 是否已经自动弹过一次教学。
    private static let didAutoShowKey = "syny.didAutoShowWifiGuide"

    /// 用户是否点过「我知道了」。
    ///
    /// 非 private：`AppModel` 初始化时要读它，键名两处分开写迟早会错位。
    static let acknowledgedKey = "syny.wifiGuideAcknowledged"

    static var needsAutoShow: Bool {
        !UserDefaults.standard.bool(forKey: didAutoShowKey)
    }

    static func markAutoShown() {
        UserDefaults.standard.set(true, forKey: didAutoShowKey)
    }

    /// 用户已确认「我知道了」。
    ///
    /// 只认「我知道了」这一个动作，**不认直接关窗**：首次启动用户顺手把窗口关掉时，
    /// 面板上那张提示卡应当继续留着，作为「这一步还没做」的兜底提醒。
    static var acknowledged: Bool {
        UserDefaults.standard.bool(forKey: acknowledgedKey)
    }

    static func markAcknowledged() {
        UserDefaults.standard.set(true, forKey: acknowledgedKey)
    }
}

/// 「修改 Wi-Fi 设置」教学窗口。
///
/// 教学内容本身在 `WifiGuideView`；这里只负责窗口生命周期与弹出时机：
///
/// - **首次启动自动弹一次**：用 `UserDefaults`（键 `syny.didAutoShowWifiGuide`）记录。
///   之所以要自动弹，是因为这个问题（「私有 Wi-Fi 地址」默认「轮换」）没有任何软件侧的
///   绕过办法：改 MAC 需要管理员权限，且该开关不在可编程范围内。
///   不告诉用户，用户只会看到「工具装了却老让重新认证」。
/// - **随时可重开**：面板上的「WiFi 设置教学」按钮 / 通知都能再开一次，不限于首次。
/// - **点「我知道了」后收起面板提示**：面板主区域那张常驻提示卡只服务于「还没读过」的用户，
///   读过之后就不该继续占位置；确认状态写入 `WifiGuideState.acknowledged`，
///   回看入口保留在「高级设置」里。
/// - 窗口是普通可关闭窗口（不是 NSPanel）：教学要能停在屏幕上对照着操作。
@MainActor
final class WifiGuideWindow: NSObject, NSWindowDelegate {

    /// 当前活着的实例。同一时刻只允许一个教学窗口。
    private static var current: WifiGuideWindow?

    /// 供 `AppDelegate.closeStrayWindows()` 识别并放行，避免窗口刚弹出就被清理掉。
    static var existingWindow: NSWindow? { current?.window }

    private var window: NSWindow?

    /// 诊断开关（默认关闭，与 `SYNY_POPOVER_SELFTEST` 同一约定）：
    /// 设环境变量 `SYNY_GUIDE_SELFTEST=1`，或创建标记文件 `/tmp/syny_guide_selftest`
    /// 才启用。启用后窗口弹出 2 秒自动走一遍「我知道了」的真实链路
    /// （写键 → 广播 → 面板收起提示卡），2.6 秒后关窗，用于回归验证这条链路没断。
    /// 默认静默、不产生任何日志。
    private var diagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["SYNY_GUIDE_SELFTEST"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/syny_guide_selftest")
    }

    /// 走一遍「我知道了」：写确认键 + 广播通知。
    ///
    /// 按钮与自检**共用这一条实现**，保证自检验的就是真实路径，
    /// 而不是另写一段「看起来等效」的代码（那种写法会随实现漂移而失去意义）。
    static func acknowledge() {
        WifiGuideState.markAcknowledged()
        NotificationCenter.default.post(name: .synyWifiGuideAcknowledged, object: nil)
    }

    /// 首次启动是否还需要自动弹出教学。
    static var needsAutoShow: Bool { WifiGuideState.needsAutoShow }

    /// 首次启动自动弹出（只在从未弹过时执行）。
    ///
    /// 标记在「即将弹出」时就写入，而不是等用户关窗：否则用户不关窗直接退出应用，
    /// 下次启动又会弹一次，变成每次都弹。
    static func showIfNeeded() {
        guard needsAutoShow else { return }
        WifiGuideState.markAutoShown()
        show()
    }

    /// 打开教学窗口（已存在则置前）。
    static func show() {
        if let existing = current, let window = existing.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = WifiGuideWindow()
        current = controller
        controller.present()
    }

    private func present() {
        // 高度按屏幕可用空间收敛（上下各留 60pt 余量），超出部分由内容区自己滚动。
        // 截图较高（第二步约 940×1066），写死高度会在小屏 / 分屏下把底部按钮顶出屏幕。
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentHeight = min(800, max(480, visible.height - 120))

        let hosting = NSHostingController(rootView: WifiGuideView(
            height: contentHeight,
            onAcknowledge: { WifiGuideWindow.acknowledge() },
            onClose: { [weak self] in self?.window?.close() }
        ))

        let window = NSWindow(contentViewController: hosting)
        window.title = "SYNY · Wi-Fi 设置教学"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 560, height: 420)
        // 尺寸完全由 WifiGuideView 的理想高度（contentHeight）决定，这里再显式确认一次：
        // 视图侧已把 ScrollView 的理想高度钉住，两者一致，不会出现「窗口比屏幕还高」。
        window.setContentSize(NSSize(width: 600, height: contentHeight))
        // 自己持有生命周期：关窗后仍保留对象，由 windowWillClose 主动断开引用。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // 应用是 .accessory（无 Dock 图标），不会因为开窗自动成为前台应用；
        // 不显式激活的话窗口会开到其它窗口后面，用户看到的是「点了没反应」。
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if diagnosticsEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                WifiGuideWindow.acknowledge()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                self?.window?.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if Self.current === self { Self.current = nil }
    }
}
