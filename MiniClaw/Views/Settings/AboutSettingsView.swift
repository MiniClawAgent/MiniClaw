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
    /// 真实版本号（从主 App bundle 读取，2026-08-14 起不再硬编码）。
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (Build \(build))"
    }

    /// 关于页顶部图标的边长与圆角。
    /// **关键约定（2026-09-12 唐唐要求）**：图标一律从包内现读（`AppIconProvider`），
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
                        // 顶部图标 = 真实 App 图标（2026-09-12 唐唐要求：读包内图标，
                        // 以后换图标这里自动跟着变）。72pt ≈ iOS 图标圆角比例 0.2237。
                        if let icon = AppIconProvider.current {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: aboutIconSide, height: aboutIconSide)
                                .clipShape(RoundedRectangle(cornerRadius: aboutIconRadius, style: .continuous))
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

            Section(String(localized: "open_source_components")) {
                Text(String(localized: "swiftsoup_html_parsing_n_highlightr_code_highlighting_n_markdownui_markdown_rendering"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
