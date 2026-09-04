import SwiftUI
import UIKit
import Combine
import Foundation

// MARK: - Tool Detail Sheet Presenter

/// Holds the state for the tool detail sheet, presented from a transparent overlay
/// on MessageListViewController — outside the UIHostingConfiguration cell tree.
/// This avoids the cell's `.transaction { disablesAnimations = true }` which would
/// suppress the sheet's slide-up animation, and prevents the double-present crash
/// caused by multiple cell bindings re-evaluating on shared state changes.
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

// MARK: - Coordinator

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

// MARK: - Compact Summary Sheet Presenter

/// Same overlay pattern as ToolSheetPresenter — presents the compact summary
/// sheet outside the cell tree so `.transaction { disablesAnimations }` does
/// not suppress the sheet's slide-up animation.
final class CompactSummaryPresenter: ObservableObject {
    @Published var summary: String?
    /// Forwarded into CompactSummarySheet so its "Revert Compact" button can
    /// invoke the view-model's revertCompact() without the sheet importing it.
    var onRevert: (() -> Void)?
}

/// Transparent SwiftUI view that owns the .sheet() modifier.
/// Installed as a child UIHostingController on MessageListViewController,
/// outside any UIHostingConfiguration cell tree.
