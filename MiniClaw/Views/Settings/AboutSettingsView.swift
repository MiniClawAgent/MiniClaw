import SwiftUI

// MARK: - About View

struct AboutView: View {
    /// 真实版本号（从主 App bundle 读取，2026-08-14 起不再硬编码）。
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (Build \(build))"
    }

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
