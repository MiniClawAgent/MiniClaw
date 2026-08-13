import Foundation
import SwiftUI

/// 工具调用前确认：在「通用设置 → 默认行为 → 工具调用前确认」开启时，
/// Agent 引擎在执行每个工具前通过本桥向 UI 请求用户批准。
///
/// 设计为**全局弹窗桥接**：待确认项以 `sessionID` 为键分别存储，每个会话各自挂起各自的确认请求，互不覆盖；
/// 弹窗挂在根视图（ContentView），无论用户当前在哪个会话/页面都能看到并处理的确认框，
/// 且框内明确标注「会话名称」，避免跨会话误认。用户点击按 `item.id` 精确恢复，不会作用于其他会话。
@MainActor
final class ToolConfirmationBridge: ObservableObject {
    static let shared = ToolConfirmationBridge()

    struct Item: Identifiable {
        let id = UUID()
        let sessionID: UUID
        let sessionTitle: String
        let toolName: String
        /// 精简的人类可读操作摘要（如「打开 baidu.com」「搜索 天气」），不含完整命令。
        let summary: String
    }

    private struct Slot {
        let item: Item
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var pendingItems: [Item] = []
    private var slots: [UUID: Slot] = [:]

    /// 点击「允许本次会话」后加入的会话集合：这些会话后续的同轮工具调用默认允许，
    /// 不弹确认框；其他会话仍走全局设置规则。会话被删除时通过 `revokeSession` 清除。
    private var sessionAutoApproved: Set<UUID> = []

    /// 兼容旧用法的便捷访问：返回任意一个待确认项（多数场景无需使用）。
    var pending: Item? { pendingItems.first }

    /// 请求用户批准某会话的工具调用。返回用户是否允许。
    /// - 注意：必须且只能被 `resolve(itemID:approved:)` 或 `cancel(sessionID:)` 恢复一次。
    /// - 超时兜底：用户长时间不响应（如确认框被其他弹层遮挡、后台引擎误触发）时自动拒绝，
    ///   保证确认请求必有终态、调用方不会永久挂起。
    func request(toolName: String, summary: String, sessionID: UUID, sessionTitle: String) async -> Bool {
        // 5 分钟不响应自动拒绝（与引擎工具 120s 超时同属"必有终态"保障）。
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            Self.shared.cancel(sessionID: sessionID)
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let item = Item(sessionID: sessionID,
                            sessionTitle: sessionTitle,
                            toolName: toolName,
                            summary: summary)
            slots[sessionID] = Slot(item: item, continuation: cont)
            rebuildPending()
        }
        timeoutTask.cancel()
        return result
    }

    /// 恢复指定待确认项（按 item.id 精确解析），恢复后该项从队列移除。
    func resolve(itemID: UUID, approved: Bool) {
        guard let idx = pendingItems.firstIndex(where: { $0.id == itemID }),
              let slot = slots[pendingItems[idx].sessionID] else { return }
        slots[slot.item.sessionID] = nil
        rebuildPending()
        slot.continuation.resume(returning: approved)
    }

    /// 取消某会话的全部待确认（离开会话 / 系统 dismiss 时调用）。幂等：无该会话待确认则直接返回。
    func cancel(sessionID: UUID) {
        guard let slot = slots[sessionID] else { return }
        slots[sessionID] = nil
        rebuildPending()
        slot.continuation.resume(returning: false)
    }

    /// 取消全部待确认（如应用进入后台等场景），避免悬挂的 continuation 泄漏。
    func cancelAll() {
        let all = slots
        slots.removeAll()
        rebuildPending()
        for (_, slot) in all { slot.continuation.resume(returning: false) }
    }

    /// 取某会话当前待确认项（供视图按会话过滤）。
    func pendingItem(for sessionID: UUID) -> Item? {
        slots[sessionID]?.item
    }

    // MARK: - 「允许本次会话」授权

    /// 标记某会话为「本次会话默认允许工具调用」（点击「允许本次会话」时调用）。
    func approveSession(sessionID: UUID) {
        sessionAutoApproved.insert(sessionID)
    }

    /// 该会话是否已获「本次会话默认允许」授权。
    func isAutoApproved(sessionID: UUID) -> Bool {
        sessionAutoApproved.contains(sessionID)
    }

    /// 撤销某会话的授权（会话被删除时调用）。
    func revokeSession(sessionID: UUID) {
        sessionAutoApproved.remove(sessionID)
    }

    private func rebuildPending() {
        // iOS16 兼容:UUID 的 Comparable 是 iOS17 才提供,用 uuidString 排序(等价语义)。
        pendingItems = slots.values.map(\.item).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
