import SwiftUI

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: ColorSchemePreference = .system
    @State private var chat: ChatSettings = SettingsStore.shared.settings.chat
    /// 订阅主题管理器：选用/清除背景主题时刷新选中勾与主题列表。
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        List {
            // 背景主题置顶（唐唐 2026-08-30 要求）。
            backgroundThemeSection

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
                Text(String(localized: "appearance_mode"))
            } footer: {
                Text(String(localized: "choose_light_dark_or_follow_system_settings_changes_apply_immediately"))
            }

            Section {
                Picker(selection: $chat.codeBlockTheme) {
                    Text(String(localized: "system")).tag("auto")
                    Text(String(localized: "light")).tag("light")
                    Text(String(localized: "dark")).tag("dark")
                } label: {
                    Text(String(localized: "code_block_theme"))
                }
            } header: {
                Text(String(localized: "chat_display"))
            }

        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selection = appState.colorSchemePreference
            // 重新进入时从持久化源同步聊天显示设置，避免缓存视图 @State 停留旧值。
            chat = SettingsStore.shared.settings.chat
        }
        .onChange(of: chat) { _ in saveChat() }
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: String(localized: "edit_appearance_chat_display"))
    }

    // MARK: - 背景主题（theme 插件，唐唐 2026-08-30 定稿）

    /// 背景主题选择区：系统默认 + 已装 theme 插件预设（缩略图 + 选中态）。
    /// 显式选用 + 排他生效；未选用时三页保持系统默认背景。
    private var backgroundThemeSection: some View {
        Section {
            // 「系统默认」恒在首行：清除选用即回退。
            Button {
                themeManager.activeThemeID = nil
            } label: {
                HStack {
                    Image(systemName: "square.on.square")
                        .frame(width: 44, height: 32)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    Text(String(localized: "background_theme_default"))
                        .foregroundStyle(.primary)
                    Spacer()
                    if themeManager.activeThemeID == nil {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }

            if themeManager.installedThemes().isEmpty {
                Text(String(localized: "background_theme_empty_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(themeManager.installedThemes(), id: \.pluginID) { theme in
                Button {
                    themeManager.activeThemeID = theme.pluginID
                } label: {
                    HStack {
                        themeThumbnail(pluginID: theme.pluginID, decl: theme.decl)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.decl.name.isEmpty ? theme.pluginID : theme.decl.name)
                                .foregroundStyle(.primary)
                            Text(theme.pluginID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if themeManager.activeThemeID == theme.pluginID {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "background_theme"))
        } footer: {
            Text(String(localized: "background_theme_footer"))
        }
    }

    /// 主题缩略图：优先 chat 槽位，其次任一可用图，downsample 到小尺寸。
    @ViewBuilder
    private func themeThumbnail(pluginID: String, decl: ThemePackageDecl) -> some View {
        let fileName = decl.fileName(for: .chat)
            ?? decl.fileName(for: .home)
            ?? decl.fileName(for: .settings)
        if let fileName,
           let small = smallThumbnail(url: ThemeManager.shared.imageURL(pluginID: pluginID, fileName: fileName)) {
            Image(uiImage: small)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "photo")
                .frame(width: 44, height: 32)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func smallThumbnail(url: URL) -> UIImage? {
        ThemeManager.downsampledImage(at: url, maxPixel: 132)
    }

    private func title(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return String(localized: "system")
        case .dark:   return String(localized: "dark")
        case .light:  return String(localized: "light")
        }
    }

    private func subtitle(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return String(localized: "match_ios_system_settings")
        case .dark: return String(localized: "always_use_dark_interface")
        case .light: return String(localized: "always_use_light_interface")
        }
    }
}
