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
                Toggle(String(localized: "confirm_before_tool_calls"), isOn: $defaults.confirmBeforeToolCall)
                Toggle(String(localized: "ai_plugin_install_requires_confirmation"), isOn: $defaults.aiPluginInstallRequiresConfirmation)
            } header: {
                Text(String(localized: "default_behavior"))
            } footer: {
                Text(String(localized: "when_enabled_the_agent_will_ask_for_your_confirmation_before_each_tool_call_file_browser_shell_etc")
                     + "\n" + String(localized: "ai_plugin_install_requires_confirmation_footer"))
            }

            // 健康数据（含写入总闸）已迁至「设置 → 权限与后台 → 控制」，
            // 与家庭配件及各自的功能说明集中一处 —— 不在通用页重复出现。
            Section {
                Toggle(String(localized: "show_thinking_process"), isOn: $chat.showThinking)
                Toggle(String(localized: "enter_to_send_off_newline"), isOn: $chat.enterToSend)
            } header: {
                Text(String(localized: "chat"))
            }

            Section {
                Stepper(value: $browser.maxTabs, in: 1...5) {
                    Text(String(format: String(localized: "max_tabs"), "\(browser.maxTabs)"))
                }
                Toggle(String(localized: "block_pop_ups"), isOn: $browser.blockPopups)
                // 默认关闭：开着等于允许 AI 访问内网（路由器后台/NAS/本地服务），
                // 也可能被网页里藏的指令利用，所以交给用户显式开启。
                Toggle(String(localized: "allow_private_network"), isOn: $browser.allowPrivateNetwork)
                // 会话页新版开关：出问题时一键切回旧页（两个版本共用同一数据源）。
                Toggle(String(localized: "chat_v2_toggle"), isOn: Binding(
                    get: { ChatV2Feature.isEnabled },
                    set: { ChatV2Feature.isEnabled = $0 }
                ))
                Toggle(String(localized: "open_in_builtin_browser"), isOn: Binding(
                    get: { MiniClawOpenURLHandler.openLinksInline() },
                    set: { UserDefaults.standard.set($0, forKey: MiniClawOpenURLHandler.openLinksInlineKey) }
                ))
                Picker(String(localized: "user_agent_form"), selection: $browser.uaMode) {
                    Text(String(localized: "mobile")).tag("mobile")
                    Text(String(localized: "desktop")).tag("desktop")
                    Text(String(localized: "custom")).tag("custom")
                }
                if browser.uaMode == "custom" {
                    TextField(String(localized: "custom_user_agent"), text: $browser.userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(String(localized: "browser"))
            } footer: {
                Text(String(localized: "choose_the_user_agent_form_used_by_the_browser_if_custom_is_selected_fill_in_the_ua_string_below"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "general_settings"))
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
        SettingsStore.shared.set(defaults, domain: .defaults, summary: String(localized: "edit_general_settings"))
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: String(localized: "edit_chat_settings"))
    }

    private func saveBrowser() {
        SettingsStore.shared.set(browser, domain: .browser, summary: String(localized: "edit_browser_settings"))
        // 立即把 UA 形态同步到浏览器运行时（若当前有打开的标签）。
        BrowserEngineAdapter.shared.applyUAProfileToAllTabs()
    }
}
