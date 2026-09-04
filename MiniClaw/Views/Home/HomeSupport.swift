import SwiftUI
import UIKit
import Combine

// MARK: - Session Group

enum SessionGroup: String, CaseIterable, Hashable {
    case pinned
    case today
    case yesterday
    case thisWeek = "this_week"
    case thisMonth = "this_month"
    case earlier

    var label: String {
        switch self {
        case .pinned: String(localized: "pin")
        case .today: String(localized: "today")
        case .yesterday: String(localized: "yesterday")
        case .thisWeek: String(localized: "this_week")
        case .thisMonth: String(localized: "this_month")
        case .earlier: String(localized: "earlier")
        }
    }

    /// 显示顺序：置顶 → 今天 → 昨天 → 本周 → 本月 → 更早
    static let displayOrder: [SessionGroup] = [.pinned, .today, .yesterday, .thisWeek, .thisMonth, .earlier]
}

/// 通用「功能不可用」占位视图（当前构建未集成 iSH 时使用）。
struct UnavailablePlaceholder: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmptyStateView(label: title, systemImage: "exclamationmark.triangle",
                             description: message)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
    }
}


