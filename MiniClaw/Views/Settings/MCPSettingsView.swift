import SwiftUI
import UIKit

extension MCPTransport: Identifiable {
    var id: Self { self }

    var displayName: String {
        switch self {
        case .auto: L10n.tr("自动")
        case .http: "Streamable HTTP"
        case .legacySSE: "Legacy SSE"
        case .stdio: L10n.tr("本地 STDIO")
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
                Label(L10n.tr("MiniClaw 支持 HTTP / SSE 远端 MCP Server；本地 STDIO 传输仅在 macOS / Simulator 可用，iOS 沙箱不支持拉起本地进程。"), systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.servers.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("尚未添加服务器"),
                        systemImage: "server.rack",
                        description: Text(L10n.tr("添加一个远端 MCP Endpoint 后即可连接并载入工具。"))
                    )
                } else {
                    ForEach(store.servers) { server in
                        serverRow(server)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(L10n.tr("删除"), role: .destructive) {
                                    serverPendingDeletion = server
                                }
                            }
                    }
                }

                Button {
                    editorItem = MCPServerEditorItem(server: nil)
                } label: {
                    Label(L10n.tr("添加 MCP 服务器"), systemImage: "plus.circle.fill")
                }

                Button {
                    refreshAll()
                } label: {
                    HStack {
                        Label(L10n.tr("刷新全部服务器"), systemImage: "arrow.clockwise")
                        Spacer()
                        if isRefreshingAll {
                            ProgressView()
                        }
                    }
                }
                .disabled(store.servers.isEmpty || isRefreshingAll)
            } header: {
                HStack {
                    Text(L10n.tr("远端服务器"))
                    Spacer()
                    if isRefreshingAll {
                        Text(L10n.tr("正在刷新"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    exportedConfig = ExportedConfigItem(json: store.exportClaudeDesktopConfig(for: store.servers))
                } label: {
                    Label(L10n.tr("导出 Claude Desktop 配置"), systemImage: "square.and.arrow.up")
                }
                Button {
                    showImportSheet = true
                } label: {
                    Label(L10n.tr("从文本导入 Claude Desktop 配置"), systemImage: "square.and.arrow.down")
                }
            } header: {
                Text(L10n.tr("Claude Desktop 兼容"))
            } footer: {
                Text(L10n.tr("导出当前已启用的服务器为 mcpServers JSON；导入同样格式的 JSON 可批量添加服务器。"))
            }

            sessionMCPExceptionSection
        }
        .navigationTitle(L10n.tr("MCP 功能"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorItem = MCPServerEditorItem(server: nil)
                } label: {
                    Label(L10n.tr("添加服务器"), systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorItem) { item in
            NavigationStack {
                MCPServerEditorView(server: item.server) { config, bearerToken in
                    store.upsert(config, bearerToken: bearerToken)
                    editorItem = nil
                } onDelete: { id in
                    store.remove(id: id)
                    editorItem = nil
                }
            }
        }
        .confirmationDialog(
            L10n.tr("删除 MCP 服务器？"),
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            ),
            presenting: serverPendingDeletion
        ) { server in
            Button(L10n.tr("删除") + server.name, role: .destructive) {
                store.remove(id: server.id)
                serverPendingDeletion = nil
            }
            Button(L10n.tr("取消"), role: .cancel) {
                serverPendingDeletion = nil
            }
        } message: { _ in
            Text(L10n.tr("服务器配置及其已保存的 Bearer Token 将一并删除，此操作无法撤销。"))
        }
        .sheet(item: $exportedConfig) { item in
            NavigationStack {
                ScrollView {
                    Text(item.json)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(L10n.tr("Claude Desktop 配置"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.tr("复制")) { UIPasteboard.general.string = item.json }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("关闭")) { exportedConfig = nil }
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
                            importMessage = L10n.tr("未解析到任何服务器条目。")
                            return
                        }
                        for cfg in configs {
                            store.upsert(cfg, bearerToken: store.takeImportedBearerToken(for: cfg.id))
                        }
                        importMessage = String(format: L10n.tr("已导入 %@ 个服务器。"), "\(configs.count)")
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
                        Text(L10n.tr("无已配置的 MCP 服务器"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.servers) { server in
                        Toggle(server.name, isOn: Binding(
                            get: { !disabled.contains(server.id) },
                            set: { on in
                                var set = Set(disabled)
                                if on { set.remove(server.id) } else { set.insert(server.id) }
                                session.disabledMCPServerIDs = set.isEmpty ? nil : Array(set)
                                try? session.modelContext?.save()
                            }
                        ))
                        .disabled(!server.isEnabled)
                    }
                    Text(L10n.tr("关闭的服务器不会在本会话加载其工具；其它会话不受影响。修改即时生效，下次发起对话时应用。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.tr("本会话 MCP 例外（") + session.title + L10n.tr("）"))
                }
            } else {
                Section {
                    Text(L10n.tr("在会话内打开设置可逐会话关闭 MCP 服务器。"))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.tr("本会话 MCP 例外"))
                }
            }
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

                        Text("\(server.lastToolCount) " + L10n.tr("个工具"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if server.hasBearerToken {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L10n.tr("已保存 Bearer Token"))
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
                        Text(L10n.tr("上次检查：") + checkedAt.formatted(date: .abbreviated, time: .shortened))
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
                    L10n.tr("启用 ") + server.name,
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
                .accessibilityLabel(L10n.tr("刷新 ") + server.name)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func statusLabel(for server: MCPServerConfig) -> some View {
        switch server.lastStatus {
        case .unknown:
            Label(L10n.tr("未检查"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting:
            Label(L10n.tr("连接中"), systemImage: "arrow.clockwise")
                .foregroundStyle(.blue)
        case .connected:
            Label(L10n.tr("已连接"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label(L10n.tr("连接失败"), systemImage: "exclamationmark.circle.fill")
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
                Text(L10n.tr("mcpServers JSON"))
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
                    Label(L10n.tr("从剪贴板粘贴"), systemImage: "doc.on.clipboard")
                }
                Button(L10n.tr("导入")) {
                    onImport(text)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(L10n.tr("导入 Claude Desktop 配置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("取消")) { message = nil }
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
                    TextField(L10n.tr("名称"), text: $name)

                    TextField("https://example.com/mcp", text: $endpointURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker(L10n.tr("连接方式"), selection: $transport) {
                        ForEach(MCPTransport.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle(L10n.tr("启用此服务器"), isOn: $isEnabled)
                },
                header: { Text(L10n.tr("服务器")) },
                footer: {
                    Text(L10n.tr("Endpoint 必须是 http:// 或 https:// 地址；http 可用于本地开发。"))
                }
            )

            if transport.isLocalOnly {
                Section {
                    TextField(L10n.tr("启动命令（如 npx -y @modelcontextprotocol/server-xxx）"), text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("参数（空格分隔）"), text: $args)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if envRows.isEmpty {
                        Text(L10n.tr("未添加环境变量"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($envRows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L10n.tr("变量名（如 API_KEY）"), text: $row.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(L10n.tr("变量值"), text: $row.value)
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
                        Label(L10n.tr("添加环境变量"), systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text(L10n.tr("STDIO 启动参数"))
                } footer: {
                    Text(L10n.tr("STDIO 传输仅在 macOS / Simulator 可用；iOS 沙箱不支持拉起本地进程。命令与参数支持 ${VAR} 展开。"))
                }
            }

            Section {
                SecureField(
                    server?.hasBearerToken == true ? L10n.tr("输入新 Token 以替换") : L10n.tr("Bearer Token（可选）"),
                    text: $bearerToken
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(removeSavedCredential)

                if server?.hasBearerToken == true {
                    if removeSavedCredential {
                        Label(L10n.tr("保存后将删除已保存的凭据"), systemImage: "trash")
                            .font(.footnote)
                            .foregroundStyle(.red)

                        Button(L10n.tr("保留已保存凭据")) {
                            removeSavedCredential = false
                        }
                    } else {
                        Button(L10n.tr("保存时删除已保存凭据"), role: .destructive) {
                            bearerToken = ""
                            removeSavedCredential = true
                        }
                    }
                }
            } header: {
                Text(L10n.tr("凭据"))
            } footer: {
                if server?.hasBearerToken == true && !removeSavedCredential {
                    Text(L10n.tr("已安全保存 Bearer Token。此处不会回显；编辑时留空表示保留原 Token。"))
                } else {
                Text(L10n.tr("Token 仅用于 Authorization 请求头，界面不会显示其内容。"))
            }
        }

        Section {
            if headerRows.isEmpty {
                Text(L10n.tr("未添加自定义请求头"))
                    .foregroundStyle(.secondary)
            }
            ForEach($headerRows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.tr("Header 名称（如 X-API-Key）"), text: $row.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L10n.tr("Header 值"), text: $row.value)
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
                Label(L10n.tr("添加请求头"), systemImage: "plus.circle.fill")
            }
        } header: {
            Text(L10n.tr("自定义请求头"))
        } footer: {
            Text(L10n.tr("自定义请求头（如 X-API-Key）将随每次请求发送。请勿在此填写 Authorization（已有独立的 Bearer Token 字段）；Content-Type / Accept / Mcp-Session-Id / MCP-Protocol-Version 等协议头由系统托管，此处设置会被忽略。"))
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
                    Button(L10n.tr("删除 MCP 服务器"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(server == nil ? L10n.tr("添加 MCP 服务器") : L10n.tr("编辑 MCP 服务器"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("保存")) { save() }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog(L10n.tr("删除 MCP 服务器？"), isPresented: $showDeleteConfirmation) {
            if let server {
                Button(L10n.tr("删除") + server.name, role: .destructive) {
                    onDelete(server.id)
                }
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("服务器配置及其已保存的 Bearer Token 将一并删除，此操作无法撤销。"))
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationMessage = L10n.tr("请输入服务器名称。")
            return
        }
        if transport.isLocalOnly {
            guard !trimmedCommand.isEmpty else {
                validationMessage = L10n.tr("STDIO 传输需要填写启动命令。")
                return
            }
        } else {
            guard isValidEndpoint(trimmedEndpoint) else {
                validationMessage = L10n.tr("请输入有效的 http:// 或 https:// Endpoint URL。")
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
