import Foundation
import SwiftUI

/// AI 可向用户请求的系统能力 —— 与「设置 → 权限与后台 → 控制」里的四个开关一一对应。
///
/// 授权分两层，互为补充：
/// 1. **持久层**：用户在设置里手动打开对应开关（AI 无法自行开启 —— 未注册进 ConfigTool，
///    否则 AI 能给自己授权，"需要用户同意"就形同虚设）；
/// 2. **会话层**：开关未开时，AI 可在**真实存在的用户会话**内经授权弹窗征得同意，
///    **仅对该会话有效**、不写设置（与TopFlow 2026-09-18 的决定一致）。
enum AICapability: String, CaseIterable {
    case healthRead
    case healthWrite
    case homeRead
    case homeControl

    /// 用户是否已在设置里持久开启该能力。
    var isEnabledInSettings: Bool {
        let d = SettingsStore.shared.settings.defaults
        switch self {
        case .healthRead:  return d.healthReadEnabled
        case .healthWrite: return d.healthWriteEnabled
        case .homeRead:    return d.homeReadEnabled
        case .homeControl: return d.homeControlEnabled
        }
    }

    /// 归属工具名（弹窗与日志用，说明"AI 想用哪条能力"）。
    var toolName: String {
        switch self {
        case .healthRead, .healthWrite: return "apple-healthkit"
        case .homeRead, .homeControl:   return "apple-homekit"
        }
    }

    /// 用户在设置里看到的开关名（也用于授权弹窗正文与未授权提示里的能力指代）。
    var displayName: String {
        switch self {
        case .healthRead:  return String(localized: "allow_health_read")
        case .healthWrite: return String(localized: "allow_health_write")
        case .homeRead:    return String(localized: "allow_home_read")
        case .homeControl: return String(localized: "allow_home_control")
        }
    }

    /// 未获授权时回报给模型的失败文案（两个工具共用一份，避免各写一份后漂移）。
    var unauthorizedMessage: String {
        String(format: String(localized: "capability_not_authorized"), displayName)
    }

    /// 弹窗标题。
    var requestTitle: String {
        switch self {
        case .healthRead:  return String(localized: "capability_request_health_read_title")
        case .healthWrite: return String(localized: "capability_request_health_write_title")
        case .homeRead:    return String(localized: "capability_request_home_read_title")
        case .homeControl: return String(localized: "capability_request_home_control_title")
        }
    }

    /// 弹窗正文：这次要做什么、影响是什么。
    var requestMessage: String {
        switch self {
        case .healthRead:  return String(localized: "capability_request_health_read_message")
        case .healthWrite: return String(localized: "capability_request_health_write_message")
        case .homeRead:    return String(localized: "capability_request_home_read_message")
        case .homeControl: return String(localized: "capability_request_home_control_message")
        }
    }
}

/// AI → 用户的授权请求桥：Agent 引擎/工具在需要用户批准时通过本桥向 UI 请求，
/// 由挂在根视图（ContentView）的**全局授权浮层**统一呈现。
///
/// 三类用途共用同一弹窗与同一套按钮（单一 UI 事实来源）：
/// - **工具调用确认**（`confirmBeforeToolCall` 开启时，每个工具调用前）；
/// - **插件安装确认**（`aiPluginInstallRequiresConfirmations` 开启时）；
/// - **能力授权请求**（`AICapability`，开关未开时 AI 请求读/写健康数据或读/控家庭配件）。
///
/// 设计为**全局弹窗桥接**：待确认项以 `sessionID` 为键分别存储，每个会话各自挂起各自的确认请求，互不覆盖；
/// 弹窗挂在根视图，无论用户当前在哪个会话/页面都能看到并处理，且框内明确标注「会话名称」，避免跨会话误认。
/// 用户点击按 `item.id` 精确恢复，不会作用于其他会话。
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
        /// 非 nil 表示这是一次**能力授权请求**（而非工具调用/插件安装确认）：
        /// 弹窗渲染能力的标题与说明，「允许本次会话」也按**能力**记账而不是全局免确认。
        var capability: AICapability? = nil
    }

    private struct Slot {
        let item: Item
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published private(set) var pendingItems: [Item] = []
    private var slots: [UUID: Slot] = [:]

    /// 点击「允许本次会话」后加入的会话集合：这些会话后续的同轮**工具调用**默认允许，
    /// 不弹确认框；其他会话仍走全局设置规则。会话被删除时通过 `revokeSession` 清除。
    private var sessionAutoApproved: Set<UUID> = []

    /// 会话级**能力**授权：与 `sessionAutoApproved` **分开记账**。
    /// 二者语义不同 —— 同意「读健康数据」不应顺带免除该会话所有工具调用的确认。
    private var sessionApprovedCapabilities: [UUID: Set<AICapability>] = [:]

    /// 兼容旧用法的便捷访问：返回任意一个待确认项（多数场景无需使用）。
    var pending: Item? { pendingItems.first }

    /// 请求用户批准某会话的工具调用 / 插件安装。返回用户是否允许。
    /// - Parameters:
    ///   - capability: 非 nil 时表示这是一次能力授权请求（按能力记账）。
    /// - 注意：必须且只能被 `resolve(itemID:approved:)` / `approveForSession(itemID:)` / `cancel(sessionID:)` 恢复一次。
    /// - 超时兜底：用户长时间不响应（如确认框被其他弹层遮挡、后台引擎误触发）时自动拒绝，
    ///   保证确认请求必有终态、调用方不会永久挂起。
    func request(toolName: String,
                 summary: String,
                 sessionID: UUID,
                 sessionTitle: String,
                 capability: AICapability? = nil) async -> Bool {
        // 5 分钟不响应自动拒绝（与引擎工具 120s 超时同属"必有终态"保障）。
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            Self.shared.cancel(sessionID: sessionID)
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let item = Item(sessionID: sessionID,
                            sessionTitle: sessionTitle,
                            toolName: toolName,
                            summary: summary,
                            capability: capability)
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

    /// 用户在弹窗点击「允许本次会话」：按待确认项的**性质**分别记账，再恢复该项。
    /// - 能力请求 → 只授权该能力（`sessionApprovedCapabilities`）；
    /// - 工具调用 / 插件安装 → 该会话后续工具调用免确认（`sessionAutoApproved`）。
    func approveForSession(itemID: UUID) {
        guard let item = pendingItems.first(where: { $0.id == itemID }) else { return }
        if let capability = item.capability {
            approveCapability(capability, sessionID: item.sessionID)
        } else {
            approveSession(sessionID: item.sessionID)
        }
        resolve(itemID: itemID, approved: true)
    }

    /// 标记某会话为「本次会话默认允许工具调用」（点击「允许本次会话」时调用）。
    func approveSession(sessionID: UUID) {
        sessionAutoApproved.insert(sessionID)
    }

    /// 该会话是否已获「本次会话默认允许」授权。
    func isAutoApproved(sessionID: UUID) -> Bool {
        sessionAutoApproved.contains(sessionID)
    }

    // MARK: - 会话级能力授权

    /// 标记某会话已同意某能力（仅本会话有效，不写设置）。
    func approveCapability(_ capability: AICapability, sessionID: UUID) {
        sessionApprovedCapabilities[sessionID, default: []].insert(capability)
    }

    /// 该会话是否已同意某能力。
    func isCapabilityApproved(_ capability: AICapability, sessionID: UUID) -> Bool {
        sessionApprovedCapabilities[sessionID]?.contains(capability) ?? false
    }

    /// 撤销某会话的全部授权（会话被删除时调用）。
    func revokeSession(sessionID: UUID) {
        sessionAutoApproved.remove(sessionID)
        sessionApprovedCapabilities[sessionID] = nil
    }

    // MARK: - 工具侧守卫（能力请求的唯一入口）

    /// 判断某能力本次是否可用；不可用时向用户发起授权请求。
    ///
    /// 判定顺序：**设置里已持久开启** → 放行；**本会话已同意** → 放行；
    /// 否则弹授权请求，用户同意即按会话记账并放行。
    ///
    /// 只有**真实存在的用户会话**才会弹窗：后台/子代理引擎用随机 UUID 运行，
    /// 弹出来会显示「未知会话」且无人归因、必然挂到超时（与 AgentLoopEngine 既有判据一致），
    /// 故此类调用直接判否，由调用方回报失败给模型。
    /// - Returns: 是否放行。
    func ensureCapability(_ capability: AICapability, sessionID: UUID?) async -> Bool {
        if capability.isEnabledInSettings { return true }
        guard let sid = sessionID else { return false }
        if isCapabilityApproved(capability, sessionID: sid) { return true }
        guard let title = SessionManager.shared.session(id: sid)?.title else { return false }
        let approved = await request(toolName: capability.toolName,
                                     summary: capability.requestMessage,
                                     sessionID: sid,
                                     sessionTitle: title,
                                     capability: capability)
        if approved { approveCapability(capability, sessionID: sid) }
        return approved
    }

    private func rebuildPending() {
        // iOS16 兼容:UUID 的 Comparable 是 iOS17 才提供,用 uuidString 排序(等价语义)。
        pendingItems = slots.values.map(\.item).sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
