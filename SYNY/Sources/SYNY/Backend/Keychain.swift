import Foundation

/// 系统钥匙串读写（密码不落盘）。
///
/// 实现说明：这里调用 macOS 自带的 `/usr/bin/security`，而不是 Security 框架。
/// 原因有二：
///   1. 与既有 Python 版使用完全相同的服务名 / 账号与写入方式，用户已经存好的
///      密码无需重新输入；
///   2. 本应用目前是临时签名（ad-hoc），每次重新编译 cdhash 都会变，Security
///      框架会因此反复弹「允许访问钥匙串」授权框；而 `/usr/bin/security` 是
///      Apple 签名的稳定工具，条目 ACL 对它长期有效，全程无弹窗。
enum Keychain {

    private static let security = "/usr/bin/security"

    static func service() -> String { AppPaths.keychainService }

    @discardableResult
    static func setPassword(username: String, password: String) -> Bool {
        guard !username.isEmpty else { return false }
        let result = Shell.capture(security, [
            "add-generic-password",
            "-a", username,
            "-s", AppPaths.keychainService,
            "-w", password,
            "-U",
        ], timeout: 10)
        if !result.ok {
            Log.write("钥匙串写入失败：\(result.err.trimmingCharacters(in: .whitespacesAndNewlines))",
                      level: "ERROR")
            return false
        }
        return true
    }

    static func password(username: String) -> String {
        guard !username.isEmpty else { return "" }
        let result = Shell.capture(security, [
            "find-generic-password",
            "-a", username,
            "-s", AppPaths.keychainService,
            "-w",
        ], timeout: 10)
        guard result.ok else { return "" }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deletePassword(username: String) {
        guard !username.isEmpty else { return }
        Shell.capture(security, [
            "delete-generic-password",
            "-a", username,
            "-s", AppPaths.keychainService,
        ], timeout: 10)
    }
}
