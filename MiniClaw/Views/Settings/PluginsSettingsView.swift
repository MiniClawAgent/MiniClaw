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
                    Text(L10n.l("no_skills_yet_tap_in_the_top_right_to_import_from_local_files_or_place_a_skill_directory_following_the_skill_format_into_skills"))
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
        .navigationTitle(L10n.l("plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sortMode = .name
                    } label: {
                        Label(L10n.l("by_name"), systemImage: sortMode == .name ? "checkmark" : "")
                    }
                    Button {
                        sortMode = .updated
                    } label: {
                        Label(L10n.l("by_update_time"), systemImage: sortMode == .updated ? "checkmark" : "")
                    }
                } label: {
                    Label(L10n.l("sort"), systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showImport = true }) {
                    Label(L10n.l("local_import"), systemImage: "plus")
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
                importMessage = res.message.isEmpty ? L10n.l("import_complete") : res.message
                showImportResult = true
                reload()
            case .failure(let error):
                importMessage = String(format: L10n.l("failed_to_select_file"), error.localizedDescription)
                showImportResult = true
            }
        }
        .alert(L10n.l("import_result"), isPresented: $showImportResult) {
            Button(L10n.l("ok")) {}
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// 拉取式绑定：开关状态以持久化设置 + 来源缺省为唯一真相（每次渲染重读），
    /// 列表行与详情页两处切换即时同步，杜绝 @State 快照漂移。
    private var enabledBinding: Binding<Bool> {
        Binding(
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
    @State private var showFile = false
    @State private var fileView: (name: String, content: String)?
    @State private var alertMsg = ""
    @State private var showAlert = false

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
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { SkillManager.shared.effectiveEnabled(name: skill.name, source: skill.source) },
            set: { newValue in
                SkillManager.shared.setEnabled(skill.name, newValue)
                onChanged()
            }
        )
    }

    var body: some View {
        List {
            Section(L10n.l("details")) {
                LabeledContent(L10n.l("name"), value: skill.name)
                LabeledContent(L10n.l("version_number"), value: "v\(skill.version)")
                LabeledContent(L10n.l("install_time"), value: Self.dateFmt.string(from: skill.installDate))
                HStack {
                    Text(L10n.l("source"))
                    Spacer()
                    sourceBadge
                }
                // 启用开关（全类型）：skill=注入会话/指令入口；subagent=角色参与派发；
                // rule=规则注入；soul=应用此人格（排他单选，启用即自动停用其他 soul 插件）。
                Toggle(skill.type == "skill"
                       ? L10n.l("enable_inject_into_conversation")
                       : L10n.l("enable_plugin"),
                       isOn: enabledBinding)
            }

            if skill.type == "skill" {
                Section(L10n.l("update")) {
                    Button {
                        // 非网页链接下载来源，禁用
                    } label: {
                        Label(L10n.l("update_from_url"), systemImage: "link")
                    }
                    .disabled(true)
                    .foregroundStyle(.secondary)

                    Button {
                        showUpdateImporter = true
                    } label: {
                        Label(L10n.l("update_from_file"), systemImage: "doc")
                    }

                    Button {
                        alertMsg = L10n.l("icloud_sync_is_not_enabled_yet_you_need_to_enable_icloud_in_the_signing_capabilities")
                        showAlert = true
                    } label: {
                        Label(L10n.l("sync_icloud"), systemImage: "icloud")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            // 描述：读 plugin.json 的 description 字段（内置必填/第三方选填，
            // loadSkills 已按清单→frontmatter→"无描述"兜底）。
            Section(L10n.l("description")) {
                Text(skill.description)
                    .font(.callout)
            }

            Section(L10n.l("files")) {
                ForEach(SkillManager.shared.skillFiles(directoryName: skill.directoryName), id: \.self) { rel in
                    Button {
                        if let content = SkillManager.shared.fileContent(
                            directoryName: skill.directoryName, relativePath: rel
                        ) {
                            fileView = (rel, content)
                            showFile = true
                        }
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
                            Label(L10n.l("delete_skill"), systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
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
                alertMsg = res.message.isEmpty ? L10n.l("update_complete") : res.message
                showAlert = true
                onChanged()
            case .failure(let error):
                alertMsg = String(format: L10n.l("failed_to_select_file"), error.localizedDescription)
                showAlert = true
            }
        }
        .alert(L10n.l("update_result"), isPresented: $showAlert) {
            Button(L10n.l("ok")) {}
        } message: {
            Text(alertMsg)
        }
        .sheet(isPresented: $showFile) {
            NavigationStack {
                ScrollView {
                    if let fv = fileView {
                        Text(fv.content)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .navigationTitle(fileView?.name ?? L10n.l("files"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.l("done")) { showFile = false }
                    }
                }
            }
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: skill.source == "builtin" ? "internaldrive.fill" : "tray.and.arrow.down.fill")
                .imageScale(.small)
            Text(skill.source == "builtin" ? L10n.l("built_in_skills") : L10n.l("local_import"))
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}
