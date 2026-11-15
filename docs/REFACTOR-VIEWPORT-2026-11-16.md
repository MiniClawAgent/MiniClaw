# 重构方案：会话页视口与滚动所有权（Viewport Ownership）

> 状态：**方案，未动代码**
> 日期：2026-11-16
> 触发问题：点输入框内容下沉/被盖住；暂停横幅露到输入栏下面；松手跳一下；流式期上下弹
> 结论先行：**这不是 8 个 bug，是一个 bug——视口没有唯一的所有者。**

---

## 一、现状诊断（有数据）

### 1.1 谁在写视口位置

| # | 写入者 | 位置 | 触发 |
|---|---|---|---|
| 1 | `contentInset.bottom` | `MessageCollectionView.swift:1155` | 4 个输入变化 |
| 2 | contentSize 增长贴底 | `MessageCollectionView.swift:280` | 每次布局 |
| 3 | `scrollToBottomNow` | `+Scrolling.swift` | focus/inset/快照/流式 flush |
| 4 | 快照后重贴底 | `+Snapshot.swift:436` | 每次 apply |
| 5 | 松手结算 | `+Scrolling.swift:1120` | 每次拖动结束 |
| 6 | 延后高度越界收敛 | `+Snapshot.swift:430` | 每次 apply |
| 7 | 聚焦延迟贴底（0.55s） | `MessageCollectionView.swift:1217` | 点输入框 |
| 8 | `applySubViewportCompensation` | `+Scrolling.swift:242` | 每帧（**判定恒假，死分支**） |

### 1.2 inset 是 4 个会各自抖动的量相加

```
inset.bottom = inputBarHeight + floatingBarHeight + 8 + bottomSafe    （非键盘态）
inset.bottom = inputBarHeight + 8                                     （键盘态，减掉后两项）
```

真机日志（02:06:50–02:07:02，一次聚焦 + 一次失焦）：

```
focused=0  base=117  (=61+48+8)      cvH=874
focused=0  base=103  (=61+8+34)      cvH=874
focused=1  base=69   (=61+8)         cvH=874     ← 键盘弹起，列表高度没变
focused=0  base=117                   cvH=874
focused=0  base=103                   cvH=874
```

两个致命事实：

1. **inset 在 45ms 内跳 3 次**，每次变化都调一次 `scrollToBottomNow` ⇒ offset 被反复重写。
2. **`cvH` 恒为 874**：键盘弹起时列表没有被推挤。代码注释假设"列表由系统推挤"，但会话页是
   `.ignoresSafeArea(.bottom)`（`ChatView.swift:1236`）⇒ 系统不会推 ⇒ 内容被**盖住**而不是**顶起**。

### 1.3 行高侧的问题（同源）

- footer 高度键 `f:<msgId>` **不含状态**：暂停/回复中/已完成共用同一个缓存槽；
- 底部增长（16.3 → 40pt）没有任何锚定，新增的 24pt 直接落到输入区后面；
- 约 8 处高度兜底常量（4 / 36 / 40 / 48 / 200 …）与视图字面量各写一份，互相漂移。

---

## 二、根因（一句话）

> 视口位置（offset + inset）没有**唯一所有者**，而是 8 个回调各自根据自己看到的局部信息做决策；
> 而它们依赖的输入（输入栏高度、浮动栏高度、安全区、键盘）本身在抖动。

修任何单点，都会被另一个写入者覆盖——这就是"修了又回来"的机制。

---

## 三、重构目标：6 条不变量

任何改动都必须能对照这 6 条验收：

| ID | 不变量 | 判据 |
|---|---|---|
| **I1** | inset 变化时，可见内容**不移动** | 前后可见行与行内偏移不变 |
| **I2** | 用户在底部时，内容在底部增长 → **底边保持** | 底边距输入区恒为 8pt |
| **I3** | 用户在浏览历史时，任何异步更新**不得移动视口** | offset 变化量 = 0 |
| **I4** | 同一帧内 offset **最多被写一次**，且只有所有者能写 | 探针计数 = 1 |
| **I5** | inset 只有一个来源：**遮挡高度** | 无第二个 inset 赋值点 |
| **I6** | 行高变化不改变"用户正在看的像素" | 锚点行内偏移恒定 |

---

## 四、新架构

```
┌────────────────────────────────────────────┐
│ ChatView (SwiftUI)                          │
│  · 只测量"输入区实际占据高度"并上报          │
└────────────────┬───────────────────────────┘
                 │ obscuredBottom（单一数字）
┌────────────────▼───────────────────────────┐
│ ViewportController（唯一所有者，@MainActor） │
│  · anchor: .bottom(distance) | .row(id, dy) │
│  · inset 计算：obscuredBottom + 8           │
│  · 事件：userScroll / contentChanged /      │
│          insetChanged / snapshotApplied      │
│  · 输出：唯一一次 setOffset(_:animated:)     │
└────────────────┬───────────────────────────┘
                 │ 指令
┌────────────────▼───────────────────────────┐
│ UIScrollView 适配层（只执行，不决策）        │
│  · contentInset.bottom = controller.inset   │
│  · contentOffset = controller.offset        │
│  · 禁用 UIKit 自动调整（.never）             │
└────────────────────────────────────────────┘
```

### 4.1 核心抽象：锚点（Anchor），不再有"模式"

现状用 `scrollMode = .autoScrolling / .userBrowsing` 表达意图，但它是一个**滞后状态**：
谁把它改成什么、什么时候改，全靠调用点自觉。改为**每次都从几何事实推导锚点**：

| 场景 | 锚点 | 内容变化时 |
|---|---|---|
| 贴底（底边距 ≤ 阈值） | `.bottom(distance)` | 底边保持，offset 随 totalHeight 平移 |
| 用户拖动/停在历史 | `.row(itemId, dy)` | 该行行内偏移不变，offset 按行位移补偿 |
| 键盘/inset 变化 | 沿用当前锚点 | 按锚点重算，**只写一次** |

锚点在**每次用户手势结束时**重新计算一次（取视口顶部第一条可见行 + 行内偏移），
之后所有布局事件都按它求解——不需要 pendingAboveShift、不需要 settle 补偿、不需要"延迟 0.55s"。

### 4.2 inset 模型（单一来源）

```swift
obscuredBottom = max(
    composerFrame.height + safeAreaBottom,   // 输入区实际占位（含浮动栏，由 ChatView 上报）
    keyboardTopInset                          // 键盘遮挡（系统通知，含动画曲线）
)
insetBottom = obscuredBottom + 8
```

- **不再做减法**：键盘态不"减掉"安全区/浮动栏；
- 键盘和输入栏谁高用谁（`max`），避免"键盘弹起但输入栏更高"时的二次跳；
- 输入栏高度由 ChatView 用 `onGeometryChange` 上报**含安全区**的整体高度，列表侧不再自己拼。

### 4.3 底部增长（用户说的"队列"）

所有指示器（思考、工具、暂停、错误、状态行）本质都是**在末尾追加或改变一个行**。
`ViewportController` 统一处理：

```
contentChanged(oldTotal, newTotal):
    switch anchor:
    case .bottom:      offset += (newTotal - oldTotal)      // 底边锚定
    case .row(id, dy): offset += deltaBefore(id)            // 只补偿该行之前的位移
```

底部增长对 `.bottom` 就是一次等量平移；对 `.row` 则完全不动（I3）。

---

## 五、要删掉的东西（这是重点）

| 删除项 | 位置 | 替代 |
|---|---|---|
| `scrollMode` 状态机 | `MessageCollectionView` / `+Scrolling` | 锚点 |
| KVO 增长贴底（含 browse 分支） | `MessageCollectionView:280-320` | `contentChanged` |
| 聚焦 0.55s 延迟贴底 | `MessageCollectionView:1213-1245` | `insetChanged` 一次求解 |
| `applySubViewportCompensation` | `+Scrolling:230-260` | 删除（死分支） |
| `pendingAboveShift` / `settleAbove` | `+Scrolling` / `Layout` | 锚点求解 |
| `suppressContentOffsetAdjustment` / `isApplyingSnapshot` 的 offset 抑制 | `+Snapshot` / `+Scrolling` | 先布局后求解，不产生自动补偿 |
| 快照后重贴底 | `+Snapshot:436` | `snapshotApplied` 事件 |
| `flushingNow` 期间跳过 KVO 的特殊处理 | `MessageCollectionView` | 事件化后不需要 |
| footer 的 `refreshFooterHeightIfProminenceChanged` 手工重测 | `MessageCollectionView:648` | 状态进内容键，高度自然失效（见 5.1） |

### 5.1 行高侧的两条配套

1. **状态进键**：footer 的键从 `f:<msgId>` 改为 `f:<msgId>:<state>`（`idle|running|resume|error|interrupted|quiet`），
   形态一变键就变，缓存自然不命中，不需要"手工清缓存 + reconfigure"。
2. **常量归一**：把 `36/40/48/4/200` 这些字面量收进一处 `RowMetrics`，视图与估高**同源引用**，
   禁止再各写一份（35 与 36 这种差 1pt 的漂移就是从这里来的）。

---

## 六、实施阶段（每阶段可独立验收、可回滚）

### Phase 0：观测（不改行为，1 天）
- 新增 `ViewportTrace`（category `BottomPad`，不受诊断静默影响）：
  记录每次 inset 变化、offset 写入（含调用者）、anchor 值、cvH、contentSize。
- 加一条**不变量断言**（DEBUG）：同一帧 offset 写入 > 1 次即打 `[VIOLATION] I4`。
- 产出：一次"点输入框 + 暂停 + 拖动"的完整轨迹，作为基线。

### Phase 1：inset 单源（1 天）
- ChatView 上报 `obscuredBottom`（含键盘），列表侧只做 `inset = obscured + 8`。
- 删除现有 4 项相加与键盘态减法。
- 验收：一次聚焦只出现 1 次 inset 变更；`cvH` 记录键盘前后对比（说明列表是否被推挤）。

### Phase 2：ViewportController 接管 offset（2 天）
- 引入锚点 + 事件；接管所有 offset 写入。
- 删除 KVO 贴底、focus 延迟贴底、快照重贴底、settle 补偿。
- 验收：I1–I4 全部通过（探针断言）。

### Phase 3：行高事件化（1.5 天）
- footer 状态进内容键；`RowMetrics` 常量化。
- 删除手工重测与 8 处兜底常量。
- 验收：暂停/继续/错误切换时，footer 高度只变一次且无裁切。

### Phase 4：清理与回归（1 天）
- 删除死分支（`applySubViewportCompensation` 等）。
- 跑完整测试矩阵（见第七节）。
- 收尾文档：`CURRENT_STATE.md` 补"视口所有权"一节。

总工期：**5.5 个工作日**（不含真机反复验证的等待）。

---

## 七、测试矩阵（每条都必须有期望值）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 点输入框（在底部） | 内容不动，输入区上移；inset 变更 1 次，offset 平移量 == inset 变化量 |
| 2 | 点输入框（在历史中） | offset 变化 0 |
| 3 | 暂停（在底部） | 横幅完整可见，底边距保持 8pt |
| 4 | 暂停（在历史中） | 视口完全不动 |
| 5 | 工具指示器追加（在底部） | 底边保持，无跳 |
| 6 | 工具指示器追加（在历史中） | 不动 |
| 7 | 快速拖动中流式 | 不抢滚动，松手后位置稳定 |
| 8 | 键盘弹起→收起往返 3 次 | 每次回到同一位置，无累积漂移 |
| 9 | 改字号 | 视口按锚点保持，无 200pt 兜底 |
| 10 | 旋转/分屏 | inset 与锚点重算一次，无二次跳 |
| 11 | 后台→前台 | 位置保持 |
| 12 | 杀 App 重进（检查点恢复） | 停在底部，无跳 |

验收方式：全部用 `ViewportTrace` 的数值断言，不靠肉眼。

---

## 八、风险与回滚

| 风险 | 缓解 |
|---|---|
| 锚点在行高未定时求解会漂 | 求解前强制 `layoutIfNeeded()`，同一帧内只解一次 |
| 键盘通知与 SwiftUI 布局时序 | 键盘用 `willChangeFrame` + 动画时长，inset 在 `UIView.animate` 内同步设置 |
| 改动面大 | `viewportV2` 特性开关；旧路径保留一个版本，出问题一键切回 |
| 长按选择/拖拽选择被影响 | 选中态期间冻结锚点（沿用现有 `isSelecting` 判定） |

---

## 九、这份方案"重写"了什么，没重写什么

**重写**：视口决策层（谁决定 offset/inset）。这一层现在有 8 个写者、0 个所有者，必须换掉。

**保留**：
- `MessageListLayout` 的高度缓存与流式保护（那是渲染正确性问题，已经验证过）；
- `MarkdownTextView` / TextKit 渲染与附件；
- 行模型（header/block/footer）与 diffable 快照；
- 消息持久化与检查点。

也就是说：**换掉"方向盘"，不换"发动机"**。这也意味着风险可控——渲染管线不动，回滚只需关开关。
