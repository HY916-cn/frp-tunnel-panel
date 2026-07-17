import Foundation
import Observation

/// 表单字段的校验结论，UI 直接照着渲染
enum FieldState: Equatable {
    case empty
    case checking
    case ok(String)
    case warning(String)
    case bad(String)

    /// 该字段是否已确认可用。检查中/未填/不可用都不算通过。
    /// warning 表示远端探测没能连上、无法确认占用情况——此时隧道本来也建不起来，同样不放行。
    var isPassing: Bool {
        if case .ok = self { return true }
        return false
    }
}

@MainActor
@Observable
final class PanelModel {
    var local: LocalStatus?
    var remote: RemoteStatus?
    var loadError: String?
    var busy = false

    // 新增隧道表单
    var newName = "" { didSet { validateName() } }
    var newLocalPort = ""
    var newRemotePort = ""

    var nameState: FieldState = .empty
    var localState: FieldState = .empty
    var remoteState: FieldState = .empty

    /// 浮层提示，不占布局
    var toast: ToastItem?

    private var refreshTask: Task<Void, Never>?
    private var localCheckTask: Task<Void, Never>?
    private var remoteCheckTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    func showToast(_ kind: ToastItem.Kind, _ message: String, autoDismiss: Bool = true) {
        toast = ToastItem(kind: kind, message: message)
        toastDismissTask?.cancel()
        guard autoDismiss else { return }
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
    }

    // MARK: - 刷新

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
    }

    func refresh() async {
        async let localResult = try? await API.shared.localStatus()
        async let remoteResult = try? await API.shared.remoteStatus()
        let (l, r) = await (localResult, remoteResult)
        local = l
        remote = r
        loadError = (l == nil)
            ? "连接不上后台服务 (127.0.0.1:8000)，隧道配置读不到。请确认 frp-panel 服务在运行。"
            : nil
        // 隧道列表变化后，已填的名称/端口可能刚好和新隧道撞上，重新校验一遍，
        // 否则用户看到的还是撞车之前的绿色"可用"，点添加时才会被后端拒绝。
        if !newName.isEmpty { validateName() }
        if !newLocalPort.trimmingCharacters(in: .whitespaces).isEmpty { onLocalPortChanged() }
        if !newRemotePort.trimmingCharacters(in: .whitespaces).isEmpty { onRemotePortChanged() }
    }

    // MARK: - 名称校验（本地即时，不需要网络）

    private func validateName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            nameState = .empty
            return
        }
        guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            nameState = .bad("只能用小写字母、数字、连字符")
            return
        }
        if let proxies = local?.proxies, proxies.contains(where: { $0.name == name }) {
            nameState = .bad("名称已存在，请换一个")
            return
        }
        nameState = .ok("可用")
    }

    // MARK: - 端口校验

    func onLocalPortChanged() {
        localCheckTask?.cancel()
        localCheckTask = checkPort(side: "local", raw: newLocalPort) { [weak self] state in
            self?.localState = state
        }
    }

    func onRemotePortChanged() {
        remoteCheckTask?.cancel()
        remoteCheckTask = checkPort(side: "remote", raw: newRemotePort) { [weak self] state in
            self?.remoteState = state
        }
    }

    private func checkPort(
        side: String,
        raw: String,
        assign: @escaping (FieldState) -> Void
    ) -> Task<Void, Never>? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            assign(.empty)
            return nil
        }
        guard let port = Int(trimmed) else {
            assign(.bad("请输入数字"))
            return nil
        }
        guard (1024...65535).contains(port) else {
            assign(.bad("需在 1024–65535 之间"))
            return nil
        }

        assign(.checking)
        return Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let result = try await API.shared.checkPort(side: side, port: port)
                guard !Task.isCancelled else { return }
                if result.valid && result.occupied == nil {
                    // 远端 SSH 探测失败：不阻止提交，但要让用户知道没能确认
                    assign(.warning(result.reason ?? "无法确认远端占用情况"))
                } else if result.valid {
                    assign(.ok("可用"))
                } else {
                    assign(.bad(result.reason ?? "不可用"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                // 探测失败不等于端口不可用，标黄警告，仍允许提交由后端裁决
                assign(.warning("检查失败：\(error.localizedDescription)"))
            }
            _ = self
        }
    }

    /// 三项检查全部通过才允许提交，任何一项未过（含检查中、未填、被占用）按钮都不可点。
    /// 后端在提交时仍会独立复核一次，这里的门槛只是让不可能成功的提交提前失败。
    var canSubmit: Bool {
        guard !busy else { return false }
        return nameState.isPassing && localState.isPassing && remoteState.isPassing
    }

    // MARK: - 操作

    func addProxy() async {
        guard !busy else { return }
        guard
            let lp = Int(newLocalPort.trimmingCharacters(in: .whitespaces)),
            let rp = Int(newRemotePort.trimmingCharacters(in: .whitespaces))
        else { return }

        busy = true
        let name = newName.trimmingCharacters(in: .whitespaces)
        do {
            try await API.shared.addProxy(name: name, localPort: lp, remotePort: rp)
            newName = ""
            newLocalPort = ""
            newRemotePort = ""
            nameState = .empty
            localState = .empty
            remoteState = .empty
            showToast(.success, "隧道 \"\(name)\" 已添加，frpc 正在重载")
        } catch {
            // 提交失败保留在表单里，方便改完再提交；错误不自动消失
            showToast(.error, error.localizedDescription, autoDismiss: false)
        }
        busy = false
        try? await Task.sleep(for: .milliseconds(1200))
        await refresh()
    }

    func removeProxy(_ name: String) async {
        guard !busy else { return }
        busy = true
        do {
            try await API.shared.removeProxy(name: name)
            showToast(.success, "隧道 \"\(name)\" 已删除")
        } catch {
            showToast(.error, error.localizedDescription, autoDismiss: false)
        }
        busy = false
        try? await Task.sleep(for: .milliseconds(1200))
        await refresh()
    }

    func clearLog(side: String) async {
        guard !busy else { return }
        busy = true
        do {
            try await API.shared.clearLog(side: side)
            showToast(.success, side == "local" ? "本地 frpc 日志已清空" : "远程 frps 日志已清空")
        } catch {
            showToast(.error, error.localizedDescription, autoDismiss: false)
        }
        busy = false
        await refresh()
    }

    private static let actionLabels = [
        "start": "启动", "stop": "停止", "reload": "重载", "restart": "重启",
    ]

    func localAction(_ action: String) async {
        guard !busy else { return }
        busy = true
        do {
            try await API.shared.localAction(action)
            showToast(.success, "本地 frpc 已\(Self.actionLabels[action] ?? action)")
        } catch {
            showToast(.error, error.localizedDescription, autoDismiss: false)
        }
        busy = false
        try? await Task.sleep(for: .milliseconds(1200))
        await refresh()
    }

    func remoteAction(_ action: String) async {
        guard !busy else { return }
        busy = true
        do {
            try await API.shared.remoteAction(action)
            showToast(.success, "远程 frps 已\(Self.actionLabels[action] ?? action)")
        } catch {
            showToast(.error, error.localizedDescription, autoDismiss: false)
        }
        busy = false
        try? await Task.sleep(for: .milliseconds(1500))
        await refresh()
    }
}
