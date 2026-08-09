import SwiftUI
import UniformTypeIdentifiers

/// 技能列表排序方式
private enum SkillSortMode {
    case name        // 按名称（默认）
    case updated      // 按更新/安装时间
}

struct SkillsSettingsView: View {
    @State private var skills: [SkillPackage] = []
    @State private var sortMode: SkillSortMode = .name

    @State private var showImport: Bool = false
    @State private var importMessage: String = ""
    @State private var showImportResult: Bool = false

    var body: some View {
        List {
            if skills.isEmpty {
                Section {
                    Text(L10n.tr("还没有任何技能。点击右上角「+」从本地导入，或把符合 技能格式 格式的技能目录放入 skills/。"))
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
        .navigationTitle(L10n.tr("技能"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sortMode = .name
                    } label: {
                        Label(L10n.tr("按名称"), systemImage: sortMode == .name ? "checkmark" : "")
                    }
                    Button {
                        sortMode = .updated
                    } label: {
                        Label(L10n.tr("按更新时间"), systemImage: sortMode == .updated ? "checkmark" : "")
                    }
                } label: {
                    Label(L10n.tr("排序"), systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showImport = true }) {
                    Label(L10n.tr("本地导入"), systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.zip, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let res = SkillManager.shared.importSkillFile(from: url)
                importMessage = res.message.isEmpty ? L10n.tr("导入完成。") : res.message
                showImportResult = true
                reload()
            case .failure(let error):
                importMessage = String(format: L10n.tr("选择文件失败：%@"), error.localizedDescription)
                showImportResult = true
            }
        }
        .alert(L10n.tr("导入结果"), isPresented: $showImportResult) {
            Button(L10n.tr("好")) {}
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
    @State private var isEnabled: Bool

    init(skill: SkillPackage) {
        self.skill = skill
        _isEnabled = State(initialValue: skill.isEnabled)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.headline)
                    Text("v\(skill.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sourceBadge
                }
                Text(skill.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    SkillManager.shared.setEnabled(skill.name, newValue)
                }
        }
        .padding(.vertical, 4)
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: skill.source == "builtin" ? "internaldrive.fill" : "tray.and.arrow.down.fill")
                .imageScale(.small)
            Text(skill.source == "builtin" ? L10n.tr("内置技能") : L10n.tr("本地导入"))
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
    }
}

/// 技能详情页
private struct SkillDetailView: View {
    let skill: SkillPackage
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool
    @State private var showUpdateImporter = false
    @State private var showFile = false
    @State private var fileView: (name: String, content: String)?
    @State private var alertMsg = ""
    @State private var showAlert = false

    init(skill: SkillPackage, onChanged: @escaping () -> Void) {
        self.skill = skill
        self.onChanged = onChanged
        _isEnabled = State(initialValue: skill.isEnabled)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    var body: some View {
        List {
            Section(L10n.tr("详情")) {
                LabeledContent(L10n.tr("名称"), value: skill.name)
                LabeledContent(L10n.tr("版本号"), value: "v\(skill.version)")
                LabeledContent(L10n.tr("安装时间"), value: Self.dateFmt.string(from: skill.installDate))
                HStack {
                    Text(L10n.tr("来源"))
                    Spacer()
                    sourceBadge
                }
                Toggle(L10n.tr("启用（注入对话）"), isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        SkillManager.shared.setEnabled(skill.name, newValue)
                    }
            }

            Section(L10n.tr("更新")) {
                Button {
                    // 非网页链接下载来源，禁用
                } label: {
                    Label(L10n.tr("从 URL 更新"), systemImage: "link")
                }
                .disabled(true)
                .foregroundStyle(.secondary)

                Button {
                    showUpdateImporter = true
                } label: {
                    Label(L10n.tr("从文件更新"), systemImage: "doc")
                }

                Button {
                    alertMsg = L10n.tr("尚未启用 iCloud 同步（需在签名能力中开启 iCloud）。")
                    showAlert = true
                } label: {
                    Label(L10n.tr("同步 iCloud"), systemImage: "icloud")
                }
                .foregroundStyle(.secondary)
            }

            Section(L10n.tr("描述")) {
                Text(SkillManager.shared.introSection(named: skill.name))
                    .font(.callout)
            }

            Section(L10n.tr("文件")) {
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
                            Label(L10n.tr("删除技能"), systemImage: "trash")
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
            allowedContentTypes: [.zip, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let res = SkillManager.shared.updateSkill(directoryName: skill.directoryName, from: url)
                alertMsg = res.message.isEmpty ? L10n.tr("更新完成。") : res.message
                showAlert = true
                onChanged()
            case .failure(let error):
                alertMsg = String(format: L10n.tr("选择文件失败：%@"), error.localizedDescription)
                showAlert = true
            }
        }
        .alert(L10n.tr("更新结果"), isPresented: $showAlert) {
            Button(L10n.tr("好")) {}
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
                .navigationTitle(fileView?.name ?? L10n.tr("文件"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("完成")) { showFile = false }
                    }
                }
            }
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: skill.source == "builtin" ? "internaldrive.fill" : "tray.and.arrow.down.fill")
                .imageScale(.small)
            Text(skill.source == "builtin" ? L10n.tr("内置技能") : L10n.tr("本地导入"))
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}
