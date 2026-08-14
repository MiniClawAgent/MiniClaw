import SwiftUI

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让所有 `L10n.tr` 文案（含语言 Picker 的「语言」标签、footer 说明等）以新语言重新求值。
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: ColorSchemePreference = .system
    @State private var chat: ChatSettings = SettingsStore.shared.settings.chat

    var body: some View {
        List {
            Section {
                ForEach(ColorSchemePreference.allCases, id: \.self) { pref in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: pref))
                                .font(.body)
                            Text(subtitle(for: pref))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == pref {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = pref
                        withAnimation(.easeInOut(duration: 0.35)) {
                            appState.colorSchemePreference = pref
                        }
                    }
                }
            } header: {
                Text(L10n.l("appearance_mode"))
            } footer: {
                Text(L10n.l("choose_light_dark_or_follow_system_settings_changes_apply_immediately"))
            }

            Section {
                Picker(selection: $appState.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                } label: {
                    Text(L10n.l("language"))
                }
            } footer: {
                Text(L10n.l("change_the_interface_display_language_applies_immediately"))
            }

            Section {
                Picker(selection: $chat.codeBlockTheme) {
                    Text(L10n.l("system")).tag("auto")
                    Text(L10n.l("light")).tag("light")
                    Text(L10n.l("dark")).tag("dark")
                } label: {
                    Text(L10n.l("code_block_theme"))
                }
            } header: {
                Text(L10n.l("chat_display"))
            }
        }
        .navigationTitle(L10n.l("appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selection = appState.colorSchemePreference
            // 重新进入时从持久化源同步聊天显示设置，避免缓存视图 @State 停留旧值。
            chat = SettingsStore.shared.settings.chat
        }
        .onChange(of: chat) { _ in saveChat() }
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: L10n.l("edit_appearance_chat_display"))
    }

    private func title(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return L10n.l("system")
        case .dark:   return L10n.l("dark")
        case .light:  return L10n.l("light")
        }
    }

    private func subtitle(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return L10n.l("match_ios_system_settings")
        case .dark: return L10n.l("always_use_dark_interface")
        case .light: return L10n.l("always_use_light_interface")
        }
    }
}
