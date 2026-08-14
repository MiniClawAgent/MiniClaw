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

                        Text(L10n.l("ios_agent_app"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }

            Section(L10n.l("about_miniclaw_doc")) {
                NavigationLink(L10n.l("about_miniclaw_doc")) {
                    DocumentView(filename: "关于MiniClaw.md", title: L10n.l("about_miniclaw_doc"))
                }
                NavigationLink(L10n.l("user_agreement")) {
                    DocumentView(filename: "用户使用协议.md", title: L10n.l("user_agreement"))
                }
                NavigationLink(L10n.l("privacy_policy")) {
                    DocumentView(filename: "用户隐私政策.md", title: L10n.l("privacy_policy"))
                }
            }

            Section(L10n.l("open_source_components")) {
                Text(L10n.l("swiftsoup_html_parsing_n_highlightr_code_highlighting_n_markdownui_markdown_rendering"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.l("about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
