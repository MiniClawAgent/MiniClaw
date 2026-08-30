import SwiftUI

/// 背景主题挂载组件：按槽位渲染当前主题的背景图；
/// 未选用主题时渲染系统默认背景（视觉与现状完全一致）。
///
/// 裁切（唐唐 2026-08-30 拍板）：
/// - `.aspectRatio(contentMode: .fill)` 等比填满 + 居中裁切 + ignoresSafeArea；
///   iPad 分屏/横竖屏切换由 GeometryReader 自适应，无需设备特判；
/// - 解码用 ImageIO downsampling（按容器尺寸 × 屏幕缩放），不做全分辨率解码；
/// - 暗色模式 = 单图 + 黑色遮罩（不透明度取包内 dimDark，缺省 0.35）。
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
                            if colorScheme == .dark {
                                Color.black.opacity(dimOpacity).ignoresSafeArea()
                            }
                        }
                } else {
                    // 未选用主题：系统默认背景（与无主题时的现状完全一致）。
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
        }
        .ignoresSafeArea()
    }

    private var dimOpacity: Double {
        min(max(manager.activeDeclaration()?.dimDark ?? 0.35, 0), 1)
    }
}
