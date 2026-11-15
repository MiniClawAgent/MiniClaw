import SwiftUI

/// 设置主页：卡片宫格布局（2026-11-15 按唐唐给的参考图重排）。
///
/// 版面：头像 + 名称 → 2 列卡片（图标 / 箭头 / 标题 / 副标题）→ 底部标语 + 版本号。
/// 六个入口与既有二级页一一对应，不新增功能、不删除入口：
/// 通用 / 模型 / 本机 / 隐私 / 数据 / 关于。
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
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                LazyVGrid(columns: columns, spacing: 14) {
                    card(
                        icon: "gearshape.fill", tint: .blue,
                        title: "settings_card_general", subtitle: "settings_card_general_sub"
                    ) { GeneralSettingsGroupView() }

                    card(
                        icon: "square.stack.3d.up.fill", tint: .green,
                        title: "settings_card_models", subtitle: "settings_card_models_sub"
                    ) { AgentSettingsGroupView() }

                    card(
                        icon: "iphone", tint: .orange,
                        title: "settings_card_device", subtitle: "settings_card_device_sub"
                    ) { RuntimeStatusView() }

                    card(
                        icon: "lock.shield.fill", tint: .red,
                        title: "settings_card_privacy", subtitle: "settings_card_privacy_sub"
                    ) { PermissionsSettingsView() }

                    card(
                        icon: "tray.full.fill", tint: .purple,
                        title: "settings_card_data", subtitle: "settings_card_data_sub"
                    ) { StorageSettingsGroupView() }

                    card(
                        icon: "info.circle", tint: .gray,
                        title: "settings_card_about", subtitle: "settings_card_about_sub"
                    ) { AboutView() }
                }
                .padding(.horizontal, 20)

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
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }

                Spacer(minLength: 18)

                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
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
