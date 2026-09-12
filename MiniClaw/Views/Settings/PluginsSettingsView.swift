import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.mpk` 插件压缩包（zip 兼容）。用于文件选择器筛选。
    static let mpk = UTType(filenameExtension: "mpk") ?? .zip
}

/// 技能列表排序方式
private enum SkillSortMode {
    case name        // 按名称（默认）
    case updated      // 按更新/安装时间
}

struct PluginsSettingsView: View {
    @State private var skills: [SkillPackage] = []
    @State private var sortMode: SkillSortMode = .name

    @State private var showImport: Bool = false
    @State private var importMessage: String = ""
    @State private var showImportResult: Bool = false

    var body: some View {
        List {
            if skills.isEmpty {
                Section {
                    Text(String(localized: "no_skills_yet_tap_in_the_top_right_to_import_from_local_files_or_place_a_skill_directory_following_the_skill_format_into_skills"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(sortedSkills) { skill in
                NavigationLink {
                    SkillDetailView(skill: skill, onChanged: reload)
                } label: {
                    SkillRowView(skill: skill)
                }
                .deleteDisabled(skill.source == "builtin")
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    let skill = sortedSkills[idx]
                    guard skill.source != "builtin" else { continue }
                    try? SkillManager.shared.deleteSkill(directoryName: skill.directoryName)
                }
                reload()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sortMode = .name
                    } label: {
                        Label(String(localized: "by_name"), systemImage: sortMode == .name ? "checkmark" : "")
                    }
                    Button {
                        sortMode = .updated
                    } label: {
                        Label(String(localized: "by_update_time"), systemImage: sortMode == .updated ? "checkmark" : "")
                    }
                } label: {
                    Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showImport = true }) {
                    Label(String(localized: "local_import"), systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.zip, .mpk],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let res = SkillManager.shared.importSkillFile(from: url)
                importMessage = res.message.isEmpty ? String(localized: "import_complete") : res.message
                showImportResult = true
                reload()
            case .failure(let error):
                importMessage = String(format: String(localized: "failed_to_select_file"), error.localizedDescription)
                showImportResult = true
            }
        }
        .alert(String(localized: "import_result"), isPresented: $showImportResult) {
            Button(String(localized: "ok")) {}
        } message: {
            Text(importMessage)
        }
        .onAppear { reload() }
    }

    private var sortedSkills: [SkillPackage] {
        switch sortMode {
        case .name:
            skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .updated:
            skills.sorted { $0.installDate > $1.installDate }
        }
    }

    private func reload() {
        skills = SkillManager.shared.loadSkills()
    }
}

/// 列表行：约三行高度 —— 第一行名称+版本+类型图标（图标紧贴版本号），右侧为启用开关。
/// NavigationLink 自动在开关右侧渲染箭头；HStack(center) 让开关与箭头垂直居中对齐。
private struct SkillRowView: View {
    let skill: SkillPackage

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: SkillManager.pluginIcon(category: skill.category, declared: skill.icon))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    sourceBadge
                }
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // 无启停语义的类型（theme/mcp/model/内置 soul）不显示开关——
            // 判定见 SkillPackage.showsEnableToggle（与详情页同源）。
            if skill.showsEnableToggle {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    /// 拉取式绑定：开关状态以持久化设置 + 来源缺省为唯一真相（每次渲染重读），
    /// 列表行与详情页两处切换即时同步，杜绝 @State 快照漂移。
    /// 例外：记忆工具包（com.miniclaw.builtin.memory）的开关即「设置-记忆-启用记忆」，
    /// 两处共用同一状态，避免插件开关与记忆总开关各说各话。
    private var enabledBinding: Binding<Bool> {
        if ToolPluginManager.isMemoryPlugin(directoryName: skill.directoryName) {
            return Binding(
                get: { ToolPluginManager.memoryToolsEnabled() },
                set: { ToolPluginManager.setMemoryToolsEnabled($0) }
            )
        }
        return Binding(
            get: { SkillManager.shared.effectiveEnabled(name: skill.name, source: skill.source) },
            set: { SkillManager.shared.setEnabled(skill.name, $0) }
        )
    }

    /// 来源标识（列表行）：仅图标——内置为服务器图标，导入为下载托盘图标；文字说明放详情页。
    private var sourceBadge: some View {
        Image(systemName: skill.source == "builtin" ? "internaldrive.fill" : "tray.and.arrow.down.fill")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
    }
}

/// 技能详情页
private struct SkillDetailView: View {
    let skill: SkillPackage
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUpdateImporter = false
    /// 待全屏预览的插件内文件（统一机制：与文件管理器同款 `FilePreviewView`，
    /// 不再自造 sheet + 自读文本渲染——那是「所有文件打开走统一套机制」的唯一例外，
    /// 且在读取失败/相对路径失真时会渲染成空白页）。
    @State private var fileToView: FileBrowserItem?
    @State private var alertMsg = ""
    @State private var showAlert = false
    /// 导出产出的临时 .mpk（非 nil 即弹出系统分享面板）。
    @State private var exportedURL: URL?
    @State private var showExport = false

    init(skill: SkillPackage, onChanged: @escaping () -> Void) {
        self.skill = skill
        self.onChanged = onChanged
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 拉取式绑定（与列表行同口径）：get 每帧读持久化真相，set 写回并通知父级刷新。
    /// 详情页开关状态因此与列表行即时一致，退出重进也不会再出现旧值。
    /// 记忆工具包同列表行：开关即「设置-记忆-启用记忆」，单一真相源。
    private var enabledBinding: Binding<Bool> {
        if ToolPluginManager.isMemoryPlugin(directoryName: skill.directoryName) {
            return Binding(
                get: { ToolPluginManager.memoryToolsEnabled() },
                set: { newValue in
                    ToolPluginManager.setMemoryToolsEnabled(newValue)
                    onChanged()
                }
            )
        }
        return Binding(
            get: { SkillManager.shared.effectiveEnabled(name: skill.name, source: skill.source) },
            set: { newValue in
                SkillManager.shared.setEnabled(skill.name, newValue)
                onChanged()
            }
        )
    }

    var body: some View {
        List {
            Section(String(localized: "details")) {
                LabeledContent(String(localized: "name"), value: skill.name)
                LabeledContent(String(localized: "version_number"), value: "v\(skill.version)")
                LabeledContent(String(localized: "install_time"), value: Self.dateFmt.string(from: skill.installDate))
                HStack {
                    Text(String(localized: "source"))
                    Spacer()
                    sourceBadge
                }
                // 启用开关（按类型）：skill=注入会话/指令入口；subagent=角色参与派发；
                // rule=规则注入；soul=应用此人格（排他单选，启用即自动停用其他 soul 插件）。
                // 无启停语义的类型不显示——判定见 SkillPackage.showsEnableToggle（与列表行同源）。
                if skill.showsEnableToggle {
                    Toggle(skill.type == "skill"
                           ? String(localized: "enable_inject_into_conversation")
                           : String(localized: "enable_plugin"),
                           isOn: enabledBinding)
                }
            }

            if skill.type == "skill" {
                Section(String(localized: "update")) {
                    Button {
                        // 非网页链接下载来源，禁用
                    } label: {
                        Label(String(localized: "update_from_url"), systemImage: "link")
                    }
                    .disabled(true)
                    .foregroundStyle(.secondary)

                    Button {
                        showUpdateImporter = true
                    } label: {
                        Label(String(localized: "update_from_file"), systemImage: "doc")
                    }

                    Button {
                        alertMsg = String(localized: "icloud_sync_is_not_enabled_yet_you_need_to_enable_icloud_in_the_signing_capabilities")
                        showAlert = true
                    } label: {
                        Label(String(localized: "sync_icloud"), systemImage: "icloud")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            // 描述：读 plugin.json 的 description 字段（内置必填/第三方选填，
            // loadSkills 已按清单→frontmatter→"无描述"兜底）。
            Section(String(localized: "description")) {
                Text(skill.description)
                    .font(.callout)
            }

            Section(String(localized: "files")) {
                ForEach(SkillManager.shared.skillFiles(directoryName: skill.directoryName), id: \.self) { rel in
                    Button {
                        guard let url = SkillManager.shared.pluginFileURL(
                            directoryName: skill.directoryName, relativePath: rel
                        ) else { return }
                        // 与文件管理器同款呈现：交给 FilePreviewView 按类型分派（文本/代码/图片/PDF/元信息兜底）。
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                        fileToView = FileBrowserItem(id: url, readURL: url, name: rel, isDir: false, size: size)
                    } label: {
                        Text(rel)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }

            if skill.source != "builtin" {
                Section {
                    Button(role: .destructive) {
                        try? SkillManager.shared.deleteSkill(directoryName: skill.directoryName)
                        onChanged()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label(String(localized: "delete_skill"), systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        // 右上角导出：把插件目录打包成 .mpk 走系统分享面板（导入的插件、
        // 或让 AI 生成的插件都能直接分享给他人安装）。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    do {
                        exportedURL = try SkillManager.shared.exportPluginMPK(directoryName: skill.directoryName)
                        showExport = exportedURL != nil
                    } catch {
                        alertMsg = String(format: String(localized: "export_plugin_failed"), error.localizedDescription)
                        showAlert = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showExport) {
            if let url = exportedURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showUpdateImporter,
            allowedContentTypes: [.zip, .mpk],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let res = SkillManager.shared.updateSkill(directoryName: skill.directoryName, from: url)
                alertMsg = res.message.isEmpty ? String(localized: "update_complete") : res.message
                showAlert = true
                onChanged()
            case .failure(let error):
                alertMsg = String(format: String(localized: "failed_to_select_file"), error.localizedDescription)
                showAlert = true
            }
        }
        .alert(String(localized: "update_result"), isPresented: $showAlert) {
            Button(String(localized: "ok")) {}
        } message: {
            Text(alertMsg)
        }
        // 统一机制：与文件管理器（UnifiedFileBrowser）**逐字同款**的呈现链路——
        // FilePreviewView 自带文件名导航栏 / 分享 / 下滑关闭，并按类型分派查看器。
        .fullScreenCover(item: $fileToView) { item in
            FilePreviewView(fileURL: item.readURL)
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: skill.source == "builtin" ? "internaldrive.fill" : "tray.and.arrow.down.fill")
                .imageScale(.small)
            Text(skill.source == "builtin" ? String(localized: "built_in_skills") : String(localized: "local_import"))
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}
