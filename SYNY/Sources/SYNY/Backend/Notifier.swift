import Foundation

/// 系统通知。
///
/// 用 `osascript` 的 `display notification`（与 Python 版一致）：不依赖 Python，
/// 也不需要额外申请通知权限，任何 Mac 上都能直接弹出。
enum Notifier {

    static func notify(title: String, message: String, subtitle: String = "") {
        var script = "display notification \(quoted(message)) with title \(quoted(title))"
        if !subtitle.isEmpty {
            script += " subtitle \(quoted(subtitle))"
        }
        Shell.capture("/usr/bin/osascript", ["-e", script], timeout: 5)
    }

    /// 把字符串转成 AppleScript 可用的字面量（JSON 转义规则与之兼容）。
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text,
                                                options: [.fragmentsAllowed])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return json.isEmpty ? "\"\"" : json
    }
}
