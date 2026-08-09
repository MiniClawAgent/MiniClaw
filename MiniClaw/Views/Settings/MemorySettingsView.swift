import SwiftUI

struct MemorySettingsView: View {
    @State private var memory: MemorySettings = MemorySettings()
    @State private var memoryLogs: [MemoryLog] = []
    @State private var longTermMemoryDraft: String = ""
    @State private var activeSheet: SettingsSheet?

    var body: some View {
        List {
            Section(L10n.tr("记忆开关")) {
                Toggle(L10n.tr("启用记忆"), isOn: $memory.isEnabled)
                    .onChange(of: memory.isEnabled) { _, _ in persist() }
                Toggle(L10n.tr("自动保存每日记忆"), isOn: $memory.autoSaveDaily)
                    .onChange(of: memory.autoSaveDaily) { _, _ in persist() }
                Toggle(L10n.tr("向量召回（FTS+向量）"), isOn: $memory.embeddingEnabled)
                    .onChange(of: memory.embeddingEnabled) { _, _ in persist() }
            }

            Section(L10n.tr("长期记忆 (MEMORY.md)")) {
                Button {
                    loadLongTermMemory()
                    activeSheet = .longTermEditor
                } label: {
                    HStack {
                        Label(L10n.tr("查看 / 编辑长期记忆"), systemImage: "brain.head.profile")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section(L10n.tr("每日记忆")) {
                if memoryLogs.isEmpty {
                    Text(L10n.tr("暂无日志"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(memoryLogs) { log in
                        Button {
                            activeSheet = .dailyLog(url: log.url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.date)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if let preview = log.preview {
                                        Text(preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Text(log.size)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        }
        .navigationTitle(L10n.tr("记忆"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadFromStore() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .dailyLog(let url):
                NavigationStack {
                    ScrollView {
                        Text((try? String(contentsOf: url, encoding: .utf8)) ?? L10n.tr("无法读取文件"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                }
            case .longTermEditor:
                NavigationStack {
                    TextEditor(text: $longTermMemoryDraft)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal)
                        .navigationTitle("MEMORY.md")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.tr("取消")) { activeSheet = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.tr("保存")) { saveLongTermMemory() }
                                    .disabled(longTermMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
            }
        }
    }

    private func loadFromStore() {
        memory = SettingsStore.shared.settings.memory
        Task { memoryLogs = await Self.readDailyLogsAsync() }
    }

    private func persist() {
        SettingsStore.shared.set(memory, domain: .memory, summary: L10n.tr("更新记忆设置"))
    }

    private func loadLongTermMemory() {
        let url = FileSystemManager.shared.memoryDir.appendingPathComponent("MEMORY.md")
        // 后台读取（MEMORY.md 随使用增长可能很大），不阻塞主线程。
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: url, encoding: .utf8)) ?? FileSystemManager.defaultMemoryMarkdown
            }.value
            longTermMemoryDraft = text
        }
    }

    private func saveLongTermMemory() {
        do {
            try MemoryManager.shared.writeLongTermMemory(longTermMemoryDraft, mode: .replace)
            activeSheet = nil
        } catch {
            return
        }
    }

    /// 后台异步读取每日记忆日志清单，避免主线程同步 IO（对齐原则：重 IO 一律 async 化）。
    private nonisolated static func readDailyLogsAsync() async -> [MemoryLog] {
        await Task.detached(priority: .userInitiated) {
            let dir = FileSystemManager.shared.memoryDir
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
            var logs: [MemoryLog] = []
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            for f in files {
                let name = f.lastPathComponent
                guard name.hasSuffix(".md"), name.count == "YYYY-MM-DD.md".count else { continue }
                let dateStr = String(name.dropLast(3))
                guard df.date(from: dateStr) != nil else { continue }
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let content = try? String(contentsOf: f, encoding: .utf8)
                let preview = content?
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .dropFirst()
                    .prefix(2)
                    .joined(separator: " ")
                logs.append(
                    MemoryLog(
                        date: dateStr,
                        size: formatBytes(Int64(size)),
                        preview: preview?.isEmpty == false ? preview : nil,
                        url: f
                    )
                )
            }
            return logs.sorted { $0.date > $1.date }
        }.value
    }

    /// nonisolated：会在 `readDailyLogsAsync` 的 detached 后台闭包里被调用，不能带 MainActor 隔离。
    private nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct MemoryLog: Identifiable {
    var id: String { url.path }
    let date: String
    let size: String
    let preview: String?
    let url: URL
}

private enum SettingsSheet: Identifiable {
    case dailyLog(url: URL)
    case longTermEditor

    var id: String {
        switch self {
        case .dailyLog(let url): return "daily-\(url.path)"
        case .longTermEditor: return "longterm"
        }
    }
}
