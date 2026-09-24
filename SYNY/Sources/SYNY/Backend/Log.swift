import Foundation

/// 日志（与 Python 版 `core.log` 行为一致）。
///
/// 默认**不写任何文件**：只有用户在界面里打开「记录运行日志」后才会落盘，
/// 避免给用户留一堆看不懂的文件。日志文件超过 1MB 时自动截断保留最后 800 行。
enum Log {

    private static let maxBytes = 1024 * 1024
    private static let keepLines = 800

    static var enabled: Bool { AppConfig.load().logging }

    static func write(_ message: String, level: String = "INFO") {
        let stamp = timestamp()
        let padded = level.padding(toLength: 5, withPad: " ", startingAt: 0)
        let line = "[\(stamp)] \(padded) \(message)"

        if enabled {
            AppPaths.ensureSupportDir()
            append(line + "\n")
            rotate()
        }

        // 仅在终端前台运行时回显；后台运行时 stdout 已重定向到日志文件，
        // 此时再 print 会造成同一条日志被记录两次。
        if isatty(STDOUT_FILENO) != 0 {
            print(line)
            fflush(stdout)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: AppPaths.logPath)
    }

    static func readTail(_ maxLines: Int = 300) -> String {
        guard let text = try? String(contentsOfFile: AppPaths.logPath, encoding: .utf8) else {
            return "(暂无日志)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    // MARK: - 内部

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: AppPaths.logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: AppPaths.logPath))
        }
    }

    private static func rotate() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.logPath)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }
        let tail = readTail(keepLines)
        try? tail.write(toFile: AppPaths.logPath, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
