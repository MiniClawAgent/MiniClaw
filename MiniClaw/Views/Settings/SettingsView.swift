import SwiftUI

/// 设置主页：头像 + 2 列卡片宫格。
///
/// 七个入口（与二级页一一对应，顺序即视觉顺序）：
/// 智能体 / 插件 / 存储 / 外观 / 通用 / 日志 / 关于。
/// 卡片参数：图标 16pt 彩色 SF Symbol、最小高 110、圆角 24（.continuous）、
/// 水平内边距 14、垂直内边距 18、副标题单行。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// 打开外部链接（备案号跳工信部 ICP 备案查询网站）。
    @Environment(\.openURL) private var openURL

    @State private var navigateToGroups: Bool = false
    @State private var navigateToProviders: Bool = false
    @State private var navigateToEnvVars: Bool = false
    @State private var navigateToPermissions: Bool = false

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    private var displayName: String {
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        return (name?.isEmpty == false ? name! : "MiniClaw")
    }

    /// 2 列等宽自适应宫格。卡片最小宽 150，间距 14（与参考图一致的比例）。
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                LazyVGrid(columns: columns, spacing: 12) {
                    card(icon: "sparkles", tint: .purple,
                         title: String(localized: "agent"),
                         subtitle: String(localized: "settings_sub_agent")) {
                        AgentSettingsGroupView()
                    }

                    card(icon: "puzzlepiece.extension.fill", tint: .blue,
                         title: String(localized: "plugins"),
                         subtitle: String(localized: "settings_sub_plugins")) {
                        PluginsSettingsView()
                    }

                    card(icon: "internaldrive.fill", tint: .green,
                         title: String(localized: "storage"),
                         subtitle: String(localized: "settings_sub_storage")) {
                        StorageSettingsGroupView()
                    }

                    card(icon: "paintpalette.fill", tint: .pink,
                         title: String(localized: "appearance"),
                         subtitle: String(localized: "settings_sub_appearance")) {
                        AppearanceSettingsView()
                    }

                    card(icon: "gearshape.fill", tint: .gray,
                         title: String(localized: "general_section"),
                         subtitle: String(localized: "settings_sub_general")) {
                        GeneralSettingsGroupView()
                    }

                    card(icon: "doc.text.magnifyingglass", tint: .orange,
                         title: String(localized: "logs"),
                         subtitle: String(localized: "settings_sub_logs")) {
                        LogsView()
                    }

                    card(icon: "info.circle.fill", tint: .indigo,
                         title: String(localized: "about_miniclaw_app"),
                         subtitle: String(localized: "settings_sub_about")) {
                        AboutView()
                    }
                }
                .padding(.horizontal, 16)

                footer
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "settings"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToGroups) { GroupsSettingsView() }
        .navigationDestination(isPresented: $navigateToProviders) { ProviderSettingsView() }
        .navigationDestination(isPresented: $navigateToPermissions) { PermissionsSettingsView() }
        .navigationDestination(isPresented: $navigateToEnvVars) { EnvVarsSettingsView() }
        .onAppear { handleDeepLink() }
        .onChange(of: appState.settingsDeepLink) { _ in handleDeepLink() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Image(systemName: "person.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .frame(width: 104, height: 104)
            .overlay(Circle().stroke(Color(.separator).opacity(0.25), lineWidth: 0.5))

            Text(displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.top, 12)
    }

    // MARK: - 卡片

    /// 一张设置卡片：左上图标、右上箭头、左下标题与副标题。
    private func card<Destination: View>(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }

                Spacer(minLength: 6)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)          // 副标题一律单行（文案已按 ≤10 字编写）
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)   // 上下内容各向内收 5pt（13 → 18），卡高保持 110
            // 高度对齐模板：约 92pt（此前 148 偏高；96 仍略高，且圆角看起来不成比例）
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .background(
                // 模板卡片的圆角约为卡高的 1/4；用 24pt 连续曲率贴近该观感
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 6) {
            Text("settings_footer_tagline")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(versionString)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text("湘ICP备2023018958号-16A")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .onTapGesture {
                    openURL(URL(string: "https://beian.miit.gov.cn/")!)
                }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 10)
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

// MARK: - Settings Row（二级页共用的行样式）

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
