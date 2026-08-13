import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MiniClawKit

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让所有 `L10n.tr` 文案（含语言 Picker 的「语言」标签、footer 说明等）以新语言重新求值。
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: ColorSchemePreference = .system
    @State private var chat: ChatSettings = SettingsStore.shared.settings.chat

    var body: some View {
        List {
            Section {
                ForEach(ColorSchemePreference.allCases, id: \.self) { pref in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: pref))
                                .font(.body)
                            Text(subtitle(for: pref))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == pref {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = pref
                        withAnimation(.easeInOut(duration: 0.35)) {
                            appState.colorSchemePreference = pref
                        }
                    }
                }
            } header: {
                Text(L10n.l("appearance_mode"))
            } footer: {
                Text(L10n.l("choose_light_dark_or_follow_system_settings_changes_apply_immediately"))
            }

            Section {
                Picker(selection: $appState.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                } label: {
                    Text(L10n.l("language"))
                }
            } footer: {
                Text(L10n.l("change_the_interface_display_language_applies_immediately"))
            }

            Section {
                Picker(selection: $chat.codeBlockTheme) {
                    Text(L10n.l("system")).tag("auto")
                    Text(L10n.l("light")).tag("light")
                    Text(L10n.l("dark")).tag("dark")
                } label: {
                    Text(L10n.l("code_block_theme"))
                }
            } header: {
                Text(L10n.l("chat_display"))
            }
        }
        .navigationTitle(L10n.l("appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selection = appState.colorSchemePreference
            // 重新进入时从持久化源同步聊天显示设置，避免缓存视图 @State 停留旧值。
            chat = SettingsStore.shared.settings.chat
        }
        .onChange(of: chat) { _ in saveChat() }
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: L10n.l("edit_appearance_chat_display"))
    }

    private func title(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return L10n.l("system")
        case .dark:   return L10n.l("dark")
        case .light:  return L10n.l("light")
        }
    }

    private func subtitle(for pref: ColorSchemePreference) -> String {
        switch pref {
        case .system: return L10n.l("match_ios_system_settings")
        case .dark: return L10n.l("always_use_dark_interface")
        case .light: return L10n.l("always_use_light_interface")
        }
    }
}

// MARK: - Sync Settings

struct SyncSettingsView: View {
    @State private var iCloudEnabled: Bool = false
    @State private var autoSync: Bool = true
    @State private var lastSyncDate: Date?
    @State private var isSyncing: Bool = false
    @State private var accountStatus: String = ""
    @State private var totalSent: Int = 0
    @State private var totalReceived: Int = 0

    var body: some View {
        List {
            Section {
                Toggle(L10n.l("icloud_sync"), isOn: $iCloudEnabled)
                    .onChange(of: iCloudEnabled) { newValue in
                        SettingsStore.shared.update(domain: .sync, summary: L10n.l("modify_sync_settings")) { (config: inout SyncConfig) in
                            config.iCloudEnabled = newValue
                        }
                        if newValue {
                            checkAccountStatus()
                            SyncBootstrap.startIfNeeded()
                        } else {
                            SyncCore.shared.stop()
                        }
                    }
                if iCloudEnabled {
                    Toggle(L10n.l("auto_sync"), isOn: $autoSync)
                }
            } footer: {
                Text(L10n.l("when_enabled_session_data_configuration_and_skills_will_sync_across_devices_via_icloud"))
            }

            if iCloudEnabled {
                // 账号状态
                if !accountStatus.isEmpty {
                    Section(L10n.l("account_status")) {
                        HStack {
                            Text(L10n.l("icloud_account"))
                            Spacer()
                            Text(accountStatus)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 同步内容
                Section(L10n.l("sync_contents")) {
                    SyncContentRow(icon: "bubble.left.and.bubble.right.fill", title: "聊天记录")
                    SyncContentRow(icon: "server.rack", title: "模型供应商配置")
                    SyncContentRow(icon: "square.stack.3d.up.fill", title: "模型分组")
                    SyncContentRow(icon: "puzzlepiece.extension.fill", title: "技能")
                    SyncContentRow(icon: "key.fill", title: "环境变量")
                    SyncContentRow(icon: "cat.fill", title: "灵魂（SOUL.md）")
                    SyncContentRow(icon: "brain.fill", title: "记忆")
                }

                // 同步状态
                Section(L10n.l("sync_status")) {
                    HStack {
                        Text(L10n.l("last_synced"))
                        Spacer()
                        if let date = lastSyncDate {
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.l("not_yet_synced"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if totalSent > 0 || totalReceived > 0 {
                        HStack {
                            Text(L10n.l("sent"))
                            Spacer()
                            Text(String(format: L10n.l("records"), "\(totalSent)"))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L10n.l("received"))
                            Spacer()
                            Text(String(format: L10n.l("records"), "\(totalReceived)"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await performSync() }
                    } label: {
                        HStack {
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(isSyncing ? L10n.l("syncing") : L10n.l("sync_now"))
                        }
                    }
                    .disabled(isSyncing)
                }
            }
        }
        .navigationTitle(L10n.l("sync"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let config = SettingsStore.shared.settings.sync
            iCloudEnabled = config.iCloudEnabled
            autoSync = config.autoSync
            lastSyncDate = config.lastSyncDate
            if iCloudEnabled { checkAccountStatus() }
        }
    }

    private func checkAccountStatus() {
        // CloudKit transport 当前不可用（entitlements 已移除，2026-08-03）。
        // 后续重做 iCloud 同步时恢复此检查。
        accountStatus = "iCloud 同步已禁用"
    }

    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }

        SyncCore.shared.markDirty(recordType: "ProviderConfigV2", recordId: "provider-config")
        SyncCore.shared.markDirty(recordType: "SoulV2", recordId: "soul")
        await SyncCore.shared.sendNow()
        await SyncCore.shared.fetchFromAllTransports()

        lastSyncDate = Date()
        totalSent = SyncCore.shared.totalSent
        totalReceived = SyncCore.shared.totalReceived
    }
}

/// 同步内容条目行
private struct SyncContentRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.cyan, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(title)
                .font(.subheadline)
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }
}

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

    /// 当前上下文占用快照（引擎实时写入）：这里展示的是「下一次请求会占多少窗口」，
    /// 与右上角圆环、以及引擎的压缩判定同一份数据。
    private var contextSnapshot: ContextUsageSnapshot? {
        ContextUsageStore.shared.snapshot(for: session.id)
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

// MARK: - Storage Settings

/// 单个会话的存储占用（设备上的文件，不含 SwiftData 聊天记录本身）。
struct SessionStorageRow: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let bytes: Int64
}

/// 存储概览分类汇总（字节）。
struct StorageOverview {
    var workspace: Int64 = 0
    var attachments: Int64 = 0
    /// 浏览器缓存（共享区 browser/ + 系统 Caches/MiniClaw/ + WebKit 真实缓存目录）
    var browserCache: Int64 = 0
    /// 会话缓存（各会话目录的 browser/ + subagent 运行期记录，可安全重建）
    var sessionCache: Int64 = 0
    /// 运行日志（由「日志」页开关控制，此处仅展示）
    var logs: Int64 = 0
    var total: Int64 { workspace + attachments + browserCache + sessionCache + logs }
}

struct StorageSettingsView: View {
    @State private var files: FileSettings = SettingsStore.shared.settings.files
    @State private var overview: StorageOverview = StorageOverview()
    @State private var sessionRows: [SessionStorageRow] = []
    @State private var isBusy: Bool = false
    @State private var showClearConfirm: Bool = false
    @State private var showCleanupResult: Bool = false
    @State private var cleanupMessage: String = ""
    @State private var pendingDeleteID: UUID? = nil
    @State private var pendingDeleteTitle: String = ""
    @State private var showDeleteSessionConfirm: Bool = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private func fmt(_ n: Int64) -> String { Self.byteFormatter.string(fromByteCount: n) }

    var body: some View {
        List {
            // 存储概览（真实扫描）
            Section {
                StorageUsageRow(label: L10n.l("workspace"), size: fmt(overview.workspace), icon: "folder")
                StorageUsageRow(label: L10n.l("attachments"), size: fmt(overview.attachments), icon: "photo")
                StorageUsageRow(label: L10n.l("browser_cache"), size: fmt(overview.browserCache), icon: "globe")
                StorageUsageRow(label: L10n.l("session_cache"), size: fmt(overview.sessionCache), icon: "clock.arrow.circlepath")
                StorageUsageRow(label: L10n.l("runtime_logs"), size: fmt(overview.logs), icon: "doc.text")
                StorageUsageRow(label: L10n.l("total"), size: fmt(overview.total), icon: "externaldrive", isTotal: true)
            } header: {
                Text(L10n.l("storage_overview"))
            } footer: {
                Text(L10n.l("real_disk_space_used_by_each_session_s_isolated_directory_and_the_shared_workspace"))
            }

            // 清理（均真实生效）
            Section {
                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.l("processing_ellipsis")).foregroundStyle(.secondary)
                    }
                } else {
                    Button(L10n.l("clear_browser_cache")) { cleanBrowserCache() }
                    Button(L10n.l("clear_session_cache")) { cleanSessionCache() }
                    Button(L10n.l("clean_old_attachments")) { cleanOldAttachments() }
                    Button(L10n.l("clear_all_data"), role: .destructive) { showClearConfirm = true }
                }
            } header: {
                Text(L10n.l("cleanup"))
            } footer: {
                Text(L10n.l("clear_browser_cache_clears_web_caches_webkit_cache_urlcache_shared_browser_data_clear_session_cache_clears_rebuildable_cache_data_in_each_session_session_browser_data_subagent_runtime_records_without_affecting_conversation_content_clear_old_attachments_deletes_attachments_older_than_the_cleanup_period_clear_all_data_deletes_all_session_isolated_files_and_local_working_data_settings_models_and_skills_are_unaffected_run_logs_and_crash_logs_are_controlled_by_toggles_on_the_logs_page"))
            }

            // 文件设置
            Section {
                TextField(L10n.l("default_workspace_directory_name"), text: $files.defaultWorkspace)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $files.autoOffloadThresholdKB, in: 1...100) {
                    Text(String(format: L10n.l("large_output_dump_threshold_kb"), "\(files.autoOffloadThresholdKB)"))
                }
                    .onChange(of: files.autoOffloadThresholdKB) { _ in FileSystemManager.shared.ensureDefaultWorkspace() }
                Stepper(value: $files.cleanupAttachmentsDays, in: 1...365) {
                    Text(String(format: L10n.l("attachment_auto_cleanup_period_days"), "\(files.cleanupAttachmentsDays)"))
                }
            } header: {
                Text(L10n.l("files"))
            } footer: {
                Text(L10n.l("default_workspace_directory_name_the_shared_workspace_where_shell_file_tools_land_when_no_session_is_bound_under_var_miniclaw_large_output_offload_threshold_shell_output_exceeding_this_value_is_auto_offloaded_to_offloads_attachment_auto_cleanup_period_clean_old_attachments_uses_this_to_delete_expired_attachments"))
            }

            // 会话占用列表
            Section {
                if sessionRows.isEmpty {
                    Text(L10n.l("no_sessions")).foregroundStyle(.secondary)
                } else {
                    ForEach(sessionRows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title.isEmpty ? L10n.l("untitled_session") : row.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(row.updatedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(fmt(row.bytes))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteID = row.id
                                pendingDeleteTitle = row.title.isEmpty ? L10n.l("untitled_session") : row.title
                                showDeleteSessionConfirm = true
                            } label: {
                                Label(L10n.l("delete_action"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(L10n.l("session_usage"))
            } footer: {
                Text(L10n.l("lists_each_session_s_on_device_file_usage_workspace_attachments_browser_offloads_excluding_the_chat_history_itself_sorted_by_size_largest_first"))
            }
        }
        .navigationTitle(L10n.l("storage"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { await reloadAsync() }
        .alert(L10n.l("clear_all_data"), isPresented: $showClearConfirm) {
            Button(L10n.l("cancel"), role: .cancel) {}
            Button(L10n.l("clear"), role: .destructive) { clearAllData() }
        } message: {
            Text(L10n.l("this_will_delete_all_session_isolated_files_and_local_working_data_workspace_attachments_browser_dumps_logs_this_action_cannot_be_undone_settings_models_and_skills_are_unaffected"))
        }
        .alert(L10n.l("cleanup_complete"), isPresented: $showCleanupResult) {
            Button(L10n.l("ok"), role: .cancel) {}
        } message: {
            Text(cleanupMessage)
        }
        .alert(L10n.l("delete_session"), isPresented: $showDeleteSessionConfirm) {
            Button(L10n.l("cancel"), role: .cancel) {
                pendingDeleteID = nil
                pendingDeleteTitle = ""
            }
            Button(L10n.l("delete_action"), role: .destructive) {
                if let id = pendingDeleteID {
                    SessionManager.shared.deleteSession(id: id)
                    pendingDeleteID = nil
                    pendingDeleteTitle = ""
                    reload()
                }
            }
        } message: {
            Text(L10n.l("this_will_delete_the_session")) + Text("「\(pendingDeleteTitle)」") + Text(L10n.l("all_isolated_files_and_chat_history_freeing_the_storage_space_they_occupy_this_action_cannot_be_undone"))
        }
        .onChange(of: files) { _ in saveFiles() }
    }

    // MARK: - 存储扫描

    private func reload() {
        let sessions: [(UUID, String, Date)] = SessionManager.shared.allSessions().map {
            ($0.id, $0.title, $0.updatedAt)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fs = FileSystemManager.shared
            let base = SessionFileRouter.sessionsHostBase
            var ov = StorageOverview()
            var rows: [SessionStorageRow] = []
            let subs = SessionFileRouter.sessionSubdirs  // workspace/attachments/browser/offloads
            for (id, title, updated) in sessions {
                let sessionDir = base.appendingPathComponent(id.uuidString, isDirectory: true)
                var sessionBytes: Int64 = 0
                for sub in subs {
                    let size = fs.sizeOfDirectory(sessionDir.appendingPathComponent(sub))
                    sessionBytes += size
                    if sub == "workspace" || sub == "offloads" { ov.workspace += size }
                    else if sub == "attachments" { ov.attachments += size }
                    else if sub == "browser" { ov.sessionCache += size }
                }
                // 会话缓存：子代理运行期记录已随会话数据入库 SQLite(可重建)，不再单独统计文件。
                rows.append(SessionStorageRow(id: id, title: title, updatedAt: updated, bytes: sessionBytes))
            }
            rows.sort { $0.bytes > $1.bytes }

            // 共享（扁平）区
            let flat = fs.miniClawRoot
            ov.workspace += fs.sizeOfDirectory(flat.appendingPathComponent("workspace"))
            ov.workspace += fs.sizeOfDirectory(flat.appendingPathComponent("offloads"))
            ov.attachments += fs.sizeOfDirectory(flat.appendingPathComponent("attachments"))
            ov.browserCache += fs.sizeOfDirectory(flat.appendingPathComponent("browser"))
            if let cachesURL = try? FileManager.default
                .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("MiniClaw") {
                ov.browserCache += fs.sizeOfDirectory(cachesURL)
            }
            // WebKit 真实磁盘缓存（Library/WebKit/）
            if let lib = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                ov.browserCache += fs.sizeOfDirectory(lib.appendingPathComponent("WebKit"))
            }
            ov.logs += fs.sizeOfDirectory(AppLogger.shared.logsDirectory)

            DispatchQueue.main.async {
                self.overview = ov
                self.sessionRows = rows
            }
        }
    }

    private func reloadAsync() async {
        await withCheckedContinuation { cont in
            reload()
            // 后台扫描通常很快；给一个极短的延以确保 @State 刷新后再结束下拉刷新。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cont.resume() }
        }
    }

    // MARK: - 清理动作

    /// 删除目录下所有内容（保留目录本身）。
    /// nonisolated：全部调用点都在 `DispatchQueue.global` 后台闭包里，方法本身不触碰任何 View 状态，
    /// 不加隔离标注会在 Swift 6 严格并发下变成硬错误。
    private nonisolated func removeContents(of dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    /// 清理浏览器缓存（2026-08-07 口径统一）：WebKit + URLCache + 共享区 browser/ + Caches/MiniClaw/。
    /// 与浏览器设置页「清理缓存」共用同一方法；会话级 browser/ 属「会话缓存」，不在此列。
    private func cleanBrowserCache() {
        isBusy = true
        Task {
            await BrowserController.shared.clearBrowserCaches()
            await MainActor.run {
                isBusy = false
                cleanupMessage = L10n.l("browser_cache_cleared")
                showCleanupResult = true
                reload()
            }
        }
    }

    /// 清理会话缓存（2026-08-07 新增）：各会话目录下可重建的缓存数据——
    /// 会话浏览器数据（browser/）+ 子代理运行期记录（SQLite 中 runtimeRecords，可重建）。
    /// 不影响会话内容、附件、工作区文件与子代理对话记录。
    private func cleanSessionCache() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            let base = SessionFileRouter.sessionsHostBase
            if let sessionDirs = try? fm.contentsOfDirectory(atPath: base.path) {
                for s in sessionDirs where UUID(uuidString: s) != nil {
                    let dir = base.appendingPathComponent(s)
                    removeContents(of: dir.appendingPathComponent("browser"))
                    if let sid = UUID(uuidString: s) {
                        SQLiteStore.shared.deleteBlob(sessionID: sid, kind: .runtimeRecords)
                    }
                }
            }
            DispatchQueue.main.async {
                isBusy = false
                cleanupMessage = L10n.l("session_cache_cleared")
                showCleanupResult = true
                reload()
            }
        }
    }

    private func cleanOldAttachments() {
        isBusy = true
        let days = files.cleanupAttachmentsDays
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            let fs = FileSystemManager.shared
            let base = SessionFileRouter.sessionsHostBase
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            var removed: Int64 = 0
            func scan(_ dir: URL) {
                guard let items = try? fm.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
                for item in items {
                    let rv = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                    if rv?.isDirectory == true {
                        scan(item)
                    } else if let mdate = rv?.contentModificationDate, mdate < cutoff {
                        if let sz = try? fm.attributesOfItem(atPath: item.path)[.size] as? UInt64 {
                            removed += Int64(sz)
                        }
                        try? fm.removeItem(at: item)
                    }
                }
            }
            scan(fs.miniClawRoot.appendingPathComponent("attachments"))
            if let sessionDirs = try? fm.contentsOfDirectory(atPath: base.path) {
                for s in sessionDirs where UUID(uuidString: s) != nil {
                    scan(base.appendingPathComponent(s).appendingPathComponent("attachments"))
                }
            }
            DispatchQueue.main.async {
                isBusy = false
                cleanupMessage = String(format: L10n.l("cleaned_of_old_attachments"), fmt(removed))
                showCleanupResult = true
                reload()
            }
        }
    }

    private func clearAllData() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            let fs = FileSystemManager.shared
            let base = SessionFileRouter.sessionsHostBase
            // 全部会话隔离目录
            if fm.fileExists(atPath: base.path) {
                try? fm.removeItem(at: base)
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            }
            // 共享区工作数据（保留 config/models/skills/mounts/rules/shared）
            for sub in ["workspace", "attachments", "browser", "offloads", "logs"] {
                removeContents(of: fs.miniClawRoot.appendingPathComponent(sub))
            }
            DispatchQueue.main.async {
                isBusy = false
                cleanupMessage = L10n.l("all_local_data_cleared")
                showCleanupResult = true
                reload()
            }
        }
    }

    private func saveFiles() {
        SettingsStore.shared.set(files, domain: .files, summary: L10n.l("edit_file_settings"))
    }
}

struct StorageUsageRow: View {
    let label: String
    let size: String
    let icon: String
    var isTotal: Bool = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isTotal ? .orange : .secondary)
            Text(label)
                .fontWeight(isTotal ? .semibold : .regular)
            Spacer()
            Text(size)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared Folder Settings

struct SharedFolderSettingsView: View {
    @State private var sharedFolders: [String] = [
        "/var/MiniClaw/shared/projects",
        "/var/MiniClaw/shared/datasets",
    ]

    var body: some View {
        List {
            Section(L10n.l("shared_folders")) {
                ForEach(sharedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cyan)
                        Text(folder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .onDelete { indexSet in
                    sharedFolders.remove(atOffsets: indexSet)
                }

                Button(action: {}) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.l("add_shared_folder"))
                    }
                }
            }

            Section {
                Text(L10n.l("files_in_the_shared_folder_persist_across_sessions_both_the_agent_and_shell_can_read_and_write_them"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.l("shared_folders"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Mount Settings

struct MountSettingsView: View {
    @State private var mounts: [MountPoint] = []
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if mounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.l("no_mounted_folders_yet"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(L10n.l("tap_add_mount_folder_below_then_choose_a_folder_from_the_files_app"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section(L10n.l("mounted")) {
                    ForEach(mounts) { mount in
                        mountRow(mount)
                    }
                    .onDelete(perform: deleteMounts)
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.l("add_mount_folder"))
                    }
                }
            } footer: {
                Text(L10n.l("select_a_folder_via_the_ios_files_app_to_mount_into_miniclaw_read_only_by_default_the_agent_can_read_its_contents_via_var_miniclaw_mounts_name_to_let_the_agent_write_enable_the_allow_write_switch_on_that_mount_writes_are_persisted_to_the_external_folder_so_please_be_careful_mount_info_remains_valid_after_the_app_restarts"))
            }
        }
        .navigationTitle(L10n.l("mounts"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !mounts.isEmpty {
                EditButton()
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            L10n.l("mount_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.l("ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func mountRow(_ mount: MountPoint) -> some View {
        NavigationLink {
            MountDetailView(mount: mount)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(mount.isMounted ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mount.name)
                            .font(.body)
                        if mount.isWritable {
                            Text(L10n.l("writable"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        } else {
                            Text(L10n.l("read_only"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(mount.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ext = mount.externalPath {
                        Text(ext)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
        }
    }

    private func reload() {
        mounts = MountStore.shared.list()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 关键：File Provider（云盘/iCloud）文件夹的 startAccessingSecurityScopedResource
            // + bookmarkData 可能阻塞数秒。.fileImporter 回调运行在主线程，若在此同步执行
            // 会触发主线程看门狗（MAIN THREAD BLOCKED）、iSH 终端视图崩溃，并连带使 iSH 内
            // ls 全部无输出。故必须放到后台执行，完成后再回主线程刷新 UI。
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try MountStore.shared.add(url: url)
                    await MainActor.run { reload() }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run { errorMessage = msg }
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMounts(at offsets: IndexSet) {
        for index in offsets {
            MountStore.shared.remove(id: mounts[index].id)
        }
        reload()
    }
}

// MARK: - 挂载详情（从挂载列表点进：顶部名称/路径，权限开关，浏览文件，卸载）

struct MountDetailView: View {
    let mountId: UUID
    @State private var mount: MountPoint
    @State private var showUnmount = false
    @State private var showBrowser = false
    @Environment(\.dismiss) private var dismiss

    init(mount: MountPoint) {
        self.mountId = mount.id
        _mount = State(initialValue: mount)
    }

    var body: some View {
        List {
            // 顶部：沿用列表的显示格式展示名称 + 虚拟路径 + 外部真实路径
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(mount.isMounted ? Color.accentColor : Color.secondary)
                        Text(mount.name)
                            .font(.headline)
                        permissionBadge
                    }
                    Text(mount.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ext = mount.externalPath {
                        Text(ext)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
            }

            // 权限：允许写入（默认开启，点击可禁止）
            Section(L10n.l("permissions")) {
                Toggle(L10n.l("allow_writing"), isOn: Binding(
                    get: { mount.isWritable },
                    set: { setWritable($0) }
                ))
            }

            // 浏览文件：点「打开」以模态方式进入外部文件夹真实内容
            // （与另外两处文件管理器一致用 .sheet 呈现，避免「外层设置导航栈 + 内层 NavigationStack」嵌套导致首次 push 被弹回）
            Section(L10n.l("browse_files")) {
                Button {
                    showBrowser = true
                } label: {
                    Label(L10n.l("open_action"), systemImage: "folder")
                }
            }

            // 卸载
            Section {
                Button(role: .destructive) {
                    showUnmount = true
                } label: {
                    Label(L10n.l("uninstall"), systemImage: "eject.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.l("mount_details"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.l("confirm_unmounting_this_folder"), isPresented: $showUnmount) {
            Button(L10n.l("uninstall"), role: .destructive) { performUnmount() }
            Button(L10n.l("cancel"), role: .cancel) { }
    } message: {
        Text(L10n.l("unmount") + mount.name + "」" + L10n.l("the_agent_will_no_longer_be_able_to_access_this_folder_via_the_virtual_path_files_inside_the_external_folder_itself_will_not_be_deleted"))
    }
    .sheet(isPresented: $showBrowser) {
        MountFileBrowserView(mountName: mount.name, subPath: "")
    }
}

    private var permissionBadge: some View {
        Text(mount.isWritable ? L10n.l("writable") : L10n.l("read_only"))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((mount.isWritable ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(mount.isWritable ? Color.green : Color.secondary)
    }

    private func setWritable(_ v: Bool) {
        MountStore.shared.setWritable(id: mountId, v)
        refresh()
    }

    private func refresh() {
        if let updated = MountStore.shared.list().first(where: { $0.id == mountId }) {
            mount = updated
        }
    }

    private func performUnmount() {
        MountStore.shared.remove(id: mountId)
        dismiss()
    }
}

// MARK: - 挂载文件浏览器（浏览外部文件夹真实内容，每项右侧分享按钮）
//
// 统一交给 UnifiedFileBrowser 渲染（信息丰富型行样式一致），挂载模式下每行文件带分享按钮。

struct MountFileBrowserView: View {
    let mountName: String
    var subPath: String = ""
    @State private var path: [FileBrowserLocation] = []

    /// 挂载内的 guest 路径（容器视角）：/var/MiniClaw/mounts/<name>/<subPath>。
    private var rootGuestPath: String {
        let v = "/var/MiniClaw/mounts/\(mountName)/\(subPath)".trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + v
    }

    /// 挂载根目录的真实外部 URL（经 bookmark 解析到外部文件夹）。
    private var rootDirectoryURL: URL? {
        try? FileSystemManager.shared.resolveAgentPath("/var/MiniClaw/mounts/\(mountName)/\(subPath)")
    }

    var body: some View {
        NavigationStack(path: $path) {
            if let url = rootDirectoryURL {
                let rootLoc = FileBrowserLocation(
                    mode: .mount(name: mountName),
                    directoryURL: url,
                    displayGuestPath: rootGuestPath,
                    sessionID: nil
                )
                UnifiedFileBrowser(location: rootLoc, path: $path)
                    .navigationTitle(subPath.isEmpty ? mountName : (subPath as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FileBrowserLocation.self) { loc in
                        UnifiedFileBrowser(location: loc, path: $path)
                    }
            } else {
                EmptyStateView(label: L10n.l("mount_unavailable"), systemImage: "tray",
                           description: L10n.l("this_mount_is_currently_inaccessible_the_external_folder_may_have_been_removed_or_its_permission_revoked"))
                .navigationTitle(subPath.isEmpty ? mountName : (subPath as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - Logs View（统一入口：运行日志列表 + 审计日志入口）

/// 统一「日志」页：运行日志（按天调试日志，含启用开关）直接列表展示；
/// 审计日志作为独立入口，点击进入后再列表展示全部审计内容。
struct LogsView: View {
    @State private var runtimeFiles: [AppLogger.LogFileEntry] = []
    @State private var crashFiles: [AppLogger.LogFileEntry] = []
    @State private var loggingEnabled: Bool = AppLogger.shared.isEnabled

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    /// 导出全部日志（运行日志 + 崩溃日志）的 URL 集合。
    private var allLogURLs: [URL] {
        runtimeFiles.map(\.url) + crashFiles.map(\.url)
    }

    var body: some View {
        List {
            runtimeSection
            crashSection
            auditEntrySection
        }
        .navigationTitle(L10n.l("logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: allLogURLs) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(L10n.l("export_all_logs_runtime_logs_crash_logs"))
                .disabled(allLogURLs.isEmpty)
            }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    // MARK: - 运行日志

    private var runtimeSection: some View {
        Section {
            Toggle(isOn: $loggingEnabled) {
                Label(L10n.l("enable_logging"), systemImage: "power")
            }
            .onChange(of: loggingEnabled) { newValue in
                AppLogger.shared.setEnabled(newValue)
                reload()
            }

            if runtimeFiles.isEmpty {
                Text(loggingEnabled
                     ? L10n.l("no_run_logs_yet_debug_logs_are_generated_daily_once_the_app_runs")
                     : L10n.l("logging_is_off_no_new_run_logs_will_be_generated"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runtimeFiles) { file in
                    NavigationLink {
                        LogDetailView(url: file.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.plaintext")
                                .foregroundStyle(.blue)
                            Text(file.url.lastPathComponent)
                                .font(.system(.subheadline, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Self.byteFormatter.string(fromByteCount: file.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: runtimeFiles[i].url) }
                    reload()
                }
            }
        } header: {
            Text(L10n.l("runtime_logs"))
        } footer: {
            Text(L10n.l("records_app_debug_logs_by_day_errors_freezes_infinite_loops_crashes_logging_stops_when_the_switch_is_off_swipe_left_to_delete_a_single_log"))
        }
    }

    // MARK: - 崩溃日志

    private var crashSection: some View {
        Section {
            if crashFiles.isEmpty {
                Text(L10n.l("no_crash_logs_yet_automatically_recorded_after_a_crash_or_abnormal_exit"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(crashFiles) { file in
                    NavigationLink {
                        LogDetailView(url: file.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(file.url.lastPathComponent)
                                .font(.system(.subheadline, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Self.byteFormatter.string(fromByteCount: file.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: crashFiles[i].url) }
                    reload()
                }
            }
        } header: {
            Text(L10n.l("crash_log"))
        } footer: {
            Text(L10n.l("crash_report_full_description"))
        }
    }

    // MARK: - 审计日志入口

    private var auditEntrySection: some View {
        Section {
            NavigationLink {
                AuditLogsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.gray)
                    Text(L10n.l("audit_log"))
                    Spacer()
                }
            }
        } header: {
            Text(L10n.l("audit_log"))
        } footer: {
            Text(L10n.l("records_setting_changes_and_rollback_actions_tap_to_view_all_audit_content"))
        }
    }

    private func reload() {
        loggingEnabled = AppLogger.shared.isEnabled
        runtimeFiles = AppLogger.shared.listLogFiles()
        crashFiles = AppLogger.shared.listCrashLogFiles()
    }
}

// MARK: - 审计日志（独立列表）

/// 审计日志独立页：列出所有设置变更 / 回滚记录。
struct AuditLogsView: View {
    @State private var auditEntries: [AuditEntry] = []

    private let auditFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        List {
            if auditEntries.isEmpty {
                Text(L10n.l("no_audit_records_yet_automatically_logged_after_any_config_change"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(auditEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(auditFormatter.string(from: entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.domain)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    Text(entry.summary)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.l("audit_log"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAudit)
        .refreshable { loadAudit() }
    }

    private func loadAudit() {
        auditEntries = SettingsStore.shared.auditEntries
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "cat.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.orange)

                        Text("MiniClaw")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("v1.0.0 (Build 1)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(L10n.l("ios_agent_app"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }

            Section(L10n.l("about_miniclaw_doc")) {
                NavigationLink(L10n.l("about_miniclaw_doc")) {
                    DocumentView(filename: "关于MiniClaw.md", title: L10n.l("about_miniclaw_doc"))
                }
                NavigationLink(L10n.l("user_agreement")) {
                    DocumentView(filename: "用户使用协议.md", title: L10n.l("user_agreement"))
                }
                NavigationLink(L10n.l("privacy_policy")) {
                    DocumentView(filename: "用户隐私政策.md", title: L10n.l("privacy_policy"))
                }
            }

            Section(L10n.l("open_source_components")) {
                Text(L10n.l("swiftsoup_html_parsing_n_highlightr_code_highlighting_n_markdownui_markdown_rendering"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.l("about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @State private var defaults: DefaultSettings = SettingsStore.shared.settings.defaults
    @State private var chat: ChatSettings = SettingsStore.shared.settings.chat
    @State private var browser: BrowserSettings = SettingsStore.shared.settings.browser

    var body: some View {
        Form {
            Section {
                Toggle(L10n.l("confirm_before_tool_calls"), isOn: $defaults.confirmBeforeToolCall)
            } header: {
                Text(L10n.l("default_behavior"))
            } footer: {
                Text(L10n.l("when_enabled_the_agent_will_ask_for_your_confirmation_before_each_tool_call_file_browser_shell_etc"))
            }

            Section {
                Toggle(L10n.l("show_thinking_process"), isOn: $chat.showThinking)
                Toggle(L10n.l("enter_to_send_off_newline"), isOn: $chat.enterToSend)
            } header: {
                Text(L10n.l("chat"))
            }

            Section {
                Stepper(value: $browser.maxTabs, in: 1...5) {
                    Text(String(format: L10n.l("max_tabs"), "\(browser.maxTabs)"))
                }
                Toggle(L10n.l("block_pop_ups"), isOn: $browser.blockPopups)
                Toggle(L10n.l("open_in_builtin_browser"), isOn: Binding(
                    get: { MiniClawOpenURLHandler.openLinksInline() },
                    set: { UserDefaults.standard.set($0, forKey: MiniClawOpenURLHandler.openLinksInlineKey) }
                ))
                Picker(L10n.l("user_agent_form"), selection: $browser.uaMode) {
                    Text(L10n.l("mobile")).tag("mobile")
                    Text(L10n.l("desktop")).tag("desktop")
                    Text(L10n.l("custom")).tag("custom")
                }
                if browser.uaMode == "custom" {
                    TextField(L10n.l("custom_user_agent"), text: $browser.userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(L10n.l("browser"))
            } footer: {
                Text(L10n.l("choose_the_user_agent_form_used_by_the_browser_if_custom_is_selected_fill_in_the_ua_string_below"))
            }
        }
        .navigationTitle(L10n.l("general_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: defaults) { _ in saveDefaults() }
        .onChange(of: chat) { _ in saveChat() }
        .onChange(of: browser) { _ in saveBrowser() }
        .onAppear {
            // 每次进入都从持久化源重新同步，避免 NavigationStack 缓存视图实例
            // 导致 @State 停留在进入时的旧值（表现为「返回后再进显示回之前的设置」）。
            defaults = SettingsStore.shared.settings.defaults
            chat = SettingsStore.shared.settings.chat
            browser = SettingsStore.shared.settings.browser
        }
    }

    private func saveDefaults() {
        SettingsStore.shared.set(defaults, domain: .defaults, summary: L10n.l("edit_general_settings"))
    }

    private func saveChat() {
        SettingsStore.shared.set(chat, domain: .chat, summary: L10n.l("edit_chat_settings"))
    }

    private func saveBrowser() {
        SettingsStore.shared.set(browser, domain: .browser, summary: L10n.l("edit_browser_settings"))
        // 立即把 UA 形态同步到浏览器运行时（若当前有打开的标签）。
        BrowserController.shared.applyUAProfileToAllTabs()
    }
}

// MARK: - 权限与后台（后台行为迁移自通用设置 + 权限授权列表）

struct PermissionsSettingsView: View {
    /// 观察统一配置，权限状态回写后徽标实时刷新。
    @ObservedObject private var store = SettingsStore.shared
    /// 提示弹窗（如剪贴板无需授权说明）。
    @State private var showInfo = false
    @State private var infoText = ""
    /// 正在申请中的权限键，避免重复点击。
    @State private var busyKey: String?
    /// 用于强制视图在权限状态回写后重绘（SettingsStore 未主动发 willChange，靠此触发刷新）。
    @State private var tick: Bool = false
    /// 通知是否已授权（决定「通知」行显示开关还是「未授权」，2026-08-07 自后台页移入）。
    @State private var notifAuthorized: Bool = false
    /// 定位授权状态（2026-08-07 自后台页移入；模糊定位保活依赖）。
    @State private var locationState: PermissionState = .notDetermined

    /// 权限清单（仅展示用户指定的项；健康仅保留「健康数据」，位置已移至「后台」页）。
    /// 2026-08-07：健康数据/家庭配件工具尚未接入（AppleHealthKitTool/AppleHomeKitTool 未注册，
    /// execute 为占位空壳），隐藏其授权入口，避免半成品入口暴露。
    /// 恢复 = 取消下方对应行注释（与用户沟通开发 HealthKit/HomeKit 工具后再恢复显示）。
    private let permissionItems: [(key: String, label: String)] = [
        // ("healthData",L10n.l("health_data")),   // 待 HealthKit 工具接入后恢复
        ("calendar",  L10n.l("calendar")),
        ("photos",    L10n.l("images")),
        // ("homeKit",   L10n.l("home_accessories")),   // 待 HomeKit 工具接入后恢复
        ("pasteboard",L10n.l("clipboard")),
        ("reminders", L10n.l("reminders")),
        ("microphone",L10n.l("microphone")),
        ("speech",    L10n.l("speech_recognition")),
        ("localNetwork", L10n.l("local_network")),   // iSH 内网 DNS/局域网设备访问依赖（NWBrowser 触发系统弹窗）
    ]

    /// 权限状态实时从统一配置读取。
    private var permissions: PermissionConfig { store.settings.permissions }

    var body: some View {
        Form {
            Section {
                NavigationLink(L10n.l("background")) {
                    BackgroundSettingsView()
                }
            } header: {
                Text(L10n.l("background"))
            } footer: {
                Text(L10n.l("background_running_live_activities_dynamic_island_notifications_and_location_keepalive_settings"))
            }

            Section {
                notificationRow
                locationRow
                ForEach(permissionItems, id: \.key) { item in
                    permissionRow(item)
                }
            } header: {
                Text(L10n.l("permissions"))
            } footer: {
                Text(L10n.l("lists_the_permissions_this_app_may_request_and_their_current_authorization_status_tap_an_unauthorized_item_to_request_it_in_app_or_jump_to_system_settings_to_enable_it"))
            }
        }
        .navigationTitle(L10n.l("permissions_background"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await MainActor.run { PermissionManager.shared.refreshStatuses() }
            let notif = await PermissionManager.shared.notificationAuthorized
            await MainActor.run {
                notifAuthorized = notif
                locationState = PermissionManager.shared.locationState()
            }
            tick.toggle()
        }
        // 从系统设置授权返回时刷新通知/定位状态（.task 不会重跑）。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                let notif = await PermissionManager.shared.notificationAuthorized
                await MainActor.run {
                    notifAuthorized = notif
                    locationState = PermissionManager.shared.locationState()
                }
            }
        }
        .alert(L10n.l("tip"), isPresented: $showInfo) {
            Button(L10n.l("got_it"), role: .cancel) {}
        } message: { Text(infoText) }
    }

    // 通知行（2026-08-07 自后台页移入）：已授权显示开关（后台通知开关），未授权显示「未授权」引导申请。
    @ViewBuilder
    private var notificationRow: some View {
        if notifAuthorized {
            Toggle(L10n.l("notifications"), isOn: Binding(
                get: { store.settings.background.notifications },
                set: { newValue in
                    var b = store.settings.background
                    b.notifications = newValue
                    store.set(b, domain: .background, summary: L10n.l("modify_notification_settings"))
                }
            ))
        } else {
            HStack {
                Text(L10n.l("notifications"))
                Spacer()
                // 与其它权限行的授权徽标同款（PermissionBadgeView 单一来源）：红字红底胶囊，
                // 但保持可点击（点击申请通知授权）。
                Button(L10n.l("not_authorized")) { requestNotification() }
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PermissionBadgeView.badgeColor(.denied).opacity(0.15))
                    .foregroundStyle(PermissionBadgeView.badgeColor(.denied))
                    .clipShape(Capsule())
            }
        }
    }

    // 定位权限行（2026-08-07 自后台页移入）：与其它权限行完全一致——
    // 整行可点击、申请中显示菊花、右侧授权胶囊徽标、申请后实时刷新状态。
    @ViewBuilder
    private var locationRow: some View {
        Button {
            Task { await requestLocation() }
        } label: {
            HStack {
                Text(L10n.l("locate_action"))
                Spacer()
                // 申请中显示菊花（与其它权限行同款）
                if busyKey == "location" {
                    ProgressView().scaleEffect(0.7)
                }
                PermissionBadgeView(state: locationState)
            }
        }
        .buttonStyle(.plain)
        .disabled(busyKey != nil && busyKey != "location")
    }

    private func requestLocation() async {
        guard busyKey == nil else { return }
        busyKey = "location"
        let result = await PermissionManager.shared.requestPermission("location")
        // 与其它权限一致：申请后仍非授权（拒绝/受限/未决定）则跳转系统设置引导开启。
        if result != .authorized {
            openSettings()
        }
        await MainActor.run {
            busyKey = nil
            locationState = PermissionManager.shared.locationState()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestNotification() {
        Task {
            let granted = await PermissionManager.shared.requestNotification()
            let notif = await PermissionManager.shared.notificationAuthorized
            await MainActor.run {
                notifAuthorized = notif
                // 授权成功且通知开关从未打开过 → 默认打开（授权即希望收到任务通知）；
                // 用户之后手动关闭不会被覆盖（只有授权这一刻才置默认开）。
                if granted, !store.settings.background.notifications {
                    var b = store.settings.background
                    b.notifications = true
                    store.set(b, domain: .background, summary: L10n.l("modify_notification_settings"))
                }
            }
        }
    }

    // 单行：可点击申请/跳转；右侧显示授权徽标；申请中显示菊花。
    @ViewBuilder
    private func permissionRow(_ item: (key: String, label: String)) -> some View {
        Button {
            handleTap(item)
        } label: {
            HStack {
                Text(item.label)
                Spacer()
                // 申请中显示菊花（名称后、徽标前），返回后恢复徽标
                if busyKey == item.key {
                    ProgressView().scaleEffect(0.7)
                }
                permissionBadge(state: state(for: item.key))
            }
        }
        .buttonStyle(.plain)
        .disabled(busyKey != nil && busyKey != item.key)
    }

    /// 点击处理：剪贴板无需授权直接提示；其余先尝试 App 内申请，若仍非授权则跳转系统设置。
    private func handleTap(_ item: (key: String, label: String)) {
        let key = item.key
        if key == "pasteboard" {
            infoText = L10n.l("the_clipboard_requires_no_authorization_the_app_can_always_read_and_write_it_and_no_system_setting_needs_to_be_enabled")
            showInfo = true
            return
        }
        // 本地网络：系统仅对 Bonjour 浏览弹窗，且无查询授权状态的公开 API——
        // 触发 NWBrowser 浏览后轮询配置域状态（由回调写回），最多等 8s。
        if key == "localNetwork" {
            guard busyKey == nil else { return }
            // 已拒绝：系统不再重复弹窗，点击无意义——直接引导去系统设置手动开启
            // （本地网络开关在「设置 → 隐私与安全性 → 本地网络」，openSettingsURLString 到不了）。
            if store.settings.permissions.localNetwork == .denied {
                infoText = L10n.l("local_network_permission_was_denied_go_to_settings_privacy_security_local_network_and_enable_miniclaw_once_enabled_internal_dns_names_and_lan_devices_will_work_automatically")
                showInfo = true
                return
            }
            busyKey = key
            PermissionManager.shared.requestLocalNetwork()
            Task { @MainActor in
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if store.settings.permissions.localNetwork != .notDetermined { break }
                }
                busyKey = nil
            }
            return
        }
        guard busyKey == nil else { return }
        busyKey = key
        Task { @MainActor in
            let result = await PermissionManager.shared.requestPermission(key)
            busyKey = nil
            if result != .authorized {
                // 未授权（拒绝/受限/未确定）：跳转系统设置引导开启
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            }
        }
    }

    private func state(for key: String) -> PermissionState {
        switch key {
        case "health", "healthData": return permissions.healthKit
        case "calendar":            return permissions.calendar
        case "photos":              return permissions.photoLibrary
        case "homeKit":             return permissions.homeKit
        case "pasteboard":          return .authorized  // 始终可用
        case "reminders":           return permissions.reminders
        case "microphone":          return permissions.microphone
        case "speech":              return permissions.speechRecognition
        case "localNetwork":        return permissions.localNetwork
        default:                    return .notDetermined
        }
    }

    @ViewBuilder
    private func permissionBadge(state: PermissionState) -> some View {
        PermissionBadgeView(state: state)
    }

    private func badgeColor(_ state: PermissionState) -> Color {
        PermissionBadgeView.badgeColor(state)
    }
}

// MARK: - 授权徽标（权限页 / 后台页共用，样式单一来源）

/// 授权状态胶囊徽标：状态文字 + 彩色圆角底（绿=已授权 / 红=拒绝 / 橙=受限 / 灰=未决定）。
struct PermissionBadgeView: View {
    let state: PermissionState

    var body: some View {
        Text(L10n.l(state.label))
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.badgeColor(state).opacity(0.15))
            .foregroundStyle(Self.badgeColor(state))
            .clipShape(Capsule())
    }

    static func badgeColor(_ state: PermissionState) -> Color {
        switch state {
        case .authorized:    return .green
        case .denied:        return .red
        case .restricted:    return .orange
        case .notDetermined: return .gray
        }
    }
}

// MARK: - Feedback View

struct FeedbackView: View {
    @State private var feedbackType: String = "bug"
    @State private var feedbackContent: String = ""
    @State private var includeLogs: Bool = true

    private let feedbackTypes = ["bug", "feature", "improvement", "other"]

    var body: some View {
        Form {
            Section(L10n.l("feedback_type")) {
                Picker(L10n.l("type"), selection: $feedbackType) {
                    Text(L10n.l("bug_report")).tag("bug")
                    Text(L10n.l("feature_suggestion")).tag("feature")
                    Text(L10n.l("usage_improvements")).tag("improvement")
                    Text(L10n.l("others")).tag("other")
                }
            }

            Section(L10n.l("detailed_description")) {
                TextEditor(text: $feedbackContent)
                    .frame(minHeight: 150)
            }

            Section {
                Toggle(L10n.l("include_daily_memory"), isOn: $includeLogs)
            } footer: {
                Text(L10n.l("logs_help_developers_quickly_pinpoint_issues"))
            }

            Section {
                Button(action: {}) {
                    HStack {
                        Spacer()
                        Label(L10n.l("submit_feedback"), systemImage: "paperplane.fill")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(feedbackContent.isEmpty)
            }
        }
        .navigationTitle(L10n.l("feedback"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 运行日志详情

/// 单日日志详情：使用只读 UITextView 渲染，可长按选中任意文字并复制；
/// 右上角导出整个日志文件。
struct LogDetailView: View {
    let url: URL
    @State private var content: String = ""

    var body: some View {
        ReadonlyLogTextView(text: content)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help(L10n.l("export_entire_log_file"))
                }
            }
            .onAppear { content = AppLogger.shared.readTail(of: url) }
    }
}

/// 只读、可选中的日志文本视图（基于 UITextView）。
/// `isEditable = false` + `isSelectable = true`：原生支持长按选区与系统「拷贝」菜单，
/// 比 SwiftUI `Text.textSelection` 在大段日志上更稳定可靠。
struct ReadonlyLogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.dataDetectorTypes = []
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = UIColor.label
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}
