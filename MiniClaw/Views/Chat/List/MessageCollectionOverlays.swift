import SwiftUI
import UIKit
import Combine
import Foundation

// MARK: - 工具详情面板呈现器

/// 工具详情面板的状态宿主，挂在 MessageListViewController 之上的透明浮层里，
/// **不在 UIHostingConfiguration 的 cell 树内**。两个原因：
/// ① cell 自带的 `.transaction { disablesAnimations = true }` 会吃掉 sheet 的滑入动画；
/// ② 多个 cell 绑定同一份共享状态时，重复 present 会直接崩溃。
struct SheetOverlayView: View {
    @ObservedObject var toolPresenter: ToolSheetPresenter
    @ObservedObject var compactPresenter: CompactSummaryPresenter

    var body: some View {
        Color.clear
            .frame(width: 0,height: 0)
            .sheet(item: $toolPresenter.sheetData) { data in
                ToolLiveSheet(
                    toolBlocks: data.toolBlocks,
                    initialIdx: data.toolBlocks.firstIndex(where: { $0.id == data.block.id }) ?? 0,
                    toolSnapshots: data.toolSnapshots,
                    browserPool: data.browserPool,
                    browserContentProvider: data.browserContentProvider
                )
            }
            .onChange(of: toolPresenter.sheetData?.id) { newVal in
                if newVal == nil {
                    toolPresenter.onDismiss?()
                }
            }
            .sheet(isPresented: Binding(
                get: { compactPresenter.summary != nil },
                set: { if !$0 { compactPresenter.summary = nil } }
            )) {
                CompactSummarySheet(
                    summary: compactPresenter.summary ?? "",
                    onRevert: compactPresenter.onRevert
                )
            }
    }
}

final class AssistantFooterCell: SelfSizingCell {}

// MARK: - 呈现器

final class ToolSheetPresenter: ObservableObject {
    struct SheetData: Identifiable {
        let id: UUID
        let block: AssistantBlock
        let toolBlocks: [AssistantBlock]
        let toolSnapshots: [ToolSnapshotItem]
        let browserPool: MiniClawTabPool?
        let browserContentProvider: ((URL?) -> AnyView)?
    }

    @Published var sheetData: SheetData?
    var onDismiss: (() -> Void)?
}

// MARK: - 压缩摘要面板呈现器

/// 与 ToolSheetPresenter 同一套「浮层 + sheet」模式：把压缩摘要面板挂在 cell 树之外，
/// 避免 cell 的 `.transaction { disablesAnimations }` 压掉滑入动画。
final class CompactSummaryPresenter: ObservableObject {
    @Published var summary: String?
/// 透传给 CompactSummarySheet，让「撤销压缩」按钮能触发 view-model 的
/// revertCompact()，而不必让 sheet 反向依赖 view-model。
    var onRevert: (() -> Void)?
}

/// 透明 SwiftUI 视图：只负责持有 `.sheet()` 修饰符。
/// 作为子 UIHostingController 挂在 MessageListViewController 上，位于所有 cell 之外。
