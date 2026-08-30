import SwiftUI

private struct ProviderModelSelection: Identifiable {
    let provider: LLMProvider
    let model: ModelConfig
    var id: UUID { model.id }
}

/// 解析 compositeKey（"{providerId}/{modelId}"）为对应的 provider 与 model。
func resolveCompositeKey(
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
func modelIdFromCompositeKey(_ compositeKey: String) -> String {
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
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
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
// MARK: - 会话设置 / 语音（入口已从设置主页移除，相关结构体删除；数据域 session/speech 仍保留由 ConfigTool 等使用）

// (DefaultsSettingsView 已并入 通用设置 GeneralSettingsView 的「默认行为」段)
