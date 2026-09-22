import SwiftUI
import AppKit
import Combine

@main
struct SYNYApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 本应用没有普通窗口，界面全部由状态栏 popover 承载。
        Settings { EmptyView() }
    }
}

/// 状态栏图标 + NSPopover。
///
/// 不用 `MenuBarExtra`：它的 `.window` 面板在内容高度变化（展开/折叠高级设置）时
/// 会丢失定位锚点、跑到屏幕中间。`NSPopover` 始终锚定在状态栏按钮下方，
/// 尺寸固定时不漂移。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    /// 诊断开关（默认关闭）：设环境变量 `SYNY_POPOVER_SELFTEST=1`，或创建标记文件
    /// `/tmp/syny_selftest` 才启用。启用后会写 `/tmp/syny_popover.log`，并在启动后
    /// 程序化点击一次状态栏按钮，用于排查「菜单栏面板不弹出」。默认静默、不产生任何日志。
    private let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["SYNY_POPOVER_SELFTEST"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/syny_selftest")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "SYNY")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: SYNYPanel().environmentObject(model))
        // NSHostingController 显式声明尺寸策略，让宿主视图有确定尺寸；否则其尺寸
        // 可能未定，影响 popover 内容布局。
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = hosting

        // 面板高度自适应内容（并受用户设定上限约束）：订阅模型尺寸变化，实时同步 popover。
        model.$panelContentHeight
            .combineLatest(model.$panelMaxHeight)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyPanelSize() }
            .store(in: &cancellables)
        applyPanelSize()

        closeStrayWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.closeStrayWindows()
        }
        debugLog("launched; statusItem=\(item.button != nil); "
                 + "statusWinVisible=\(item.button?.window?.isVisible ?? false)")

        if diagnosticsEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.debugLog("selftest: performClick(nil)")
                self?.statusItem?.button?.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.debugLog("selftest: popover.isShown=\(self.popover.isShown); "
                              + "winFrame=\(String(describing: self.popover.contentViewController?.view.window?.frame))")
            }
        }
    }

    /// 关掉「无界面只有外框」的空窗口。
    ///
    /// 注意：必须放行状态栏项所在的 `NSStatusBarWindow`——它只是普通 `NSWindow`、
    /// 并非 `NSPanel`，若被一并关掉，状态栏按钮的窗口将 `isVisible == false`，
    /// `NSPopover.show(relativeTo:of:)` 会因此静默失败，表现为「点菜单栏图标无反应」。
    private func closeStrayWindows() {
        let popoverWindow = popover.contentViewController?.view.window
        let statusWindow = statusItem?.button?.window
        for window in NSApplication.shared.windows where window.isVisible {
            if window is NSPanel { continue }
            if let popoverWindow, window === popoverWindow { continue }
            if let statusWindow, window === statusWindow { continue }
            window.orderOut(nil)
            window.close()
        }
    }

    /// 同步 popover 尺寸为「内容自适应、且不超过用户上限」的高度。
    private func applyPanelSize() {
        let size = NSSize(width: AppModel.panelWidth, height: model.panelPreferredHeight)
        popover.contentSize = size
        popover.contentViewController?.preferredContentSize = size
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            debugLog("toggle: no button")
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            debugLog("toggle: closed")
            return
        }
        // 先激活 app，再弹出 popover —— 避免 `.transient` 在未激活时刚弹出就被系统吞掉
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        debugLog("toggle: isShown=\(popover.isShown); "
                 + "statusWinVisible=\(button.window?.isVisible ?? false)")
    }

    // MARK: - 拒绝一切自动窗口 / 状态恢复
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool { false }
    func application(_ app: NSApplication,
                     shouldSaveApplicationState coder: NSCoder) -> Bool { false }
    func application(_ app: NSApplication,
                     shouldRestoreApplicationState coder: NSCoder) -> Bool { false }

    // MARK: - 诊断日志（仅在诊断开关开启时写文件，默认不产生任何日志）
    private func debugLog(_ message: String) {
        guard diagnosticsEnabled else { return }
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/syny_popover.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
