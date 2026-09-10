import SwiftUI

// MARK: - 长按菜单等价门（消息气泡）

/// 用「值键」把重型的 `.contextMenu` 子树挡在 SwiftUI 的重复构建之外。
///
/// 背景：`contextMenu(menuItems:)` 是**饿汉式**的——cell 每次 `body` 求值，SwiftUI
/// 都会把整棵菜单子树（按钮、条件分支、带 SF Symbol 的标签，以及被捕获的大段回复
/// 正文）重新物化一遍，而不是等真正长按才构建。流式输出期间气泡 body 每帧求值，
/// 于是每帧都要重建并 diff 整棵菜单树；嵌套的 `if let` 分支会让 AttributeGraph 的
/// 条件投影递归越走越深，最终把更新栈顶穿到未映射内存，进程被 EXC_BAD_ACCESS 杀掉
///（2026-07-07 线上事故）。
///
/// 现在的做法：`menuItems` 闭包照常每帧执行，但只返回这个极轻的包装视图；只有当
/// `key`（真正决定菜单渲染结果的那几个值）变化时，才重建菜单内容。
struct AssistantMenuKey: Equatable {
    let messageId: UUID
    let hasReadAloud: Bool
    let hasCopyScreenshot: Bool
    let compact: Bool
    let active: Bool
}

/// 长按菜单的等价门：`key` 相同即视为渲染等价，SwiftUI 跳过子树重建。
/// 工具胶囊菜单以 `blockId` 标识目标、以 `isProcessing` 决定「从此处重跑」分支；
/// 剪贴板内容在点击时才构建，因此**刻意不进 key**，避免流式期间反复失效重建。
struct EquatableMenuGate<Key: Equatable,Content: View>: View,Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self,rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// 回复气泡长按菜单的等价键：只有这两个字段会改变**渲染结果**（哪些可选动作出现、
/// 是否处于流式禁用态）。被捕获的回复全文刻意排除——复制按钮在点击时才读取它，
/// 流式增长不应触发菜单树重建。
struct ToolMenuKey: Equatable {
    let blockId: UUID
    let processing: Bool
}
