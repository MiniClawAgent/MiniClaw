import SwiftUI

// MARK: - 工具卡片浮层（方案 B：会话页内嵌卡片，替代全屏 sheet）
//
// 唐唐 2026-09-01 拍板的呈现形态：
// - 卡片高度 = 屏高 60%，**不透明实体卡**（实色底 + 圆角 + 投影），位置固定不随消息滚动
// - **左右滑动**切换上/下一个工具指示器卡片：TabView(.page) 分页，两侧露出相邻卡片
//   边缘（peek），一眼可见可滑动；底部圆点分页指示
// - **卡内上滑**滚动查看 Result 等长内容（卡内容区自带滚动）
// - **下滑关闭**：卡头把手下拉（跟手限幅，松手超阈值触发关闭）；卡外区域点按同样关闭
//
// 内容复用：每页 = 一个 ToolLiveSheet 实例（三级布局：状态行/动作行/Result 卡），
// 卡片模式传入 onClose（替代 sheet dismiss）与 hidesSwitchRow（分页替代切换行）。
// 浏览器接管：ToolLiveSheet 内部的二级 sheet 在卡片层级之上仍可正常 present，保留。

struct ToolCardOverlay: View {
    let toolBlocks: [AssistantBlock]
    /// 初始定位的工具块 id（对应消息流中被点按的那个指示器）。
    let initialBlockID: UUID
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: MiniClawTabPool?
    var browserContentProvider: ((URL?) -> AnyView)?
    /// 关闭卡片（由宿主置空呈现状态）。
    let onClose: () -> Void

    /// TabView 分页选中索引。
    @State private var pageIdx: Int = 0
    /// 出现动画状态。
    @State private var appeared = false

    private var initialIndex: Int {
        toolBlocks.firstIndex(where: { $0.id == initialBlockID }) ?? 0
    }

    var body: some View {
        // 独立 UIWindow 宿主：proposed 尺寸即全屏，GeometryReader 直接可用。
        GeometryReader { geo in
            let cardHeight = geo.size.height * 0.6
            ZStack {
                // 遮罩：轻暗化，点按关闭（卡片外区域）。
                Color.black.opacity(appeared ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 14) {
                    TabView(selection: $pageIdx) {
                        ForEach(toolBlocks.indices, id: \.self) { i in
                            // 2026-09-01 唐唐拍板：每个工具快照 = **独立卡片**——
                            // 卡宽 < 页宽（页内左右 24 边距），页间自然形成卡间隔；
                            // 圆角/描边/投影/底色挂在**卡片级**（不是 TabView 级），
                            // 滑动即「一张卡片切换到另一张卡片」，而非连体内容。
                            ToolLiveSheet(
                                toolBlocks: toolBlocks,
                                initialIdx: i,
                                toolSnapshots: toolSnapshots,
                                browserPool: browserPool,
                                browserContentProvider: browserContentProvider,
                                // 关闭按钮与卡外点按走同一动画路径（close() 先播
                                // 下沉淡出，再触发 onClose 隐藏窗口）。
                                onClose: { close() },
                                hidesSwitchRow: true,
                                cardSurface: true
                            )
                            .frame(height: cardHeight)
                            // 背景必须在 clipShape 之前：先画底色再裁圆角——
                            // 顺序反了会让直角背景从圆角外露出（唐唐真机截图）。
                            .background(Color(UIColor.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color(.separator).opacity(0.8), lineWidth: 1)
                            )
                            // 不加卡片投影：TabView(.page) 页间隔仅 24pt，大半径阴影会
                            // 渗进两卡缝隙形成阴影带（2026-09-02 唐唐截图）；层次由
                            // 底层 0.35 黑遮罩提供。
                            .padding(.horizontal, 24)
                            .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: cardHeight)

                    pageDots
                }
                .offset(y: appeared ? 0 : geo.size.height)
                .opacity(appeared ? 1 : 0)
            }
            .onAppear {
                pageIdx = initialIndex
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    appeared = true
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 关闭

    private func close() {
        withAnimation(.easeIn(duration: 0.22)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    // MARK: - 分页指示

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(toolBlocks.indices, id: \.self) { i in
                Capsule()
                    .fill(i == pageIdx ? Color.white : Color.white.opacity(0.35))
                    .frame(width: i == pageIdx ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: pageIdx)
            }
        }
    }
}
