import SwiftUI

struct ProxyRow: View {
    let proxy: Proxy
    let isLast: Bool
    let busy: Bool
    let isDragging: Bool
    let onDelete: () -> Void

    /// 本地/远程端口不一致时高亮提示——网站项目要求两者相同，
    /// 不同通常意味着这是系统级服务（远端端口被占而错开）。
    private var remoteColor: Color {
        proxy.localPort == proxy.remotePort ? .primary : .orange
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)
                    .help("拖拽调整隧道顺序")

                Text(proxy.name)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 150, alignment: .leading)

                Text(String(proxy.localPort))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 80, alignment: .leading)

                Text(String(proxy.remotePort))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(remoteColor)
                    .frame(width: 80, alignment: .leading)

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            .padding(.vertical, 7)
            .opacity(isDragging ? 0.45 : 1)

            if !isLast {
                Divider().opacity(0.5)
            }
        }
    }
}
