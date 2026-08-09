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
    @Environment(AppState.self) private var appState
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
                            Text(g.name.isEmpty ? L10n.tr("(未命名组)") : g.name)
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
                    saveGroups(summary: L10n.tr("删除模型组"))
                    saveAssignments(summary: L10n.tr("清理已删除模型组用途"))
                }

                if groups.isEmpty {
                    Button {
                        newNameFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text(L10n.tr("点击创建模型组"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.tr("模型分组"))
            }

            Section {
                HStack {
                    TextField(L10n.tr("新建模型组"), text: $newName)
                        .focused($newNameFocused)
                    Button(L10n.tr("添加")) {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        groups.append(ModelGroup(name: name, modelIds: []))
                        newName = ""
                        saveGroups(summary: L10n.tr("新建模型组"))
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(L10n.tr("模型组即使尚未关联模型也会立即保存。"))
            }

            groupAssignmentsContent
            configuredModelsContent
        }
        .navigationTitle(L10n.tr("模型管理"))
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
                    .accessibilityLabel(L10n.tr("保存"))
                }
            }
        }
        .onAppear {
            groups = SettingsStore.shared.settings.groups
            sessionSettings = SettingsStore.shared.settings.session
            normalizeAssignments()
        }
        .onChange(of: groups) { _ in
            saveGroups(summary: L10n.tr("修改模型组"))
        }
        .onChange(of: sessionSettings) { _ in
            saveAssignments(summary: L10n.tr("修改模型组用途"))
        }
        .onDisappear {
            saveGroups(summary: L10n.tr("保存模型组"))
            saveAssignments(summary: L10n.tr("保存模型组用途"))
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
            modelSlotPicker(L10n.tr("主模型"), selection: $sessionSettings.mainModel, textInAndOutOnly: true)
            modelSlotPicker(L10n.tr("副模型"), selection: $sessionSettings.secondaryModel, textInAndOutOnly: true)
            modelSlotPicker(L10n.tr("语音输入"), selection: $sessionSettings.speechInputModel)
            modelSlotPicker(L10n.tr("语音输出"), selection: $sessionSettings.speechOutputModel)
        } header: {
            Text(L10n.tr("设置分组"))
        } footer: {
            Text(L10n.tr("为不同用途选择模型组或单个模型；选择“无”表示不指定。副模型同时承担标题、记忆、子代理、Embedding 等全部后台任务（子代理自动走副模型，无需单独设置）。"))
        }
    }

    /// 槽位选择器：模型组优先展示，其后为拉取到的单模型（按名称排序）。
    /// `textInAndOutOnly` 为 true 时（主/副模型），单模型列表仅含同时具备文本输入与输出能力的模型；
    /// 为 false 时（语音输入/输出）保留原"文本输入或输出"的宽松过滤。
    private func modelSlotPicker(_ title: String, selection: Binding<ModelSelection>, textInAndOutOnly: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text(L10n.tr("无")).tag(ModelSelection.none)
            if !groups.isEmpty {
                Section(L10n.tr("模型组")) {
                    ForEach(groups) { group in
                        Text(group.name.isEmpty ? L10n.tr("(未命名组)") : group.name)
                            .tag(ModelSelection.group(id: group.id))
                    }
                }
            }
            let models = textInAndOutOnly ? chatModelOptions : textCapableModelOptions
            if !models.isEmpty {
                Section(L10n.tr("单个模型")) {
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
                Text(L10n.tr("尚未添加任何已启用的智能体服务商"))
                    .foregroundStyle(.secondary)
            } else if providersWithModels.isEmpty {
                Text(L10n.tr("已启用的服务商尚未获取模型"))
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
                            .accessibilityLabel(String(format: L10n.tr("调整模型 %@"), model.resolvedName))
                        }
                    } label: {
                        HStack {
                            Text(provider.label.isEmpty ? provider.providerType.defaultLabel : provider.label)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(provider.models.filter { !$0.hidden }.count) " + L10n.tr("个模型"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.tr("模型选项"))
        } footer: {
            Text(L10n.tr("点击模型进入详情页调整参数；默认推理模型请在「模型分组」中设置主模型。"))
        }
    }

    private func groupSummary(_ group: ModelGroup) -> String {
        if !group.entries.isEmpty {
            let names = group.entries.map { entry in
                resolveCompositeKey(entry.compositeKey, in: appState.providers)?.model.resolvedName
                    ?? modelIdFromCompositeKey(entry.compositeKey)
            }
            return names.isEmpty ? L10n.tr("无关联模型") : names.joined(separator: ", ")
        }
        return group.modelIds.isEmpty ? L10n.tr("无关联模型") : group.modelIds.joined(separator: ", ")
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
    @Environment(AppState.self) private var appState
    @Binding var group: ModelGroup
    @State private var showingModelPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var draftName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(L10n.tr("组名称"), text: $draftName)
                    Button(L10n.tr("保存")) {
                        saveGroupName()
                    }
                    .disabled(!canSaveGroupName)
                }
            }
            Section {
                Picker(L10n.tr("路由策略"), selection: $group.strategy) {
                    Text(L10n.tr("故障转移 (fallback)")).tag("fallback")
                    Text(L10n.tr("负载均衡 (loadBalance)")).tag("loadBalance")
                }
                Picker(L10n.tr("降级策略"), selection: $group.fallbackStrategy) {
                    Text(L10n.tr("仅拒绝时 (limited)")).tag("limited")
                    Text(L10n.tr("短暂错误也降级 (always)")).tag("always")
                }
                Picker(L10n.tr("默认思考等级"), selection: $group.defaultThinkingLevel) {
                    Text(L10n.tr("关闭 (off)")).tag("off")
                    Text(L10n.tr("低 (low)")).tag("low")
                    Text(L10n.tr("中 (medium)")).tag("medium")
                    Text(L10n.tr("高 (high)")).tag("high")
                    Text(L10n.tr("超高 (xhigh)")).tag("xhigh")
                    Text(L10n.tr("最大 (max)")).tag("max")
                    Text(L10n.tr("极限 (ultra)")).tag("ultra")
                }
                Stepper(value: $group.contextLimitTokens, in: 0...200000, step: 1000) {
                    Text(group.contextLimitTokens == 0 ? L10n.tr("上下文上限：原生窗口") : String(format: L10n.tr("上下文上限：%@ tokens"), "\(group.contextLimitTokens)"))
                }
            } header: {
                Text(L10n.tr("路由与降级（对齐 spec 9.2.2）"))
            } footer: {
                Text(L10n.tr("上下文上限 0 表示使用模型原生窗口大小。"))
            }
            Section {
                if group.entries.isEmpty {
                    Text(L10n.tr("尚未添加模型"))
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
                                Text(L10n.tr("不可用"))
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
                    Text(L10n.tr("模型 ID 列表"))
                    Spacer()
                    Button {
                        withAnimation { editMode = (editMode == .active) ? .inactive : .active }
                    } label: {
                        Label(editMode == .active ? L10n.tr("完成") : L10n.tr("排序"), systemImage: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                    .disabled(group.entries.isEmpty)
                    Button {
                        showingModelPicker = true
                    } label: {
                        Label(L10n.tr("添加"), systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                    .disabled(availableModels.isEmpty)
                }
            } footer: {
                if availableModels.isEmpty {
                    Text(L10n.tr("请先在智能体服务商中拉取模型。"))
                } else {
                    Text(L10n.tr("点「排序」进入编辑模式可拖动调整优先级；行左滑可移除模型。列表顺序即故障转移（limited）尝试顺序：排在前面的优先使用，失败才按顺序轮换。"))
                }
            }
        }
        .navigationTitle(L10n.tr("编辑组"))
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
            .navigationTitle(L10n.tr("添加模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("添加")) {
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
