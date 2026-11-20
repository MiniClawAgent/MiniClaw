import SwiftUI

// MARK: - 当前 App 图标

/// 读取**当前 App 图标**（跟随包内 AppIcon 资源：以后图标换成什么样，关于页就显示什么样）。
///
/// iOS 没有「直接取图标 UIImage」的公开 API，标准做法是读 Info.plist 里
/// `CFBundleIcons(CFBundleIcons~ipad).CFBundlePrimaryIcon.CFBundleIconFiles` 列出的
/// 图标文件名，再从 bundle 根目录加载 —— asset catalog 里的 AppIcon 会被编译成
/// 这些 PNG 落到 bundle 根（如 `AppIcon60x60@2x.png`），所以 `UIImage(named:)`
/// 传基础名即可命中对应倍率图。
/// 注意：包内图标是**方形不透明**图（圆角由系统在桌面侧裁），故展示时需自行裁圆角。
/// 读不到时返回 nil，由调用方兜底（绝不出现空白）。
private enum AppIconProvider {
    static var current: UIImage? {
        let info = Bundle.main.infoDictionary
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info?[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            names.append(contentsOf: files)
        }
        // 文件名自带尺寸（AppIcon60x60 / AppIcon76x76…）：按字典序倒排近似取分辨率最高者。
        for name in names.sorted(by: >) where !name.isEmpty {
            if let image = UIImage(named: name) { return image }
        }
        return nil
    }
}

// MARK: - About View

struct AboutView: View {
    /// 开发者选项：连点图标 10 次解锁（点击不赋予任何视觉反馈）。
    @AppStorage("dev.options.enabled") private var devOptionsEnabled = false
    @State private var iconTapCount = 0
    /// 真实版本号（从主 App bundle 读取，2026-08-14 起不再硬编码）。
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (Build \(build))"
    }

    /// 图标连点计数：满 10 次解锁开发者选项，且**不弹任何提示**（TopFlow要求）。
    private func handleIconTap() {
        guard !devOptionsEnabled else { return }
        iconTapCount += 1
        if iconTapCount >= 10 {
            iconTapCount = 0
            devOptionsEnabled = true
        }
    }

    /// 关于页顶部图标的边长与圆角。
    /// **关键约定（2026-09-12 TopFlow要求）**：图标一律从包内现读（`AppIconProvider`），
    /// 圆角**由我们自己裁** —— 包内图标是方形不透明图（圆角由系统在桌面侧裁），
    /// 不自己裁就是一张方图。两者刻意解耦：**以后换成任何新 App 图标，这里自动显示新图标，
    /// 且始终按同一 iOS 图标比例裁角**，无需改这里任何一行。
    private let aboutIconSide: CGFloat = 72
    /// iOS 图标圆角 ≈ 边长的 22.37%（squircle），由边长推导而非写死，
    /// 避免以后调整尺寸时圆角比例失真。
    private var aboutIconRadius: CGFloat { aboutIconSide * 0.2237 }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        // 顶部图标 = 真实 App 图标（2026-09-12 TopFlow要求：读包内图标，
                        // 以后换图标这里自动跟着变）。72pt ≈ iOS 图标圆角比例 0.2237。
                        if let icon = AppIconProvider.current {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: aboutIconSide, height: aboutIconSide)
                                .clipShape(RoundedRectangle(cornerRadius: aboutIconRadius, style: .continuous))
                                // 2026-09-15 TopFlow要求：描边颜色**对齐聊天页工具指示器**
                                // （`ChatColors.toolBorder` = separator@50%，见 AssistantBlockView）。
                                // 粗细取 1pt —— 图标 72pt 是工具胶囊（36pt）的两倍，同值 0.5pt 观感只有一半。
                                // 圆角矩形参数与上方 clipShape 完全相同，描边才与外轮廓严丝合缝。
                                .overlay(
                                    RoundedRectangle(cornerRadius: aboutIconRadius, style: .continuous)
                                        .stroke(ChatColors.toolBorder, lineWidth: 1)
                                )
                                // 连点 10 次解锁开发者选项：**不给任何反馈**（无动画、无提示）。
                                .contentShape(RoundedRectangle(cornerRadius: aboutIconRadius, style: .continuous))
                                .onTapGesture { handleIconTap() }
                        } else {
                            // 兜底：读不到图标时保留原 SF Symbol，绝不渲染成空白。
                            Image(systemName: "cat.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.orange)
                        }

                        Text("MiniClaw")
                            .font(.title)
                            .fontWeight(.bold)

                        Text(versionString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(String(localized: "ios_agent_app"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }

            Section(String(localized: "about_miniclaw_doc")) {
                NavigationLink(String(localized: "about_miniclaw_doc")) {
                    DocumentView(filename: "关于MiniClaw.md", title: String(localized: "about_miniclaw_doc"))
                }
                NavigationLink(String(localized: "user_agreement")) {
                    DocumentView(filename: "用户使用协议.md", title: String(localized: "user_agreement"))
                }
                NavigationLink(String(localized: "privacy_policy")) {
                    DocumentView(filename: "用户隐私政策.md", title: String(localized: "privacy_policy"))
                }
            }

            // 连点图标 10 次解锁开发者选项（无任何提示/动画，符合"不给反馈"）。
            Section(String(localized: "acknowledgements")) {
                NavigationLink(String(localized: "acknowledgements")) {
                    DocumentView(filename: "鸣谢.md", title: String(localized: "acknowledgements"))
                }
            }

            if devOptionsEnabled {
                Section("开发者选项") {
                    NavigationLink("提示词与调试") {
                        DeveloperOptionsView()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 开发者选项

/// 开发者选项（连点关于页图标 10 次解锁）。
/// 目前只放"把发给模型的提示词落盘"，用于核对实际注入内容，不做任何 UI 提示。
struct DeveloperOptionsView: View {
    @AppStorage("dev.promptDump") private var promptDumpEnabled = false
    @AppStorage("chat.inlineToolBadges") private var inlineToolBadges = true
    @State private var dumpFiles: [(name: String, size: Int)] = []

    var body: some View {
        List {
            Section {
                Toggle("记录每轮提示词", isOn: $promptDumpEnabled)
                Text("开启后，每次向模型发起请求前，把拼好的 system（稳定段 + 易变段）原样写入 logs/prompt-<时间>.txt，仅保留最近 20 份。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("提示词转储")
            }

            Section {
                Toggle("工具指示器折叠为圆点", isOn: $inlineToolBadges)
                Text("关闭后回到「每个工具占一行」的旧形态（用于对比）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("会话页")
            }

            Section {
                if dumpFiles.isEmpty {
                    Text("还没有转储。开启上面的开关后，发一条消息就会生成。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(dumpFiles, id: \.name) { f in
                    NavigationLink {
                        PromptDumpDetailView(fileName: f.name)
                    } label: {
                        HStack {
                            Text(f.name).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Button(role: .destructive) {
                    PromptDumpStore.clearAll()
                    refresh()
                } label: {
                    Text("清除全部转储")
                }
            } header: {
                Text("已生成的文件")
            }
        }
        .navigationTitle("开发者选项")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        dumpFiles = PromptDumpStore.list()
    }
}

/// 提示词转储的落盘与清理（logs 目录，按时间命名，只保留最近 20 份）。
enum PromptDumpStore {
    static var directory: URL {
        FileSystemManager.shared.miniClawRoot.appendingPathComponent("logs", isDirectory: true)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dev.promptDump")
    }

    static func list() -> [(name: String, size: Int)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("prompt-") && $0.hasSuffix(".txt") }
            .sorted(by: >)
            .compactMap { name in
                let p = directory.appendingPathComponent(name).path
                guard let attrs = try? fm.attributesOfItem(atPath: p),
                      let size = attrs[.size] as? Int else { return nil }
                return (name, size)
            }
    }

    static func clearAll() {
        for f in list() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(f.name))
        }
    }

    /// 写一份转储；超过 20 份删最旧的。失败静默（开发工具不应影响主流程）。
    static func write(stable: String, volatile: String, sessionID: UUID?) {
        guard isEnabled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let sid = sessionID?.uuidString.prefix(8) ?? "nil"
        let name = "prompt-\(fmt.string(from: Date()))-\(sid).txt"
        let body = """
        # MiniClaw 提示词转储
        # 会话: \(sessionID?.uuidString ?? "nil")
        # 时间: \(Date())
        # 稳定段字符数: \(stable.count)  易变段字符数: \(volatile.count)

        ===== STABLE =====
        \(stable)

        ===== VOLATILE =====
        \(volatile)
        """
        try? body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let all = list()
        if all.count > 20 {
            for old in all.suffix(from: 20) {
                try? fm.removeItem(at: directory.appendingPathComponent(old.name))
            }
        }
    }
}

// MARK: - 提示词转储详情

/// 查看单份提示词转储：等宽字体、可滚动、可选中复制。
struct PromptDumpDetailView: View {
    let fileName: String
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "（空文件）" : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let url = PromptDumpStore.directory.appendingPathComponent(fileName)
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
