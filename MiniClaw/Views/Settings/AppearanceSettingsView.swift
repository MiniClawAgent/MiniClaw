import SwiftUI

// MARK: - Appearance Settings

/// 外观设置：仅保留背景主题（theme 插件选用）。外观模式与代码块主题已移除，
/// 均默认跟随系统（唐唐 2026-09-05 决定）。
/// 背景主题为双列封面卡片网格（唐唐 2026-09-05 定稿）：矩形封面 + 左下角主题名 +
/// 名字下方渐变阴影遮罩；选中态 = 一圈边框 + 右上角绿色勾。
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

    // MARK: - 背景主题（theme 插件，唐唐 2026-08-30 定稿 / 09-05 重做卡片网格）

    /// 「系统默认」恒为首张卡片：清除选用即回退。
    private var backgroundThemeSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                      spacing: 14) {
                themeCard(id: nil,
                          name: String(localized: "background_theme_default"),
                          imageURL: nil)
                ForEach(themeManager.installedThemes(), id: \.pluginID) { theme in
                    let file = theme.decl.fileName(for: .chat)
                        ?? theme.decl.fileName(for: .home)
                        ?? theme.decl.fileName(for: .settings)
                    themeCard(id: theme.pluginID,
                              name: theme.decl.name.isEmpty ? theme.pluginID : theme.decl.name,
                              imageURL: file.map { ThemeManager.shared.imageURL(pluginID: theme.pluginID, fileName: $0) })
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)

            if themeManager.installedThemes().isEmpty {
                Text(String(localized: "background_theme_empty_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        } header: {
            Text(String(localized: "background_theme"))
        } footer: {
            Text(String(localized: "background_theme_footer"))
        }
    }

    /// 单张主题封面卡片：矩形封面（0.75 宽高比）+ 底部渐变阴影遮罩 + 左下角名字；
    /// 选中态 = 强调色边框 + 右上角绿色勾。
    private func themeCard(id: String?, name: String, imageURL: URL?) -> some View {
        let selected = themeManager.activeThemeID == id
        return Button {
            themeManager.activeThemeID = id
        } label: {
            ZStack(alignment: .bottomLeading) {
                // 封面
                if let imageURL, let cover = ThemeManager.downsampledImage(at: imageURL, maxPixel: 600) {
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "square.on.square")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                // 名字下方的渐变阴影遮罩（保证白字可读）
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                Text(name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(10)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
    }
}
