import SwiftUI
import UniformTypeIdentifiers

// MARK: - 添加服务商

/// 添加服务商的导航目标（携值类型，避免 @State 快照时序问题）
struct AddProviderDestination: Hashable {
    let id: UUID
    let providerType: ProviderType
    let label: String
    /// 认证方式：nil=需先选择（支持 OAuth 的服务商）；"apiKey"/"oauth"=直接进入对应配置页。
    var authMethod: String? = nil
}

struct AddProviderView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AddProviderDestination] = []
    @State private var showImportFile: Bool = false

    /// 已适配的服务商模板
    private let templates: [(ProviderType, String)] = [
        (.openai, "openai_compatible_api"),
        (.anthropic, "anthropic_compatible_api"),
        (.google, "google_gemini"),
        (.grok, "xai_grok"),
        (.deepSeek, "deepseek"),
        (.qwen, "qwen"),
        (.xiaomi, "xiaomi_mimo"),
        (.zhipu, "zhipu"),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(templates, id: \.1) { type, title in
                        Button {
                            let p = LLMProvider(label: title, providerType: type)
                            path.append(AddProviderDestination(id: p.id, providerType: type, label: title))
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.blue)
                                Text(L10n.l(title))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text(L10n.l("supported_providers"))
                } footer: {
                    Text(L10n.l("you_can_add_multiple_instances_of_the_same_provider"))
                }

                Section {
                    Button {
                        showImportFile = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundStyle(.orange)
                            Text(L10n.l("import_config_from_file"))
                        }
                    }
                }
            }
            .navigationTitle(L10n.l("add_provider_action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.l("done")) { dismiss() }
                }
            }
            .navigationDestination(for: AddProviderDestination.self) { dest in
                // 支持 OAuth 的服务商：先选择认证方式；否则直接进入详细配置。
                if dest.authMethod == nil, dest.providerType.supportsOAuth {
                    AuthMethodPickerView(id: dest.id, providerType: dest.providerType, label: dest.label, path: $path)
                } else if dest.authMethod == "oauth" {
                    OAuthSetupView(id: dest.id, providerType: dest.providerType, label: dest.label, onSaved: { dismiss() })
                } else {
                    let draft = LLMProvider(id: dest.id, label: dest.label, providerType: dest.providerType)
                    ProviderDetailView(providerId: dest.id, draftProvider: draft, onSaveDraft: { dismiss() })
                }
            }
            .fileImporter(isPresented: $showImportFile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result,
                   let url = urls.first,
                   let p = decodeProviderFile(url) {
                    appState.updateProviders { $0.append(p) }
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 认证方式选择（支持 OAuth 的服务商）

/// 添加支持 OAuth 的服务商时，先选择认证方式：API Key / OAuth。
struct AuthMethodPickerView: View {
    let id: UUID
    let providerType: ProviderType
    let label: String
    @Binding var path: [AddProviderDestination]

    var body: some View {
        List {
            Section {
                Button {
                    path.append(AddProviderDestination(id: id, providerType: providerType, label: label, authMethod: "apiKey"))
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.l("api_key_authentication"))
                            Text(L10n.l("use_an_api_key_to_access_the_provider_api"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    path.append(AddProviderDestination(id: id, providerType: providerType, label: label, authMethod: "oauth"))
                } label: {
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.l("oauth_authentication"))
                            Text(L10n.l("sign_in_with_your_account_or_enter_a_bearer_token_manually"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                Text(L10n.l("choose_an_authentication_method_credentials_renew_automatically_after_oauth_sign_in"))
            }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
