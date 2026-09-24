import Foundation

/// 与 Python 后端 `core.DEFAULT_CONFIG` 一一对应的配置模型。
struct SYNYConfig: Codable, Equatable {
    var username: String
    var checkInterval: Int
    var captiveURL: String
    var portalHint: String
    var autoStart: Bool
    var notify: Bool
    var logging: Bool
    var onlySynyWifi: Bool
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case username
        case checkInterval = "check_interval"
        case captiveURL = "captive_url"
        case portalHint = "portal_hint"
        case autoStart = "auto_start"
        case notify
        case logging
        case onlySynyWifi = "only_syny_wifi"
        case enabled
    }

    static let fallback = SYNYConfig(
        username: "",
        checkInterval: 30,
        captiveURL: "http://captive.apple.com/hotspot-detect.html",
        portalHint: "",
        autoStart: true,
        notify: true,
        logging: false,
        onlySynyWifi: true,
        enabled: false
    )
}

struct ServiceStatus: Codable {
    var mode: String       // launchd / process / stopped
    var running: Bool
    var pid: Int?
}

struct WifiStatus: Codable {
    var ssid: String
    var isSyny: Bool
    var hasWifiInterface: Bool
    var wifiHasAddress: Bool
    var nameIsRedacted: Bool
    
    enum CodingKeys: String, CodingKey {
        case ssid
        case isSyny = "is_syny"
        case hasWifiInterface = "has_wifi_interface"
        case wifiHasAddress = "wifi_has_address"
        case nameIsRedacted = "name_is_redacted"
    }
}

struct StatusPayload: Codable {
    var config: SYNYConfig
    var hasPassword: Bool
    var service: ServiceStatus
    var wifi: WifiStatus
    var logTail: String

    enum CodingKeys: String, CodingKey {
        case config
        case hasPassword = "has_password"
        case service
        case wifi
        case logTail = "log_tail"
    }
}

/// 后端统一响应信封：{ ok, message, data }
struct APIEnvelope: Decodable {
    var ok: Bool
    var message: String
    var data: AnyDecodable?
}

/// 任意 JSON 值的轻量解码器（用于 data 字段再解析为具体类型）。
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode([String: AnyDecodable].self) {
            value = v.mapValues { $0.value }
        } else if let v = try? container.decode([AnyDecodable].self) {
            value = v.map { $0.value }
        } else if let v = try? container.decode(String.self) {
            value = v
        } else if let v = try? container.decode(Int.self) {
            value = v
        } else if let v = try? container.decode(Double.self) {
            value = v
        } else if let v = try? container.decode(Bool.self) {
            value = v
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported")
        }
    }

    var asDict: [String: Any]? { value as? [String: Any] }
}
