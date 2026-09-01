import SwiftUI

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
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
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
        // Responses 是否实际生效(与 AppState.makeRouteEndpoint 同源):供应商能力表支持,
        // 且模型声明 responsesSupported != false(声明数据由 model 插件承载)——
        // 不满足则自动回落 Chat Completions。
        let usesResponses = provider.apiFormat == .responsesAPI
            && provider.providerType.responsesPath != nil
            && PluginModelCatalog.modelCapabilities(providerType: provider.providerType, modelID: model.modelId)?
                .responsesSupported != false
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

        let prompt = L10n.l("connectivity_probe_prompt")
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
