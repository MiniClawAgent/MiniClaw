import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// 打开外部链接（备案号跳工信部 ICP 备案查询网站）。
    @Environment(\.openURL) private var openURL
    /// 真实版本号（从主 App bundle 读取，2026-08-14 起不再硬编码）。
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "MiniClaw v\(version)"
    }
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让所有 `L10n.tr` 文案以新语言重新求值（替代旧的 .id() 整树重建方案）。
    @ObservedObject private var l10n = L10n.shared
    @State private var navigateToGroups: Bool = false
    @State private var navigateToProviders: Bool = false
    @State private var navigateToEnvVars: Bool = false
    @State private var navigateToPermissions: Bool = false

    var body: some View {
        List {
            // 主页仅显示组入口行（唐唐 2026-08-30 定稿）：点入二级页才显示组内内容。
            // 每行独立 Section = 独立卡片，行间留隙不贴连（唐唐要求）。
            Section(footer: Text(L10n.l("settings_group_agent_sub"))) {
                NavigationLink(destination: { AgentSettingsGroupView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "cat.fill", color: .orange, title: L10n.l("agent"))
                }
            }

            Section(footer: Text(L10n.l("manage_extensible_plugin_packages"))) {
                NavigationLink(destination: { PluginsSettingsView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "puzzlepiece.extension.fill", color: .blue, title: L10n.l("plugins"))
                }
            }

            Section(footer: Text(L10n.l("settings_group_storage_sub"))) {
                NavigationLink(destination: { StorageSettingsGroupView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "externaldrive.fill", color: .green, title: L10n.l("storage"))
                }
            }

            Section(footer: Text(L10n.l("system_dark_light"))) {
                NavigationLink(destination: { AppearanceSettingsView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: L10n.l("appearance"))
                }
            }

            Section(footer: Text(L10n.l("settings_group_general_sub"))) {
                NavigationLink(destination: { GeneralSettingsGroupView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "gearshape.2.fill", color: .gray, title: L10n.l("general_section"))
                }
            }

            Section(footer: Text(L10n.l("runtime_logs_and_audit_logs"))) {
                NavigationLink(destination: { LogsView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "doc.text.below.ecg", color: .blue, title: L10n.l("logs"))
                }
            }

            Section(footer: Text(L10n.l("version_info_and_license"))) {
                NavigationLink(destination: { AboutView() }) {
                    // 副标题移到分组脚注（唐唐 2026-09-02）。
                    SettingsRow(icon: "info.circle.fill", color: .teal, title: L10n.l("about_miniclaw_app"))
                }
            }

            // App version footer（版本号 Bundle.main 真实值；备案号点击跳工信部备案查询）
            Section {
                EmptyView()
            } footer: {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(versionString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("湘ICP备2023018958号-16A")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .onTapGesture {
                                openURL(URL(string: "https://beian.miit.gov.cn/")!)
                            }
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.insetGrouped)
        // 背景主题挂载点：列表整体背景透明（行白卡保留，间隙透出主题）；
        // 无主题时组件回退系统背景（视觉与现状一致）。
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("settings"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToGroups) {
            GroupsSettingsView()
        }
        .navigationDestination(isPresented: $navigateToProviders) {
            ProviderSettingsView()
        }
        .navigationDestination(isPresented: $navigateToPermissions) {
            PermissionsSettingsView()
        }
        .navigationDestination(isPresented: $navigateToEnvVars) {
            EnvVarsSettingsView()
        }
        .onAppear {
            handleDeepLink()
        }
        .onChange(of: appState.settingsDeepLink) { _ in handleDeepLink() }
    }

    // MARK: - Deep Link
    private func handleDeepLink() {
        guard let link = appState.settingsDeepLink else { return }
        switch link {
        case "models":
            navigateToGroups = true
        case "providers":
            navigateToProviders = true
        case "environments":
            navigateToEnvVars = true
        case "permissions":
            navigateToPermissions = true
        default:
            break
        }
        appState.settingsDeepLink = nil
    }
}

// MARK: - Settings Row

struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    /// 副标题（可省略）：设置主页 2026-09-02 起副标题移到分组脚注，行内仅剩图标+标题。
    var subtitle: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
