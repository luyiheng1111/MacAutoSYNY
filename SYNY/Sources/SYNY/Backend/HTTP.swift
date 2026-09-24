import Foundation

/// 极简同步 HTTP 客户端（对齐 Python 版 `core._http`）。
///
/// 两个关键点：
///   1. **不自动跟随跳转** —— 未认证时校园网关会把请求 302 到认证页，
///      必须拿到这个 3xx 响应本身（Location 头 / 正文里的认证页地址），
///      自动跟随反而会丢失线索；
///   2. 网络层失败时返回 `status == nil`，把异常降级成「探测未通过」，
///      让调用方继续尝试认证，而不是直接放弃。
struct HTTPResult {
    var status: Int?          // nil 表示网络层失败（DNS 不通 / 超时 / 连接被拒）
    var text: String = ""
    var headers: [String: String] = [:]   // key 统一小写，便于取值
    var error: String = ""

    var location: String { headers["location"] ?? "" }
}

enum HTTP {

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/61.0.3163.91 Safari/537.36"

    /// 禁止跟随跳转的 URLSession。
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // 传 nil = 不跟随，直接把 3xx 响应交回调用方
            completionHandler(nil)
        }
    }

    private static let delegate = NoRedirectDelegate()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        // 绕过系统代理，防止误判网络状态
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration,
                          delegate: delegate,
                          delegateQueue: nil)
    }()

    /// 发起请求并同步等待结果。
    static func request(_ url: String,
                        method: String = "GET",
                        body: String? = nil,
                        headers: [String: String] = [:],
                        timeout: TimeInterval = 10) -> HTTPResult {
        guard let target = URL(string: url) else {
            return HTTPResult(status: nil, error: "URL 非法：\(url)")
        }

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeout
        var allHeaders = ["User-Agent": userAgent]
        for (key, value) in headers { allHeaders[key] = value }
        for (key, value) in allHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = Data(body.utf8) }

        let semaphore = DispatchSemaphore(value: 0)
        var result: HTTPResult?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = HTTPResult(status: nil,
                                    error: "\(type(of: error)): \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = HTTPResult(status: nil, error: "无 HTTP 响应")
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            let payload = data ?? Data()
            result = HTTPResult(status: http.statusCode,
                                text: decode(payload, contentType: headers["content-type"] ?? ""),
                                headers: headers)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 10) == .timedOut {
            task.cancel()
            return HTTPResult(status: nil, error: "请求超时：\(url)")
        }
        return result ?? HTTPResult(status: nil, error: "未知错误")
    }

    static func post(_ url: String, form: String,
                     headers: [String: String], timeout: TimeInterval = 12) -> HTTPResult {
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        return request(url, method: "POST", body: form, headers: headers, timeout: timeout)
    }

    // MARK: - 正文解码

    /// 按响应声明的字符集解码正文，解码不出来再靠试探兜底。
    ///
    /// 为什么必须做这件事：锐捷 eportal 返回的是 **GBK**，且 Content-Type 里
    /// 往往只写 `text/html` 不带 charset。旧实现一律 `String(decoding:as: UTF8.self)`，
    /// 后果不只是「门户中文提示显示成乱码」，更严重的是**所有基于中文关键字的
    /// 判断全部失效** —— 登录时的「已在线」、下线时的「下线/成功」、
    /// 门户页的「登录」标记、以及识别「WEB认证设备未注册」这类异常页面，
    /// 都会因为关键字匹配不上而走向错误分支。
    ///
    /// 顺序：显式 charset → 严格 UTF-8 → GB18030 → 有损 UTF-8（保证不丢响应）。
    private static func decode(_ data: Data, contentType: String) -> String {
        guard !data.isEmpty else { return "" }

        if let declared = contentType.lowercased().range(of: "charset=") {
            let name = contentType.lowercased()[declared.upperBound...]
                .prefix { ![";", " ", "\"", "'"].contains($0) }
            if let encoding = encoding(forCharset: String(name)),
               let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        if let text = String(data: data, encoding: .utf8) { return text }

        if let text = String(data: data, encoding: GB18030) { return text }

        return String(decoding: data, as: UTF8.self)
    }

    /// GBK / GB2312 的公共超集，覆盖国内校园网门户的实际编码。
    private static let GB18030 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private static func encoding(forCharset name: String) -> String.Encoding? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb-2312", "gb18030", "x-gbk", "cp936": return GB18030
        case "big5", "big-5": return String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        default: return nil
        }
    }
}
