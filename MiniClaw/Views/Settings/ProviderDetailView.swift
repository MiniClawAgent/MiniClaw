import SwiftUI

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
        // 双向删除：供应商由 model 插件导入（sourcePlugin 非空且非内置包）→ 连带删除该插件。
        // 内置包是常驻模板，不随供应商删除。
        if let p = appState.providers.first(where: { $0.id == providerId }),
           let sp = p.sourcePlugin,
           !SkillManager.shared.bundledPluginIds().contains(sp) {
            try? SkillManager.shared.deleteSkill(directoryName: sp)
        }
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
