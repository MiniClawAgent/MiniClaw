import SwiftUI

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
