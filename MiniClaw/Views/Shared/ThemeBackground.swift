import SwiftUI

/// 背景主题挂载组件：按槽位渲染当前主题的背景图；
/// 未选用主题时渲染系统默认背景（视觉与现状完全一致）。
///
/// 裁切（唐唐 2026-08-30 拍板）：
/// - `.aspectRatio(contentMode: .fill)` 等比填满 + 居中裁切 + ignoresSafeArea；
///   iPad 分屏/横竖屏切换由 GeometryReader 自适应，无需设备特判；
/// - 解码用 ImageIO downsampling（按容器尺寸 × 屏幕缩放），不做全分辨率解码；
/// - 暗色模式 = 单图 + 黑色遮罩（不透明度取包内 dimDark，缺省 0.55）；
/// - 浅色模式 = 无遮罩，除非主题声明 dimLight（0-1）——供亮壁纸主题自行压暗。
struct ThemeBackground: View {
    enum Slot: String {
        case home, chat, settings
    }

    let slot: Slot

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = ThemeManager.shared

    var body: some View {
        GeometryReader { geo in
            let maxSide = max(geo.size.width, geo.size.height)
            // 屏幕缩放上限 3x：downsample 到物理像素级，既保画质又控内存。
            let scale = min(max(UITraitCollection.current.displayScale, 1), 3)
            Group {
                if let ui = manager.backgroundImage(for: slot, maxPixel: maxSide * scale) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay {
                            switch colorScheme {
                            case .dark:
                                Color.black.opacity(dimOpacity).ignoresSafeArea()
                            default:
                                // 浅色遮罩：仅当主题声明 dimLight > 0 才生效（缺省无遮罩，
                                // 默认视觉零变化）；供亮壁纸主题自行压暗降纹理干扰。
                                if dimLightOpacity > 0 {
                                    Color.black.opacity(dimLightOpacity).ignoresSafeArea()
                                }
                            }
                        }
                } else {
                    // 未选用主题：回退与该页面原生列表背景一致的颜色（唐唐反馈：
                    // 设置页 inset grouped 的原生背景是 systemGroupedBackground 浅灰，
                    // 行白卡靠它才有分组边界——回退纯白会让边界消失）。
                    fallbackColor.ignoresSafeArea()
                }
            }
        }
        .ignoresSafeArea()
    }

    private var dimOpacity: Double {
        min(max(manager.activeDeclaration()?.dimDark ?? 0.55, 0), 1)
    }

    /// 浅色遮罩：仅在主题声明 dimLight 时生效（缺省 nil → 0 → 不遮罩）。
    private var dimLightOpacity: Double {
        min(max(manager.activeDeclaration()?.dimLight ?? 0, 0), 1)
    }

    /// 无主题时的回退色：与各页面原生列表背景一致，保证默认视觉零变化。
    /// - home / chat：systemBackground（首页 .plain 列表、会话页原生背景）
    /// - settings：systemGroupedBackground（inset grouped 行白卡的分组底色）
    private var fallbackColor: Color {
        switch slot {
        case .home, .chat: return Color(.systemBackground)
        case .settings: return Color(.systemGroupedBackground)
        }
    }
}
