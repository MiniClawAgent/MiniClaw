import SwiftUI

/// 联网搜索插件的可编辑设置（插入在插件详情页，只有 `WebSearchPlugin.id` 的详情页会渲染）。
///
/// 设计取舍：
/// - API Key 走独立 Keychain 槽位（`APIKeyStore` webSearch），不写 settings.json；
///   留空时工具自动回退「设置 → 服务商」里的 DeepSeek 实例，所以用户不填也能用。
/// - 其余参数（Base URL / 默认条数 / 默认正文 / 超时 / 正文预算）落在
///   `settings.webSearch`，按域写审计（`SettingsDomain.webSearch`）。
struct WebSearchSettingsSection: View {
    @State private var config: WebSearchSettings = WebSearchSettings()
    @State private var apiKeyDraft: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var revealKey: Bool = false
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false
    /// 移除密钥前的二次确认（密钥删掉就得重填，误触代价高）
    @State private var showRemoveConfirm: Bool = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                if hasStoredKey {
                    // 已保存：输入框位置改为展示「已保存密钥」，避免把真实密钥显示在界面上，
                    // 也避免用户以为还能直接编辑一个已被存起来的 Key。
                    Text("web_search_api_key_stored_display")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("web_search_api_key_stored_display"))
                } else {
                    Group {
                        if revealKey {
                            TextField(String(localized: "web_search_api_key_placeholder"), text: $apiKeyDraft)
                        } else {
                            SecureField(String(localized: "web_search_api_key_placeholder"), text: $apiKeyDraft)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(String(localized: "web_search_api_key_save")) {
                    saveKey()
                }
                // 已保存时按钮置灰不可点（此时草稿为空，也不用靠"空草稿"来禁用）
                .disabled(hasStoredKey
                          || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Spacer()
                    Label(String(localized: "web_search_api_key_saved"), systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Text(String(localized: "web_search_api_key_delete"))
                    }
                    .font(.caption)
                }
            }

            TextField(String(localized: "web_search_base_url_placeholder"), text: $config.baseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(String(localized: "web_search_settings_title"))
        } footer: {
            Text(String(localized: "web_search_settings_footer"))
        }
        // 移除密钥前二次确认（删掉就得重填，误触代价高）。
        // 挂在 Section 上会破坏 `header:/footer:` 的尾随闭包结构，故挂在外层容器。
        .confirmationDialog(
            Text("web_search_api_key_remove_confirm_title"),
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "web_search_api_key_delete"), role: .destructive) {
                removeKey()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text("web_search_api_key_remove_confirm_message")
        }

        Section {
            LabeledContent(String(localized: "web_search_default_count")) {
                Stepper(value: $config.defaultCount, in: 1...50) {
                    Text("\(config.defaultCount)")
                        .monospacedDigit()
                }
            }
            Toggle(String(localized: "web_search_default_need_content"), isOn: $config.defaultNeedContent)
            LabeledContent(String(localized: "web_search_timeout")) {
                Stepper(value: $config.timeoutSeconds, in: 5...120, step: 5) {
                    Text(String(format: String(localized: "web_search_seconds_value"), config.timeoutSeconds))
                        .monospacedDigit()
                }
            }
            LabeledContent(String(localized: "web_search_content_cap")) {
                Stepper(value: $config.contentCapChars, in: 200...20_000, step: 200) {
                    Text(String(format: String(localized: "web_search_chars_value"), config.contentCapChars))
                        .monospacedDigit()
                }
            }
            LabeledContent(String(localized: "web_search_content_budget")) {
                Stepper(value: $config.contentBudgetChars, in: 1_000...200_000, step: 1_000) {
                    Text(String(format: String(localized: "web_search_chars_value"), config.contentBudgetChars))
                        .monospacedDigit()
                }
            }
        } header: {
            Text(String(localized: "web_search_defaults_title"))
        } footer: {
            Text(String(localized: "web_search_defaults_footer"))
        }
        .onAppear {
            config = SettingsStore.shared.settings.webSearch
            hasStoredKey = APIKeyStore.hasWebSearchKey()
        }
        .onChange(of: config) { _ in
            SettingsStore.shared.set(
                config,
                domain: .webSearch,
                summary: String(localized: "web_search_settings_title")
            )
        }
        .alert(String(localized: "web_search_settings_title"), isPresented: $showAlert) {
            Button(String(localized: "ok")) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try APIKeyStore.saveWebSearchKey(trimmed)
            hasStoredKey = true
            apiKeyDraft = ""
            revealKey = false
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func removeKey() {
        APIKeyStore.deleteWebSearchKey()
        hasStoredKey = false
        apiKeyDraft = ""
    }
}
