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
                SettingsRow(icon: "server.rack", color: .blue, title: String(localized: "providers"), subtitle: String(localized: "configure_llm_providers_and_api"))
            }

            NavigationLink {
                GroupsSettingsView()
            } label: {
                SettingsRow(icon: "square.stack.3d.up.fill", color: .purple, title: String(localized: "model_management"), subtitle: String(localized: "manage_model_groups_and_default_model"))
            }

            NavigationLink {
                TokenUsageView()
            } label: {
                SettingsRow(icon: "chart.bar.fill", color: .orange, title: String(localized: "token_usage_alias"), subtitle: String(localized: "view_api_usage_statistics"))
            }

            NavigationLink {
                SoulSettingsView()
            } label: {
                SettingsRow(icon: "cat.fill", color: .orange, title: String(localized: "soul"), subtitle: String(localized: "define_agent_personality_and_behavior"))
            }

            NavigationLink {
                SubAgentSettingsView()
            } label: {
                SettingsRow(icon: "person.2.fill", color: .indigo, title: String(localized: "subagents"), subtitle: String(localized: "control_subagent_enablement_concurrency_and_thinking"))
            }

            NavigationLink {
                MemorySettingsView()
            } label: {
                SettingsRow(icon: "brain.fill", color: .purple, title: String(localized: "memory"), subtitle: String(localized: "manage_long_term_and_daily_memory"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "agent"))
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
                SettingsRow(icon: "externaldrive.fill", color: .green, title: String(localized: "storage"), subtitle: String(localized: "view_and_manage_file_storage"))
            }

            NavigationLink {
                MountSettingsView()
            } label: {
                SettingsRow(icon: "externaldrive.connected.to.line.below.fill", color: .mint, title: String(localized: "mounts"), subtitle: String(localized: "manage_external_folder_mount_points"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "storage"))
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
                SettingsRow(icon: "link.circle.fill", color: .teal, title: String(localized: "mcp"), subtitle: String(localized: "connect_external_services_and_protocols"))
            }

            NavigationLink {
                EnvVarsSettingsView()
            } label: {
                SettingsRow(icon: "key.fill", color: .gray, title: String(localized: "environment_variables"), subtitle: String(localized: "manage_api_keys_and_secrets"))
            }

            NavigationLink {
                RuntimeStatusView()
            } label: {
                SettingsRow(icon: "cpu", color: .teal, title: String(localized: "rootfs_management"), subtitle: String(localized: "ish_running"))
            }

            NavigationLink {
                PermissionsSettingsView()
            } label: {
                SettingsRow(icon: "lock.shield.fill", color: .indigo, title: String(localized: "permissions_background"), subtitle: String(localized: "background_permission_grants"))
            }

            NavigationLink {
                GeneralSettingsView()
            } label: {
                SettingsRow(icon: "gearshape.2.fill", color: .gray, title: String(localized: "general_settings"), subtitle: String(localized: "defaults_name_language_confirm_full"))
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "general_section"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
