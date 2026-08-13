import SwiftUI

/// iOS16 兼容的空态视图(2026-08-12):替代 iOS17 的 ContentUnavailableView,
/// 视觉对齐系统样式(居中大图标 + 标题 + 次要说明),不改变任何 UI 表现。
struct EmptyStateView: View {
    var label: String
    var systemImage: String
    var description: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 搜索无结果空态(对齐系统 ContentUnavailableView.search(text:))。
    static func search(text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(String(format: L10n.l("no_results_for"), text))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
