import SwiftUI

// MARK: - OAuth 配置

/// OAuth 配置页：标签 + OAuth 登录按钮 + 手动配置（API 地址 / Bearer 令牌 / 添加）。
struct OAuthSetupView: View {
    let id: UUID
    let providerType: ProviderType
    let defaultLabel: String
    var onSaved: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var labelText: String
    @State private var isLoggingIn = false
    @State private var apiURL = ""
    @State private var bearerToken = ""
    @State private var errorMessage: String? = nil

    init(id: UUID, providerType: ProviderType, label: String, onSaved: (() -> Void)? = nil) {
        self.id = id
        self.providerType = providerType
        self.defaultLabel = label
        self.onSaved = onSaved
        _labelText = State(initialValue: label)
    }

    private var manager: (any OAuthManager)? { AppState.oauthManager(for: providerType) }

    var body: some View {
        Form {
            Section(L10n.l("tabs")) {
                TextField(L10n.l("tabs"), text: $labelText)
            }

            Section {
                Button {
                    Task { await loginViaOAuth() }
                } label: {
                    HStack {
                        if isLoggingIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.badge.key")
                        }
                        Text(isLoggingIn ? L10n.l("signing_in") : String(format: L10n.l("sign_in_with"), defaultLabel))
                    }
                }
                .disabled(isLoggingIn)
            } footer: {
                Text(L10n.l("sign_in_via_official_oauth_credentials_renew_automatically"))
            }

            Section {
                TextField("https://...", text: $apiURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.l("bearer_token"), text: $bearerToken)
                Button(L10n.l("add")) {
                    Task { await saveManual() }
                }
                .disabled(bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(L10n.l("manual_configuration"))
            } footer: {
                Text(L10n.l("you_can_fill_in_an_existing_access_token_directly_leave_the_api_url_empty_to_use_the_official_default"))
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.l("oauth_authentication"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func loginViaOAuth() async {
        guard let manager else { return }
        isLoggingIn = true
        errorMessage = nil
        defer { isLoggingIn = false }
        do {
            let tokens = try await manager.startOAuthFlow(instanceId: id.uuidString)
            await finishWith(tokens: tokens, baseURL: "")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveManual() async {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        // 手动 令牌 无过期时间与 refresh 令牌：永不过期，刷新逻辑自动跳过。
        let tokens = OAuthTokens(accessToken: token, refreshToken: nil, expiresAt: nil, tokenType: "Bearer")
        await finishWith(tokens: tokens, baseURL: apiURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 保存：令牌 持久化到 OAuthKeychainStorage（instanceId = provider.id），
    /// 服务商落盘时 apiKey 置空（不污染 APIKeyStore），运行时由 Keychain 兜底 / 刷新回填。
    @MainActor
    private func finishWith(tokens: OAuthTokens, baseURL: String) async {
        do {
            try await OAuthKeychainStorage.shared.saveToken(tokens, instanceId: id.uuidString)
        } catch {
            errorMessage = String(format: L10n.l("failed_to_save_credentials"), error.localizedDescription)
            return
        }
        let label = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = LLMProvider(
            id: id,
            label: label.isEmpty ? defaultLabel : label,
            providerType: providerType
        )
        p.credentialType = "oauth"
        p.customBaseURL = baseURL
        p.hasApiKey = true
        appState.updateProviders { $0.append(p) }
        // 仅内存回填 apiKey（persist 已执行，不会污染 Keychain），当前会话立即可用。
        if let idx = appState.providers.firstIndex(where: { $0.id == id }) {
            appState.providers[idx].apiKey = tokens.accessToken
        }
        onSaved?()
    }
}
