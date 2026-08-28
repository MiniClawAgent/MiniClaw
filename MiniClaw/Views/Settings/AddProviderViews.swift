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
    /// model 插件模板声明的连接字段（创建 draft 时应用）。
    var templateBaseURL: String? = nil
    var templateAPIFormat: String? = nil
    var templateAppendV1Suffix: Bool? = nil
    var templateCustomHeaders: [String: String]? = nil
    var templateOrganizationId: String? = nil
    var templateProjectId: String? = nil
}

struct AddProviderView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AddProviderDestination] = []
    @State private var showImportFile: Bool = false

    /// model 插件模板（单条声明 → 添加流程所需字段）。
    struct ProviderTemplate: Identifiable, Hashable {
        let id: String
        let label: String
        let providerType: ProviderType
        let baseURL: String
        let apiFormat: String?
        let appendV1Suffix: Bool?
        let headers: [String: String]?
        let organizationId: String?
        let projectId: String?
    }

    /// 模板来源 = 已安装 model 插件的 providers.json 声明（业界语义：装了什么插件，
    /// 就能添加什么供应商）。
    private var pluginTemplates: [ProviderTemplate] {
        var result: [ProviderTemplate] = []
        let fs = FileSystemManager.shared
        for dir in fs.allPluginDirectories() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  m.type == "model",
                  let json = try? String(contentsOf: dir.appendingPathComponent("providers.json"), encoding: .utf8),
                  let decls = try? JSONDecoder().decode([ModelPluginProviderDecl].self, from: Data(json.utf8)) else { continue }
            for d in decls {
                let label = d.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, let pt = ProviderType(flexibleID: d.providerType) else { continue }
                result.append(ProviderTemplate(
                    id: dir.lastPathComponent + "/" + label,
                    label: label,
                    providerType: pt,
                    baseURL: d.customBaseURL ?? "",
                    apiFormat: d.apiFormat,
                    appendV1Suffix: d.appendV1Suffix,
                    headers: d.customHeaders,
                    organizationId: d.organizationId,
                    projectId: d.projectId
                ))
            }
        }
        return result
    }

    /// 由模板声明构造初始 draft（baseURL/格式/追加后缀/自定义头等来自 model 插件声明）。
    private func draftFromTemplate(_ dest: AddProviderDestination) -> LLMProvider {
        var draft = LLMProvider(id: dest.id, label: dest.label, providerType: dest.providerType)
        draft.customBaseURL = dest.templateBaseURL ?? ""
        if let f = APIFormat(flexibleID: dest.templateAPIFormat) { draft.apiFormat = f }
        draft.appendV1Suffix = dest.templateAppendV1Suffix ?? false
        draft.customHeaders = dest.templateCustomHeaders ?? [:]
        draft.organizationId = dest.templateOrganizationId ?? ""
        draft.projectId = dest.templateProjectId ?? ""
        return draft
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if pluginTemplates.isEmpty {
                        Text(L10n.l("no_provider_templates"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pluginTemplates) { tpl in
                        Button {
                            // 网关性质模板默认走 API Key 认证（authMethods 声明机制后续扩展）。
                            path.append(AddProviderDestination(
                                id: UUID(), providerType: tpl.providerType, label: tpl.label,
                                authMethod: "apiKey",
                                templateBaseURL: tpl.baseURL,
                                templateAPIFormat: tpl.apiFormat,
                                templateAppendV1Suffix: tpl.appendV1Suffix,
                                templateCustomHeaders: tpl.headers,
                                templateOrganizationId: tpl.organizationId,
                                templateProjectId: tpl.projectId))
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.blue)
                                Text(tpl.label)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text(L10n.l("providers_from_installed_plugins"))
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
            .onAppear {
                let tpls = pluginTemplates
                AppLogger.shared.info("[AddProvider] 供应商模板扫描: \(tpls.count) 个 ← \(tpls.map(\.id))",
                                      category: "Plugins", subsystem: "Plugins")
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
                    ProviderDetailView(providerId: dest.id, draftProvider: draftFromTemplate(dest), onSaveDraft: { dismiss() })
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
