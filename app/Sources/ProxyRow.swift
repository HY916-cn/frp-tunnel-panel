import SwiftUI

struct ProxyRow: View {
    let proxy: Proxy
    let isLast: Bool
    let busy: Bool
    let isDropTarget: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

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
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    onDragStarted()
                                }
                                dragOffset = value.translation.height
                                onDragChanged(value.translation.height)
                            }
                            .onEnded { _ in
                                withAnimation(.snappy(duration: 0.18)) {
                                    dragOffset = 0
                                }
                                isDragging = false
                                onDragEnded()
                            }
                    )
                    .help("按住并拖动到另一条隧道")

                Text(proxy.name)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 144, alignment: .leading)

                Text(String(proxy.localPort))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 80, alignment: .leading)

                Text(String(proxy.remotePort))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(remoteColor)
                    .frame(width: 80, alignment: .leading)

                Spacer()

                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(busy || !canMoveUp)
                .help("上移")
                .opacity(isHovered ? 1 : 0)

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(busy || !canMoveDown)
                .help("下移")
                .opacity(isHovered ? 1 : 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 5)
            .offset(y: dragOffset)
            .zIndex(isDragging ? 10 : 0)
            .background(
                isDragging
                    ? Color.accentColor.opacity(0.18)
                    : (isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                if isDragging || isDropTarget {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(isDragging ? 0.9 : 0.7), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 8, y: 3)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)

            if !isLast {
                Divider().opacity(0.5)
            }
        }
    }
}
