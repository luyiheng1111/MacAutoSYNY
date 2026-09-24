import Foundation

// MARK: - JSON 宽松取值
//
// Python 版直接 `cfg.update({k: v ...})`，类型不匹配时由 Python 的动态类型兜底。
// Swift 是静态类型，这里统一做「宽松转换 + 失败回落默认值」，保证任何手写或
// 旧版本写坏了的 config.json 都不会让程序崩掉。

enum JSONValue {

    static func string(_ any: Any?, default def: String = "") -> String {
        switch any {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        case .none, is NSNull: return def
        default: return def
        }
    }

    static func int(_ any: Any?, default def: Int) -> Int {
        switch any {
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value.trimmingCharacters(in: .whitespaces)) ?? def
        case .none, is NSNull: return def
        default: return def
        }
    }

    /// 与 Python `bool(v)` 语义对齐：非空字符串 / 非 0 数字为真。
    static func bool(_ any: Any?, default def: Bool) -> Bool {
        switch any {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String:
            let lowered = value.lowercased().trimmingCharacters(in: .whitespaces)
            if ["true", "yes", "y", "1", "on"].contains(lowered) { return true }
            if ["false", "no", "n", "0", "off", ""].contains(lowered) { return false }
            return true
        case .none, is NSNull: return def
        default: return def
        }
    }
}

// MARK: - URL 工具
//
// 对齐 Python 的 `urllib.parse`：校园网门户的 query 需要「原样搬运 + 二次编码」，
// URLComponents 遇到非标准 query（重复键、未编码中文、特殊字符）会直接失败，
// 因此这里用与 Python 等价的手写解析，保证行为完全一致。

enum WebUtil {

    /// 与 Python `quote(safe="")` 等价：除 unreserved 字符外全部百分号编码。
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func quote(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// 与 Python `unquote` 等价（不把 `+` 当空格）。
    static func unquote(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }

    /// 与 Python `urlencode` 等价：空格编码为 `+`，其余按 unreserved 收紧。
    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = unreserved
        allowed.insert(charactersIn: " ")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)".replacingOccurrences(of: " ", with: "+")
        }.joined(separator: "&")
    }

    // MARK: urlsplit / parse_qsl

    struct Parts {
        var scheme = ""
        var netloc = ""
        var path = ""
        var query = ""

        /// 去掉 query 与 fragment 的完整 URL
        var origin: String { "\(scheme)://\(netloc)" }
    }

    static func split(_ url: String) -> Parts {
        var rest = url
        var parts = Parts()

        if let range = rest.range(of: "://") {
            parts.scheme = String(rest[rest.startIndex..<range.lowerBound])
            rest = String(rest[range.upperBound...])
        }
        // 去掉 fragment
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[rest.startIndex..<hash]) }
        // netloc 到第一个 `/` 或 `?` 为止
        let netlocEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        parts.netloc = String(rest[rest.startIndex..<netlocEnd])
        rest = String(rest[netlocEnd...])

        if let mark = rest.firstIndex(of: "?") {
            parts.path = String(rest[rest.startIndex..<mark])
            parts.query = String(rest[rest.index(after: mark)...])
        } else {
            parts.path = rest
        }
        if parts.scheme.isEmpty { parts.scheme = "http" }
        return parts
    }

    /// 与 Python `parse_qsl(qs, keep_blank_values=True)` 等价。
    static func parseQuery(_ query: String) -> [(String, String)] {
        guard !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            guard let eq = pair.firstIndex(of: "=") else {
                return (unquote(String(pair)), "")
            }
            return (unquote(String(pair[pair.startIndex..<eq])),
                    unquote(String(pair[pair.index(after: eq)...])))
        }
    }

    /// 从 query 串还原成「+ 与 %20 都视为空格」的参数字典（用于缓存）。
    static func queryDictionary(_ query: String) -> [String: String] {
        var dict: [String: String] = [:]
        for (key, value) in parseQuery(query) where !key.isEmpty {
            dict[key] = value
        }
        return dict
    }
}

// MARK: - 正则小工具

enum Regex {

    /// 返回第一个匹配的第 `group` 个捕获组。
    static func firstGroup(_ pattern: String, in text: String,
                           group: Int = 1,
                           options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              group < match.numberOfRanges,
              let captured = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    /// 返回全部匹配的指定捕获组。
    static func allGroups(_ pattern: String, in text: String,
                          group: Int = 1,
                          options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let captured = Range(match.range(at: group), in: text) else { return nil }
            return String(text[captured])
        }
    }
}
