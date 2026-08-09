import SwiftUI

struct SettingsMenuView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MenuRow(icon: "brain.head.profile", color: .purple, title: L10n.tr("智能体")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "slider.horizontal.3", color: .blue, title: L10n.tr("管理")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "externaldrive", color: .green, title: L10n.tr("存储")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }

                Section {
                    MenuRow(icon: "doc.text.magnifyingglass", color: .gray, title: L10n.tr("日志")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "info.circle", color: .teal, title: L10n.tr("关于 MiniClaw")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "envelope", color: .orange, title: L10n.tr("反馈")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }
            }
            .navigationTitle(Text(L10n.tr("设置")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("完成")) { dismiss() }
                }
            }
        }
    }
}

struct MenuRow: View {
    let icon: String
    let color: Color
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
