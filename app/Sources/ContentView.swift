import SwiftUI

struct ContentView: View {
    /// 由 AppDelegate 持有并注入：菜单栏图标的健康轮询和面板共用同一份状态
    @Bindable var model: PanelModel
    @State private var pendingDelete: String?
    @State private var logTab = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            // GlassEffectContainer 让容器内的玻璃元素共享采样、正确相互融合，
            // 比每张卡片各自独立做模糊更省性能，视觉也更统一。
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) {
                    header
                    // 后端离线是持续状态而非一次性事件，留在文档流里常驻显示
                    if let error = model.loadError {
                        banner(error, icon: "exclamationmark.triangle.fill", color: .orange)
                    }
                    endpoints
                    tunnels
                    addTunnel
                    logs
                }
            }
            .padding(18)
            .padding(.top, 8)
        }
        .frame(minWidth: 640, minHeight: 720)
        .background(backdrop)
        .toast(model.toast) { model.dismissToast() }
        .task {
            await model.refresh()
            model.startAutoRefresh()
        }
        .onDisappear { model.stopAutoRefresh() }
        .confirmationDialog(
            "删除隧道 \"\(pendingDelete ?? "")\"？",
            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let name = pendingDelete {
                    Task { await model.removeProxy(name) }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后会立即重载 frpc，该端口的公网访问会中断。")
        }
    }

    /// 玻璃要有东西可折射才立得住。纯色背景下 glassEffect 几乎看不出来，
    /// 所以铺一层柔和的品牌色光晕作为底，与 app 图标同色系。
    /// .background 本身是浅色/深色自适应的语义色，但这层光晕原来是写死的不透明度——
    /// 同样的饱和蓝叠在浅色 .background（近白）上比叠在深色 .background 上扎眼得多，
    /// 所以浅色模式下调低透明度，保持两种外观下视觉分量相近。
    private var backdrop: some View {
        let intensity = colorScheme == .dark ? 1.0 : 0.45
        return ZStack {
            Rectangle().fill(.background)
            RadialGradient(
                colors: [Color(red: 0.29, green: 0.53, blue: 1.0).opacity(0.30 * intensity), .clear],
                center: .init(x: 0.08, y: 0.0),
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color(red: 0.09, green: 0.26, blue: 0.77).opacity(0.26 * intensity), .clear],
                center: .init(x: 1.0, y: 0.85),
                startRadius: 0,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("frp 隧道面板")
                    .font(.system(size: 17, weight: .semibold))
                Text("Mac Mini ↔ \(model.local?.serverAddr ?? "…")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.busy)
        }
    }

    private func banner(_ message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(11)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: 两端状态

    private var endpoints: some View {
        // 必须等于外层 GlassEffectContainer 的 spacing（14）。GlassEffectContainer 的 spacing
        // 不是纯布局参数，而是"两个玻璃形状多近会被判定为需要融合"的阈值；小于容器 spacing
        // 会导致这两张本该独立的卡片在静止状态下就产生非预期的粘连观感。
        HStack(spacing: 14) {
            EndpointCard(
                title: "本地 frpc",
                subtitle: "Mac Mini · launchd",
                health: localHealth,
                statusText: localStatusText,
                detail: model.local.map { "\($0.proxies.count) 条隧道 · 控制端口 \($0.serverPort)" },
                actions: [("启动", "start"), ("停止", "stop"), ("重载", "reload")],
                onAction: { action in Task { await model.localAction(action) } },
                busy: model.busy
            )
            EndpointCard(
                title: "远程 frps",
                subtitle: "\(model.remote?.host ?? "…") · systemd",
                health: remoteHealth,
                statusText: remoteStatusText,
                detail: model.remote?.since.map { "启动于 \($0)" },
                actions: [("启动", "start"), ("停止", "stop"), ("重启", "restart")],
                onAction: { action in Task { await model.remoteAction(action) } },
                busy: model.busy
            )
        }
    }

    private var localHealth: Health {
        guard let l = model.local else { return .unknown }
        if !l.loaded { return .idle }
        return l.connected ? .good : .bad
    }

    private var localStatusText: String {
        guard let l = model.local else { return "未知" }
        if !l.loaded { return "未运行" }
        return l.connected ? "已连接" : "运行中，未连上服务端"
    }

    private var remoteHealth: Health {
        guard let r = model.remote else { return .unknown }
        if !r.reachable { return .bad }
        return (r.active ?? false) ? .good : .idle
    }

    private var remoteStatusText: String {
        guard let r = model.remote else { return "未知" }
        if !r.reachable { return r.reason ?? "无法连接" }
        return (r.active ?? false) ? "运行中" : "已停止 (\(r.rawState ?? "unknown"))"
    }

    // MARK: 隧道列表

    private var proxyList: [Proxy] {
        model.local?.proxies ?? []
    }

    private var tunnels: some View {
        Card(title: "隧道") {
            if !proxyList.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("名称").frame(width: 150, alignment: .leading)
                        Text("本地").frame(width: 80, alignment: .leading)
                        Text("远程").frame(width: 80, alignment: .leading)
                        Spacer()
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)

                    ForEach(proxyList) { proxy in
                        ProxyRow(
                            proxy: proxy,
                            isLast: proxy.id == proxyList.last?.id,
                            busy: model.busy,
                            onDelete: { pendingDelete = proxy.name }
                        )
                    }
                }
            } else {
                Text("还没有配置隧道")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: 新增

    private var addTunnel: some View {
        Card(title: "新增隧道") {
            HStack(alignment: .top, spacing: 10) {
                LabeledField(
                    label: "名称",
                    placeholder: "如 myapp",
                    text: $model.newName,
                    state: model.nameState,
                    width: 148,
                    onChange: {}
                )
                LabeledField(
                    label: "本地端口 (Mac)",
                    placeholder: "8002",
                    text: $model.newLocalPort,
                    state: model.localState,
                    width: 122,
                    onChange: { model.onLocalPortChanged() }
                )
                LabeledField(
                    label: "远程端口 (\(model.remote?.host ?? "服务端"))",
                    placeholder: "8002",
                    text: $model.newRemotePort,
                    state: model.remoteState,
                    width: 122,
                    onChange: { model.onRemotePortChanged() }
                )
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(height: 14)
                    Button {
                        Task { await model.addProxy() }
                    } label: {
                        Text(model.busy ? "添加中…" : "添加")
                            .frame(width: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmit)
                }
            }
        }
    }

    // MARK: 日志

    private var logs: some View {
        Card(
            title: "日志",
            trailing: AnyView(
                Button {
                    Task { await model.clearLog(side: logTab == 0 ? "local" : "remote") }
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.system(size: 11))
                }
                // 这个按钮嵌在 Card 自带的 glassEffect 容器里，玻璃套玻璃会互相干扰采样，
                // 用非玻璃样式（同 EndpointCard 的处理）
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.busy)
                .help(logTab == 0
                      ? "清空本地 frpc 日志文件"
                      : "隐藏此刻之前的远程 frps 日志（journalctl 不支持按服务删除，这里只做时间过滤）")
            )
        ) {
            Picker("", selection: $logTab) {
                Text("本地 frpc").tag(0)
                Text("远程 frps").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LogView(lines: logTab == 0 ? (model.local?.log ?? []) : (model.remote?.log ?? []))
        }
    }
}
