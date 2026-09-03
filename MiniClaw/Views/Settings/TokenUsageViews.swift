import SwiftUI

// MARK: - Token Usage

struct TokenUsageView: View {
    @State private var todayInput: Int = 0
    @State private var todayOutput: Int = 0
    @State private var monthInput: Int = 0
    @State private var monthOutput: Int = 0
    @State private var totalInput: Int = 0
    @State private var totalOutput: Int = 0
    @State private var totalCachedRead: Int = 0
    @State private var totalCachedWrite: Int = 0
    @State private var providerSections: [ProviderUsageSection] = []
    @State private var showResetConfirm: Bool = false

    var body: some View {
        List {
            if !TokenUsageTracker.hasData() {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(L10n.l("no_usage_data_yet"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(L10n.l("your_token_usage_accumulates_here_after_you_start_a_conversation"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }

            Section(L10n.l("total_usage")) {
                UsageRow(label: L10n.l("total_input_incl_cache"), value: compact(totalInput), color: .blue)
                UsageRow(label: L10n.l("total_output"), value: compact(totalOutput), color: .green)
                UsageRow(label: L10n.l("cache_reads"), value: compact(totalCachedRead), color: .purple)
                UsageRow(label: L10n.l("cache_hit_rate"), value: hitRateString, color: .orange)
            }

            Section(L10n.l("recent_usage")) {
                UsageRow(label: L10n.l("today_s_input"), value: compact(todayInput), color: .blue)
                UsageRow(label: L10n.l("today_s_output"), value: compact(todayOutput), color: .green)
                UsageRow(label: L10n.l("input_this_month"), value: compact(monthInput), color: .blue)
                UsageRow(label: L10n.l("this_month_output"), value: compact(monthOutput), color: .green)
            }

            ForEach(providerSections) { section in
                Section(section.label) {
                    ForEach(section.models) { row in
                        HStack {
                            Text(row.name)
                                .font(.body)
                            Spacer()
                            Text("\(compact(row.input))/\(compact(row.output))")
                                .foregroundStyle(.secondary)
                                .fontWeight(.medium)
                        }
                    }
                }
            }

            Section {
                Button(L10n.l("reset_statistics"), role: .destructive) {
                    showResetConfirm = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(!TokenUsageTracker.hasData())
            } footer: {
                Text(L10n.l("data_from_real_conversations_accumulated_across_sessions_cache_hit_rate_cache_reads_total_input_including_cache_when_a_provider_doesn_t_report_usage_in_streaming_responses_a_local_estimate_is_used_1_6_cjk_chars_token_4_latin_chars_token"))
                    .font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("token_usage_alias"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .alert(L10n.l("reset_token_statistics"), isPresented: $showResetConfirm) {
            Button(L10n.l("cancel"), role: .cancel) {}
            Button(L10n.l("reset"), role: .destructive) {
                TokenUsageTracker.reset()
                reload()
            }
        } message: {
            Text(L10n.l("this_will_clear_all_token_usage_records_including_total_usage_provider_breakdown_and_recent_stats_this_action_cannot_be_undone"))
        }
    }

    private var hitRateString: String {
        guard totalInput > 0 else { return "—" }
        let rate = Double(totalCachedRead) / Double(totalInput) * 100
        return String(format: "%.1f%%", rate)
    }

    private func reload() {
        let today = TokenUsageTracker.today()
        todayInput = today.input
        todayOutput = today.output
        let month = TokenUsageTracker.month()
        monthInput = month.input
        monthOutput = month.output

        let totals = TokenUsageTracker.globalTotals()
        totalInput = totals.input
        totalOutput = totals.output
        totalCachedRead = totals.cachedRead
        totalCachedWrite = totals.cachedWrite

        // 建立 modelId -> (服务商标签, 显示名) 映射，用于按厂商分组。
        let providers = MainActor.assumeIsolated { AppState.shared.providers }
        var info: [String: (provider: String, name: String)] = [:]
        for p in providers {
            let label = p.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? p.providerType.defaultLabel
                : p.label
            for m in p.models {
                info[m.modelId] = (label, m.resolvedName)
            }
        }

        var grouped: [String: [(name: String, input: Int, output: Int)]] = [:]
        for row in TokenUsageTracker.byModel() {
            let provider = info[row.model]?.provider ?? L10n.l("others")
            let name = info[row.model]?.name ?? ModelConfig.titleCasedModelId(row.model)
            grouped[provider, default: []].append((name: name, input: row.input, output: row.output))
        }

        // 厂商顺序：AppState.providers 中出现的顺序优先，其余按名称排序。
        var ordered: [ProviderUsageSection] = []
        let knownOrder = providers.map { p in
            p.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p.providerType.defaultLabel : p.label
        }
        for label in knownOrder where grouped[label] != nil {
            let models = grouped.removeValue(forKey: label)!
                .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
                .map { ProviderModelRow(name: $0.name, input: $0.input, output: $0.output) }
            ordered.append(ProviderUsageSection(label: label, models: models))
        }
        for label in grouped.keys.sorted() {
            let models = grouped[label]!
                .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
                .map { ProviderModelRow(name: $0.name, input: $0.input, output: $0.output) }
            ordered.append(ProviderUsageSection(label: label, models: models))
        }
        providerSections = ordered
    }

    /// 紧凑计数格式：如 12.3M / 140.6k / 950。
    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

/// 按厂商聚合的 词元 用量分区（用于设置 → 词元 用量）。
struct ProviderUsageSection: Identifiable {
    var id: String { label }
    let label: String
    let models: [ProviderModelRow]
}

struct ProviderModelRow: Identifiable {
    var id: String { name }
    let name: String
    let input: Int
    let output: Int
}

// MARK: - 会话 词元 用量

/// 单会话的 词元 用量明细（从 AppSettings.sessionTokenUsage 读取）。
struct SessionTokenUsageView: View {
    let session: ChatSession
    @State private var data: SessionTokenUsageData?
    @Environment(\.dismiss) private var dismiss
    /// 订阅快照仓库：裸读单例不建立依赖，引擎写入后 UI 不会刷新。
    @ObservedObject private var contextStore = ContextUsageStore.shared

    /// 当前上下文占用快照（引擎实时写入）：这里展示的是「下一次请求会占多少窗口」，
    /// 与右上角圆环、以及引擎的压缩判定同一份数据。
    private var contextSnapshot: ContextUsageSnapshot? {
        contextStore.snapshot(for: session.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = contextSnapshot, snapshot.tokens > 0 {
                    contextSection(snapshot)
                }
                if let d = data {
                    if contextSnapshot == nil || contextSnapshot?.tokens == 0 {
                        Section(L10n.l("context")) {
                            UsageRow(label: L10n.l("context_used"), value: compact(d.input), color: .blue)
                            UsageRow(label: L10n.l("context_window"), value: windowString, color: .gray)
                        }
                    }

                    Section(L10n.l("tokens_session_total")) {
                        UsageRow(label: L10n.l("input_with_cache"), value: compact(d.input), color: .blue)
                        UsageRow(label: L10n.l("output"), value: compact(d.output), color: .green)
                    }

                    Section(L10n.l("cache_session_total")) {
                        UsageRow(label: L10n.l("cache_reads"), value: compact(d.cachedRead ?? 0), color: .purple)
                        UsageRow(label: L10n.l("cache_write"), value: compact(d.cachedWrite ?? 0), color: .indigo)
                        UsageRow(label: L10n.l("cache_hit_rate"), value: sessionHitRate(d), color: .orange)
                    }

                    Section(L10n.l("speed")) {
                        UsageRow(label: L10n.l("output_speed_average"), value: speedString(d), color: .teal)
                    }

                    Section(L10n.l("agent_loop")) {
                        UsageRow(label: L10n.l("total_loop_count"), value: "\(d.agentLoops)", color: .red)
                    }
                } else {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(L10n.l("no_usage_data_for_this_session_yet"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(L10n.l("after_starting_a_conversation_this_will_accumulate_the_session_s_token_usage"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeBackground(slot: .settings))
            .navigationTitle(L10n.l("session_token_usage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.l("done")) { dismiss() }
                }
            }
            .onAppear(perform: reload)
        }
    }

    /// 上下文占用明细区块（对标 /context 拆解）：
    /// 让用户看清窗口被谁吃掉了——系统提示词、工具定义、历史、本轮输入、图片附件。
    @ViewBuilder
    private func contextSection(_ s: ContextUsageSnapshot) -> some View {
        Section {
            UsageRow(
                label: L10n.l("current_usage"),
                value: s.isUnlimited ? compact(s.tokens) : "\(compact(s.tokens)) / \(compact(s.window))（\(Int(s.ratio * 100))%）",
                color: s.ratio >= s.thresholdRatio ? .red : (s.ratio >= s.thresholdRatio * 0.8 ? .orange : .green)
            )
            if !s.isUnlimited, s.compactThreshold > 0 {
                UsageRow(
                    label: L10n.l("compaction_trigger_line"),
                    value: "\(compact(s.compactThreshold))（\(Int(s.thresholdRatio * 100))%）",
                    color: .gray
                )
            }
            UsageRow(label: L10n.l("system_prompt"), value: compact(s.breakdown.system), color: .purple)
            UsageRow(label: L10n.l("tool_definitions"), value: compact(s.breakdown.tools), color: .indigo)
            UsageRow(label: L10n.l("history_chats"), value: compact(s.breakdown.history), color: .blue)
            UsageRow(label: L10n.l("this_turn_input"), value: compact(s.breakdown.current), color: .teal)
            if s.breakdown.media > 0 {
                UsageRow(label: L10n.l("images_attachments"), value: compact(s.breakdown.media), color: .pink)
            }
            if !s.isUnlimited {
                UsageRow(label: L10n.l("remaining"), value: compact(max(0, s.window - s.tokens)), color: .gray)
            }
        } header: {
            Text(L10n.l("context_usage_label"))
        } footer: {
            Text(s.measured
                 ? L10n.l("data_from_real_usage_reported_by_the_provider")
                 : L10n.l("local_estimate_shown_when_the_provider_doesn_t_report_usage_based_on_calibrated_estimates"))
        }
    }

    private var windowString: String {
        compact(contextWindow(for: session))
    }

    private func sessionHitRate(_ d: SessionTokenUsageData) -> String {
        guard d.input > 0 else { return "—" }
        let cr = d.cachedRead ?? 0
        return String(format: "%.1f%%", Double(cr) / Double(d.input) * 100)
    }

    private func speedString(_ d: SessionTokenUsageData) -> String {
        guard d.outputDurationMs > 0, d.output > 0 else { return "—" }
        let tps = Double(d.output) / (d.outputDurationMs / 1000)
        return String(format: "%.1f tok/s", tps)
    }

    private func reload() {
        data = TokenUsageTracker.sessionUsage(session.id)
    }

    /// 解析本会话模型对应的上下文窗口（词元）。优先按会话 modelName 匹配已配置模型，
    /// 否则回退到当前活动模型，最后回退到常见默认 128K。
    private func contextWindow(for session: ChatSession) -> Int {
        let providers = MainActor.assumeIsolated { AppState.shared.providers }
        for p in providers {
            if let m = p.models.first(where: {
                $0.resolvedName == session.modelName || $0.modelId == session.modelName
            }), m.contextLimit > 0 {
                return m.contextLimit
            }
        }
        if let (_, m) = MainActor.assumeIsolated({ AppState.shared.resolveActiveEndpoint() }), m.contextLimit > 0 {
            return m.contextLimit
        }
        return 128_000
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct UsageRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
