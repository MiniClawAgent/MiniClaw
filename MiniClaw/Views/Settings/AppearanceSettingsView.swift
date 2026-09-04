import SwiftUI

// MARK: - Appearance Settings

/// 外观设置：仅保留背景主题（theme 插件选用）。外观模式与代码块主题已移除，
/// 均默认跟随系统（唐唐 2026-09-05 决定）。
struct AppearanceSettingsView: View {
    /// 订阅主题管理器：选用/清除背景主题时刷新选中勾与主题列表。
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        List {
            backgroundThemeSection
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "appearance"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 背景主题（theme 插件，唐唐 2026-08-30 定稿）

    /// 背景主题选择区：系统默认 + 已装 theme 插件预设（缩略图 + 选中态）。
    /// 显式选用 + 排他生效；未选用时三页保持系统默认背景。
    private var backgroundThemeSection: some View {
        Section {
            // 「系统默认」恒在首行：清除选用即回退。
            Button {
                themeManager.activeThemeID = nil
            } label: {
                HStack {
                    Image(systemName: "square.on.square")
                        .frame(width: 44, height: 32)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    Text(String(localized: "background_theme_default"))
                        .foregroundStyle(.primary)
                    Spacer()
                    if themeManager.activeThemeID == nil {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }

            if themeManager.installedThemes().isEmpty {
                Text(String(localized: "background_theme_empty_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(themeManager.installedThemes(), id: \.pluginID) { theme in
                Button {
                    themeManager.activeThemeID = theme.pluginID
                } label: {
                    HStack {
                        themeThumbnail(pluginID: theme.pluginID, decl: theme.decl)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.decl.name.isEmpty ? theme.pluginID : theme.decl.name)
                                .foregroundStyle(.primary)
                            Text(theme.pluginID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if themeManager.activeThemeID == theme.pluginID {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "background_theme"))
        } footer: {
            Text(String(localized: "background_theme_footer"))
        }
    }

    /// 主题缩略图：优先 chat 槽位，其次任一可用图，downsample 到小尺寸。
    @ViewBuilder
    private func themeThumbnail(pluginID: String, decl: ThemePackageDecl) -> some View {
        let fileName = decl.fileName(for: .chat)
            ?? decl.fileName(for: .home)
            ?? decl.fileName(for: .settings)
        if let fileName,
           let small = smallThumbnail(url: ThemeManager.shared.imageURL(pluginID: pluginID, fileName: fileName)) {
            Image(uiImage: small)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "photo")
                .frame(width: 44, height: 32)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func smallThumbnail(url: URL) -> UIImage? {
        ThemeManager.downsampledImage(at: url, maxPixel: 132)
    }
}
