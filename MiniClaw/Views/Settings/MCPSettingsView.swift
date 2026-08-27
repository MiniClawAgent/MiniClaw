import SwiftUI
import UIKit

extension MCPTransport: Identifiable {
    var id: Self { self }

    var displayName: String {
        switch self {
        case .auto: L10n.l("automatic")
        case .http: "Streamable HTTP"
        case .legacySSE: "Legacy SSE"
        case .stdio: L10n.l("local_stdio")
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
                Label(L10n.l("miniclaw_supports_remote_mcp_servers_over_http_sse_local_stdio_transport_is_only_available_on_macos_simulator_since_the_ios_sandbox_cannot_launch_local_processes"), systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.servers.isEmpty {
                    EmptyStateView(
                        label: L10n.l("no_server_added_yet"),
                        systemImage: "server.rack",
                        description: L10n.l("after_adding_a_remote_mcp_endpoint_you_can_connect_and_load_tools")
                    )
                } else {
                    ForEach(store.servers) { server in
                        serverRow(server)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(L10n.l("delete_action"), role: .destructive) {
                                    serverPendingDeletion = server
                                }
                            }
                    }
                }

                Button {
                    editorItem = MCPServerEditorItem(server: nil)
                } label: {
                    Label(L10n.l("add_mcp_server"), systemImage: "plus.circle.fill")
                }

                Button {
                    refreshAll()
                } label: {
                    HStack {
                        Label(L10n.l("refresh_all_servers"), systemImage: "arrow.clockwise")
                        Spacer()
                        if isRefreshingAll {
                            ProgressView()
                        }
                    }
                }
                .disabled(store.servers.isEmpty || isRefreshingAll)
            } header: {
                HStack {
                    Text(L10n.l("remote_server"))
                    Spacer()
                    if isRefreshingAll {
                        Text(L10n.l("refreshing"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    exportedConfig = ExportedConfigItem(json: store.exportClaudeDesktopConfig(for: store.servers))
                } label: {
                    Label(L10n.l("export_claude_desktop_config"), systemImage: "square.and.arrow.up")
                }
                Button {
                    showImportSheet = true
                } label: {
                    Label(L10n.l("import_claude_desktop_config_from_text"), systemImage: "square.and.arrow.down")
                }
            } header: {
                Text(L10n.l("claude_desktop_compatible"))
            } footer: {
                Text(L10n.l("export_currently_enabled_servers_as_mcpservers_json_import_json_in_the_same_format_to_add_servers_in_bulk"))
            }

            sessionMCPExceptionSection
        }
        .navigationTitle(L10n.l("mcp"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorItem = MCPServerEditorItem(server: nil)
                } label: {
                    Label(L10n.l("add_server"), systemImage: "plus")
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
        .confirmationDialog(
            L10n.l("delete_mcp_server_confirm"),
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            ),
            presenting: serverPendingDeletion
        ) { server in
            Button(L10n.l("delete_action") + server.name, role: .destructive) {
                removeServerWithPlugin(server)
                serverPendingDeletion = nil
            }
            Button(L10n.l("cancel"), role: .cancel) {
                serverPendingDeletion = nil
            }
        } message: { _ in
            Text(L10n.l("the_server_configuration_and_its_saved_bearer_token_will_be_deleted_together_this_action_cannot_be_undone"))
        }
        .sheet(item: $exportedConfig) { item in
            NavigationStack {
                ScrollView {
                    Text(item.json)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(L10n.l("claude_desktop_configuration"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.l("copy_action")) { UIPasteboard.general.string = item.json }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.l("close")) { exportedConfig = nil }
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
                            importMessage = L10n.l("no_server_entries_were_parsed")
                            return
                        }
                        for cfg in configs {
                            store.upsert(cfg, bearerToken: store.takeImportedBearerToken(for: cfg.id))
                        }
                        importMessage = String(format: L10n.l("imported_servers"), "\(configs.count)")
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
                        Text(L10n.l("no_mcp_servers_configured"))
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
                    Text(L10n.l("disabled_servers_won_t_load_their_tools_in_this_session_other_sessions_are_unaffected_changes_take_effect_immediately_and_apply_on_the_next_conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.l("mcp_session_exception_prefix") + session.title + L10n.l("close_paren"))
                }
            } else {
                Section {
                    Text(L10n.l("open_settings_within_a_session_to_disable_mcp_servers_per_session"))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.l("mcp_session_exception"))
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

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                editorItem = MCPServerEditorItem(server: server)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(server.endpointURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        statusLabel(for: server)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text("\(server.lastToolCount) " + L10n.l("tool_count_suffix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if server.hasBearerToken {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L10n.l("bearer_token_saved"))
                        }
                    }

                    if let error = server.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }

                    if let checkedAt = server.lastCheckedAt {
                        Text(L10n.l("last_checked_label") + checkedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 12) {
                Toggle(
                    L10n.l("enable_label") + server.name,
                    isOn: Binding(
                        get: { server.isEnabled },
                        set: { store.setEnabled($0, id: server.id) }
                    )
                )
                .labelsHidden()

                Button {
                    refresh(server.id)
                } label: {
                    if isRefreshing(server) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing(server) || isRefreshingAll)
                .accessibilityLabel(L10n.l("refresh_label") + server.name)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func statusLabel(for server: MCPServerConfig) -> some View {
        switch server.lastStatus {
        case .unknown:
            Label(L10n.l("not_checked"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting:
            Label(L10n.l("connecting"), systemImage: "arrow.clockwise")
                .foregroundStyle(.blue)
        case .connected:
            Label(L10n.l("connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label(L10n.l("connection_failed"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func isRefreshing(_ server: MCPServerConfig) -> Bool {
        refreshingServerIDs.contains(server.id) || server.lastStatus == .connecting
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
                Text(L10n.l("mcpservers_json"))
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
                    Label(L10n.l("paste_from_clipboard"), systemImage: "doc.on.clipboard")
                }
                Button(L10n.l("import")) {
                    onImport(text)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(L10n.l("import_claude_desktop_config"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.l("cancel")) { message = nil }
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
                    TextField(L10n.l("name"), text: $name)

                    TextField("https://example.com/mcp", text: $endpointURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker(L10n.l("connection_method"), selection: $transport) {
                        ForEach(MCPTransport.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle(L10n.l("enable_this_server"), isOn: $isEnabled)
                },
                header: { Text(L10n.l("server")) },
                footer: {
                    Text(L10n.l("endpoint_must_be_an_http_or_https_address_http_can_be_used_for_local_development"))
                }
            )

            if transport.isLocalOnly {
                Section {
                    TextField(L10n.l("launch_command_e_g_npx_y_modelcontextprotocol_server_xxx"), text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.l("arguments_space_separated"), text: $args)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if envRows.isEmpty {
                        Text(L10n.l("no_environment_variables_added"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($envRows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.l("variable_name_e_g_api_key"), text: $row.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(L10n.l("variable_value"), text: $row.value)
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
                        Label(L10n.l("add_environment_variable"), systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text(L10n.l("stdio_launch_arguments"))
                } footer: {
                    Text(L10n.l("stdio_transport_is_only_available_on_macos_simulator_the_ios_sandbox_cannot_launch_local_processes_var_expansion_is_supported_in_command_and_arguments"))
                }
            }

            Section {
                SecureField(
                    server?.hasBearerToken == true ? L10n.l("enter_new_token_to_replace") : L10n.l("bearer_token_optional"),
                    text: $bearerToken
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(removeSavedCredential)

                if server?.hasBearerToken == true {
                    if removeSavedCredential {
                        Label(L10n.l("saving_will_delete_the_saved_credentials"), systemImage: "trash")
                            .font(.footnote)
                            .foregroundStyle(.red)

                        Button(L10n.l("keep_saved_credentials")) {
                            removeSavedCredential = false
                        }
                    } else {
                        Button(L10n.l("delete_saved_credentials_when_saving"), role: .destructive) {
                            bearerToken = ""
                            removeSavedCredential = true
                        }
                    }
                }
            } header: {
                Text(L10n.l("credentials_item"))
            } footer: {
                if server?.hasBearerToken == true && !removeSavedCredential {
                    Text(L10n.l("bearer_token_saved_securely_it_will_not_be_shown_here_leaving_it_blank_when_editing_means_keeping_the_original_token"))
                } else {
                Text(L10n.l("the_token_is_used_only_for_the_authorization_request_header_its_content_is_not_shown_in_the_ui"))
            }
        }

        Section {
            if headerRows.isEmpty {
                Text(L10n.l("no_custom_headers_added"))
                    .foregroundStyle(.secondary)
            }
            ForEach($headerRows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.l("header_name_e_g_x_api_key"), text: $row.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L10n.l("header_value"), text: $row.value)
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
                Label(L10n.l("add_request_header"), systemImage: "plus.circle.fill")
            }
        } header: {
            Text(L10n.l("custom_headers"))
        } footer: {
            Text(L10n.l("custom_request_headers_e_g_x_api_key_are_sent_with_every_request_do_not_enter_authorization_here_there_is_a_separate_bearer_token_field_protocol_headers_such_as_content_type_accept_mcp_session_id_mcp_protocol_version_are_managed_by_the_system_and_any_settings_here_will_be_ignored"))
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
                    Button(L10n.l("delete_mcp_server_action"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(server == nil ? L10n.l("add_mcp_server") : L10n.l("edit_mcp_server"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.l("cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.l("save")) { save() }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog(L10n.l("delete_mcp_server_confirm"), isPresented: $showDeleteConfirmation) {
            if let server {
                Button(L10n.l("delete_action") + server.name, role: .destructive) {
                    onDelete(server.id)
                }
            }
            Button(L10n.l("cancel"), role: .cancel) {}
        } message: {
            Text(L10n.l("the_server_configuration_and_its_saved_bearer_token_will_be_deleted_together_this_action_cannot_be_undone"))
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationMessage = L10n.l("please_enter_the_server_name")
            return
        }
        if transport.isLocalOnly {
            guard !trimmedCommand.isEmpty else {
                validationMessage = L10n.l("stdio_transport_requires_a_launch_command")
                return
            }
        } else {
            guard isValidEndpoint(trimmedEndpoint) else {
                validationMessage = L10n.l("please_enter_a_valid_http_or_https_endpoint_url")
                return
            }
        }

        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBearerToken = removeSavedCredential
            ? false
            : (server?.hasBearerToken == true || !trimmedToken.isEmpty)
        let customHeaders = Dictionary(
            uniqueKeysWithValues: headerRows
                .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) }
                .filter { !$0.0.isEmpty }
        )
        let envVars = Dictionary(
            uniqueKeysWithValues: envRows
                .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) }
                .filter { !$0.0.isEmpty }
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
