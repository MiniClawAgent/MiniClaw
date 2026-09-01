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
    /// 把手下拉的跟手位移（限幅，只向下）。
    @State private var dragOffset: CGFloat = 0
    /// 出现动画状态。
    @State private var appeared = false

    private var initialIndex: Int {
        toolBlocks.firstIndex(where: { $0.id == initialBlockID }) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let cardHeight = geo.size.height * 0.6
            ZStack {
                // 遮罩：轻暗化，点按关闭（卡片外区域）。
                Color.black.opacity(appeared ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 14) {
                    grabber
                        .gesture(dragToClose)

                    TabView(selection: $pageIdx) {
                        ForEach(toolBlocks.indices, id: \.self) { i in
                            ToolLiveSheet(
                                toolBlocks: toolBlocks,
                                initialIdx: i,
                                toolSnapshots: toolSnapshots,
                                browserPool: browserPool,
                                browserContentProvider: browserContentProvider,
                                onClose: onClose,
                                hidesSwitchRow: true
                            )
                            .padding(.horizontal, 16)
                            .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)

                    pageDots
                }
                .offset(y: appeared ? dragOffset : geo.size.height)
                .opacity(appeared ? 1 : 0)
            }
            .onAppear {
                pageIdx = initialIndex
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - 关闭

    private func close() {
        withAnimation(.easeIn(duration: 0.22)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
    }

    // MARK: - 把手 + 下拉关闭手势

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.5))
            .frame(width: 44, height: 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // 只响应向下拖动，限幅避免卡片飞出。
                dragOffset = max(0, min(value.translation.height, 320))
            }
            .onEnded { value in
                let shouldClose = value.translation.height > 140
                    || value.predictedEndTranslation.height > 260
                if shouldClose {
                    withAnimation(.easeIn(duration: 0.2)) { dragOffset = 420 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onClose() }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
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
