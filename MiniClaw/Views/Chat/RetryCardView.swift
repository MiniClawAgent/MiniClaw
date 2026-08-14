import SwiftUI

struct RetryCardView: View {
    let state: RetryState
    /// 受控展开状态（2026-08-09 与思考块同机制）。
    var isExpanded: Bool = false
    var onToggle: (() -> Void)? = nil
    /// 手动立即重试（转发到 engine.requestImmediateRetry）
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.phase == .retrying {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(format: L10n.l("retrying"), "\(state.attempt)", "\(state.total)"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Text(L10n.l("retry_failed"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 右侧重试按钮：点击立即重试；次数耗尽后禁用。
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(state.canRetry ? Color.accentColor : Color(.systemGray3))
                }
                .disabled(!state.canRetry)
                .buttonStyle(.plain)

                // 展开 / 收起错误详情（2026-08-09：同样去掉动画，与思考块同机制）
                Button {
                    onToggle?()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
            }

            // 错误详情：多行完整展示（比工具指示器长），可选中复制。
            if isExpanded {
                Text(state.lastError.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }
}

