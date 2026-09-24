import Foundation
import Network

/// 网络路径变化监视器（事件驱动，替代「死等 check_interval」）。
///
/// 为什么必须有它：
/// macOS 在 Wi-Fi 关联完成后会**立刻**自己做一次 captive 探测，一旦发现被
/// 网关劫持，就弹出系统默认的登录页（Captive Network Assistant，即用户看到的
/// 「系统默认登录页」）。如果此时 SYNY 已经抢先完成认证，macOS 那次探测就会
/// 拿到真正的 204，登录页根本不会弹。
///
/// 旧实现靠 `check_interval`（默认 5 秒）轮询，等它发现网络变化时，系统登录页
/// 早已弹出 —— 表现就是用户说的「断网后弹出系统默认登录页，工具没起作用」。
/// 这里改成事件驱动：网络路径一有变化立刻结束等待，马上进入下一轮认证，
/// 把「抢占」的时间窗从最坏 5 秒压到毫秒级。
///
/// 设计要点：`NWPathMonitor` 的回调在后台队列触发，只做一件事 ——
/// 给信号量 `signal()`；主循环用 `waitForChange(upTo:)` 等待。
/// 若监视器不可用（被系统拒绝等），循环退化为普通定时等待，功能不受影响。
final class PathMonitor {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.syny.path-monitor")
    private let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false

    /// 启动监视。重复调用无副作用。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            // 回调里绝不做任何耗时操作，只唤醒主循环
            self?.signal.signal()
        }
        monitor.start(queue: queue)
    }

    /// 等待最多 `seconds` 秒；期间网络路径发生变化则提前返回。
    ///
    /// 返回后被唤醒的含义是「网络状态可能变了，值得立刻重新探测一次」，
    /// 调用方无需关心是新旧哪种状态 —— 下一轮探测自己会判断。
    func waitForChange(upTo seconds: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, seconds)))
        var woke = false

        while !woke, Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            // 分段等待，便于及时响应退出信号
            woke = signal.wait(timeout: .now() + min(remaining, 1.0)) == .success
        }

        // 排空等待期间堆积的信号，避免下一轮被陈旧事件立刻唤醒而空转。
        while signal.wait(timeout: .now()) == .success {}
    }
}
