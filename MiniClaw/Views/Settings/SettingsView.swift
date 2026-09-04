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
    @State private var navigateToGroups: Bool = false
    @State private var navigateToProviders: Bool = false
    @State private var navigateToEnvVars: Bool = false
    @State private var navigateToPermissions: Bool = false

    var body: some View {
        List {
            // 主页仅显示组入口行（唐唐 2026-08-30 定稿）：点入二级页才显示组内内容。
            // 每行独立 Section = 独立卡片，行间留隙不贴连（唐唐要求）。
            Section {
                NavigationLink {
                    AgentSettingsGroupView()
                } label: {
                    SettingsRow(icon: "cat.fill", color: .orange, title: String(localized: "agent"), subtitle: String(localized: "settings_group_agent_sub"))
                }
            }

            Section {
                NavigationLink {
                    PluginsSettingsView()
                } label: {
                    SettingsRow(icon: "puzzlepiece.extension.fill", color: .blue, title: String(localized: "plugins"), subtitle: String(localized: "manage_extensible_plugin_packages"))
                }
            }

            Section {
                NavigationLink {
                    StorageSettingsGroupView()
                } label: {
                    SettingsRow(icon: "externaldrive.fill", color: .green, title: String(localized: "storage"), subtitle: String(localized: "settings_group_storage_sub"))
                }
            }

            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: String(localized: "appearance"), subtitle: String(localized: "system_dark_light"))
                }
            }

            Section {
                NavigationLink {
                    GeneralSettingsGroupView()
                } label: {
                    SettingsRow(icon: "gearshape.2.fill", color: .gray, title: String(localized: "general_section"), subtitle: String(localized: "settings_group_general_sub"))
                }
            }

            Section {
                NavigationLink {
                    LogsView()
                } label: {
                    SettingsRow(icon: "doc.text.below.ecg", color: .blue, title: String(localized: "logs"), subtitle: String(localized: "runtime_logs_and_audit_logs"))
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(icon: "info.circle.fill", color: .teal, title: String(localized: "about_miniclaw_app"), subtitle: String(localized: "version_info_and_license"))
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
        .navigationTitle(String(localized: "settings"))
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
    let subtitle: String

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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
