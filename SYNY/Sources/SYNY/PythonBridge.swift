import Foundation

/// 通过子进程与 Python 后端通信：每次调用起一个进程，
/// 执行 `python3 -m syny_auth api`，stdin 传入一行 JSON，stdout 读回一行 JSON。
enum PythonBridge {

    /// 后端只用 Python 标准库，因此任意可用的 python3 都行；
    /// 优先系统 framework Python（Finder 启动时 PATH 极简，必须用绝对路径）。
    static func pythonExecutable() -> String {
        if let override = ProcessInfo.processInfo.environment["SYNY_PYTHON"],
           !override.isEmpty {
            return override
        }
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/python3"
    }

    /// 包含 `syny_auth` 包的目录（需放在 PYTHONPATH 上）。
    static func pythonPath() -> String {
        if let override = ProcessInfo.processInfo.environment["SYNY_PYTHONPATH"],
           !override.isEmpty {
            return override
        }
        if let res = Bundle.main.resourceURL {
            let pkg = res.appendingPathComponent("syny_auth")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return res.path
            }
        }
        return Bundle.main.resourceURL?.path ?? ""
    }

    /// 发起一次后端调用，返回解析后的 JSON 字典（失败时返回 {ok:false,message:...}）。
    static func call(_ request: [String: Any]) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable())
        process.arguments = ["-m", "syny_auth", "api"]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pythonPath()
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ["ok": false, "message": "无法启动 Python 后端：\(error.localizedDescription)"]
        }

        let requestData = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.closeFile()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let object = try? JSONSerialization.jsonObject(with: outputData),
           let dict = object as? [String: Any] {
            return dict
        }

        let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        let raw = String(data: outputData, encoding: .utf8) ?? ""
        let detail = [raw, errText].filter { !$0.isEmpty }.joined(separator: " / ")
        return ["ok": false, "message": "后端无有效响应。\(detail.prefix(300))"]
    }

    /// 把 data 字段重新序列化后解码为具体类型。
    static func decode<T: Decodable>(_ type: T.Type, from data: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(data),
              let raw = try? JSONSerialization.data(withJSONObject: data) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: raw)
    }

    /// 把后端响应的 data 字典解码为具体类型。
    static func decode<T: Decodable>(_ type: T.Type, response: [String: Any]) -> T? {
        guard let data = response["data"] as? [String: Any] else { return nil }
        return decode(type, from: data)
    }

    static func message(_ response: [String: Any]) -> String {
        (response["message"] as? String) ?? ""
    }

    static func isOK(_ response: [String: Any]) -> Bool {
        (response["ok"] as? Bool) ?? false
    }
}
