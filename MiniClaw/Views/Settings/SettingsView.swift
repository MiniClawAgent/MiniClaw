import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    /// 订阅界面语言单例：语言切换时 `current` 变化触发本视图重渲染，
    /// 让所有 `L10n.tr` 文案以新语言重新求值（替代旧的 .id() 整树重建方案）。
    @ObservedObject private var l10n = L10n.shared
    @State private var navigateToGroups: Bool = false
    @State private var navigateToProviders: Bool = false
    @State private var navigateToEnvVars: Bool = false
    @State private var navigateToPermissions: Bool = false

    var body: some View {
        List {
            // Section 1: 管理
            Section {
                NavigationLink {
                    ProviderSettingsView()
                } label: {
                    SettingsRow(icon: "server.rack", color: .blue, title: L10n.tr("智能体服务商"), subtitle: L10n.tr("配置 LLM 提供商与 API"))
                }

                NavigationLink {
                    GroupsSettingsView()
                } label: {
                    SettingsRow(icon: "square.stack.3d.up.fill", color: .purple, title: L10n.tr("模型管理"), subtitle: L10n.tr("管理模型分组与默认模型"))
                }

                NavigationLink {
                    TokenUsageView()
                } label: {
                    SettingsRow(icon: "chart.bar.fill", color: .orange, title: L10n.tr("词元用量"), subtitle: L10n.tr("查看 API 使用统计"))
                }
            } header: {
                Text(L10n.tr("管理"))
            }

            // Section 2: 智能体
            Section {
                NavigationLink {
                    SoulSettingsView()
                } label: {
                    SettingsRow(icon: "cat.fill", color: .orange, title: L10n.tr("灵魂"), subtitle: L10n.tr("定义 Agent 人格与行为"))
                }

                NavigationLink {
                    SkillsSettingsView()
                } label: {
                    SettingsRow(icon: "puzzlepiece.extension.fill", color: .blue, title: L10n.tr("技能"), subtitle: L10n.tr("管理可扩展的 Skill 包"))
                }

                NavigationLink {
                    SubAgentSettingsView()
                } label: {
                    SettingsRow(icon: "person.2.fill", color: .indigo, title: L10n.tr("子代理"), subtitle: L10n.tr("控制子代理的启用、并发与思考"))
                }

                NavigationLink {
                    MemorySettingsView()
                } label: {
                    SettingsRow(icon: "brain.fill", color: .purple, title: L10n.tr("记忆"), subtitle: L10n.tr("管理长期记忆与每日记忆"))
                }
            } header: {
                Text(L10n.tr("智能体"))
            }

            // Section 3: 存储
            Section {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    SettingsRow(icon: "externaldrive.fill", color: .green, title: L10n.tr("存储"), subtitle: L10n.tr("查看与管理文件存储"))
                }

                NavigationLink {
                    MountSettingsView()
                } label: {
                    SettingsRow(icon: "externaldrive.connected.to.line.below.fill", color: .mint, title: L10n.tr("挂载"), subtitle: L10n.tr("管理外部文件夹挂载点"))
                }

                // 同步（iCloud 跨设备同步）：功能开发中，入口暂时隐藏；
                // 完成同步功能后恢复此 NavigationLink（SyncSettingsView 已实现，见 SettingsSubViews.swift）。
                // NavigationLink {
                //     SyncSettingsView()
                // } label: {
                //     SettingsRow(icon: "icloud.fill", color: .cyan, title: L10n.tr("同步"), subtitle: L10n.tr("iCloud 跨设备同步"))
                // }
            } header: {
                Text(L10n.tr("存储"))
            }

            // Section 4: 通用
            Section {
                NavigationLink {
                    MCPSettingsView()
                } label: {
                    SettingsRow(icon: "link.circle.fill", color: .teal, title: L10n.tr("MCP 功能"), subtitle: L10n.tr("连接外部服务与协议"))
                }

                NavigationLink(isActive: $navigateToEnvVars) {
                    EnvVarsSettingsView()
                } label: {
                    SettingsRow(icon: "key.fill", color: .gray, title: L10n.tr("环境变量"), subtitle: L10n.tr("管理 API Key 与机密信息"))
                }

                NavigationLink {
                    RuntimeStatusView()
                } label: {
                    SettingsRow(icon: "cpu", color: .teal, title: L10n.tr("Rootfs 管理"), subtitle: L10n.tr("iSH 运行中"))
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: L10n.tr("外观"), subtitle: L10n.tr("跟随系统 / 深色 / 浅色"))
                }

                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    SettingsRow(icon: "gearshape.2.fill", color: .gray, title: L10n.tr("通用设置"), subtitle: L10n.tr("默认名称 / 语言 / 确认"))
                }
            } header: {
                Text(L10n.tr("通用"))
            }

            // Section 5: 日志
            Section {
                NavigationLink {
                    LogsView()
                } label: {
                    SettingsRow(icon: "doc.text.below.ecg", color: .blue, title: L10n.tr("日志"), subtitle: L10n.tr("运行日志与审计日志"))
                }
            } header: {
                Text(L10n.tr("日志"))
            }

            // Section 5.8: 权限与后台
            Section {
                NavigationLink {
                    PermissionsSettingsView()
                } label: {
                    SettingsRow(icon: "lock.shield.fill", color: .indigo, title: L10n.tr("权限与后台"), subtitle: L10n.tr("后台行为 / 权限授权"))
                }
            } header: {
                Text(L10n.tr("权限与后台"))
            }

            // Section 6: 关于与反馈
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(icon: "info.circle.fill", color: .teal, title: L10n.tr("关于 MiniClaw"), subtitle: L10n.tr("版本信息与许可"))
                }
            } header: {
                Text(L10n.tr("其他"))
            }

            // App version footer
            Section {
                EmptyView()
            } footer: {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("MiniClaw v1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Build 1")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.tr("设置"))
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
        .onAppear {
            handleDeepLink()
        }
        .onChange(of: appState.settingsDeepLink) { _, _ in handleDeepLink() }
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
