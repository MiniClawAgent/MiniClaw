import SwiftUI

struct SettingsMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MenuRow(icon: "brain.head.profile", color: .purple, title: L10n.l("agent")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "slider.horizontal.3", color: .blue, title: L10n.l("management")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "externaldrive", color: .green, title: L10n.l("storage")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }

                Section {
                    MenuRow(icon: "doc.text.magnifyingglass", color: .gray, title: L10n.l("logs")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "info.circle", color: .teal, title: L10n.l("about_miniclaw_app")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "envelope", color: .orange, title: L10n.l("feedback")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }
            }
            .navigationTitle(Text(L10n.l("settings")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.l("done")) { dismiss() }
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
