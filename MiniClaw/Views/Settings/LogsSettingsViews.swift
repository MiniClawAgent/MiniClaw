import SwiftUI
import UIKit

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
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: allLogURLs) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(String(localized: "export_all_logs_runtime_logs_crash_logs"))
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
                Label(String(localized: "enable_logging"), systemImage: "power")
            }
            .onChange(of: loggingEnabled) { newValue in
                AppLogger.shared.setEnabled(newValue)
                reload()
            }

            if runtimeFiles.isEmpty {
                Text(loggingEnabled
                     ? String(localized: "no_run_logs_yet_debug_logs_are_generated_daily_once_the_app_runs")
                     : String(localized: "logging_is_off_no_new_run_logs_will_be_generated"))
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
            Text(String(localized: "runtime_logs"))
        } footer: {
            Text(String(localized: "records_app_debug_logs_by_day_errors_freezes_infinite_loops_crashes_logging_stops_when_the_switch_is_off_swipe_left_to_delete_a_single_log"))
        }
    }

    // MARK: - 崩溃日志

    private var crashSection: some View {
        Section {
            if crashFiles.isEmpty {
                Text(String(localized: "no_crash_logs_yet_automatically_recorded_after_a_crash_or_abnormal_exit"))
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
            Text(String(localized: "crash_log"))
        } footer: {
            Text(String(localized: "crash_report_full_description"))
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
                    Text(String(localized: "audit_log"))
                    Spacer()
                }
            }
        } header: {
            Text(String(localized: "audit_log"))
        } footer: {
            Text(String(localized: "records_setting_changes_and_rollback_actions_tap_to_view_all_audit_content"))
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
                Text(String(localized: "no_audit_records_yet_automatically_logged_after_any_config_change"))
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
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .listStyle(.plain)
        .navigationTitle(String(localized: "audit_log"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAudit)
        .refreshable { loadAudit() }
    }

    private func loadAudit() {
        auditEntries = SettingsStore.shared.auditEntries
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
                    .help(String(localized: "export_entire_log_file"))
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
