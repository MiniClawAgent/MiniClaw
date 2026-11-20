import SwiftUI

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
            // 存储概览（真实扫描，2026-09-05 改为 iOS 存储风格的柱状图 + 图例）
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(String(localized: "storage_overview"))
                            .font(.headline)
                        Spacer()
                        // 已使用合计后面直接跟具体占用（2026-09-06 TopFlow要求）
                        Text(String(localized: "storage_used_total") + " " + fmt(overview.total))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    storageBar
                    storageLegend
                }
                .padding(.vertical, 4)
            } header: {
                Text(String(localized: "storage_overview"))
            } footer: {
                Text(String(localized: "real_disk_space_used_by_each_session_s_isolated_directory_and_the_shared_workspace"))
            }

            // 清理（均真实生效）
            Section {
                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(String(localized: "processing_ellipsis")).foregroundStyle(.secondary)
                    }
                } else {
                    Button(String(localized: "clear_browser_cache")) { cleanBrowserCache() }
                    Button(String(localized: "clear_session_cache")) { cleanSessionCache() }
                    Button(String(localized: "clean_old_attachments")) { cleanOldAttachments() }
                    Button(String(localized: "clear_all_data"), role: .destructive) { showClearConfirm = true }
                }
            } header: {
                Text(String(localized: "cleanup"))
            } footer: {
                Text(String(localized: "clear_browser_cache_clears_web_caches_webkit_cache_urlcache_shared_browser_data_clear_session_cache_clears_rebuildable_cache_data_in_each_session_session_browser_data_subagent_runtime_records_without_affecting_conversation_content_clear_old_attachments_deletes_attachments_older_than_the_cleanup_period_clear_all_data_deletes_all_session_isolated_files_and_local_working_data_settings_models_and_skills_are_unaffected_run_logs_and_crash_logs_are_controlled_by_toggles_on_the_logs_page"))
            }

            // 文件设置
            Section {
                TextField(String(localized: "default_workspace_directory_name"), text: $files.defaultWorkspace)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $files.autoOffloadThresholdKB, in: 1...100) {
                    Text(String(format: String(localized: "large_output_dump_threshold_kb"), "\(files.autoOffloadThresholdKB)"))
                }
                    .onChange(of: files.autoOffloadThresholdKB) { _ in FileSystemManager.shared.ensureDefaultWorkspace() }
            } header: {
                Text(String(localized: "files"))
            } footer: {
                Text(String(localized: "default_workspace_directory_name_the_shared_workspace_where_shell_file_tools_land_when_no_session_is_bound_under_var_miniclaw_large_output_offload_threshold_shell_output_exceeding_this_value_is_auto_offloaded_to_offloads_attachment_auto_cleanup_period_clean_old_attachments_uses_this_to_delete_expired_attachments"))
            }

            // 会话占用列表
            Section {
                if sessionRows.isEmpty {
                    Text(String(localized: "no_sessions")).foregroundStyle(.secondary)
                } else {
                    ForEach(sessionRows) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title.isEmpty ? String(localized: "untitled_session") : row.title)
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
                                pendingDeleteTitle = row.title.isEmpty ? String(localized: "untitled_session") : row.title
                                showDeleteSessionConfirm = true
                            } label: {
                                Label(String(localized: "delete_action"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "session_usage"))
            } footer: {
                Text(String(localized: "lists_each_session_s_on_device_file_usage_workspace_attachments_browser_offloads_excluding_the_chat_history_itself_sorted_by_size_largest_first"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "storage"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { await reloadAsync() }
        .alert(String(localized: "clear_all_data"), isPresented: $showClearConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "clear"), role: .destructive) { clearAllData() }
        } message: {
            Text(String(localized: "this_will_delete_all_session_isolated_files_and_local_working_data_workspace_attachments_browser_dumps_logs_this_action_cannot_be_undone_settings_models_and_skills_are_unaffected"))
        }
        .alert(String(localized: "cleanup_complete"), isPresented: $showCleanupResult) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text(cleanupMessage)
        }
        .alert(String(localized: "delete_session"), isPresented: $showDeleteSessionConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {
                pendingDeleteID = nil
                pendingDeleteTitle = ""
            }
            Button(String(localized: "delete_action"), role: .destructive) {
                if let id = pendingDeleteID {
                    SessionManager.shared.deleteSession(id: id)
                    pendingDeleteID = nil
                    pendingDeleteTitle = ""
                    reload()
                }
            }
        } message: {
            Text(String(localized: "this_will_delete_the_session")) + Text("「\(pendingDeleteTitle)」") + Text(String(localized: "all_isolated_files_and_chat_history_freeing_the_storage_space_they_occupy_this_action_cannot_be_undone"))
        }
        .onChange(of: files) { _ in saveFiles() }
    }

    // MARK: - 存储概览柱状图（2026-09-05，iOS 存储风格）

    /// 分类色板：工作区/附件/浏览器缓存/会话缓存/日志。
    private var overviewSegments: [(color: Color, value: Int64)] {
        [(Color.red, overview.workspace),
         (Color.orange, overview.attachments),
         (Color.yellow, overview.browserCache),
         (Color.green, overview.sessionCache),
         (Color.gray, overview.logs)]
    }

    /// 分段柱状条：各分类按占比着色。
    private var storageBar: some View {
        GeometryReader { geo in
            let total = max(overview.total, 1)
            HStack(spacing: 1) {
                ForEach(overviewSegments.indices, id: \.self) { i in
                    let seg = overviewSegments[i]
                    if seg.value > 0 {
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(2, geo.size.width * CGFloat(seg.value) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 14, alignment: .leading)
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    /// 图例：色点 + 标签 + 具体占用（2026-09-06 TopFlow要求标签后带数值）。
    private var storageLegend: some View {
        // 标签后追加数值（如「浏览器缓存 10.5 MB」），最小列宽相应放宽避免折行。
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(overviewSegments.indices, id: \.self) { i in
                let seg = overviewSegments[i]
                HStack(spacing: 5) {
                    Circle().fill(seg.color).frame(width: 8, height: 8)
                    Text(legendLabel(i) + " " + fmt(seg.value))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legendLabel(_ i: Int) -> String {
        [String(localized: "workspace"), String(localized: "attachments"),
         String(localized: "browser_cache"), String(localized: "session_cache"),
         String(localized: "runtime_logs")][i]
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
            // [2026-09-11 修复] sessionSubdirs 实为 5 个（含 subagent），旧注释漏写；
            // 且 subagent 此前**无归类分支**——它计入会话占用列表却不进任何概览分类，
            // 造成「会话占用合计 ≠ 概览五类之和」的口径漏项。
            let subs = SessionFileRouter.sessionSubdirs
            for (id, title, updated) in sessions {
                let sessionDir = base.appendingPathComponent(id.uuidString, isDirectory: true)
                var sessionBytes: Int64 = 0
                for sub in subs {
                    let size = fs.sizeOfDirectory(sessionDir.appendingPathComponent(sub))
                    sessionBytes += size
                    switch sub {
                    case "workspace", "offloads": ov.workspace += size
                    case "attachments": ov.attachments += size
                    // browser/ 与 subagent/ 都属「会话缓存」（可重建，见 StorageOverview 定义）
                    case "browser", "subagent": ov.sessionCache += size
                    default: break
                    }
                }
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
            await BrowserEngineAdapter.shared.clearBrowserCaches()
            await MainActor.run {
                isBusy = false
                cleanupMessage = String(localized: "browser_cache_cleared")
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
            let fs = FileSystemManager.shared
            let base = SessionFileRouter.sessionsHostBase
            // [2026-09-11 验证性反馈] 先统计后删除——与「清理旧附件」同口径，把实际
            // 释放字节写进结果提示。此前只弹固定文案，而会话缓存本就常为 0，
            // 用户无法区分「清掉了」与「本来就没有」。
            var freed: Int64 = 0
            if let sessionDirs = try? fm.contentsOfDirectory(atPath: base.path) {
                for s in sessionDirs where UUID(uuidString: s) != nil {
                    // 仅清各会话的浏览器数据（截图/下载，可重建）；runtimeRecords
                    // 不是缓存——子代理复用/关闭依赖它（2026-09-05 修复，不再删除）。
                    let browserDir = base.appendingPathComponent(s).appendingPathComponent("browser")
                    freed += fs.sizeOfDirectory(browserDir)
                    removeContents(of: browserDir)
                }
            }
            DispatchQueue.main.async {
                isBusy = false
                cleanupMessage = String(format: String(localized: "session_cache_cleared_bytes"), fmt(freed))
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
                cleanupMessage = String(format: String(localized: "cleaned_of_old_attachments"), fmt(removed))
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
                cleanupMessage = String(localized: "all_local_data_cleared")
                showCleanupResult = true
                reload()
            }
        }
    }

    private func saveFiles() {
        SettingsStore.shared.set(files, domain: .files, summary: String(localized: "edit_file_settings"))
    }
}
