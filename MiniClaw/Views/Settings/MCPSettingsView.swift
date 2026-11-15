import SwiftUI
import UIKit
import MiniClawKit

extension MCPTransport: Identifiable {
    var id: Self { self }

    var displayName: String {
        switch self {
        case .auto: String(localized: "automatic")
        case .http: "Streamable HTTP"
        case .legacySSE: "Legacy SSE"
        case .stdio: String(localized: "local_stdio")
        }
    }

    /// STDIO 传输需要本地进程能力，iOS 沙箱不可用，仅在 macOS / Simulator 生效。
    var isLocalOnly: Bool {
        switch self {
        case .stdio: true
        default: false
        }
    }
}

struct MCPSettingsView: View {
    @StateObject private var store = MCPConfigStore.shared
    /// MCP OAuth 2.1：授权流程状态与认证页 sheet 驱动。
    @ObservedObject private var oauth = MCPOAuthManager.shared
    @State private var editorItem: MCPServerEditorItem?
    @State private var serverPendingDeletion: MCPServerConfig?
    @State private var refreshingServerIDs: Set<UUID> = []
    @State private var isRefreshingAll = false
    @State private var exportedConfig: ExportedConfigItem?
    @State private var showImportSheet = false
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                Label(String(localized: "miniclaw_supports_remote_mcp_servers_over_http_sse_local_stdio_transport_is_only_available_on_macos_simulator_since_the_ios_sandbox_cannot_launch_local_processes"), systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.servers.isEmpty {
                    EmptyStateView(
                        label: String(localized: "no_server_added_yet"),
                        systemImage: "server.rack",
                        description: String(localized: "after_adding_a_remote_mcp_endpoint_you_can_connect_and_load_tools")
                    )
                } else {
                    ForEach(store.servers) { server in
                        serverRow(server)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(String(localized: "delete_action"), role: .destructive) {
                                    serverPendingDeletion = server
                                }
                            }
                    }
                }

                // 2026-09-01 唐唐拍板：需要 OAuth 授权的 server 在列表下方
                // 显示「认证」按钮，点击进入授权流程（SFSafariViewController + loopback）。
                if let pending = store.servers.first(where: { needsAuthorization($0) }) {
                    Button {
                        startAuthorization(for: pending)
                    } label: {
                        HStack {
                            Label(
                                String(localized: "mcp_authorize_server_button") + pending.name,
                                systemImage: "checkmark.shield"
                            )
                            Spacer()
                            if oauth.isAuthorizing, oauth.pendingServerID == pending.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(oauth.isAuthorizing)
                }
            } header: {
                HStack {
                    Text(String(localized: "remote_server"))
                    Spacer()
                    if isRefreshingAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        // 2026-09-01 唐唐拍板：刷新收进标题行最右，一键刷新全部远端服务器。
                        Button {
                            refreshAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.servers.isEmpty)
                        .accessibilityLabel(String(localized: "refresh_all_servers"))
                    }
                }
            }

            sessionMCPExceptionSection
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "mcp"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 2026-09-01 唐唐拍板：入口收敛到右上角 + 菜单（添加/导出/从文本导入）；
                // CLAUDE DESKTOP 兼容独立区块移除，导出/导入功能保留在菜单里。
                Menu {
                    Button {
                        editorItem = MCPServerEditorItem(server: nil)
                    } label: {
                        Label(String(localized: "add_mcp_server"), systemImage: "plus.circle")
                    }
                    Button {
                        exportedConfig = ExportedConfigItem(json: store.exportClaudeDesktopConfig(for: store.servers))
                    } label: {
                        Label(String(localized: "export_claude_desktop_config"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImportSheet = true
                    } label: {
                        Label(String(localized: "import_claude_desktop_config_from_text"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editorItem) { item in
            NavigationStack {
                MCPServerEditorView(server: item.server) { config, bearerToken in
                    store.upsert(config, bearerToken: bearerToken)
                    editorItem = nil
                } onDelete: { id in
                    if let server = store.server(id: id) {
                        removeServerWithPlugin(server)
                    }
                    editorItem = nil
                }
            }
        }
        // MCP OAuth 授权页已移除 sheet 挂载（2026-09-02 唐唐拍板：审核不允许 OAuth 走
        // WebView，现为 SFSafariViewController + loopback；授权由 MCPOAuthManager 直接触发）。
        .confirmationDialog(
            String(localized: "delete_mcp_server_confirm"),
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            ),
            presenting: serverPendingDeletion
        ) { server in
            Button(String(localized: "delete_action") + server.name, role: .destructive) {
                removeServerWithPlugin(server)
                serverPendingDeletion = nil
            }
            Button(String(localized: "cancel"), role: .cancel) {
                serverPendingDeletion = nil
            }
        } message: { _ in
            Text(String(localized: "the_server_configuration_and_its_saved_bearer_token_will_be_deleted_together_this_action_cannot_be_undone"))
        }
        .sheet(item: $exportedConfig) { item in
            NavigationStack {
                ScrollView {
                    Text(item.json)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(String(localized: "claude_desktop_configuration"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "copy_action")) { UIPasteboard.general.string = item.json }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "close")) { exportedConfig = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            NavigationStack {
                ImportClaudeConfigView(onImport: { json in
                    do {
                        let configs = try store.importClaudeDesktopConfig(json)
                        guard !configs.isEmpty else {
                            importMessage = String(localized: "no_server_entries_were_parsed")
                            return
                        }
                        for cfg in configs {
                            store.upsert(cfg, bearerToken: store.takeImportedBearerToken(for: cfg.id))
                        }
                        importMessage = String(format: String(localized: "imported_servers"), "\(configs.count)")
                        showImportSheet = false
                    } catch {
                        importMessage = error.localizedDescription
                    }
                }, message: $importMessage)
            }
        }
    }

    private var sessionMCPExceptionSection: some View {
        Group {
            if let session = AppState.shared.selectedSession {
                Section {
                    let disabled = session.disabledMCPServerIDs ?? []
                    if store.servers.isEmpty {
                        Text(String(localized: "no_mcp_servers_configured"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.servers) { server in
                        Toggle(server.name, isOn: Binding(
                            get: { !disabled.contains(server.id) },
                            set: { on in
                                var set = Set(disabled)
                                if on { set.remove(server.id) } else { set.insert(server.id) }
                                session.disabledMCPServerIDs = set.isEmpty ? nil : Array(set)
                                SessionManager.shared.persist(session)
                            }
                        ))
                        .disabled(!server.isEnabled)
                    }
                    Text(String(localized: "disabled_servers_won_t_load_their_tools_in_this_session_other_sessions_are_unaffected_changes_take_effect_immediately_and_apply_on_the_next_conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "mcp_session_exception_prefix") + session.title + String(localized: "close_paren"))
                }
            } else {
                Section {
                    Text(String(localized: "open_settings_within_a_session_to_disable_mcp_servers_per_session"))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "mcp_session_exception"))
                }
            }
        }
    }

    /// 删除 MCP server；若该 server 由 mcp 插件导入（sourcePlugin 非空），
    /// 连带删除对应插件——插件删除会连带其导入的全部 server（对称语义，唐唐 2026-08-28）。
    private func removeServerWithPlugin(_ server: MCPServerConfig) {
        let source = server.sourcePlugin
        store.remove(id: server.id)
        if let source {
            try? SkillManager.shared.deleteSkill(directoryName: source)
        }
    }

    /// 唐唐 2026-09-02 排版定稿：名称 + 连接状态图标（icon-only），下行 = 工具数 + 检查时间；
    /// 服务器地址行移除（地址在编辑页可见），行内仅保留错误详情。列表更紧凑。
    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                editorItem = MCPServerEditorItem(server: server)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        statusIcon(for: server)
                    }

                    HStack(spacing: 6) {
                        Text("\(server.lastToolCount) " + String(localized: "tool_count_suffix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let checkedAt = server.lastCheckedAt {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "last_checked_label") + checkedAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        if server.hasBearerToken {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "bearer_token_saved"))
                        }
                    }

                    if let error = server.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(
                String(localized: "enable_label") + server.name,
                isOn: Binding(
                    get: { server.isEnabled },
                    set: { store.setEnabled($0, id: server.id) }
                )
            )
            .labelsHidden()
            // 2026-09-01 唐唐拍板：行内刷新钮移除——刷新统一收进列表标题行最右。
        }
        .padding(.vertical, 5)
    }

    /// 连接状态 icon-only（文字语义保留在 accessibilityLabel）。
    @ViewBuilder
    private func statusIcon(for server: MCPServerConfig) -> some View {
        switch server.lastStatus {
        case .unknown:
            Image(systemName: "circle.dashed")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(String(localized: "not_checked"))
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "connecting"))
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .accessibilityLabel(String(localized: "connected"))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityLabel(String(localized: "connection_failed"))
        }
    }

    private func isRefreshing(_ server: MCPServerConfig) -> Bool {
        refreshingServerIDs.contains(server.id) || server.lastStatus == .connecting
    }

    /// 需要 OAuth 授权：插件 servers.json 声明 auth=oauth、尚未完成授权、
    /// 且没有可用的静态 Bearer Token。
    private func needsAuthorization(_ server: MCPServerConfig) -> Bool {
        server.requiresAuthorization == true
            && !server.hasBearerToken
            && !oauth.isAuthorized(serverID: server.id)
    }

    /// 启动 MCP OAuth 2.1 授权（发现 → DCR → 系统 Safari 视图授权 → Token 入 Keychain）。
    /// 唐唐 2026-09-02：认证成功后**自动启用并连接**该 MCP 服务（工具列表刷新 = 建立连接），
    /// 即使 server 此前被停用也恢复启用——认证的语义就是"我要用这个服务"。
    private func startAuthorization(for server: MCPServerConfig) {
        Task {
            do {
                try await MCPOAuthManager.shared.startAuthorization(server: server)
                store.setEnabled(true, id: server.id)
                await store.refresh(id: server.id)
            } catch is CancellationError {
                // 用户取消，静默。
            } catch {
                // 失败信息落到 server 行（复用 lastError 展示位）。
                store.updateDiscovery(id: server.id, toolCount: 0, error: error)
            }
        }
    }

    private func refresh(_ id: UUID) {
        guard !refreshingServerIDs.contains(id) else { return }
        refreshingServerIDs.insert(id)
        Task {
            await store.refresh(id: id)
            refreshingServerIDs.remove(id)
        }
    }

    private func refreshAll() {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        Task {
            await store.refreshAll()
            isRefreshingAll = false
        }
    }
}

private struct MCPServerEditorItem: Identifiable {
    let id = UUID()
    let server: MCPServerConfig?
}

private struct ExportedConfigItem: Identifiable {
    let id = UUID()
    let json: String
}

/// 从文本导入 Claude Desktop 配置（mcpServers JSON）。
private struct ImportClaudeConfigView: View {
    let onImport: (String) -> Void
    @Binding var message: String?

    @State private var text: String = ""
    @State private var showPaste = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text(String(localized: "mcpservers_json"))
            } footer: {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    if let pb = UIPasteboard.general.string, !pb.isEmpty {
                        text = pb
                    }
                } label: {
                    Label(String(localized: "paste_from_clipboard"), systemImage: "doc.on.clipboard")
                }
                Button(String(localized: "import")) {
                    onImport(text)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "import_claude_desktop_config"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { message = nil }
            }
        }
    }
}

/// 自定义请求头编辑行（与保存后的 `customHeaders` 字典互转）。
private struct MCPHeaderRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

private struct MCPServerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let server: MCPServerConfig?
    let onSave: (MCPServerConfig, String?) -> Void
    let onDelete: (UUID) -> Void

    @State private var name: String
    @State private var endpointURL: String
    @State private var transport: MCPTransport
    @State private var isEnabled: Bool
    @State private var bearerToken = ""
    @State private var removeSavedCredential = false
    @State private var headerRows: [MCPHeaderRow]
    @State private var command: String
    @State private var args: String
    @State private var envRows: [MCPHeaderRow]
    @State private var validationMessage: String?
    @State private var showDeleteConfirmation = false

    init(
        server: MCPServerConfig?,
        onSave: @escaping (MCPServerConfig, String?) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        self.server = server
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: server?.name ?? "")
        _endpointURL = State(initialValue: server?.endpointURL ?? "")
        _transport = State(initialValue: server?.transport ?? .auto)
        _isEnabled = State(initialValue: server?.isEnabled ?? true)
        _headerRows = State(initialValue: (server?.customHeaders ?? [:]).map { MCPHeaderRow(key: $0.key, value: $0.value) })
        _command = State(initialValue: server?.command ?? "")
        _args = State(initialValue: server?.args ?? "")
        _envRows = State(initialValue: (server?.envVars ?? [:]).map { MCPHeaderRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            Section(
                content: {
                    TextField(String(localized: "name"), text: $name)

                    TextField("https://example.com/mcp", text: $endpointURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker(String(localized: "connection_method"), selection: $transport) {
                        ForEach(MCPTransport.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle(String(localized: "enable_this_server"), isOn: $isEnabled)
                },
                header: { Text(String(localized: "server")) },
                footer: {
                    Text(String(localized: "endpoint_must_be_an_http_or_https_address_http_can_be_used_for_local_development"))
                }
            )

            if transport.isLocalOnly {
                Section {
                    TextField(String(localized: "launch_command_e_g_npx_y_modelcontextprotocol_server_xxx"), text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(String(localized: "arguments_space_separated"), text: $args)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if envRows.isEmpty {
                        Text(String(localized: "no_environment_variables_added"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($envRows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(String(localized: "variable_name_e_g_api_key"), text: $row.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(String(localized: "variable_value"), text: $row.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    .onDelete { indexSet in
                        envRows.remove(atOffsets: indexSet)
                    }
                    Button {
                        envRows.append(MCPHeaderRow())
                    } label: {
                        Label(String(localized: "add_environment_variable"), systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text(String(localized: "stdio_launch_arguments"))
                } footer: {
                    Text(String(localized: "stdio_transport_is_only_available_on_macos_simulator_the_ios_sandbox_cannot_launch_local_processes_var_expansion_is_supported_in_command_and_arguments"))
                }
            }

            Section {
                SecureField(
                    server?.hasBearerToken == true ? String(localized: "enter_new_token_to_replace") : String(localized: "bearer_token_optional"),
                    text: $bearerToken
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(removeSavedCredential)

                if server?.hasBearerToken == true {
                    if removeSavedCredential {
                        Label(String(localized: "saving_will_delete_the_saved_credentials"), systemImage: "trash")
                            .font(.footnote)
                            .foregroundStyle(.red)

                        Button(String(localized: "keep_saved_credentials")) {
                            removeSavedCredential = false
                        }
                    } else {
                        Button(String(localized: "delete_saved_credentials_when_saving"), role: .destructive) {
                            bearerToken = ""
                            removeSavedCredential = true
                        }
                    }
                }
            } header: {
                Text(String(localized: "credentials_item"))
            } footer: {
                if server?.hasBearerToken == true && !removeSavedCredential {
                    Text(String(localized: "bearer_token_saved_securely_it_will_not_be_shown_here_leaving_it_blank_when_editing_means_keeping_the_original_token"))
                } else {
                Text(String(localized: "the_token_is_used_only_for_the_authorization_request_header_its_content_is_not_shown_in_the_ui"))
            }
        }

        Section {
            if headerRows.isEmpty {
                Text(String(localized: "no_custom_headers_added"))
                    .foregroundStyle(.secondary)
            }
            ForEach($headerRows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(String(localized: "header_name_e_g_x_api_key"), text: $row.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "header_value"), text: $row.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { indexSet in
                headerRows.remove(atOffsets: indexSet)
            }

            Button {
                headerRows.append(MCPHeaderRow())
            } label: {
                Label(String(localized: "add_request_header"), systemImage: "plus.circle.fill")
            }
        } header: {
            Text(String(localized: "custom_headers"))
        } footer: {
            Text(String(localized: "custom_request_headers_e_g_x_api_key_are_sent_with_every_request_do_not_enter_authorization_here_there_is_a_separate_bearer_token_field_protocol_headers_such_as_content_type_accept_mcp_session_id_mcp_protocol_version_are_managed_by_the_system_and_any_settings_here_will_be_ignored"))
        }

        if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if server != nil {
                Section {
                    Button(String(localized: "delete_mcp_server_action"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(server == nil ? String(localized: "add_mcp_server") : String(localized: "edit_mcp_server"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "save")) { save() }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog(String(localized: "delete_mcp_server_confirm"), isPresented: $showDeleteConfirmation) {
            if let server {
                Button(String(localized: "delete_action") + server.name, role: .destructive) {
                    onDelete(server.id)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_server_configuration_and_its_saved_bearer_token_will_be_deleted_together_this_action_cannot_be_undone"))
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationMessage = String(localized: "please_enter_the_server_name")
            return
        }
        if transport.isLocalOnly {
            guard !trimmedCommand.isEmpty else {
                validationMessage = String(localized: "stdio_transport_requires_a_launch_command")
                return
            }
        } else {
            guard isValidEndpoint(trimmedEndpoint) else {
                validationMessage = String(localized: "please_enter_a_valid_http_or_https_endpoint_url")
                return
            }
        }

        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBearerToken = removeSavedCredential
            ? false
            : (server?.hasBearerToken == true || !trimmedToken.isEmpty)
        // [P0-2] 重名容错：uniqueKeysWithValues 撞键会 fatalError 崩溃。
        let customHeaders = Dictionary(
            headerRows
                .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { first, _ in first }
        )
        let envVars = Dictionary(
            envRows
                .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { first, _ in first }
        )
        let config = MCPServerConfig(
            id: server?.id ?? UUID(),
            name: trimmedName,
            endpointURL: trimmedEndpoint,
            transport: transport,
            isEnabled: isEnabled,
            hasBearerToken: hasBearerToken,
            customHeaders: customHeaders,
            envVars: envVars,
            command: trimmedCommand,
            args: args,
            lastStatus: server?.lastStatus ?? .unknown,
            lastError: server?.lastError,
            lastToolCount: server?.lastToolCount ?? 0,
            lastCheckedAt: server?.lastCheckedAt
        )

        let credentialUpdate: String?
        if removeSavedCredential {
            credentialUpdate = ""
        } else if trimmedToken.isEmpty {
            credentialUpdate = nil
        } else {
            credentialUpdate = trimmedToken
        }
        onSave(config, credentialUpdate)
    }

    private func isValidEndpoint(_ value: String) -> Bool {
        guard
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else {
            return false
        }
        return true
    }
}
