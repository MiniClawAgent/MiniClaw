import Foundation
import ActivityKit

/// Live Activity 属性结构（共享给 Widget 扩展）。
///
/// 注意：本文件同时被主 App 目标与 `MiniClawWidget` 扩展目标编译。
/// ActivityKit 以类型名（不带模块前缀）作为 activityType 标识符，
/// 因此两个目标里必须保持**同名、同字段**，Live Activity 才能正确启动并被 Widget 渲染。
public struct MiniClawLiveActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// 会话图标（SF Symbol 名称）：显示在灵动岛 / 锁屏第二排，取当前会话图标。
        /// 放在 ContentState 以支持「智能体更新标题/图标后实时回传」。
        public var sessionIcon: String
        /// 会话标题：显示在灵动岛 / 锁屏第二排。可被 智能体或用户更新后回传。
        public var sessionTitle: String
        /// 任务执行信息（工具调用 / 最后回复内容）：第三排左侧。
        public var progressText: String
        /// 时间（每次刷新更新为当前时刻 HH:mm）：标题行右侧。
        public var timeText: String
        /// 阶段文本（运行 / 完成 / 失败）：保留供兜底，展示侧改用下方 `status` 决定图标。
        public var phase: String
        /// 状态标识：决定灵动岛 / 锁屏右上角的状态图标。取值：
        /// running（回复中，转动）/ completed（已完成，绿勾）/ failed（失败，红叉）/
        /// paused（已暂停）/ stopped（已停止）/ interrupted（已中断）。
        /// 为空时由 `phase` 兜底映射，确保旧调用点不崩溃。
        public var status: String
        public init(
            sessionIcon: String = "bubble.left.and.bubble.right.fill",
            sessionTitle: String = "",
            progressText: String = "",
            timeText: String = "",
            phase: String = "",
            status: String = ""
        ) {
            self.sessionIcon = sessionIcon
            self.sessionTitle = sessionTitle
            self.progressText = progressText
            self.timeText = timeText
            self.phase = phase
            self.status = status
        }
    }

    /// 智能体名字（第一行左侧，如「MiniClaw」）。
    public var aiName: String
    /// 所属会话 ID（字符串形式）：用于「同一会话只维护一个 LA」并支持点击跳转该会话。
    public var sessionID: String

    public init(aiName: String = "MiniClaw", sessionID: String = "") {
        self.aiName = aiName
        self.sessionID = sessionID
    }
}
