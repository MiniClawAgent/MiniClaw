import SwiftUI

/// 设置主页二级组页（唐唐 2026-08-30 定稿：主页只显示组入口行，点入后显示组内二级内容）。
/// 三个组页：智能体 / 存储 / 通用；插件、外观、日志、关于直接链接到现有页面。

/// 智能体组页：供应商、模型管理、词元用量、灵魂、子代理、记忆。
struct AgentSettingsGroupView: View {
    var body: some View {
        List {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("agent"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 存储组页：存储、挂载。
struct StorageSettingsGroupView: View {
    var body: some View {
        List {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("storage"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 通用组页：MCP、环境变量、rootfs管理、权限与后台、通用设置。
struct GeneralSettingsGroupView: View {
    var body: some View {
        List {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(L10n.l("general_section"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
