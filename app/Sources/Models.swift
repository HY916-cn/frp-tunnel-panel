import Foundation

struct Proxy: Codable, Identifiable, Hashable {
    let name: String
    let type: String
    let localPort: Int
    let remotePort: Int

    var id: String { name }
}

struct LocalStatus: Codable {
    let serverAddr: String
    let serverPort: Int
    let loaded: Bool
    let connected: Bool
    let proxies: [Proxy]
    let log: [String]
}

struct RemoteStatus: Codable {
    let reachable: Bool
    let host: String
    let reason: String?
    let active: Bool?
    let rawState: String?
    let since: String?
    let log: [String]?
}

struct PortCheck: Codable {
    let valid: Bool
    let occupied: Bool?
    let reason: String?
}

struct ActionResult: Codable {
    let ok: Bool?
    let error: String?
}

enum PanelError: LocalizedError {
    case backendDown
    case http(String)

    var errorDescription: String? {
        switch self {
        case .backendDown:
            return "连接不上后台服务 (127.0.0.1:8000)"
        case .http(let message):
            return message
        }
    }
}
