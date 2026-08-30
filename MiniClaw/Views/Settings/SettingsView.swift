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
            // Section 1: 智能体（供应商/模型/词元用量/灵魂/子代理/记忆）
            Section {
                NavigationLink {
                    ProviderSettingsView()
                } label: {
                    SettingsRow(icon: "server.rack", color: .blue, title: L10n.l("providers"), subtitle: L10n.l("configure_llm_providers_and_api"))
                }

                NavigationLink {
                    GroupsSettingsView()
                } label: {
                    SettingsRow(icon: "square.stack.3d.up.fill", color: .purple, title: L10n.l("model_management"), subtitle: L10n.l("manage_model_groups_and_default_model"))
                }

                NavigationLink {
                    TokenUsageView()
                } label: {
                    SettingsRow(icon: "chart.bar.fill", color: .orange, title: L10n.l("token_usage_alias"), subtitle: L10n.l("view_api_usage_statistics"))
                }

                NavigationLink {
                    SoulSettingsView()
                } label: {
                    SettingsRow(icon: "cat.fill", color: .orange, title: L10n.l("soul"), subtitle: L10n.l("define_agent_personality_and_behavior"))
                }

                NavigationLink {
                    SubAgentSettingsView()
                } label: {
                    SettingsRow(icon: "person.2.fill", color: .indigo, title: L10n.l("subagents"), subtitle: L10n.l("control_subagent_enablement_concurrency_and_thinking"))
                }

                NavigationLink {
                    MemorySettingsView()
                } label: {
                    SettingsRow(icon: "brain.fill", color: .purple, title: L10n.l("memory"), subtitle: L10n.l("manage_long_term_and_daily_memory"))
                }
            } header: {
                Text(L10n.l("agent"))
            }

            // Section 2: 插件（插件页 = 所有插件的列表）
            Section {
                NavigationLink {
                    PluginsSettingsView()
                } label: {
                    SettingsRow(icon: "puzzlepiece.extension.fill", color: .blue, title: L10n.l("plugins"), subtitle: L10n.l("manage_extensible_plugin_packages"))
                }
            } header: {
                Text(L10n.l("plugins"))
            }

            // Section 3: 存储
            Section {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    SettingsRow(icon: "externaldrive.fill", color: .green, title: L10n.l("storage"), subtitle: L10n.l("view_and_manage_file_storage"))
                }

                NavigationLink {
                    MountSettingsView()
                } label: {
                    SettingsRow(icon: "externaldrive.connected.to.line.below.fill", color: .mint, title: L10n.l("mounts"), subtitle: L10n.l("manage_external_folder_mount_points"))
                }

                // 同步（iCloud 跨设备同步）：功能开发中，入口暂时隐藏；
                // 完成同步功能后恢复此 NavigationLink（SyncSettingsView 已实现，见 SettingsSubViews.swift）。
                // NavigationLink {
                //     SyncSettingsView()
                // } label: {
                //     SettingsRow(icon: "icloud.fill", color: .cyan, title: L10n.l("sync"), subtitle: L10n.l("icloud_cross_device_sync"))
                // }
            } header: {
                Text(L10n.l("storage"))
            }

            // Section 4: 外观
            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: L10n.l("appearance"), subtitle: L10n.l("system_dark_light"))
                }
            } header: {
                Text(L10n.l("appearance"))
            }

            // Section 5: 通用
            Section {
                NavigationLink {
                    MCPSettingsView()
                } label: {
                    SettingsRow(icon: "link.circle.fill", color: .teal, title: L10n.l("mcp"), subtitle: L10n.l("connect_external_services_and_protocols"))
                }

                NavigationLink {
                    EnvVarsSettingsView()
                } label: {
                    SettingsRow(icon: "key.fill", color: .gray, title: L10n.l("environment_variables"), subtitle: L10n.l("manage_api_keys_and_secrets"))
                }

                NavigationLink {
                    RuntimeStatusView()
                } label: {
                    SettingsRow(icon: "cpu", color: .teal, title: L10n.l("rootfs_management"), subtitle: L10n.l("ish_running"))
                }

                NavigationLink {
                    PermissionsSettingsView()
                } label: {
                    SettingsRow(icon: "lock.shield.fill", color: .indigo, title: L10n.l("permissions_background"), subtitle: L10n.l("background_permission_grants"))
                }

                // 通用设置（默认名/语言/确认对话）——用户重排清单未提及，暂保留于此。
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    SettingsRow(icon: "gearshape.2.fill", color: .gray, title: L10n.l("general_settings"), subtitle: L10n.l("defaults_name_language_confirm_full"))
                }
            } header: {
                Text(L10n.l("general_section"))
            }

            // Section 6: 日志
            Section {
                NavigationLink {
                    LogsView()
                } label: {
                    SettingsRow(icon: "doc.text.below.ecg", color: .blue, title: L10n.l("logs"), subtitle: L10n.l("runtime_logs_and_audit_logs"))
                }
            } header: {
                Text(L10n.l("logs"))
            }

            // Section 7: 关于MiniClaw
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(icon: "info.circle.fill", color: .teal, title: L10n.l("about_miniclaw_app"), subtitle: L10n.l("version_info_and_license"))
                }
            } header: {
                Text(L10n.l("about_miniclaw_app"))
            }

            // App version footer（版本号读取 Bundle.main 真实值，2026-08-14 起不再硬编码）
            Section {
                EmptyView()
            } footer: {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(versionString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 备案号（工信部 ICP 备案，2026-08-14 上架合规要求；点击跳转工信部备案查询网站）
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
