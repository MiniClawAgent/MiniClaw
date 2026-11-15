# 会话页整页重构方案（Chat Screen Rewrite）

> 状态：**方案，未动代码**
> 日期：2026-11-16
> 范围：`MiniClaw/Views/Chat/` 全部，共 17 个核心文件、**28,407 行**
> 结论：**换掉决策层，保留渲染内核。** 正文继续用 UITextView + TextKit 承载，不改。

---

## 一、体量与你踩到的 bug 的对应关系

| 文件 | 行数 | 你现在能看到的问题主要出在这里 |
|---|---|---|
| ChatView | 1,939 | 键盘/输入框/安全区/浮层，**输入框遮挡** |
| MessageCollectionView | 1,282 | **8 个 offset 写入点**、焦点贴底、KVO 贴底 |
| +Scrolling | 1,390 | 松手结算、贴底、补偿 |
| +Snapshot | 940 | 快照应用后重贴底、越界收敛 |
| +Heights | 554 | 估高与兜底常量 |
| MessageListLayout | 1,573 | 高度缓存、流式范围、失效 |
| MessageListInfrastructure | 1,315 | 身份/协议/基础视图 |
| AssistantBlockView + BridgedCellViews | 1,278 | **工具指示器空白**、状态行裁切 |
| RenderModels + Bridge + Adapter | 1,682 | 双份真相（就地改对象）+ 身份 |
| Markdown* + ToolLiveSheet | 8,937 | 渲染内核（**保留**） |
| ChatInputBar | 936 | 输入区几何 |

**一个反直觉的事实**：这页里 60% 的代码（Markdown/TextKit/ToolLiveSheet）是**好的**，问题集中在剩下 40% 的"调度层"。

---

## 二、为什么继续打补丁一定失败（三条结构性原因）

### 2.1 视口没有所有者

已实测：8 个写入者、4 个抖动输入（输入栏高 / 浮动栏高 / 安全区 / 键盘），
inset 在 45ms 内跳 3 次（117→103→69），每次跳都触发一次强制贴底。

### 2.2 双份真相

Bridge 一边"就地改渲染对象"（19 处字段直接赋值），一边"发新快照"。
- 就地改：界面立刻变，但**高度/身份/顺序可能没更新** ⇒ 状态行显示成旧形态、工具卡空白；
- 发快照：走 diffable，但**早退条件**（`identityUnchanged`、指纹相同、0.25s 节流）随时把更新吞掉。

同一个状态有两个入口、两套生效时机，这类 bug 不可能靠逐个补入口解决。

### 2.3 测量与布局耦合

- 19 处缓存（`MarkdownRenderCache`、`rendererCache`、`cachedSizes`、`tableAttachmentCache`…），键各不相同、淘汰策略各不相同；
- 23 个"跳过测量"的 guard（`deferSelfSizing`、`hasFreshRenderedContent`、`attributed.length==0`、80ms 节流…）；
- 高度兜底常量散落 5 处（4 / 36 / 40 / 48 / 200），与视图里的 `.frame(height: 36)` 各写一份，已经漂移（35 vs 36）。

于是"这一行长多高"取决于**谁在什么时机问**，而不是内容本身。

---

## 三、新架构

### 3.1 分层与依赖方向（只允许箭头向下）

```
┌──────────────────────────────────────────────────────┐
│ ChatScreen（UICollectionView + diffable）             │
│  RowCell 家族 · Overlays（工具浮层）                  │
├──────────────────────────────────────────────────────┤
│ Composer（输入区）  ViewportController（视口所有者）   │
│  · 只上报 obscuredBottom   · 锚点 + inset + 唯一写 offset │
├──────────────────────────────────────────────────────┤
│ HeightEngine（纯测量）   RowBuilder（纯行构造）        │
│  · 输入 row+width 出高度  · (store) -> [Row]          │
├──────────────────────────────────────────────────────┤
│ ConversationStore（唯一真相，不可变快照）              │
│  · messages/blocks/运行态 → 版本号                    │
├──────────────────────────────────────────────────────┤
│ StreamingMerger（唯一写入者）  Persistence（复用现有） │
└──────────────────────────────────────────────────────┘
```

**铁律**：
- UI 层不得直接改 store；只能发意图（用户动作）或读快照。
- 只有 `ViewportController` 能写 `contentOffset` / `contentInset`。
- 只有 `HeightEngine` 能产出高度；任何 cell、任何 layout 不得自己算高度再写回。
- `Row` 是不可变结构体，身份 = `RowID`，内容版本 = `RowVersion`。

### 3.2 核心类型

```swift
struct RowID: Hashable { let messageID: UUID; let kind: Kind; let blockID: UUID? }
enum RowKind { case userBubble, assistantHeader, text, thinking, tool, question, footer, divider, systemInfo }

struct Row: Identifiable {
    let id: RowID
    let version: RowVersion        // 内容哈希（含状态：running/paused/error…）
    let content: RowContent        // 只读载荷
    let metrics: RowMetricsSpec    // 视图与估高共用同一份尺寸参数
}

struct ConversationSnapshot {
    let rows: [Row]
    let revision: UInt64           // 单调整体版本
}
```

### 3.3 视口：锚点模型（取代 8 个写入者）

```swift
enum ViewportAnchor {
    case bottom(distance: CGFloat)          // 贴底：底边距输入区 distance
    case row(RowID, offsetInRow: CGFloat)   // 历史：该行行内偏移不变
}

final class ViewportController {
    private(set) var insetBottom: CGFloat    // = max(composer, keyboard) + 8
    private(set) var anchor: ViewportAnchor
    // 唯一入口：
    func handle(_ event: ViewportEvent)      // .scrollByUser / .layoutChanged / .insetChanged / .snapshotApplied
    // 唯一出口：
    var onOffsetChange: ((CGFloat) -> Void)? // 一帧最多一次
}
```

处理规则（表）：

| 事件 | 锚点 bottom | 锚点 row |
|---|---|---|
| 内容变高（底部增长） | offset += Δtotal | offset += Δ(该行之前的位移) |
| 内容变矮 | offset += Δtotal（保持底边） | 同上 |
| inset 变化 | offset += Δinset（底边像素不动） | offset += Δinset |
| 用户拖动结束 | 距底 ≤ 阈值 → `.bottom`，否则取顶部行 → `.row` | 同 |
| 快照应用 | 先布局，再按锚点求解一次 | 同 |

**禁止**：`scrollToBottomNow` 出现在除"发送新消息""点跳到底部按钮"以外的任何路径。

### 3.4 高度：单一测量通道

```swift
protocol RowMeasuring {
    func measure(_ row: Row, width: CGFloat, scale: CGFloat) -> CGFloat   // 纯函数，可缓存
}
```

- 缓存键：`RowID + version + 宽度桶(1pt) + 字号档`；`version` 变了就必然重测；
- **状态进版本**：footer 从"回复中"变"已暂停"，version 必变 ⇒ 不存在"键没变所以拿旧高度"；
- 同步测量只允许在主线程一次；离屏预测量走后台但**不得写回布局**（只写缓存，下一次布局读）；
- 兜底只有一张表 `RowMetricsSpec`，与视图共用同一常量（`36` 只有一处定义）。

### 3.5 输入区与键盘

- Composer 用一个 `onGeometryChange` 上报 **"输入区实际占据的高度"**（含安全区、含浮动栏、键盘弹起时用键盘高度）；列表侧不拼、不减；
- 键盘用 `keyboardWillChangeFrame` + 动画参数，inset 在同一个 `UIView.animate` 事务内设置；
- 列表 `contentInsetAdjustmentBehavior = .never`，不依赖系统推挤（现在的注释与实际相反）。

### 3.6 渲染承载（回答你的问题）

**继续用 UITextView + TextKit**，理由：

1. 正文需要精确行数/字符偏移（附件、选中、代码块），SwiftUI Text 做不到；
2. 现有 `MarkdownTextView`、`MarkdownAttachments`（表格/代码/公式/图片）是资产，重写等于重做 8,900 行；
3. 问题不在渲染，在调度。

**保留**：`MarkdownView`、`MarkdownTextView`、`MarkdownAttachments`、`MiniClawMarkdownParser`、`MarkdownRenderCache`（键需并入 `RowVersion`）。

**重写**：cell 容器、行构造、高度调度、视口、输入区几何、浮层挂载。

---

## 四、删除清单（重构的收益主要在这里）

| 删除 | 原因 |
|---|---|
| `scrollMode` 状态机 | 由锚点取代 |
| KVO 增长贴底 / browse 分支 | 由 `layoutChanged` 事件取代 |
| 聚焦 0.55s 延迟贴底 | 由 `insetChanged` 取代 |
| `applySubViewportCompensation` | 判定恒假（死分支） |
| `pendingAboveShift` / `settleAbove` / `suppressContentOffsetAdjustment` | 锚点求解后不需要 |
| `flushingNow` / `isApplyingSnapshot` 的偏移抑制 | 事件化后不需要 |
| footer 手工重测（`refreshFooterHeightIfProminenceChanged`） | 状态进 version |
| `rendererCache`（无淘汰） | 改由 `MarkdownRenderCache` 分代 |
| 5 处高度兜底常量 | 收敛到 `RowMetricsSpec` |
| `MessageListCoordinator` 的 4 个 extension 拆分 | 合并进 RowBuilder/Viewport/HeightEngine |

预计净减 **6,000–8,000 行**。

---

## 五、迁移路线（分阶段，每阶段可装机理）

| 阶段 | 内容 | 验收（数值断言） | 预估 |
|---|---|---|---|
| **P0** | 探针与基线：`ViewportTrace` + 不变量断言 | 拿到一次"输入/暂停/拖动"轨迹 | 0.5 天 |
| **P1** | 新模块骨架：Row/RowID/RowBuilder + ConversationStore（只读挂到旧界面） | 新旧渲染结果逐行一致 | 2 天 |
| **P2** | HeightEngine 接管高度（旧 layout 只读它） | 高度与旧路径差异 ≤ 0.5pt | 2 天 |
| **P3** | ViewportController 接管 offset/inset，删旧写入者 | 一次聚焦：inset 变更 1 次、offset 写入 1 次 | 2 天 |
| **P4** | Composer 上报遮挡高度，替换 4 项相加 | 键盘往返 3 次无漂移 | 1 天 |
| **P5** | 新 ChatScreen 替换旧页（flag `chatV2`），旧页保留一版 | 12 场景全绿 | 2 天 |
| **P6** | 删旧代码与探针 | 行数下降、无回归 | 1 天 |

总计 **10.5 个工作日**（不含真机反复验证等待）。

---

## 六、测试矩阵（全部可数值断言）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 底部点输入框 | 内容像素不动；inset Δ == offset Δ |
| 2 | 历史中点输入框 | offset Δ == 0 |
| 3 | 底部暂停 / 继续 | 横幅完整；底边距恒 8pt |
| 4 | 历史中暂停 | 视口不动 |
| 5 | 工具指示器追加（底部） | 底边保持 |
| 6 | 工具指示器追加（历史） | 不动 |
| 7 | 流式中快速拖动 | 不抢滚动；松手稳定 |
| 8 | 键盘往返 3 次 | 回原位，无累积漂移 |
| 9 | 改字号 | 按锚点保持，无 200pt 兜底 |
| 10 | 旋转/分屏 | 一次重算，无二次跳 |
| 11 | 后台→前台 | 位置保持 |
| 12 | 杀 App 重进 | 停在底部 |

---

## 七、需要你定的规则（我会按你的规则改方案细节）

1. **视觉：允许哪些变化？** 例如状态行/横幅是否统一高度、圆角与间距是否可微调。
2. **灰度：能否接受"新页先只读、不能发消息"的中间态**（最容易保稳定）？
3. **并行：重构期间是否冻结会话页的功能新增**（ask_user 卡片等）？
4. **验收：以你手上哪几个场景为准**（你说的 12 条我可以删到 6 条核心）。
5. **旧页去留**：切换失败时必须能一键回旧页，是否需要保留一整版？

---

## 八、风险与对策

| 风险 | 对策 |
|---|---|
| TextKit 测量在后台线程与主线程不一致 | 测量统一在主线程串行；后台只预热缓存 |
| diffable 身份变化导致闪烁 | RowID 只由 (messageID, kind, blockID) 组成；版本只管内容 |
| 搬迁期间两边都改 | 冻结期 + 单入口 |
| 行高与视觉对不齐 | `RowMetricsSpec` 与视图共用同一常量，漂移即编译期可查 |

---

## 九、这份方案的边界

- 不改：消息持久化、Agent 引擎、工具系统、设置页；
- 不改：Markdown/TextKit 渲染内核；
- 改：**行模型、高度调度、视口所有权、输入区几何、cell 容器、浮层挂载**。

一句话：**把"谁来决定"重写，把"怎么画"留下。**

---

## 十、补充：外层清点结论（并入方案）

### 10.1 三份重复的高度测量

| 量 | 测量点 | 用途 |
|---|---|---|
| `inputBarHeight` | `ChatView.swift:888` `.onGeometryChange(global frame)` | 列表 inset |
| `barHeight` | `ChatInputBar.swift:154` 自身几何 | 斜杠菜单底距 |
| `floatingBarHeight` | `ChatView.swift:854` VStack 几何 | 列表 inset |

同一棵子树测了两次高度（`inputBarHeight` 与 `barHeight`），两份防抖算法（380/320ms 与 300ms），
且 `inputBarHeight` 的防抖 Task 在 `onDisappear` **没有取消**（离开会话后仍会写 `@State`）。
→ 新架构里由 `Composer` 单一测量、单一上报。

### 10.2 一个"看起来在工作"的空门

`shouldAutoFollow`（`ChatView.swift:55`）的三个写点全是 `= true`（320/503/1238），两个 guard 恒通过。
注释说"用户一拖动就关"，**实际从未关过**。这类"注释描述了一个不存在的机制"是这页最典型的腐化方式。

### 10.3 呈现层：7 个布尔 + 3 个 item + 11 个 presentation 修饰符

`showFileManager / showSessionTerminal / showSessionBrowser / showTokenUsage / showSoulSettings / showModelManagement /
showProviderSettings` + `previewFileURL / activeSubagentConversation / pendingRemoveSubagent`。
后果之一：`onDisappear` 的守卫只覆盖了 terminal/browser 两个（`ChatView.swift:1186`），
其余三个 `fullScreenCover` 同样会让会话页 `onDisappear`，但不在守卫内 → 会误触发复盘与空会话删除。

→ 新架构改成一个 `ChatPresentation` 枚举 + `.sheet(item:)`。

### 10.4 可以直接删的（有依据）

| 项 | 位置 | 依据 |
|---|---|---|
| `isNearBottom` 镜像 + 其 onChange | `ChatView.swift:1219,1262` | 写后无读（原"回到底部"按钮已删） |
| `lastMessageID` + 其 onChange | `:50,1058,1133` | 无读取点 |
| `lastLoggedInputBarH` | `:85,901` | 只自更新 |
| `ContextRingIndicator` | `ChatViewComponents.swift:132` | 全仓零引用 |
| `import QuickLook/AVKit` | `ChatView.swift:5-6` | 本文件无相关符号 |
| 空 `else {}` | `:959` | 死分支 |
| `let lastAssistant` | `:1073` | 未使用变量 |
| `MiniClawChatBridge.onSend/onPause` | `Bridge:479,563` | 无赋值无读取 |

**草稿重复落盘**：`onDraftChanged`（:869）与 `.onChange(inputText)`（:1175）各写一次盘 → 每次输入写两次。
**提示条定时器竞争**：`showAttachmentNotice`（:1550）的 5s 清理无句柄，连续两次提示会提前清掉第二次。

### 10.5 一个必须澄清的事实（影响第一节的结论）

外层清点认为「键盘会让列表 frame 变矮」（依据是 `.ignoresSafeArea` 只忽略 `.container`，且代码注释写着"列表由系统推挤"）。

但真机日志（17:06:50 与 17:57 两次）显示 `cvH` 在 `focused=0` 与 `focused=1` 时都是 **874**，没有变化。

两种可能：
1. 日志采样时刻都在键盘动画完成之前 → 需要 `keyboardWillChangeFrame` 时刻的采样；
2. 列表确实没被推挤 → 那么"只改 34pt inset"就是在补偿一件没发生的事。

**P0 探针必须直接回答这个问题**：在键盘 `willChangeFrame` 回调里记录 `cvH` 前后值。
这条不确认，Phase 4 的输入区改造就没有地基。

### 10.6 外层拆分建议（并入第三节）

| 新单元 | 承接 |
|---|---|
| `ChatComposerView` + `ChatComposerModel` | 输入文本、注入、附件、语音、测高与持久化 |
| `ChatFloatingStack` | 排队消息、子代理胶囊、附件提示、添加密钥条（只上报总高） |
| `ChatToolbar` | 标题、模型名、菜单 |
| `ChatPresentation` | 所有 sheet/cover 的统一枚举 |
| `ChatSessionController` | 发送/停止/暂停/恢复/恢复检查点/排队消息/深链 |
| `ViewportController` | 滚动与 inset（本方案核心） |
| `BarHeightTracker` | 合并三份测高与两套防抖 |

### 10.7 修订后的工期

原 10.5 天 → **12 天**：外层拆分（`ChatSessionController` + 呈现层收敛）多出 1.5 天，
但换来的是"`onAppear`/`onDisappear` 隐式顺序"这类脆弱耦合被拔掉。

### 10.8 三条不可谈判的前置条件

1. **P0 先回答 `cvH` 是否随键盘变化**（决定输入区方案）；
2. **外层拆分与视口重写分开做**，不要在同一次提交里同时动（否则出问题无法归因）；
3. **每个阶段保留旧路径开关**，直到该阶段验收通过。
