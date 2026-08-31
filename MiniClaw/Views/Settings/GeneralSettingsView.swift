import SwiftUI
import MiniClawKit

// MARK: - General Settings

struct GeneralSettingsView: View {
    @State private var defaults: DefaultSettings = SettingsStore.shared.settings.defaults
    @State private var chat: ChatSettings = SettingsStore.shared.settings.chat
    @State private var browser: BrowserSettings = SettingsStore.shared.settings.browser

    var body: some View {
        Form {
            Section {
                Toggle(L10n.l("confirm_before_tool_calls"), isOn: $defaults.confirmBeforeToolCall)
            } header: {
                Text(L10n.l("default_behavior"))
            } footer: {
                Text(L10n.l("when_enabled_the_agent_will_ask_for_your_confirmation_before_each_tool_call_file_browser_shell_etc"))
            }

            // 健康写入总闸：write / delete 执行前检查（apple-healthkit）。
            // 独立于 confirmBeforeToolCall —— 后者只控制「调用前要不要问」，
            // 这个开关决定「这条能力存不存在」。
            Section {
                Toggle(L10n.l("allow_health_write"), isOn: $defaults.healthWriteEnabled)
            } header: {
                Text(L10n.l("health_data_section"))
            } footer: {
                Text(L10n.l("allow_health_write_footer"))
            }

            Section {
                Toggle(L10n.l("show_thinking_process"), isOn: $chat.showThinking)
                Toggle(L10n.l("enter_to_send_off_newline"), isOn: $chat.enterToSend)
            } header: {
                Text(L10n.l("chat"))
            }

            Section {
                Stepper(value: $browser.maxTabs, in: 1...5) {
                    Text(String(format: L10n.l("max_tabs"), "\(browser.maxTabs)"))
                }
                Toggle(L10n.l("block_pop_ups"), isOn: $browser.blockPopups)
                Toggle(L10n.l("open_in_builtin_browser"), isOn: Binding(
                    get: { MiniClawOpenURLHandler.openLinksInline() },
                    set: { UserDefaults.standard.set($0, forKey: MiniClawOpenURLHandler.openLinksInlineKey) }
                ))
                Picker(L10n.l("user_agent_form"), selection: $browser.uaMode) {
                    Text(L10n.l("mobile")).tag("mobile")
                    Text(L10n.l("desktop")).tag("desktop")
                    Text(L10n.l("custom")).tag("custom")
                }
                if browser.uaMode == "custom" {
                    TextField(L10n.l("custom_user_agent"), text: $browser.userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(L10n.l("browser"))
            } footer: {
                Text(L10n.l("choose_the_user_agent_form_used_by_the_browser_if_custom_is_selected_fill_in_the_ua_string_below"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("general_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: defaults) { _ in saveDefaults() }
        .onChange(of: chat) { _ in saveChat() }
        .onChange(of: browser) { _ in saveBrowser() }
        .onAppear {
            // 每次进入都从持久化源重新同步，避免 NavigationStack 缓存视图实例
            // 导致 @State 停留在进入时的旧值（表现为「返回后再进显示回之前的设置」）。
            defaults = SettingsStore.shared.settings.defaults
            chat = SettingsStore.shared.settings.chat
            browser = SettingsStore.shared.settings.browser
        }
    }

    private func saveDefaults() {
        SettingsStore.shared.set(defaults, domain: .defaults, summary: L10n.l("edit_general_settings"))
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: L10n.l("edit_chat_settings"))
    }

    private func saveBrowser() {
        SettingsStore.shared.set(browser, domain: .browser, summary: L10n.l("edit_browser_settings"))
        // 立即把 UA 形态同步到浏览器运行时（若当前有打开的标签）。
        BrowserController.shared.applyUAProfileToAllTabs()
    }
}
