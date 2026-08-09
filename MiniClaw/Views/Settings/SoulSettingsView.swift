import SwiftUI

struct SoulSettingsView: View {
    @Environment(AppState.self) private var appState
    /// 关闭回调：仅当以全屏封面（如会话页点击 智能体名）弹出时由调用方传入；
    /// 在「设置」页通过 NavigationLink 进入时为 nil，沿用系统返回按钮。
    var dismissAction: (() -> Void)? = nil
    @State private var name: String = ""
    @State private var style: String = ""
    @State private var lang: String = "auto"
    @State private var bodyText: String = ""
    @State private var showSoulFile = false
    @State private var fullSoulText: String = ""
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section(L10n.tr("基本信息")) {
                HStack {
                    Text(L10n.tr("名称"))
                    Spacer()
                    TextField(L10n.tr("智能体名称"), text: $name)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text(L10n.tr("风格"))
                    Spacer()
                    TextField(L10n.tr("响应风格"), text: $style, axis: .vertical)
                        .lineLimit(2...4)
                        .multilineTextAlignment(.trailing)
                        // 多行 TextField 在 HStack 里会吃掉全部可用宽度（比单行的「名称」行宽很多），
                        // 固定宽度与名称行右端对齐。
                        .frame(width: 200)
                }
            }

            Section(L10n.tr("灵魂定义 (SOUL.md)")) {
                TextEditor(text: $bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
            }

            Section {
                Button {
                    fullSoulText = (try? String(contentsOf: soulURL(), encoding: .utf8)) ?? ""
                    showSoulFile = true
                } label: {
                    Label(L10n.tr("查看 / 编辑 SOUL.md 完整内容"), systemImage: "doc.plaintext")
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(L10n.tr("重置灵魂"), systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle(L10n.tr("灵魂"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 弹出场景（首页/会话页顶部点击）不需要左上关闭按钮：右上「勾」= 保存并退出。
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
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
        .onAppear { loadFromSoulFile() }
        .alert(L10n.tr("重置灵魂"), isPresented: $showResetConfirm) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("重置"), role: .destructive) { resetSoulToDefault() }
        } message: {
            Text(L10n.tr("这将把 SOUL.md 恢复为默认内容，你当前的修改（名称、风格、语言、正文）都会丢失。确定继续吗？"))
        }
        .sheet(isPresented: $showSoulFile) {
            NavigationStack {
                TextEditor(text: $fullSoulText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .navigationTitle("SOUL.md")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(L10n.tr("取消")) { showSoulFile = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.tr("保存")) {
                                try? fullSoulText.write(to: soulURL(), atomically: true, encoding: .utf8)
                                loadFromSoulFile() // 回写后重新同步基本信息字段
                                showSoulFile = false
                            }
                        }
                    }
            }
        }
    }

    // MARK: - 读取：SOUL.md 的 frontmatter（灵魂本身）

    private func soulURL() -> URL {
        FileSystemManager.shared.memoryDir.appendingPathComponent("SOUL.md")
    }

    private func loadFromSoulFile() {
        // SOUL.md 可能随使用增长，读取放到后台，主线程只做轻量赋值（对齐原则：重 IO 一律 async）。
        let url = FileSystemManager.shared.memoryDir.appendingPathComponent("SOUL.md")
        Task {
            let raw = await Task.detached(priority: .userInitiated) {
                try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard let raw else { return }
            let (meta, body) = FileSystemManager.parseFrontmatter(raw)
            var newName = meta["name"] ?? "MiniClaw"
            let newStyle = meta["style"] ?? ""
            let newLang = meta["lang"] ?? "auto"
            await MainActor.run {
                name = newName
                style = newStyle
                lang = newLang
                bodyText = body
                // 同步显示名
                appState.agentName = newName
            }
        }
    }

    // MARK: - 保存：写回 SOUL.md 并同步 SoulConfig

    private func save() {
        let content = """
        ---
        name: "\(name)"
        style: "\(style)"
        lang: "\(lang)"
        ---

        \(bodyText)
        """
        try? content.write(to: soulURL(), atomically: true, encoding: .utf8)

        // 同步 SoulConfig（供 ConfigTool / 其它读取保持一致）
        SettingsStore.shared.update(domain: .soul, summary: L10n.tr("修改人格配置")) { (s: inout SoulConfig) in
            s.name = name
            s.style = style
            s.lang = lang
            s.body = bodyText
        }
        // 同步 AppState 显示名（会话页/首页使用）
        appState.agentName = name
        // 以全屏封面弹出时，保存后一并关闭页面
        dismissAction?()
    }

    // MARK: - 重置：恢复为默认 SOUL.md

    private func resetSoulToDefault() {
        try? FileSystemManager.defaultSoulMarkdown.write(to: soulURL(), atomically: true, encoding: .utf8)
        loadFromSoulFile() // 重新同步基本信息与正文
    }
}
