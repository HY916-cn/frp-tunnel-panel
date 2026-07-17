import SwiftUI

enum Health {
    case good, bad, idle, unknown

    var color: Color {
        switch self {
        case .good: return .green
        case .bad: return .red
        case .idle: return .orange
        case .unknown: return .secondary
        }
    }
}

struct StatusDot: View {
    let health: Health
    var body: some View {
        Circle()
            .fill(health.color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(health.color)
                    .opacity(0.28)
                    .frame(width: 16, height: 16)
            )
    }
}

/// 全局统一的卡片圆角，Liquid Glass 需要形状一致才能正确融合
let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.7)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: cardShape)
    }
}

struct EndpointCard: View {
    let title: String
    let subtitle: String
    let health: Health
    let statusText: String
    let detail: String?
    let actions: [(String, String)]
    let onAction: (String) -> Void
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusDot(health: health)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(health == .bad ? Color.red : .primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 6) {
                ForEach(actions, id: \.1) { label, key in
                    Button(label) { onAction(key) }
                        // 外层卡片本身已经是 glassEffect，玻璃套玻璃会互相采样导致
                        // 边界/高光糊成一团，Apple 不建议嵌套，这里用非玻璃样式
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: cardShape)
    }
}

/// 字段下方的校验反馈，带图标，颜色明确
struct FieldFeedback: View {
    let state: FieldState

    private var parts: (String, String, Color)? {
        switch state {
        case .empty:
            return nil
        case .checking:
            return ("clock", "检查中…", .secondary)
        case .ok(let message):
            return ("checkmark.circle.fill", message, .green)
        case .warning(let message):
            return ("exclamationmark.triangle.fill", message, .orange)
        case .bad(let message):
            return ("xmark.circle.fill", message, .red)
        }
    }

    var body: some View {
        Group {
            if let (icon, message, color) = parts {
                HStack(alignment: .top, spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                    Text(message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(color)
            } else {
                Color.clear
            }
        }
        .frame(height: 30, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let state: FieldState
    let width: CGFloat
    let onChange: () -> Void

    private var borderColor: Color {
        switch state {
        case .bad: return .red.opacity(0.7)
        case .ok: return .green.opacity(0.5)
        case .warning: return .orange.opacity(0.6)
        default: return .clear
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor, lineWidth: 1.5)
                )
                .onChange(of: text) { _, _ in onChange() }
            FieldFeedback(state: state)
                .frame(width: width)
        }
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "暂无日志" : lines.joined(separator: "\n"))
                .font(.system(size: 10.5, design: .monospaced))
                // 固定浅灰而非 .secondary：日志区背景是固定深色（见下），不随系统浅色/深色切换，
                // 用语义色 .secondary 在浅色模式下会算成深灰，糊在深色底上几乎看不清
                .foregroundStyle(Color(white: 0.78))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 150)
        // 日志区固定走深色主题、不跟随系统浅色/深色切换：一是等宽文本压在半透明玻璃背景上
        // 可读性差，二是控制台类界面（Xcode 控制台、Terminal、Docker Desktop 日志面板）保持
        // 固定深色是常见且合理的既定做法，不需要花两套配色去追系统外观。
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
