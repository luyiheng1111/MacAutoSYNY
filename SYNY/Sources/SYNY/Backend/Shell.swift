import Foundation

/// 系统命令封装。
///
/// 只调用 macOS 自带的命令行工具（security / launchctl / networksetup /
/// osascript / open），这些工具在任何 Mac 上开箱即用，不引入第三方依赖，
/// 更不依赖 Python。
enum Shell {

    struct Result {
        var status: Int32 = -1
        var out = ""
        var err = ""
        var timedOut = false

        var ok: Bool { status == 0 }
        /// 合并输出，便于在错误信息里带上原因
        var text: String { out.isEmpty ? err : (err.isEmpty ? out : out + "\n" + err) }
    }

    /// 执行命令并收集输出（stdout / stderr 分开读取，避免管道写满互相阻塞）。
    @discardableResult
    static func capture(_ launchPath: String,
                        _ arguments: [String],
                        env: [String: String]? = nil,
                        timeout: TimeInterval = 15) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return Result(status: -1, out: "", err: "命令超时：\(launchPath)", timedOut: true)
        }
        process.waitUntilExit()

        return Result(status: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// 只关心退出码时使用。
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String],
                    env: [String: String]? = nil) -> Int32 {
        capture(launchPath, arguments, env: env).status
    }

    /// 启动一个与当前进程解耦的子进程（用于「独立进程模式」的守护进程）。
    ///
    /// stdout / stderr 直接重定向到日志文件或 /dev/null，stdin 接 /dev/null，
    /// 这样父进程（设置界面）退出后子进程依然存活。
    static func spawnDetached(_ launchPath: String,
                              _ arguments: [String],
                              env: [String: String],
                              currentDirectory: String,
                              stdoutPath: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.standardInput = FileHandle.nullDevice

        // /dev/null 用 nullDevice；日志文件用追加方式打开
        if stdoutPath == "/dev/null" {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        } else {
            FileManager.default.createFile(atPath: stdoutPath, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: stdoutPath) else { return nil }
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        return process.processIdentifier
    }
}
