import SwiftUI

struct SettingsMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MenuRow(icon: "brain.head.profile", color: .purple, title: String(localized: "agent")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "slider.horizontal.3", color: .blue, title: String(localized: "management")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "externaldrive", color: .green, title: String(localized: "storage")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }

                Section {
                    MenuRow(icon: "doc.text.magnifyingglass", color: .gray, title: String(localized: "logs")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "info.circle", color: .teal, title: String(localized: "about_miniclaw_app")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }

                    MenuRow(icon: "envelope", color: .orange, title: String(localized: "feedback")) {
                        dismiss()
                        appState.navigationPath.append("settings")
                    }
                }
            }
            .navigationTitle(Text(String(localized: "settings")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
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
