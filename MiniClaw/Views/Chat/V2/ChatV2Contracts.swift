import Foundation
import CoreGraphics

/// 会话页 V2 的**唯一契约**。所有子模块只依赖本文件，不得互相 import 具体实现。
///
/// 设计要点（2026-11-16 唐唐决策）：
/// - 列表被键盘顶上去（系统键盘避让生效，不忽略 .keyboard）；
/// - 状态行/暂停横幅统一高度（固定行高，形态切换不改高度）；
/// - 旧页保留开关，验收通过后再删；
/// - 重构期冻结会话页功能新增。

// MARK: - 行身份与版本

enum ChatRowKind: String, Hashable {
    case userBubble
    case assistantHeader
    case text
    case thinking
    case tool
    case question
    case footer
    case divider
    case systemInfo
    /// 尾部占位：保证短会话也能贴底（高度为剩余空间，由布局计算）
    case bottomSpacer
}

/// 行身份：只由「属于哪条消息 + 哪种行 + 哪个块」决定，**永不因为内容变化而变**。
struct ChatRowID: Hashable {
    let messageID: UUID
    let kind: ChatRowKind
    let blockID: UUID?
}

/// 一行的只读快照。
///
/// `version` 是**内容版本**：内容或状态（流式中/暂停/错误/展开态…）变化时必须改变，
/// 用于高度缓存、diffable 的 reconfigure 判定。身份不变、版本变 = 只更新内容。
struct ChatRow: Identifiable, Equatable {
    let id: ChatRowID
    let version: String
    /// 复用现有渲染对象（引用类型，内容已由 Bridge 维护）。
    let message: RenderMessage
    let block: AssistantBlock?

    var kind: ChatRowKind { id.kind }

    /// 相等 = 身份 + 内容版本。`RenderMessage`/`AssistantBlock` 是引用类型且非 Equatable，
    /// 不能合成；而 diffable 需要的正是「同一行、内容变了没有」。
    static func == (l: ChatRow, r: ChatRow) -> Bool {
        l.id == r.id && l.version == r.version
    }
}

/// 行高策略：由 Builder 决定，布局只读。
enum ChatRowHeightPolicy: Equatable {
    /// 固定高度（header / footer / divider / 统一状态行）。
    case fixed(CGFloat)
    /// 自适应（正文 / 工具卡 / 问答卡等，由 cell 自 sizing 决定）。
    case automatic(estimated: CGFloat)
}

// MARK: - 高度与尺寸常量（唯一来源）

enum ChatV2Metrics {
    /// 状态行/暂停横幅统一高度：形态切换不改高度，从根上消除裁切与底部增长。
    static let footerHeight: CGFloat = 40
    /// 「✨ MiniClaw」标题行。
    static let headerHeight: CGFloat = 26
    /// 用户气泡的估高（真实高度由 cell 决定）。
    static let userBubbleEstimate: CGFloat = 56
    static let textEstimate: CGFloat = 64
    static let toolEstimate: CGFloat = 40
    static let questionEstimate: CGFloat = 220
    static let dividerEstimate: CGFloat = 44
    static let systemInfoEstimate: CGFloat = 32
    /// 行间距（由布局统一添加，cell 不得自带外边距）。
    static let interItemSpacing: CGFloat = 8
    /// 内容与输入区之间的固定留白。
    static let bottomGap: CGFloat = 8
    static let horizontalInset: CGFloat = 16
}

// MARK: - 视口

/// V2 对"底部被谁遮挡"的唯一描述。
///
/// 由 Composer 上报：**输入区实际占据的高度**（含安全区、含浮动栏；键盘弹起时由系统压缩列表，
/// 因此这里**不包含键盘高度**）。列表只用它算 inset。
struct ChatV2ObscuredBottom: Equatable {
    var composerAndSafeArea: CGFloat
    static let zero = ChatV2ObscuredBottom(composerAndSafeArea: 0)
}

/// 视口事件：V2 只有这四种，全部由 Screen/Composer 产生。
enum ChatV2ViewportEvent {
    /// 用户拖动/惯性滚动结束（用于重算"是否贴底"）。
    case userScrollEnded(atBottom: Bool)
    /// 内容在底部增长（新增行或行高变大）。
    case contentGrewAtBottom(delta: CGFloat)
    /// 内容整体高度变化（非底部）。
    case contentResized(delta: CGFloat)
    /// 底部遮挡高度变化（输入栏/安全区/浮动栏）。
    case obscuredBottomChanged(delta: CGFloat)
    /// 显式贴底（发送消息、点"回到底部"）。
    case pinToBottom
}

/// 视口唯一所有者。**禁止**其它任何地方写 contentOffset / contentInset。
protocol ChatV2ViewportOwning: AnyObject {
    var isPinnedToBottom: Bool { get }
    func handle(_ event: ChatV2ViewportEvent)
    /// 注册输出：一帧内最多回调一次。
    var applyOffset: ((_ offsetY: CGFloat, _ animated: Bool) -> Void)? { get set }
    var applyBottomInset: ((_ inset: CGFloat) -> Void)? { get set }
    func attach(contentHeight: @escaping () -> CGFloat,
                viewportHeight: @escaping () -> CGFloat,
                currentOffset: @escaping () -> CGFloat)
}

// MARK: - Row 构建

protocol ChatV2RowBuilding {
    /// 从当前渲染快照构造行。必须是**纯函数**：同输入必同输出，不读全局状态。
    func buildRows(messages: [RenderMessage]) -> [ChatRow]
}

// MARK: - 开关

enum ChatV2Feature {
    /// 读取设置；默认 false（旧页），验收通过后由用户切换。
    static let defaultsKey = "chat.v2.enabled"

    /// [2026-11-16 03:05] 默认关闭：V2 的"自 sizing 引擎"在流式场景不成立
    /// （每次 apply 都会重新测量并重写 offset，导致跳跃与阻尼），先回到稳定的旧页，
    /// 保留本目录作为视口所有权的试验田，等续写方案落地后再启用。
    static var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: defaultsKey) == nil ? false : d.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
