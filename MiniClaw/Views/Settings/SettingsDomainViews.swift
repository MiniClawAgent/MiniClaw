import SwiftUI

private struct ProviderModelSelection: Identifiable {
    let provider: LLMProvider
    let model: ModelConfig
    var id: UUID { model.id }
}

/// 解析 compositeKey（"{providerId}/{modelId}"）为对应的 provider 与 model。
private func resolveCompositeKey(
    _ compositeKey: String,
    in providers: [LLMProvider]
) -> (provider: LLMProvider, model: ModelConfig)? {
    let parts = compositeKey.split(separator: "/", maxSplits: 1)
    guard parts.count == 2,
          let providerId = UUID(uuidString: String(parts[0])) else { return nil }
    let modelId = String(parts[1])
    guard let provider = providers.first(where: { $0.id == providerId }),
          let model = provider.models.first(where: { $0.modelId == modelId }) else { return nil }
    return (provider, model)
}

/// 从 compositeKey（"{providerId}/{modelId}"）中提取 modelId 部分。
private func modelIdFromCompositeKey(_ compositeKey: String) -> String {
    let parts = compositeKey.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : compositeKey
}

// MARK: - 模型组 (groups)

struct GroupsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// 关闭回调：仅当以全屏封面（如会话页点击模型名）弹出时由调用方传入；
    /// 在「设置」页通过 NavigationLink 进入时为 nil，沿用系统返回按钮。
    var dismissAction: (() -> Void)? = nil
    @State private var groups: [ModelGroup] = SettingsStore.shared.settings.groups
    @State private var sessionSettings: SessionSettings = SettingsStore.shared.settings.session
    @State private var expandedProviderIds: Set<UUID> = []
    @State private var editingProviderModel: ProviderModelSelection?
    @State private var newName: String = ""
    @FocusState private var newNameFocused: Bool

    var body: some View {
        List {
            Section {
                ForEach($groups) { $g in
                    NavigationLink {
                        ModelGroupEditView(group: $g)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name.isEmpty ? L10n.l("unnamed_group") : g.name)
                                .font(.headline)
                            Text(groupSummary(g))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { idx in
                    let deletedIds = Set(idx.map { groups[$0].id })
                    groups.remove(atOffsets: idx)
                    clearDeletedAssignments(deletedIds)
                    saveGroups(summary: L10n.l("delete_model_group"))
                    saveAssignments(summary: L10n.l("clear_deleted_model_group_assignments"))
                }

                if groups.isEmpty {
                    Button {
                        newNameFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text(L10n.l("tap_to_create_model_group"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.l("model_group"))
            }

            Section {
                HStack {
                    TextField(L10n.l("new_model_group"), text: $newName)
                        .focused($newNameFocused)
                    Button(L10n.l("add")) {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        groups.append(ModelGroup(name: name, modelIds: []))
                        newName = ""
                        saveGroups(summary: L10n.l("new_model_group"))
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(L10n.l("a_model_group_is_saved_immediately_even_if_no_models_are_linked_yet"))
            }

            groupAssignmentsContent
            configuredModelsContent
        }
        .navigationTitle(L10n.l("model_management"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 弹出场景（首页/会话页顶部点击）：保存由 onChange/onDisappear 自动完成，
            // 右上「勾」= 保存并退出；设置页内嵌场景保留系统返回，不显示勾。
            if dismissAction != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissAction?()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(L10n.l("save"))
                }
            }
        }
        .onAppear {
            groups = SettingsStore.shared.settings.groups
            sessionSettings = SettingsStore.shared.settings.session
            normalizeAssignments()
        }
        .onChange(of: groups) { _ in
            saveGroups(summary: L10n.l("edit_model_group"))
        }
        .onChange(of: sessionSettings) { _ in
            saveAssignments(summary: L10n.l("edit_model_group_assignment"))
        }
        .onDisappear {
            saveGroups(summary: L10n.l("save_model_group"))
            saveAssignments(summary: L10n.l("save_model_group_assignment"))
        }
        .sheet(item: $editingProviderModel) { selection in
            NavigationStack {
                CustomModelEditorView(
                    initial: selection.model,
                    provider: selection.provider,
                    isNew: false
                ) { updated in
                    appState.updateProviders { providers in
                        guard let providerIndex = providers.firstIndex(where: { $0.id == selection.provider.id }),
                              let modelIndex = providers[providerIndex].models.firstIndex(where: { $0.id == updated.id }) else {
                            return
                        }
                        providers[providerIndex].models[modelIndex] = updated
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupAssignmentsContent: some View {
        Section {
            modelSlotPicker(L10n.l("primary_model"), selection: $sessionSettings.mainModel, textInAndOutOnly: true)
            modelSlotPicker(L10n.l("sub_model"), selection: $sessionSettings.secondaryModel, textInAndOutOnly: true)
            modelSlotPicker(L10n.l("voice_input"), selection: $sessionSettings.speechInputModel)
            modelSlotPicker(L10n.l("voice_output"), selection: $sessionSettings.speechOutputModel)
        } header: {
            Text(L10n.l("settings_group"))
        } footer: {
            Text(L10n.l("choose_a_model_group_or_a_single_model_per_purpose_none_means_unspecified_the_secondary_model_also_handles_all_background_tasks_titles_memory_subagents_embedding_etc_subagents_automatically_use_the_secondary_model_no_separate_setup_needed"))
        }
    }

    /// 槽位选择器：模型组优先展示，其后为拉取到的单模型（按名称排序）。
    /// `textInAndOutOnly` 为 true 时（主/副模型），单模型列表仅含同时具备文本输入与输出能力的模型；
    /// 为 false 时（语音输入/输出）保留原"文本输入或输出"的宽松过滤。
    private func modelSlotPicker(_ title: String, selection: Binding<ModelSelection>, textInAndOutOnly: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text(L10n.l("none")).tag(ModelSelection.none)
            if !groups.isEmpty {
                Section(L10n.l("model_groups")) {
                    ForEach(groups) { group in
                        Text(group.name.isEmpty ? L10n.l("unnamed_group") : group.name)
                            .tag(ModelSelection.group(id: group.id))
                    }
                }
            }
            let models = textInAndOutOnly ? chatModelOptions : textCapableModelOptions
            if !models.isEmpty {
                Section(L10n.l("individual_models")) {
                    ForEach(models, id: \.tag) { option in
                        Text(option.title).tag(option.tag)
                    }
                }
            }
        }
    }

    /// 所有启用服务商下、具备文本输入或输出能力的可见模型，按名称排序（用于语音输入/输出槽位）。
    private var textCapableModelOptions: [(title: String, tag: ModelSelection)] {
        var options: [(title: String, tag: ModelSelection)] = []
        let enabledProviders = appState.providers.filter { $0.isEnabled }
        let showProviderLabel = enabledProviders.count > 1
        for provider in enabledProviders {
            let providerLabel = provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label
            for model in provider.models where !model.hidden && (model.inputText || model.outputText) {
                let title = showProviderLabel
                    ? "\(model.resolvedName)（\(providerLabel)）"
                    : model.resolvedName
                options.append((title, .model(compositeKey: "\(provider.id.uuidString)/\(model.modelId)")))
            }
        }
        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 所有启用服务商下、同时具备文本输入与文本输出能力的可见模型，按名称排序（用于主/副模型槽位）。
    private var chatModelOptions: [(title: String, tag: ModelSelection)] {
        var options: [(title: String, tag: ModelSelection)] = []
        let enabledProviders = appState.providers.filter { $0.isEnabled }
        let showProviderLabel = enabledProviders.count > 1
        for provider in enabledProviders {
            let providerLabel = provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label
            for model in provider.models where !model.hidden && model.inputText && model.outputText {
                let title = showProviderLabel
                    ? "\(model.resolvedName)（\(providerLabel)）"
                    : model.resolvedName
                options.append((title, .model(compositeKey: "\(provider.id.uuidString)/\(model.modelId)")))
            }
        }
        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder
    private var configuredModelsContent: some View {
        let enabledProviders = appState.providers.filter { $0.isEnabled }
        let providersWithModels = enabledProviders.filter { provider in
            provider.models.contains(where: { !$0.hidden })
        }

        Section {
            if enabledProviders.isEmpty {
                Text(L10n.l("no_enabled_providers_yet"))
                    .foregroundStyle(.secondary)
            } else if providersWithModels.isEmpty {
                Text(L10n.l("enabled_providers_have_not_fetched_models_yet"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providersWithModels) { provider in
                    DisclosureGroup(
                        isExpanded: providerExpansionBinding(provider.id)
                    ) {
                        let visibleModels = provider.models.filter { !$0.hidden }
                            .sorted { $0.resolvedName.localizedStandardCompare($1.resolvedName) == .orderedAscending }
                        ForEach(visibleModels) { model in
                            Button {
                                editingProviderModel = ProviderModelSelection(
                                    provider: provider,
                                    model: model
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.resolvedName)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if !model.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                                            Text(model.modelId)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: L10n.l("adjust_model"), model.resolvedName))
                        }
                    } label: {
                        HStack {
                            Text(provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(provider.models.filter { !$0.hidden }.count) " + L10n.l("model_count_suffix"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.l("model_options"))
        } footer: {
            Text(L10n.l("tap_a_model_to_open_its_detail_page_and_adjust_parameters_set_the_default_inference_model_as_the_main_model_in_model_groups"))
        }
    }

    private func groupSummary(_ group: ModelGroup) -> String {
        if !group.entries.isEmpty {
            let names = group.entries.map { entry in
                resolveCompositeKey(entry.compositeKey, in: appState.providers)?.model.resolvedName
                    ?? modelIdFromCompositeKey(entry.compositeKey)
            }
            return names.isEmpty ? L10n.l("no_associated_model") : names.joined(separator: ", ")
        }
        return group.modelIds.isEmpty ? L10n.l("no_associated_model") : group.modelIds.joined(separator: ", ")
    }

    private func providerExpansionBinding(_ providerId: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedProviderIds.contains(providerId) },
            set: { isExpanded in
                if isExpanded {
                    expandedProviderIds.insert(providerId)
                } else {
                    expandedProviderIds.remove(providerId)
                }
            }
        )
    }

    private func clearDeletedAssignments(_ deletedIds: Set<UUID>) {
        func clear(_ selection: inout ModelSelection) {
            if let id = selection.groupId, deletedIds.contains(id) {
                selection = .none
            }
        }
        clear(&sessionSettings.mainModel)
        clear(&sessionSettings.secondaryModel)
        clear(&sessionSettings.speechInputModel)
        clear(&sessionSettings.speechOutputModel)
    }

    private func normalizeAssignments() {
        let validGroupIds = Set(groups.map(\.id))
        func normalize(_ selection: inout ModelSelection) {
            switch selection {
            case .none:
                break
            case .group(let id):
                if !validGroupIds.contains(id) { selection = .none }
            case .model(let compositeKey):
                let exists = resolveCompositeKey(compositeKey, in: appState.providers) != nil
                if !exists { selection = .none }
            }
        }
        normalize(&sessionSettings.mainModel)
        normalize(&sessionSettings.secondaryModel)
        normalize(&sessionSettings.speechInputModel)
        normalize(&sessionSettings.speechOutputModel)
    }

    private func saveGroups(summary: String) {
        guard SettingsStore.shared.settings.groups != groups else { return }
        SettingsStore.shared.set(
            groups,
            domain: .groups,
            summary: summary
        )
    }

    private func saveAssignments(summary: String) {
        let current = SettingsStore.shared.settings.session
        guard current.mainModel != sessionSettings.mainModel ||
                current.secondaryModel != sessionSettings.secondaryModel ||
                current.speechInputModel != sessionSettings.speechInputModel ||
                current.speechOutputModel != sessionSettings.speechOutputModel else {
            return
        }
        SettingsStore.shared.update(
            domain: .session,
            summary: summary
        ) { (settings: inout SessionSettings) in
            settings.mainModel = sessionSettings.mainModel
            settings.secondaryModel = sessionSettings.secondaryModel
            settings.speechInputModel = sessionSettings.speechInputModel
            settings.speechOutputModel = sessionSettings.speechOutputModel
        }
    }
}

struct ModelGroupEditView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var group: ModelGroup
    @State private var showingModelPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var draftName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(L10n.l("group_name"), text: $draftName)
                    Button(L10n.l("save")) {
                        saveGroupName()
                    }
                    .disabled(!canSaveGroupName)
                }
            }
            Section {
                Picker(L10n.l("routing_strategy"), selection: $group.strategy) {
                    Text(L10n.l("failover_fallback")).tag("fallback")
                    Text(L10n.l("load_balancing_loadbalance")).tag("loadBalance")
                }
                Picker(L10n.l("degradation_strategy"), selection: $group.fallbackStrategy) {
                    Text(L10n.l("on_decline_only_limited")).tag("limited")
                    Text(L10n.l("downgrade_even_on_transient_errors_always")).tag("always")
                }
                Picker(L10n.l("default_thinking_level"), selection: $group.defaultThinkingLevel) {
                    Text(L10n.l("off")).tag("off")
                    Text(L10n.l("level_low_display")).tag("low")
                    Text(L10n.l("level_medium_display")).tag("medium")
                    Text(L10n.l("high_high")).tag("high")
                    Text(L10n.l("ultra_high")).tag("xhigh")
                    Text(L10n.l("maximum_value")).tag("max")
                    Text(L10n.l("extreme_ultra")).tag("ultra")
                }
                Stepper(value: $group.contextLimitTokens, in: 0...200000, step: 1000) {
                    Text(group.contextLimitTokens == 0 ? L10n.l("context_limit_native_window") : String(format: L10n.l("context_limit_tokens"), "\(group.contextLimitTokens)"))
                }
            } header: {
                Text(L10n.l("routing_and_fallback_aligned_with_spec_9_2_2"))
            } footer: {
                Text(L10n.l("a_context_limit_of_0_means_using_the_model_s_native_window_size"))
            }
            Section {
                if group.entries.isEmpty {
                    Text(L10n.l("no_models_added_yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($group.entries) { $entry in
                        HStack(spacing: 12) {
                            Image(systemName: "cpu")
                                .foregroundStyle(Color(red: 0.098, green: 0.549, blue: 0.996))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(modelDisplayName(for: entry))
                                    .foregroundStyle(.primary)
                                if modelDisplayName(for: entry) != modelIdFromCompositeKey(entry.compositeKey) {
                                    Text(modelIdFromCompositeKey(entry.compositeKey))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !isEntryAvailable(entry) {
                                Text(L10n.l("unavailable"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        group.entries.remove(atOffsets: indexSet)
                        syncLegacyModelIds()
                    }
                    .onMove { from, to in
                        group.entries.move(fromOffsets: from, toOffset: to)
                        syncLegacyModelIds()
                    }
                }
            } header: {
                HStack {
                    Text(L10n.l("model_id_list"))
                    Spacer()
                    Button {
                        withAnimation { editMode = (editMode == .active) ? .inactive : .active }
                    } label: {
                        Label(editMode == .active ? L10n.l("done") : L10n.l("sort"), systemImage: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                    .disabled(group.entries.isEmpty)
                    Button {
                        showingModelPicker = true
                    } label: {
                        Label(L10n.l("add"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                    .disabled(availableModels.isEmpty)
                }
            } footer: {
                if availableModels.isEmpty {
                    Text(L10n.l("fetch_models_from_a_provider_first"))
                } else {
                    Text(L10n.l("tap_sort_to_enter_edit_mode_and_drag_to_adjust_priority_swipe_left_on_a_row_to_remove_a_model_the_list_order_is_the_failover_limited_attempt_order_earlier_entries_are_tried_first_and_only_on_failure_does_it_move_down_the_list"))
                }
            }
        }
        .navigationTitle(L10n.l("edit_group"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .onAppear {
            draftName = group.name
            migrateLegacyEntriesIfNeeded()
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelGroupModelPicker(
                providers: availableProviders,
                selectedModelIds: Set(resolvedGroupEntries.compactMap { entry in
                    resolveCompositeKey(entry.compositeKey, in: availableProviders)?.model.id
                })
            ) { selectedIds in
                appendModels(selectedIds)
            }
        }
    }

    private var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveGroupName: Bool {
        !trimmedDraftName.isEmpty && trimmedDraftName != group.name
    }

    private func saveGroupName() {
        guard canSaveGroupName else { return }
        group.name = trimmedDraftName
        draftName = group.name
    }

    private var availableProviders: [LLMProvider] {
        appState.providers.compactMap { provider in
            guard provider.isEnabled else { return nil }
            var visibleProvider = provider
            visibleProvider.models = provider.models.filter { !$0.hidden }
            return visibleProvider.models.isEmpty ? nil : visibleProvider
        }
    }

    private var availableModels: [ModelConfig] {
        availableProviders.flatMap(\.models)
    }

    /// 该条目当前是否可用于路由（服务商启用且已加 Key、模型未隐藏）。
    private func isEntryAvailable(_ entry: ModelGroupEntry) -> Bool {
        guard let resolved = resolveCompositeKey(entry.compositeKey, in: appState.providers) else { return false }
        return resolved.provider.isEnabled && resolved.provider.keyAdded && !resolved.model.hidden
    }

    /// entries 成为真实顺序后，同步旧版 modelIds 字段（仅兼容用途）。
    private func syncLegacyModelIds() {
        group.modelIds = group.entries.map { modelIdFromCompositeKey($0.compositeKey) }
    }

    /// 旧版仅填 modelIds 的组：进入编辑时把 entries 补全，使列表可重排。
    private func migrateLegacyEntriesIfNeeded() {
        guard group.entries.isEmpty, !group.modelIds.isEmpty else { return }
        var entries: [ModelGroupEntry] = []
        for modelId in group.modelIds {
            if let provider = appState.providers.first(where: { $0.models.contains { $0.modelId == modelId } }),
               let model = provider.models.first(where: { $0.modelId == modelId }) {
                entries.append(ModelGroupEntry(compositeKey: "\(provider.id.uuidString)/\(model.modelId)"))
            }
        }
        if !entries.isEmpty {
            group.entries = entries
            syncLegacyModelIds()
        }
    }

    private var resolvedGroupEntries: [ModelGroupEntry] {
        if !group.entries.isEmpty { return group.entries }
        return group.modelIds.compactMap { modelId in
            for provider in availableProviders {
                if let model = provider.models.first(where: { $0.modelId == modelId }) {
                    return ModelGroupEntry(compositeKey: "\(provider.id.uuidString)/\(model.modelId)")
                }
            }
            return nil
        }
    }

    private func modelDisplayName(for entry: ModelGroupEntry) -> String {
        resolveCompositeKey(entry.compositeKey, in: availableProviders)?.model.resolvedName
            ?? modelIdFromCompositeKey(entry.compositeKey)
    }

    private func appendModels(_ selectedIds: Set<UUID>) {
        var entries = resolvedGroupEntries
        var seen = Set(entries.map(\.compositeKey))
        for provider in availableProviders {
            for model in provider.models where selectedIds.contains(model.id) {
                let key = "\(provider.id.uuidString)/\(model.modelId)"
                if seen.insert(key).inserted {
                    entries.append(ModelGroupEntry(compositeKey: key))
                }
            }
        }
        group.entries = entries
        group.modelIds = []
    }
}

private struct ModelGroupModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let providers: [LLMProvider]
    let initiallySelectedModelIds: Set<UUID>
    let onAdd: (Set<UUID>) -> Void

    @State private var selectedModelIds: Set<UUID>

    init(
        providers: [LLMProvider],
        selectedModelIds: Set<UUID>,
        onAdd: @escaping (Set<UUID>) -> Void
    ) {
        self.providers = providers
        self.initiallySelectedModelIds = selectedModelIds
        self.onAdd = onAdd
        _selectedModelIds = State(initialValue: [])
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(providers) { provider in
                    let chatModels = provider.models.filter { $0.inputText && $0.outputText }
                    if !chatModels.isEmpty {
                        Section(provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label) {
                            ForEach(chatModels) { model in
                                Button {
                                    toggle(model.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.resolvedName)
                                                .foregroundStyle(.primary)
                                            if !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Text(model.modelId)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: isSelected(model.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected(model.id) ? Color(red: 0.098, green: 0.549, blue: 0.996) : .secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(initiallySelectedModelIds.contains(model.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.l("add_model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.l("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.l("add")) {
                        onAdd(selectedModelIds)
                        dismiss()
                    }
                    .disabled(selectedModelIds.isEmpty)
                }
            }
        }
    }

    private func isSelected(_ modelId: UUID) -> Bool {
        initiallySelectedModelIds.contains(modelId) || selectedModelIds.contains(modelId)
    }

    private func toggle(_ modelId: UUID) {
        guard !initiallySelectedModelIds.contains(modelId) else { return }
        if selectedModelIds.contains(modelId) {
            selectedModelIds.remove(modelId)
        } else {
            selectedModelIds.insert(modelId)
        }
    }
}

// MARK: - 会话设置 / 语音（入口已从设置主页移除，相关结构体删除；数据域 session/speech 仍保留由 ConfigTool 等使用）

// (DefaultsSettingsView 已并入 通用设置 GeneralSettingsView 的「默认行为」段)
