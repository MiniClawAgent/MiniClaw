import SwiftUI
import UniformTypeIdentifiers

// MARK: - 智能体服务商列表

struct ProviderSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAdd: Bool = false
    @State private var showImportFile: Bool = false

    /// 按兼容格式分类的固定顺序
    private let categoryOrder = ["openai_compatible", "anthropic_compatible", "google_gemini"]

    var body: some View {
        List {
            ForEach(categoryOrder, id: \.self) { category in
                let items = appState.providers.filter { $0.providerType.compatFormat == category }
                if !items.isEmpty {
                    Section(L10n.l(category)) {
                        ForEach(items) { p in
                            NavigationLink {
                                ProviderDetailView(providerId: p.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.label.isEmpty ? p.providerType.defaultLabel : p.label)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    HStack(spacing: 6) {
                                        Image(systemName: p.keyAdded ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                            .foregroundStyle(p.keyAdded ? .green : .orange)
                                        Text(p.keyAdded ? L10n.l("key_added") : L10n.l("key_not_added"))
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text(L10n.l("model_label_space") + "\(p.models.count)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { idx in
                                let target = items[idx]
                                appState.removeProvider(id: target.id)
                            }
                        }
                    }
                }
            }

            if appState.providers.isEmpty {
                Section {
                    Text(L10n.l("no_providers_yet"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.l("providers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAdd = true
                    } label: {
                        Label(L10n.l("add_provider_button"), systemImage: "plus")
                    }
                    Button {
                        showImportFile = true
                    } label: {
                        Label(L10n.l("import_provider"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProviderView()
        }
        .fileImporter(isPresented: $showImportFile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result,
               let url = urls.first,
               let p = decodeProviderFile(url) {
                appState.updateProviders { $0.append(p) }
            }
        }
    }
}

// MARK: - 服务商配置详情

private struct CustomHeaderRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct ProviderDetailView: View {
    @EnvironmentObject private var appState: AppState
    let providerId: UUID
    /// 是否为本次新建（从「添加服务商」进来）。新建后若未填任何内容直接返回，应自动丢弃，避免生成空白服务商。
    var isNew: Bool = false
    /// 草稿服务商（新建流程未保存前在此持有，不在 appState 中）
    var draftProvider: LLMProvider? = nil
    /// 草稿保存后通知父视图关闭整个 sheet（而非仅 pop 导航栈）
    var onSaveDraft: (() -> Void)?

    @State private var draft: LLMProvider
    @State private var isRefreshing: Bool = false
    @State private var showAddModel: Bool = false
    @State private var editingModel: ModelConfig? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput: String = ""
    @State private var showKeyConfirm: Bool = false
    @State private var modelFetchError: String? = nil
    /// 非阻断提示：实时模型列表不可用时回退到内置目录后给出说明。
    @State private var modelFetchNotice: String? = nil
    /// 添加流程底部「保存」进行中（拉取模型时显示进度）
    @State private var isSaving: Bool = false
    /// 自定义请求头编辑行（与 draft.customHeaders 双向同步）
    @State private var headerRows: [CustomHeaderRow] = []

    private var isDraft: Bool { draftProvider != nil }
    /// Google Gemini 仅支持标签 / 密钥 / 地址，其余冗余控件一律隐藏
    private var isGemini: Bool { draft.providerType == .google }

    init(providerId: UUID, isNew: Bool = false, draftProvider: LLMProvider? = nil, onSaveDraft: (() -> Void)? = nil) {
        self.providerId = providerId
        self.isNew = isNew
        self.draftProvider = draftProvider
        self.onSaveDraft = onSaveDraft
        _draft = State(initialValue: draftProvider ?? LLMProvider())
        _headerRows = State(initialValue: (draftProvider ?? LLMProvider()).customHeaders.map { CustomHeaderRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            // 1. 标签
            Section(L10n.l("tabs")) {
                TextField(L10n.l("tabs"), text: $draft.label)
                // API 兼容格式（不可编辑，仅显示）
                HStack {
                    Text(L10n.l("api_compatible_format"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.l(draft.providerType.compatFormat))
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
            }

            // 2. 凭证
            Section {
                if draft.credentialType == "oauth" {
                    Label(L10n.l("this_provider_uses_oauth_credentials_renew_automatically"), systemImage: "person.badge.key")
                        .font(.caption)
                } else {
                    SecureField(draft.keyAdded ? L10n.l("enter_a_new_key_to_replace") : "API Key", text: $apiKeyInput)
                }
            } header: {
                Text(L10n.l("credential_item"))
            } footer: {
                if draft.keyAdded {
                    Label(L10n.l("key_configured_cannot_be_read_back_after_writing_saving_with_it_blank_does_not_affect_the_existing_key_only_entering_a_new_value_will_overwrite_it"),
                          systemImage: "lock.fill")
                        .font(.caption)
                }
            }

            // 3. 自定义 API 地址
            Section(L10n.l("custom_api_url")) {
                TextField("https://...", text: $draft.customBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            // 3.5 自定义请求头（对接需附加请求头的中转网关）
            Section(L10n.l("custom_headers")) {
                if headerRows.isEmpty {
                    Text(L10n.l("no_custom_headers_used_to_connect_to_relay_gateways_that_require_additional_request_headers_e_g_x_api_version_custom_auth"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($headerRows) { $row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(L10n.l("header_name"), text: $row.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField(L10n.l("header_value"), text: $row.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            if let idx = headerRows.firstIndex(where: { $0.id == row.id }) {
                                headerRows.remove(at: idx)
                                syncHeaders()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    headerRows.append(CustomHeaderRow(key: "", value: ""))
                    syncHeaders()
                } label: {
                    Label(L10n.l("add_custom_header"), systemImage: "plus")
                }
            }

            // 4. API 格式（Gemini 不适用）
            if !isGemini {
                Section(L10n.l("api_format")) {
                    Picker(L10n.l("api_format"), selection: $draft.apiFormat) {
                        ForEach(APIFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // 5. Azure OpenAI（Gemini 不适用）
            if !isGemini {
                Section {
                    Toggle("Azure OpenAI", isOn: $draft.azureEnabled)
                } footer: {
                    Text(L10n.l("when_using_azure_openai_authentication_append_the_full_azure_endpoint_including_query_parameters_in_the_custom_api"))
                }
            }

            // 6. 状态（Gemini 不适用）
            if !isGemini {
                Section {
                    Toggle(L10n.l("enable_this_provider"), isOn: $draft.isEnabled)
                } header: {
                    Text(L10n.l("status"))
                }
            }

            // 7. 模型列表（Gemini / 草稿添加模式 不适用：添加页不展示拉取模型，完成后在详情页展示）
            if !isGemini && !isDraft {
                providerModelsSection
            }

            // 8. 删除 智能体服务商（草稿模式不显示）
            if !isDraft {
                Section {
                    Button(L10n.l("delete_provider"), role: .destructive) {
                        deleteProvider()
                    }
                }
            }

            // 9. 添加流程：底部统一的「保存」按钮（保存供应商信息并后台拉取模型）
            if isDraft {
                Section {
                    Button {
                        Task { await saveNewProvider() }
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(L10n.l("save"))
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .navigationTitle(isDraft ? L10n.l("add_provider_action") : (draft.label.isEmpty ? L10n.l("provider") : draft.label))
        .navigationBarTitleDisplayMode(.inline)
        // 已添加（编辑）态：隐藏系统返回按钮，统一由右上角「保存」退出并落盘；草稿态保留返回键取消。
        .navigationBarBackButtonHidden(!isDraft)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isDraft {
                    Button(L10n.l("save")) {
                        Task { await saveForExistingProvider() }
                    }
                }
            }
        }
        .onAppear { load() }   // 不回读已存密钥（spec 12.2：写入后不可回读）
        .onChange(of: draft) { _ in persist() }
        .onDisappear {
            // 草稿模式：取消时不保存（不操作 appState）
            if isDraft { return }
            // 本次新建且未填任何内容就返回：丢弃空白服务商，避免污染列表
            if isNew && isBlank {
                appState.updateProviders { $0.removeAll { $0.id == providerId } }
            }
        }
        .sheet(isPresented: $showAddModel) {
            NavigationStack {
                CustomModelEditorView(initial: ModelConfig(), provider: draft, isNew: true) { newModel in
                    draft.models.append(newModel)
                    persist()
                }
            }
        }
        .sheet(item: $editingModel) { model in
            NavigationStack {
                CustomModelEditorView(initial: model, provider: draft, isNew: false) { updated in
                    if let idx = draft.models.firstIndex(where: { $0.id == updated.id }) {
                        draft.models[idx] = updated
                    }
                    persist()
                }
            }
        }
        .confirmationDialog(L10n.l("save_api_key"), isPresented: $showKeyConfirm) {
            Button(L10n.l("save")) {
                Task { await saveCredentialAndFetchModels() }
            }
            Button(L10n.l("cancel"), role: .cancel) { }
        } message: {
            Text(L10n.l("after_saving_the_api_key_is_written_to_local_storage_and_cannot_be_read_back_the_ui_shows_a_mask_config_get_returns_a_protected_message"))
        }
    }

    @ViewBuilder
    private func providerModelRow(_ model: ModelConfig) -> some View {
        let isHidden = model.hidden
        HStack(spacing: 12) {
            Button {
                editingModel = model
            } label: {
                ModelRow(model: model)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleModelVisibility(model.id)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .foregroundColor(isHidden ? .secondary : .blue)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isHidden ? L10n.l("show_model") : L10n.l("hidden_model"))
        }
    }

    private func toggleModelVisibility(_ modelId: UUID) {
        guard let index = draft.models.firstIndex(where: { $0.id == modelId }) else { return }
        draft.models[index].isHidden = !draft.models[index].hidden
        persist()
    }

    /// 模型列表区内容（独立抽出以控制 body 表达式复杂度，规避类型检查超时）。
    /// 仅在非草稿（已添加）态展示；拉取失败时于「模型」位置提示检查密钥 / API 地址。
    @ViewBuilder
    private var providerModelsSection: some View {
        Section {
            // 拉取失败：在「模型」位置提示用户检查密钥 / API 地址
            if let err = draft.modelFetchError, !err.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.l("model_fetch_failed"), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Text(L10n.l("check_that_the_key_credential_or_api_url_is_correct"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = draft.modelFetchNotice, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if draft.models.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.l("no_models_yet"))
                        .foregroundStyle(.secondary)
                    Button(L10n.l("add_custom_model")) { showAddModel = true }
                }
            } else {
                let sortedModels = draft.models.sorted {
                    $0.resolvedName.localizedStandardCompare($1.resolvedName) == .orderedAscending
                }
                ForEach(sortedModels) { model in
                    providerModelRow(model)
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { sortedModels[$0].id }
                    draft.models.removeAll { ids.contains($0.id) }
                    persist()
                }
                Button(L10n.l("add_custom_model")) { showAddModel = true }
            }
        } header: {
            HStack {
                Text(L10n.l("model_label"))
                Spacer()
                Button {
                    Task { await refreshModels() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || !draft.keyAdded)
            }
        }
    }

    // MARK: - 数据读写
    private func load() {
        if let dp = draftProvider {
            draft = dp
        } else if let p = appState.providers.first(where: { $0.id == providerId }) {
            draft = p
        }
    }

    private func persist() {
        guard !isDraft else { return }  // 草稿模式不自动持久化，等「保存」按钮触发
        appState.updateProviders { arr in
            if let idx = arr.firstIndex(where: { $0.id == providerId }) {
                arr[idx] = draft
            }
        }
    }

    /// 把 headerRows 编辑结果同步回 draft.customHeaders（触发 onChange → persist 落盘）。
    private func syncHeaders() {
        draft.customHeaders = Dictionary(
            uniqueKeysWithValues: headerRows
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key, $0.value) }
        )
    }

    /// 草稿（添加流程）提交：把当前草稿写入 appState（落盘 + Keychain），
    /// 已存在则更新，避免重复追加。
    private func commitDraftToAppState() {
        appState.updateProviders { arr in
            if let idx = arr.firstIndex(where: { $0.id == draft.id }) {
                arr[idx] = draft
            } else {
                arr.append(draft)
            }
        }
    }

    /// 添加流程底部「保存」：保存供应商信息（含密钥，经 ProviderFileStore 落 Keychain），
    /// 后台拉取模型，结果（模型或失败信息）提交进 appState，随后关闭整页回到列表。
    @MainActor
    private func saveNewProvider() async {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        draft.apiKey = trimmed
        draft.hasApiKey = true
        draft.modelFetchError = nil
        draft.modelFetchNotice = nil

        // 1) 先把基础信息落盘（密钥经 ProviderFileStore.save 写入 Keychain）
        commitDraftToAppState()

        // 2) 后台拉取模型（结果写入 draft.models / draft.modelFetchError）
        await refreshModels()

        // 3) 把拉取结果（模型或失败信息）提交进 appState 的该 provider
        commitDraftToAppState()

        // 4) 关闭整页，回到服务商列表（失败信息会在详情页「模型」位置展示）
        onSaveDraft?()
    }

    /// 判断是否为「完全空白」的服务商：未填标签、密钥、地址，且无任何模型。
    private var isBlank: Bool {
        draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.hasApiKey
            && draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.models.isEmpty
    }

    private func deleteProvider() {
        appState.removeProvider(id: providerId)
        dismiss()
    }

    // MARK: - 拉取模型
    @MainActor
    private func saveCredentialAndFetchModels() async {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.apiKey = trimmed
        draft.hasApiKey = !trimmed.isEmpty
        modelFetchError = nil
        modelFetchNotice = nil
        persist()
        await refreshModels()
    }

    /// 已添加（编辑）态右上角「保存」：若填写了新密钥则写入 Keychain 并后台拉取模型；
    /// 标签 / 地址 / 请求头 / 格式 / 启停 / 模型等其余字段已通过 onChange 实时持久化。最后关闭页面返回列表。
    @MainActor
    private func saveForExistingProvider() async {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            draft.apiKey = trimmed
            draft.hasApiKey = true
            modelFetchError = nil
            modelFetchNotice = nil
            persist()
            await refreshModels()
        }
        dismiss()
    }

    @MainActor
    private func refreshModels() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        modelFetchError = nil
        modelFetchNotice = nil
        draft.modelFetchError = nil
        draft.modelFetchNotice = nil
        defer { isRefreshing = false }

        // 构造鉴权策略序列：
        // - Anthropic 兼容：绝大多数网关实为 OpenAI 后端，模型列表是 OpenAI 风格 (Bearer + /v1/models)；
        //   故先试 Bearer，失败（含 401/403/404）再试 Anthropic 原生 (x-api-key + anthropic-version)。
        //   这同时修复了「用 x-api-key 请求 OpenAI 后端的 /v1/models 报 404」的问题。
        // - 其他类型：仅默认策略（Bearer）。
        let strategies: [Bool] = (draft.providerType == .anthropic) ? [true, false] : [false]

        var data = Data()
        var response: URLResponse?
        var lastURL: URL?

        for forceBearer in strategies {
            guard let req = makeModelsRequest(forceBearer: forceBearer) else { continue }
            lastURL = req.url
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                // 仅当所有策略都失败（网络错误）才最终报错
                if forceBearer == strategies.last {
                    let msg = String(format: L10n.l("failed_to_fetch_models_network_or_request_error"), error.localizedDescription)
                    modelFetchError = msg
                    draft.modelFetchError = msg
                }
                continue
            }
            // 拿到 2xx 即视为成功，停止尝试后续策略
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                break
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            if modelFetchError == nil {
                let msg = L10n.l("model_fetch_failed_no_valid_http_response_received")
                modelFetchError = msg
                draft.modelFetchError = msg
            }
            return
        }
        let status = httpResponse.statusCode
        // 诊断：打印状态码与响应片段（密钥做掩码，不打印明文），便于现场排查。
        let logURL = (draft.providerType == .google)
            ? (lastURL?.absoluteString.replacingOccurrences(of: "key=[^&]*", with: "key=***", options: .regularExpression) ?? "")
            : (lastURL?.absoluteString ?? "")
        print("[ProviderDetail] 🔍 \(draft.providerType.rawValue) 模型列表 HTTP \(status)  url=\(logURL)")
        if let preview = String(data: data.prefix(600), encoding: .utf8) {
            print("[ProviderDetail] 📄 响应片段: \(preview)")
        }
        guard (200...299).contains(status) else {
            var serverMsg = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = json["error"] as? [String: Any], let m = err["message"] as? String { serverMsg = m }
                else if let m = json["error"] as? String { serverMsg = m }
                else if let m = json["message"] as? String { serverMsg = m }
            }
            // 关键兜底：绝大多数「Anthropic 兼容」代理只代理 /v1/messages（聊天），
            // 并未实现 /v1/models（模型列表），对其请求必 404/401/403。
            // 此时回退到内置模型目录，按 base URL 推断的厂商给出已知模型，用户仍可立即选用。
            let fb = fallbackModelsForCurrentProvider()
            if !fb.isEmpty {
                applyFetchedModels(fb, archive: false)
                let note = String(format: L10n.l("live_model_list_unavailable_http_1_loaded_2_models_from_the_built_in_model_catalog_for_other_model_ids_use_add_custom_model_below"), String(status), String(fb.count))
                modelFetchError = nil
                modelFetchNotice = note
                draft.modelFetchError = nil
                draft.modelFetchNotice = note
                return
            }
            let msg = String(format: L10n.l("failed_to_fetch_models_http_1_2"), String(status), serverMsg.isEmpty ? "" : "： \(serverMsg)")
            modelFetchError = msg
            draft.modelFetchError = msg
            return
        }

        guard let models = parseModels(from: data), !models.isEmpty else {
            let msg = L10n.l("failed_to_fetch_models_empty_response_please_confirm_the_provider_supports_the_v1_models_list_endpoint")
            modelFetchError = msg
            draft.modelFetchError = msg
            return
        }

        applyFetchedModels(models)
    }

    /// 把拉取到的模型写入草稿（合并用户已改名称、持久化、按需默选），
    /// 同时把 API 返回的新模型持续归档进内置目录（archive=false 时跳过，用于目录回退避免重复建档）。
    private func applyFetchedModels(_ models: [ModelConfig], archive: Bool = true) {
        // 拉取成功：清空上一次的失败 / 提示信息
        modelFetchError = nil
        modelFetchNotice = nil
        draft.modelFetchError = nil
        draft.modelFetchNotice = nil
        let previousModels = Dictionary(
                uniqueKeysWithValues: draft.models.map { ($0.modelId, $0) }
            )
        draft.models = models.map { fetched in
            guard var existing = previousModels[fetched.modelId] else { return fetched }
            // 用户手动改过名称则不再被拉取覆盖
            if !fetched.displayName.isEmpty, existing.userRenamed != true {
                existing.displayName = fetched.displayName
            }
            if fetched.contextLimit > 0 {
                existing.contextLimit = fetched.contextLimit
            }
            if let maxOutputTokens = fetched.maxOutputTokens {
                existing.maxOutputTokens = maxOutputTokens
            }
            existing.deepThinking = fetched.deepThinking
            // 模态开关：统一交给 BuiltinModelInfo.reconcile（厂商适配器目录为准 + 语音启发式兜底），
            // 不在此处重复手写易错的重置/回填逻辑。
            let info = LLMProviderFactory.modelCapabilities(providerType: draft.providerType, modelID: fetched.modelId)
            BuiltinModelInfo.reconcile(info, modelId: fetched.modelId, config: &existing)
            return existing
        }
        persist()

        // 仅当全局尚未选中任何默认模型时才默认选中第一个；
        // 已有选中则保留用户的选择，只刷新列表、绝不覆盖。
        if appState.selectedModelId == nil,
           let firstModel = draft.models.first(where: { !$0.hidden }) {
            appState.setActiveModel(
                providerId: providerId,
                modelId: firstModel.id
            )
        }

        // 首次配置：自动把拉取到的模型填入「设置分组」的主/副槽位（仅当槽位仍为"无"时）。
        autoAssignModelSlots()
    }

    /// 首次设置 API 拉取到模型后：主模型槽位填入默认对话模型（优先当前全局默认、需同时具备文本输入与输出能力），
    /// 副模型槽位填入另一个对话模型；若拉取到的模型里只有一个对话模型（其余是语音等单向模型），
    /// 则主、副均填写该对话模型，避免副模型相关后台功能因副模型为空而失效。已由用户配置过的槽位绝不覆盖。
    private func autoAssignModelSlots() {
        let session = SettingsStore.shared.settings.session
        guard session.mainModel.isNone || session.secondaryModel.isNone else { return }

        // 主/副模型都必须是真正的对话模型：同时具备文本输入与文本输出能力（排除纯语音等单向模型）。
        let chatModels = draft.models.filter { !$0.hidden && $0.inputText && $0.outputText }
        guard !chatModels.isEmpty else { return }

        var main = session.mainModel
        var secondary = session.secondaryModel

        if main.isNone {
            // 优先与全局默认模型对齐（属于本服务商且具文本能力），否则取第一个对话模型。
            let mainModel: ModelConfig
            if appState.selectedProviderId == providerId,
               let mid = appState.selectedModelId,
               let m = chatModels.first(where: { $0.id == mid }) {
                mainModel = m
            } else {
                mainModel = chatModels[0]
            }
            main = .model(compositeKey: "\(providerId.uuidString)/\(mainModel.modelId)")
        }

        if secondary.isNone {
            // 副模型优先选与主模型不同的另一个对话模型；
            // 仅有一个对话模型时（例如拉取到的模型里只有一个文本模型、其余是语音模型），
            // 直接复用主模型（同一个文本模型），避免副模型相关的标题生成、记忆复盘等后台功能因副模型为空而失效。
            let mainModelId: String? = {
                if case .model(let compositeKey) = main {
                    let parts = compositeKey.split(separator: "/", maxSplits: 1)
                    return parts.count == 2 ? String(parts[1]) : nil
                }
                return nil
            }()
            if let other = chatModels.first(where: { $0.modelId != mainModelId }) {
                secondary = .model(compositeKey: "\(providerId.uuidString)/\(other.modelId)")
            } else if case .model(let compositeKey) = main {
                secondary = .model(compositeKey: compositeKey)
            }
        }

        guard main != session.mainModel || secondary != session.secondaryModel else { return }
        SettingsStore.shared.update(
            domain: .session,
            summary: L10n.l("auto_fill_primary_secondary_model")
        ) { (settings: inout SessionSettings) in
            if settings.mainModel.isNone { settings.mainModel = main }
            if settings.secondaryModel.isNone { settings.secondaryModel = secondary }
        }
    }

    // MARK: - 内置目录兜底

    /// 实时列表不可用时，从厂商适配器内置目录回退该厂商的已知模型。
    /// openRouter/custom 无专属目录（继承 OpenAI 基类目录），直接回退全量目录
    /// （这些模型在 OpenRouter 上均可用），按模型 ID 排序保证列表顺序稳定。
    private func fallbackModelsForCurrentProvider() -> [ModelConfig] {
        let builtin = LLMProviderFactory.builtinModels(providerType: draft.providerType)
        return builtin.keys.sorted().map { configFromInfo(id: $0, info: builtin[$0]!) }
    }

    /// 由内置目录条目构造 ModelConfig（复用 parseModels 中的能力回填逻辑）。
    private func configFromInfo(id: String, info: BuiltinModelInfo) -> ModelConfig {
        var config = ModelConfig(
            modelId: id,
            displayName: info.displayName ?? ModelConfig.titleCasedModelId(id),
            contextLimit: info.contextWindow ?? 0,
            deepThinking: info.deepThinking ?? false,
            maxOutputTokens: info.maxOutputTokens
        )
        if let inTok = info.input, !inTok.isEmpty {
            BuiltinModelInfo.applyModalities(inTok, to: &config)
        }
        if let outTok = info.output, !outTok.isEmpty {
            BuiltinModelInfo.applyOutputModalities(outTok, to: &config)
        }
        return config
    }

    private func makeModelsRequest(forceBearer: Bool = false) -> URLRequest? {
        let customBase = draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = customBase.isEmpty ? draft.providerType.defaultBaseURL : customBase
        guard !base.isEmpty, draft.keyAdded else { return nil }

        let endpoint: String
        switch draft.providerType {
        case .google:
            endpoint = appendingPath("v1beta/models", to: base)
        case .openai, .anthropic, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu:
            endpoint = appendingPath("v1/models", to: base)
        }

        guard var components = URLComponents(string: endpoint) else { return nil }
        if draft.providerType == .google {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "key" }
            queryItems.append(URLQueryItem(name: "key", value: draft.apiKey))
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch draft.providerType {
        case .anthropic:
            if forceBearer {
                request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(draft.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        case .google:
            break
        case .openai, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu:
            request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func appendingPath(_ path: String, to base: String) -> String {
        var normalizedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedBase.hasSuffix("/v1") {
            normalizedBase.removeLast(3)
            normalizedBase = normalizedBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if normalizedBase.hasSuffix("/v1beta") {
            normalizedBase.removeLast(7)
            normalizedBase = normalizedBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normalizedBase + "/" + path
    }

    /// 解析服务商 /models 响应为模型列表。
    /// 方法 A+B+C：
    /// A. 读取 OpenRouter 等兼容端点的扩展字段（name / context_length / top_provider.max_completion_tokens / reasoning / architecture.input/output_modalities）；
    /// B. API 缺失字段回退到厂商适配器内置目录；
    /// C. 模态 词元（text/image/audio/video/file）→ ModelConfig 的 input/output 布尔开关。
    private func parseModels(from data: Data) -> [ModelConfig]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawModels: [[String: Any]]
        if let dataModels = json["data"] as? [[String: Any]] {
            rawModels = dataModels
        } else if let googleModels = json["models"] as? [[String: Any]] {
            rawModels = googleModels
        } else {
            return nil
        }

        var seen = Set<String>()
        return rawModels.compactMap { item in
            let rawID = (item["id"] as? String) ?? (item["name"] as? String) ?? ""
            let modelID = rawID.hasPrefix("models/")
                ? String(rawID.dropFirst("models/".count))
                : rawID
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { return nil }

            // —— 显示名称：API 优先，其次目录，最后 title-case 兜底 ——
            var displayName: String = {
                if let dn = (item["display_name"] as? String) ?? (item["displayName"] as? String),
                   !dn.isEmpty { return dn }
                // OpenRouter 的 name 是漂亮显示名（如 "GPT-4o"）；Gemini 的 name 是资源名 "models/..."，跳过
                if let nm = item["name"] as? String,
                   !nm.isEmpty, !nm.contains("/"), !nm.hasPrefix("models/") { return nm }
                return ""
            }()

            // —— 上下文窗口 ——
            let contextLimit: Int = {
                if let c = integerValue(item["context_window"] ?? item["contextWindow"] ?? item["inputTokenLimit"]) { return c }
                if let cl = item["context_length"] as? Int, cl > 0 { return cl }
                if let tp = item["top_provider"] as? [String: Any],
                   let tcl = tp["context_length"] as? Int, tcl > 0 { return tcl }
                return 0
            }()

            // —— 最大输出 词元 ——
            let maxOutputTokens: Int? = {
                if let m = integerValue(item["max_output_tokens"] ?? item["maxOutputTokens"] ?? item["outputTokenLimit"]) { return m }
                if let tp = item["top_provider"] as? [String: Any],
                   let mt = tp["max_completion_tokens"] as? Int { return mt }
                return nil
            }()

            // —— 深度思考 ——
            let deepThinking: Bool = {
                if let t = item["thinking"] as? Bool, t { return true }
                if let _ = item["reasoning"] as? [String: Any] { return true }
                if let dt = booleanValue(item["deep_thinking"] ?? item["deepThinking"] ?? item["reasoning"]) { return dt }
                let lower = modelID.lowercased()
                return lower.contains("reasoning") || lower.contains("think")
                    || lower.contains("o1") || lower.contains("o3") || lower.contains("o4")
                    || lower.contains("r1") || lower.contains("qwq")
            }()

            // —— 模态（输入 / 输出）由下方 BuiltinModelInfo.reconcile 统一处理
            // (目录为准 + 语音启发式),API 的 architecture 字段仅作参考 ——

            // —— 合并内置目录兜底（B）：API 缺失字段回退到厂商适配器内置目录 ——
            var fallbackContext = contextLimit
            var fallbackMax = maxOutputTokens
            var fallbackDeep = deepThinking
            let catalogEntry = LLMProviderFactory.modelCapabilities(providerType: draft.providerType, modelID: modelID)
            if let catalog = catalogEntry {
                if displayName.isEmpty, let dn = catalog.displayName { displayName = dn }
                if fallbackContext == 0, let cw = catalog.contextWindow, cw > 0 { fallbackContext = cw }
                if fallbackMax == nil, let mo = catalog.maxOutputTokens, mo > 0 { fallbackMax = mo }
                if !fallbackDeep, catalog.deepThinking == true { fallbackDeep = true }
            }

            // 仍为空则回退 title-case
            if displayName.isEmpty { displayName = ModelConfig.titleCasedModelId(modelID) }

            var config = ModelConfig(
                modelId: modelID,
                displayName: displayName,
                contextLimit: fallbackContext,
                deepThinking: fallbackDeep,
                maxOutputTokens: fallbackMax
            )
            // 模态统一交给 BuiltinModelInfo.reconcile（厂商目录为准 + 语音启发式兜底）。
            BuiltinModelInfo.reconcile(catalogEntry, modelId: modelID, config: &config)

            return config
        }
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "supported", "yes", "1": return true
            case "false", "unsupported", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

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

// MARK: - 自定义模型编辑器

struct CustomModelEditorView: View {
    let initial: ModelConfig
    let provider: LLMProvider
    var isNew: Bool = false
    var onSave: ((ModelConfig) -> Void)? = nil

    @State private var draft: ModelConfig
    @State private var showingTestCard = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    init(
        initial: ModelConfig,
        provider: LLMProvider,
        isNew: Bool = false,
        onSave: ((ModelConfig) -> Void)? = nil
    ) {
        self.initial = initial
        self.provider = provider
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section(L10n.l("identifier")) {
                HStack {
                    Text(L10n.l("model_name"))
                        .foregroundStyle(.primary)
                    Spacer()
                    TextField(L10n.l("display_name"), text: $draft.displayName)
                        .multilineTextAlignment(.trailing)
                }
                if isNew {
                    TextField(L10n.l("model_id"), text: $draft.modelId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent(L10n.l("model_id"), value: draft.modelId)
                }
                LabeledContent(L10n.l("model_provider"), value: providerName)
            }

            Section {
                HStack {
                    Text(L10n.l("context_window"))
                    Spacer()
                    TextField(vendorContextText, value: contextLimitBinding, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .focused($fieldFocused)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(isContextDefault ? .secondary : .primary)
                        .frame(width: 140)
                }
                HStack {
                    Text(L10n.l("max_output_tokens"))
                    Spacer()
                    TextField(vendorMaxOutputText, value: maxOutputBinding, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .focused($fieldFocused)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(isMaxOutputDefault ? .secondary : .primary)
                        .frame(width: 140)
                }
                if draft.deepThinking {
                    LabeledContent(L10n.l("deep_thinking_label")) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(L10n.l("support"))
                        }
                        .foregroundStyle(.green)
                    }
                } else {
                    LabeledContent(L10n.l("deep_thinking_label")) {
                        Text(L10n.l("not_supported"))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text(L10n.l("features"))
            } footer: {
                Text(L10n.l("context_window_and_max_output_leave_blank_or_enter_0_to_use_the_provider_default_once_set_your_values_take_effect_and_actually_constrain_requests"))
            }

            Section {
                Toggle(L10n.l("hidden_model"), isOn: hiddenBinding)
            } header: {
                Text(L10n.l("hide"))
            } footer: {
                Text(L10n.l("once_hidden_this_model_will_not_appear_in_the_model_group_s_model_options_or_the_add_list"))
            }

            Section {
                modalityRow(L10n.l("text_input"), supported: catalogSupportsInput("text"), toggle: $draft.inputText)
                modalityRow(L10n.l("image_input"), supported: catalogSupportsInput("image"), toggle: $draft.inputImage)
                modalityRow(L10n.l("audio_input"), supported: catalogSupportsInput("audio"), toggle: $draft.inputAudio)
                modalityRow(L10n.l("video_input"), supported: catalogSupportsInput("video"), toggle: $draft.inputVideo)
            } header: {
                Text(L10n.l("input_modality"))
            } footer: {
                Text(L10n.l("not_supported_means_the_model_profile_marks_this_model_as_lacking_that_input_capability_matching_attachments_are_skipped_when_sending_text_is_the_universal_baseline_and_is_on_by_default"))
            }

            Section {
                modalityRow(L10n.l("text_output"), supported: catalogSupportsOutput("text"), toggle: $draft.outputText)
                modalityRow(L10n.l("image_output"), supported: catalogSupportsOutput("image"), toggle: $draft.outputImage)
                modalityRow(L10n.l("audio_output"), supported: catalogSupportsOutput("audio"), toggle: $draft.outputAudio)
            } header: {
                Text(L10n.l("output_modality"))
            } footer: {
                Text(L10n.l("models_that_only_support_text_output_are_marked_not_supported_here_so_you_can_tell_the_model_type_at_a_glance_text_is_the_universal_baseline_and_is_on_by_default"))
            }

            Section {
                Button(L10n.l("test")) {
                    showingTestCard = true
                }
                .disabled(
                    draft.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !provider.keyAdded
                )
            } header: {
                Text(L10n.l("test"))
            } footer: {
                if !provider.keyAdded {
                    Text(L10n.l("you_must_save_the_provider_key_before_testing"))
                } else {
                    Text(L10n.l("send_a_simulated_message_and_measure_the_first_token_latency"))
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { fieldFocused = false })
        .navigationTitle(isNew ? L10n.l("add_model") : L10n.l("model_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.l("save")) {
                    var saved = draft
                    let original = initial.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let current = saved.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if current != original {
                        saved.userRenamed = true
                    }
                    onSave?(saved)
                    dismiss()
                }
                .disabled(draft.modelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.l("done")) { fieldFocused = false }
            }
        }
        .sheet(isPresented: $showingTestCard) {
            ModelLatencyTestView(provider: provider, model: draft)
        }
    }

    private var providerName: String {
        provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(
            get: { draft.hidden },
            set: { draft.isHidden = $0 }
        )
    }

    // MARK: - 模型目录能力（厂商默认）

    /// 厂商适配器内置目录条目（可能不存在——未知模型）。
    private var catalogEntry: BuiltinModelInfo? {
        LLMProviderFactory.modelCapabilities(providerType: provider.providerType, modelID: draft.modelId)
    }

    /// 上下文窗口输入框的占位文案：有厂商默认则展示，否则提示未知。
    private var vendorContextText: String {
        if let v = catalogEntry?.contextWindow, v > 0 { return v.formatted(.number.grouping(.never)) }
        return L10n.l("unknown")
    }

    /// 最大输出输入框的占位文案。
    private var vendorMaxOutputText: String {
        if let v = catalogEntry?.maxOutputTokens, v > 0 { return v.formatted(.number.grouping(.never)) }
        return L10n.l("provider_not_provided")
    }

    /// 上下文窗口上限（厂商默认）；档案未标注则不限。
    private var contextLimitCap: Int {
        guard let v = catalogEntry?.contextWindow, v > 0 else { return Int.max }
        return v
    }

    /// 当前上下文窗口是否仍是厂商默认（未自定义）：是则输入框置灰提示“可改”。
    private var isContextDefault: Bool {
        catalogEntry?.contextWindow ?? 0 > 0 && draft.contextLimit == contextLimitCap
    }

    /// 上下文窗口可编辑绑定：clamp 到厂商默认上限（输入不得超过厂商默认）。
    private var contextLimitBinding: Binding<Int> {
        Binding(
            get: { draft.contextLimit },
            set: { draft.contextLimit = min($0, contextLimitCap) }
        )
    }

    /// 最大输出上限（厂商默认）；档案未标注则不限。
    private var maxOutputCap: Int {
        guard let v = catalogEntry?.maxOutputTokens, v > 0 else { return Int.max }
        return v
    }

    /// 当前最大输出是否仍是厂商默认（未自定义）：是则输入框置灰提示“可改”。
    private var isMaxOutputDefault: Bool {
        catalogEntry?.maxOutputTokens ?? 0 > 0 && (draft.maxOutputTokens ?? 0) == maxOutputCap
    }

    /// 最大输出 词元 的可编辑绑定：nil ↔ 0（0 表示未设置、跟随厂商默认）；
    /// 同时 clamp 到厂商默认上限，输入不得超过厂商默认。
    private var maxOutputBinding: Binding<Int> {
        Binding(
            get: { draft.maxOutputTokens ?? 0 },
            set: {
                let clamped = min($0, maxOutputCap)
                draft.maxOutputTokens = clamped > 0 ? clamped : nil
            }
        )
    }

    /// 模型档案是否标注支持某输入模态。返回 nil 表示档案缺失 / 未标注（未知）。
    private func catalogSupportsInput(_ token: String) -> Bool? {
        guard let input = catalogEntry?.input else { return nil }
        if token == "file" { return input.contains("file") || input.contains("document") }
        return input.contains(token)
    }

    /// 模型档案是否标注支持某输出模态。返回 nil 表示未知。
    private func catalogSupportsOutput(_ token: String) -> Bool? {
        guard let output = catalogEntry?.output else { return nil }
        return output.contains(token)
    }

    /// 模态行：档案明确「不支持」→ 只读灰字「不支持」，让用户一眼看清模型类型；
    /// 档案支持或未知 → 保留可编辑开关（未知模型允许用户手动标注）。
    @ViewBuilder
    private func modalityRow(_ title: String, supported: Bool?, toggle: Binding<Bool>) -> some View {
        if supported == false {
            LabeledContent(title) {
                Text(L10n.l("not_supported"))
                    .foregroundStyle(.tertiary)
            }
        } else {
            Toggle(title, isOn: toggle)
        }
    }
}

private struct ModelLatencyTestView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: LLMProvider
    let model: ModelConfig

    @State private var status: TestStatus = .idle
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: status.symbol)
                    .font(.system(size: 42))
                    .foregroundStyle(status.color)

                VStack(spacing: 8) {
                    Text(model.resolvedName)
                        .font(.headline)
                    Text(status.title)
                        .font(.title3.weight(.semibold))
                    Text(status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(status.isRunning ? L10n.l("testing") : L10n.l("start_test")) {
                    runTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.isRunning)
            }
            .padding(28)
            .navigationTitle(L10n.l("model_test"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.l("done")) { dismiss() }
                }
            }
            .onDisappear {
                testTask?.cancel()
            }
        }
        .presentationDetents([.medium])
    }

    @MainActor
    private func runTest() {
        testTask?.cancel()
        status = .running
        let startedAt = Date()

        testTask = Task { @MainActor in
            do {
                let request = try makeTestRequest()
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    status = .failed(L10n.l("invalid_response"))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    status = .failed("HTTP \(http.statusCode)")
                    return
                }

                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty, payload != "[DONE]",
                          let jsonData = payload.data(using: .utf8) else {
                        continue
                    }
                    guard containsOutputText(jsonData) else { continue }
                    let latency = Date().timeIntervalSince(startedAt)
                    status = .success(latency)
                    return
                }
                status = .failed(L10n.l("stream_ended_with_no_output"))
            } catch is CancellationError {
                if case .running = status {
                    status = .failed(L10n.l("test_canceled"))
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func makeTestRequest() throws -> URLRequest {
        let base = provider.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? provider.providerType.defaultBaseURL
            : provider.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw TestError.invalidURL }

        let urlString: String
        // Responses 是否实际生效(与 AppState.makeRouteEndpoint 同源):供应商能力表支持
        // 且 DeepSeek 模型在官方支持列表内,否则自动回落 Chat Completions。
        let usesResponses = provider.apiFormat == .responsesAPI
            && provider.providerType.responsesPath != nil
            && !(provider.providerType == .deepSeek
                 && !DeepSeekProviderAdapter.responsesSupportedModels.contains(model.modelId))
        switch provider.providerType {
        case .google:
            let escapedModel = model.modelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.modelId
            urlString = endpoint("v1beta/models/\(escapedModel):streamGenerateContent", base: base)
                + "?alt=sse&key="
                + (provider.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? provider.apiKey)
        case .anthropic:
            urlString = endpoint("v1/messages", base: base)
        case .openai, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu:
            let path = usesResponses ? provider.providerType.responsesPath! : "v1/chat/completions"
            urlString = endpoint(path, base: base)
        }
        guard let url = URL(string: urlString) else { throw TestError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = "请只回复一个字：好"
        let body: [String: Any]
        switch provider.providerType {
        case .google:
            body = [
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": 8]
            ]
        case .anthropic:
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model.modelId,
                "max_tokens": 8,
                "stream": true,
                "messages": [["role": "user", "content": prompt]]
            ]
        case .openai, .openRouter, .custom, .grok, .deepSeek, .qwen, .xiaomi, .zhipu:
            if provider.azureEnabled {
                request.setValue(provider.apiKey, forHTTPHeaderField: "api-key")
            } else {
                request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
            }
            if usesResponses {
                // OpenAI Responses API 标准测试请求体
                body = [
                    "model": model.modelId,
                    "input": [["role": "user", "content": prompt]],
                    "stream": true,
                    "max_output_tokens": 8
                ]
            } else {
                var chatBody: [String: Any] = [
                    "model": model.modelId,
                    "messages": [["role": "user", "content": prompt]],
                    "stream": true
                ]
                if usesCompletionTokenLimit(model.modelId) {
                    chatBody["max_completion_tokens"] = 8
                } else {
                    chatBody["max_tokens"] = 8
                }
                body = chatBody
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func usesCompletionTokenLimit(_ modelId: String) -> Bool {
        let normalized = modelId.lowercased()
        return normalized.hasPrefix("o1") ||
            normalized.hasPrefix("o3") ||
            normalized.hasPrefix("o4") ||
            normalized.contains("gpt-5")
    }

    private func endpoint(_ path: String, base: String) -> String {
        // 与主链路 AppState.makeRouteEndpoint 同源的规范化：customBaseURL 常带 /v1（官方文档写法），
        // 先剥掉尾部 /v1(/v1/) 再拼统一路径，避免拼出 /v1/v1/... 双段 404
        // （曾因此出现「测试失败而会话正常」——测试与主链路此前拼接规则不一致）。
        var normalized = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/v1/") {
            normalized = String(normalized.dropLast("/v1/".count))
        } else if normalized.hasSuffix("/v1") {
            normalized = String(normalized.dropLast("/v1".count))
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized + "/" + path
    }

    private func containsOutputText(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        return hasOutputText(json)
    }

    private func hasOutputText(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if ["text", "delta", "content", "output_text"].contains(key),
                   let text = child as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                if hasOutputText(child) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: hasOutputText)
        }
        return false
    }

    private enum TestStatus {
        case idle
        case running
        case success(TimeInterval)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
        var symbol: String {
            switch self {
            case .idle: return "stopwatch"
            case .running: return "ellipsis.circle"
            case .success: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .idle, .running: return .blue
            case .success: return .green
            case .failed: return .red
            }
        }
        var title: String {
            switch self {
            case .idle: return L10n.l("first_token_output_test")
            case .running: return L10n.l("waiting_for_first_output")
            case .success(let latency): return String(format: L10n.l("first_token_output_2fs"), latency)
            case .failed: return L10n.l("test_failed")
            }
        }
        var detail: String {
            switch self {
            case .idle: return L10n.l("the_test_will_send_a_minimal_simulated_message_to_the_current_model")
            case .running: return L10n.l("request_sent_measuring_the_first_valid_output")
            case .success: return L10n.l("the_model_has_successfully_returned_its_first_valid_text")
            case .failed(let message): return message
            }
        }
    }

    private enum TestError: LocalizedError {
        case invalidURL
        case http(Int)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .invalidURL: return L10n.l("provider_request_url_invalid")
            case .http(let code): return String(format: L10n.l("provider_returned_http"), String(code))
            case .noOutput: return L10n.l("connection_ended_but_the_model_returned_no_valid_text")
            }
        }
    }
}

// MARK: - 模型行

struct ModelRow: View {
    let model: ModelConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.resolvedName)
                    .font(.body)
                if !model.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(model.modelId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if model.deepThinking {
                Image(systemName: "brain")
                    .foregroundStyle(.purple)
            }
        }
    }
}

// MARK: - 文件导入辅助

private func decodeProviderFile(_ url: URL) -> LLMProvider? {
    guard url.startAccessingSecurityScopedResource() else { return nil }
    defer { url.stopAccessingSecurityScopedResource() }
    do {
        let data = try Data(contentsOf: url)
        var p = try JSONDecoder().decode(LLMProvider.self, from: data)
        p.id = UUID()
        return p
    } catch {
        return nil
    }
}
