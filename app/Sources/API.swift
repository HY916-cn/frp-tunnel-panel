import Foundation

/// 与本机 Node 后端 (127.0.0.1:8000) 通信。后端负责 TOML 读写、端口探测、
/// launchctl 与远程 systemctl 调用；这里只做 HTTP 与解码。
actor API {
    static let shared = API()

    private let base = URL(string: "http://127.0.0.1:8000")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    /// 构造请求 URL。查询参数必须走 URLComponents —— 直接把 "path?a=b" 交给
    /// appendingPathComponent 会把 "?" 转义成 %3F，整串被当成路径，后端返回 404。
    private func makeURL(path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PanelError.http("URL 构造失败")
        }
        components.path = "/" + path
        components.queryItems = query.isEmpty
            ? nil
            : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw PanelError.http("URL 构造失败: \(path)")
        }
        return url
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        as type: T.Type
    ) async throws -> T {
        var req = URLRequest(url: try makeURL(path: path, query: query))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PanelError.backendDown
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let payload = try? JSONDecoder().decode([String: String].self, from: data),
               let message = payload["error"] {
                throw PanelError.http(message)
            }
            throw PanelError.http("请求失败 (HTTP \(http.statusCode))")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    func localStatus() async throws -> LocalStatus {
        try await request("api/status", as: LocalStatus.self)
    }

    func remoteStatus() async throws -> RemoteStatus {
        try await request("api/remote/status", as: RemoteStatus.self)
    }

    func checkPort(side: String, port: Int) async throws -> PortCheck {
        try await request(
            "api/check-port",
            query: ["side": side, "port": String(port)],
            as: PortCheck.self
        )
    }

    func addProxy(name: String, localPort: Int, remotePort: Int) async throws {
        _ = try await request(
            "api/proxies",
            method: "POST",
            body: ["name": name, "localPort": localPort, "remotePort": remotePort],
            as: ActionResult.self
        )
    }

    // components.path 会自行做百分号编码，这里传未编码的名称即可，不要预先编码（会双重转义）
    func removeProxy(name: String) async throws {
        _ = try await request("api/proxies/\(name)", method: "DELETE", as: ActionResult.self)
    }

    func localAction(_ action: String) async throws {
        _ = try await request("api/\(action)", method: "POST", as: ActionResult.self)
    }

    func clearLog(side: String) async throws {
        _ = try await request(
            "api/logs/clear",
            method: "POST",
            query: ["side": side],
            as: ActionResult.self
        )
    }

    func remoteAction(_ action: String) async throws {
        _ = try await request("api/remote/\(action)", method: "POST", as: ActionResult.self)
    }
}
