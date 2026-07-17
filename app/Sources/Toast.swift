import SwiftUI

struct ToastItem: Equatable {
    enum Kind {
        case success, error, warning

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .warning: return .orange
            }
        }
    }

    let kind: Kind
    let message: String
}

/// 悬浮提示。用 overlay 渲染在内容之上，不参与布局，
/// 所以出现/消失时页面不会被顶得上下跳动。
struct ToastView: View {
    let item: ToastItem
    let onDismiss: () -> Void

    var body: some View {
        // 用 .center 而不是手工基线偏移：toast 消息绝大多数是单行短句，.center 对单行是
        // 天然正确的（图标、文字、关闭按钮视觉中心对齐）；用 .firstTextBaseline 配合手工
        // alignmentGuide 猜偏移量的做法已经证明不可靠（猜错方向会把关闭按钮往下推出安全区，
        // 顶到圆角边缘），.center 不需要猜任何像素值。多行消息时图标会居中于整个文字块，
        // 不如逐行贴合精致，但没有裁切/溢出风险，用短消息为主的场景里这个取舍是对的。
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.kind.tint)
            Text(item.message)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 11)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(item.kind.tint.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}

struct ToastOverlay: ViewModifier {
    let item: ToastItem?
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let item {
                ToastView(item: item, onDismiss: onDismiss)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: item)
    }
}

extension View {
    func toast(_ item: ToastItem?, onDismiss: @escaping () -> Void) -> some View {
        modifier(ToastOverlay(item: item, onDismiss: onDismiss))
    }
}
