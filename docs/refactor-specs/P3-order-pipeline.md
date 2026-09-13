# P3 · S4 顺序管线显式化 —— 实现规格

> 来源：重构调研（2026-09-13）。基准文档：`../render-pipeline-refactor-2026-09-13.md`（§2 S1–S15 / §3 M1–M8 / §5 阶段表）。
> 行号为**调研时**的盘上值，会随实施漂移；跨文件引用优先按**符号名**定位。

## 0 一句话结论

`applySnapshot` 已经是"单函数顺序管线"，但它把 **5 个补播调用点、1 个重映射、8 个失效调用点**全部内联在 ~330 行里，靠 6 段长注释维护顺序。P3 的落点不是"新写管线"，而是把这条既有序列**切成有名字、可断言的分段**，并把 3 个 seed/reseed 实现 + 5 个外部播种旁路收进同一入口。

## 1 `applySnapshot` 完整执行序列

函数体：`:59`（签名）— `:395`（结束）。

| # | 行号 | 动作 | S | 隐式依赖 |
|---|---|---|---|---|
| 1 | `:60` | `guard let vm, !vm.isLoadingSession else { return }` | — | 所有后续步骤的前提 |
| 2 | `:63-65` | 过滤 `isInternalBridge` 消息 | — | 影响 `newRows`/`messageIndex`，必须早于 `:171` |
| 3 | `:68` | `lastJumpedUserId = nil` | — | 无依赖 |
| 4 | `:70-115` | 懒安装 `attachmentSizeChangedSub`（`.miniClawAttachmentSizeChanged`） | — | 一次性订阅；handler 内含 3 个失效入口 `:88` `:96` `:108` |
| 5 | `:117-169` | 懒安装 `thinkingToggleSub`（`.thinkingBlockToggled`） | — | handler 含失效入口 `:149` `:153` |
| 6 | `:171-174` | 重建 `messageIndex`（msg.id→index） | — | **必须早于 `:220`**：`seedHeight` 在 `:585/:597/:637` 依赖它 |
| 7 | `:176-179` | 算 `removedIds`、清 `bridgeSheetSubs`、过滤 `cellBridgeMap` | — | 早于 `:191`（footer 判定读 `cellBridgeMap`） |
| 8 | `:181-212` | 构建 `newRows`：user/compact/system → `.wholeMessage`；assistant → `.assistantHeader` + blocks（`:191-194` 按 `timelineOrder` 排序）+ `.assistantFooter`（`:199-210`） | — | 必须早于 `:220`/`:275`/`:278` |
| 9 | `:214-222` | **补播 · 全量**：`seedHeights(.all, …)` @ `:220` | S1/S4 家族 | ① 必须早于 `dataSource.apply`(`:340`)；② **必须在早退 `:275` 之前** |
| 10 | `:223-226` | 重建 `itemToIndex` | — | 无强依赖 |
| 11 | `:229-256` | 计算流式块区间 → `layout.streamingCellRanges`（`:253`）或 `= []`（`:255`） | — | **必须早于 `apply`**：`prepare()` `:262-264` 与 `isStreamingCell`(`Layout:542`) 读它 |
| 12 | `:258` | `layout.isAutoScrollPinning = (scrollMode == .autoScrolling)` | — | 早退前也须更新 |
| 13 | `:259` | `oldCount = prevSnapshotIds.count` | — | **必须在 `:279` 覆写 `prevSnapshotIds` 之前读** |
| 14 | `:262` | `snapshotMessages = messages` | — | `prefetchItemsAt`(`Scrolling:745`) 优先读它 |
| 15 | `:269-273` | 整轮结束 → `reseedTrailingTextBlock`(`:271`)；更新 `lastWasProcessing` | **S3** | **必须早于早退 `:275`** |
| 16 | `:275` | **早退**：`if newRows == prevSnapshotIds { return }` | — | 早退点 |
| 17 | `:276-279` | `oldRows`；`inserted = newRows − oldSet`；`prevSnapshotIds = newRows` | — | `:278` 必须早于 `:279`；`oldRows` 必须早于 `:289` |
| 18 | `:281-283` | 构建 `NSDiffableDataSourceSnapshot` | — | 早于 `:340` |
| 19 | `:284-289` | **重映射**：`remapHeights(oldIds:newIds:)` @`:289` | **S4/S5** | **必须早于 `:333`（缺失全扫）与 `:330`（新增补播）**。注意它排在 `:220` 全量补播**之后**（见 §6 R1） |
| 20 | `:291-303` | **补播 · 前驱文本块**：`reseedTextBlock(before:)` @`:301` | **S2** | **必须早于 `:340`** |
| 21 | `:326-334` | **补播 · 新增 → 缺失**：`seedHeights(.inserted)` @`:330`，`seedHeights(.missing)` @`:333` | **S1** | 必须早于 `:340`；`.inserted` 必须先于 `.missing` |
| 22 | `:336-337` | `suppressContentOffsetAdjustment = true`；`flushingNow = true` | **S10** | 静默窗开始；**无 `defer`** |
| 23 | `:338` | `cellConfigCount = 0` | — | — |
| 24 | `:339` | `isApplyingSnapshot = true` | — | 与 22 同窗（M7） |
| 25 | `:340` | **`dataSource.apply(snapshot, animatingDifferences: false)`** | **S10 核心** | 全序列分水岭 |
| 26 | `:341` | `isApplyingSnapshot = false` | — | 必须紧跟 `:340` |
| 27 | `:342` | `collectionView.setNeedsLayout()` | — | — |
| 28 | `:344-351` | `cv.layoutIfNeeded()` @`:351` | **S10** | **必须在 `:340` 之后、`:352` 复位之前** |
| 29 | `:352-353` | `suppressContentOffsetAdjustment = false`；`flushingNow = false` | **S10** | **必须晚于 `:351`** |
| 30 | `:354-367` | 收缩 clamp / `autoScrolling` 贴底 / `applySubViewportCompensation`(`:360`/`:366`) | — | 依赖 `:351` 后的 `contentSize` |
| 31 | `:370-376` | 同步 `vm.isNearBottom` + `syncScrollFlags()` | — | `flushingNow` 已复位才读得到 `contentSize` KVO 态 |
| 32 | `:385-390` | 条件触发 `scheduleHeightPrewarm` | — | 依赖 `:351` 后布局稳定 |
| 33 | `:391-394` | else 分支（无 cv）复位 `suppress`/`flushingNow` | **S10** | 与 `:352-353` 是两条并行复位路径（**另一处无 `defer` 的隐患**） |

**早退路径（`:275`）的副作用可见性**：`messageIndex`(6)、`cellBridgeMap`(7)、`newRows`(8)、`seedHeights(.all)`(9)、`streamingCellRanges`(11)、`isAutoScrollPinning`(12)、`snapshotMessages`(14)、`reseedTrailingTextBlock`(15) 都在早退前生效 —— **这 8 项是"身份不变也要跑"的语义**，切管线时不得移入早退之后。

**陈旧行号引用**：`:215` 注释写 `:239 remapHeights`（实际 `:289`）；`:324` 注释写 `:247 reseedTextBlock`（实际 `:301`）。已在 `85a9d4e` 改为符号名。

## 2 「补播 / 重映射 / 失效」入口清点

### 2.1 补播（seed / reseed）

**官方入口**：
- `seedHeights(_:rows:messages:width:)` — `Snapshot.swift:33-57`；`SeedScope` `:17-24`
  - `.all` → `:220`；`.inserted` → `:330`；`.missing` → `:333`
- `seedHeight(at:item:messages:width:isReseed:)` — `Snapshot.swift:578-752`；**仅被 `seedHeights` 调用**
- `reseedTextBlock(before:…)` — `Snapshot.swift:501-539`；调用点 `:301`
- `reseedTrailingTextBlock(rows:messages:)` — `Snapshot.swift:543-576`；调用点 `:271`

⇒ 补播 = **5 个调用点 / 4 个实现函数**。

**绕过同一入口的写入点**：

| 语义 | 文件:行号 | 说明 |
|---|---|---|
| `setEstimatedHeight` | `MessageCollectionView.swift:463` | configureCell 兜底 |
| `setEstimatedHeight` | `Scrolling.swift:754` | `prefetchItemsAt` 预取兜底 —— **已并入 `seedHeights(.indices:)`（`373cd2f`）** |
| `setPrecalcHeight` | `Snapshot.swift:526` | `reseedTextBlock` HIT 分支 |
| `setPrecalcHeight` | `Snapshot.swift:558` | `reseedTrailingTextBlock` HIT 分支 |
| `setEntry(.measured)` | `Layout.swift:341` | `applyDeferredHeights` 解冻回灌 |
| `setEntry(.measured)` | `Layout.swift:456` | `invalidationContext`（PLAF 提交点） |
| `recordMeasuredHeight` | 定义 `Layout.swift:728-736`；唯一调用 `Infrastructure.swift:842` | 进程级 memo 写入（PLAF live 路径） |

### 2.2 重映射

| 项 | 文件:行号 | 调用点 |
|---|---|---|
| `remapHeights(oldIds:newIds:)` | 定义 `Layout.swift:620-642` | **全库唯一调用**：`Snapshot.swift:289` → **已上移到段 0（`e9caf03`）** |
| `setContentKey(_:at:)` | 定义 `Layout.swift:676-678` | `Snapshot.swift:586`（seedHeight 内）、`MessageCollectionView.swift:427` |
| `updateCacheForSnapshot` | **已删除**，仅存注释 `Layout.swift:587-591` | 无调用点 |

⇒ 重映射已收敛；S5 空成立（`updateCacheForSnapshot` 是 `remapHeights` 严格子集）。**残留双写是 `contentKeyByIndex`**（seedHeight 与 configureCell 两处 `setContentKey`）。

### 2.3 失效

**官方唯一入口**：`invalidateHeight(at:memo:)` — `Layout.swift:606-613`（`MemoPolicy` `:604`）。调用点 8 处：

| 文件:行号 | 策略 | 场景 |
|---|---|---|
| `Snapshot.swift:46` | `.indexOnly` | `seedHeights(.inserted)` |
| `Snapshot.swift:88` | 默认 | 附件尺寸变化（可见 cell） |
| `Snapshot.swift:96` | 默认 | 附件尺寸变化（全部 index） |
| `Snapshot.swift:149` | 默认 | 思考块折叠切换 |
| `Snapshot.swift:525` | `.indexOnly` | `reseedTextBlock` |
| `Snapshot.swift:557` | `.indexOnly` | `reseedTrailingTextBlock` |
| `MessageCollectionView.swift:878` | 默认 | 回前台（内容增长 ≥200 字） |
| `MessageCollectionView.swift:897` | 默认 | `blockContentFilledSignal` |

**其余失效旁路**：

| 入口 | 文件:行号 | 调用点 |
|---|---|---|
| `invalidateMemo(forKey:)` | 定义 `Layout.swift:738-742` | `MessageCollectionView.swift:444`；另 `Layout:611` 内部 |
| `clearHeightCache(keepingSharedMemo:)` | 定义 `Layout.swift:758-769` | `MessageCollectionView.swift:783`(true)、`Snapshot.swift:755`(默认) |
| `clearSharedMemo()` | 定义 `Layout.swift:746-751` | 仅 `Layout:763` |
| `clearUserBubbleMemo()` | 定义 `Heights.swift:76-80` | 仅 `Layout:768` |
| **`heightEntries.removeAll()` 直清** | `Layout.swift:581`（`scheduleWidthPurge`） | **已并入 `clearHeightCache(keepingSharedMemo: true)`（`85a9d4e`）** |
| `clearCachedHeight()`（cell 级） | 定义 `Infrastructure.swift:860-864` | `Snapshot:87/106/147`、`Infrastructure:134`、`MarkdownTextView:1282`、`prepareForReuse:868` |
| `invalidateLayout()`（重排，非高度失效） | — | `Layout:528/583`、`View:880`、`Bindings:99`、`Scrolling:1016`、`Snapshot:108/153/570`、`Infrastructure:113/137`、`MarkdownTextView:1285` |
| `streamingCellRanges` 赋值 | `Snapshot:253/255` | 状态失效 |

## 3 `remapHeights` 专项

- **位置**：`Layout.swift:620-642`。
- **做什么**：① 建 `oldIndexByItem: [MessageListItem: Int]`；② 建四个新字典；③ 遍历 `newIds`，`guard let oldIndex = oldIndexByItem[item] else { continue }`（**未匹配的 item 不写 ⇒ 条目自然清空**），搬 `heightEntries`(`:629`)、`contentKeyByIndex`(`:630`)、`footerHugByIndex`(`:631`)、`metricsTagByIndex`(`:633`, DEBUG)；④ 整体替换四个字典。
- **优先级语义**：搬移的是 `HeightEntry`（含 `source` 与 `key`），故 `setEntry` 的"低不覆盖高"闸门仍按原 source 生效 —— **搬移不降级**。

## 4 目标结构

### 4.1 设计原则

1. `applySnapshot` 只做"编排"，每段有名字；顺序由**分段函数的调用次序**保证，注释降级为文档。
2. 补播收敛为**一个入口 + `SeedScope` 穷举**；`reseedTextBlock`/`reseedTrailingTextBlock` 降级为 `SeedScope` 的两个 case（本质就是"按内容的定向补播"）。
3. 失效收敛为 `seedHeights` 内部副作用，外部调用点只允许 `invalidateHeight`。
4. `plan` 段纯计算、零副作用，使"哪一步依赖哪个索引表"变成类型可见。

### 4.2 目标签名

```swift
private struct SnapshotPlan {
    let caller: String
    let messages: [RenderMessage]
    let rows: [MessageListItem]
    let inserted: [MessageListItem]
    let identityUnchanged: Bool
    let streamingRanges: [Range<Int>]
    let roundJustEnded: Bool          // lastWasProcessing && !isProcessing
}
private func makeSnapshotPlan(_ messages: [RenderMessage], caller: String) -> SnapshotPlan?
private func commitPlanState(_ p: SnapshotPlan)          // 索引表 + 流式区间（早退前必须生效）

enum SeedScope {
    case all
    case inserted([MessageListItem])
    case missing
    case indices([Int])                                  // ✅ 已落地（预取）
    case predecessorTextBlock(of: MessageListItem)        // 原 reseedTextBlock
    case trailingTextBlock                                // 原 reseedTrailingTextBlock
}
```

### 4.3 目标调用顺序

```swift
func applySnapshot(messages raw: [RenderMessage], caller: String = "?") {
    guard let plan = makeSnapshotPlan(raw, caller: caller) else { return }   // ① plan
    commitPlanState(plan)                                    // ② state
    remap(plan)                                              // ③ 迁移（必须早于播种）✅ 已落地
    seedHeights(.all, …)                                     // ④ seed（必须早于 apply）
    if plan.roundJustEnded { seedHeights(.trailingTextBlock, …) }   // S3（必须早于早退）
    guard !plan.identityUnchanged else { return }             // ⑤ 早退
    for item in plan.inserted { seedHeights(.predecessorTextBlock(of: item), …) }  // S2
    seedHeights(.inserted(plan.inserted), …); seedHeights(.missing, …)             // S1
    withSilentWindow { dataSource.apply(snapshot, animatingDifferences: false) }    // ⑥ apply（defer 复位，S10）
    reconcile(plan)                                          // ⑦ layoutIfNeeded → 复位 → clamp → 补偿 → flags → prewarm
}
```

**分段相对次序的理由**：
- `plan` → `state`：`state` 写 `messageIndex`/`itemToIndex`/`streamingCellRanges`，`seedHeights` 依赖它们。
- `state` → `remap`：`remapHeights` 读 `oldIds/newIds` 两个完整列表，必须是 `plan` 里冻结的快照。
- `remap` → `seed`：见 §6 R1。
- `seed` 三连 → `apply`：S1/S2。`trailing seed` → 早退：S3。
- `apply` 前后包静默窗：S10。`reconcile` 复位晚于 `layoutIfNeeded`：S10/S11。

## 5 不可重排清单

### 5.1 P3 范围内必须结构化的

| S | 约束 | 盘上锚点 | 换错的后果 |
|---|---|---|---|
| **S1** | `.inserted`/`.missing` 补播必须早于 `dataSource.apply` | `Snapshot:330/333` 早于 `:340` | `prepare()` 落 200pt 兜底 → 手势期拒绝收缩 → **拖动期大片空白**（实测 Σ928.6pt/38 格位） |
| **S2** | `reseedTextBlock(before:)` 同 S1 | `Snapshot:301` 早于 `:340` | 同上 |
| **S3** | `reseedTrailingTextBlock` 必须早于 `itemIdentifiers` 早退 | `Snapshot:271` 早于 `:275` | 终态身份集合不变 ⇒ 最终回复少字/少行不修 |
| **S4** | `remapHeights` 必须早于"缺失全扫补播" | `Snapshot:289` 早于 `:333` | 新播条目被错位旧条目替换／部分 index 回落兜底 |
| **S5** | `updateCacheForSnapshot` 早于 `remapHeights` | **已删除** ⇒ 空成立 | 登记为"已闭环"，不保留两步 |
| **S10** | `suppressContentOffsetAdjustment`/`flushingNow` 必须包住 apply→`layoutIfNeeded` 且之后复位 | 置位 `:336-337`，重置 `:352-353` 与 else `:391-394` | **无 `defer`**，任一路径提前 return ⇒ 永久滞留 |
| **S15** | `.measured` 条目必须随内容变化被显式失效 | `HeightEntry.key` + `currentEntry` `Layout:64-77`；`setEntry` `:138`；`hasMeasuredHeight` `:667-672`；`seedHeight` 早退 `Snapshot:618` | 旧实测值永久滞留 ⇒ 拖动期冻结成空白 |

### 5.2 相邻文件、P3 不得破坏

| S | 约束 | 盘上锚点 |
|---|---|---|
| **S11** | offset 锚定必须在 `takePendingAboveShift()` 之后 | `Scrolling:1012` → `:1021` → `:1023` |
| **S12** | `clearPendingAboveShift` 必须在拖动开始 | `Scrolling:775` |
| **S14** | settle 内 `deferSelfSizing=false` 在 `applyDeferredHeights` 之前 | `Scrolling:1004` → `:1012`；`deferredHeights` 唯一写入点 `Layout:394` |

### 5.3 明确不在 P3 范围

S6/S7/S8/S9/S13 全部落在 `MiniClawChatBridge`。P3 只做 List 层管线，**不得顺手改动 Bridge 的合并/挂起/指纹顺序**。

### 5.4 P3 新增的验收硬指标

- 早退前必须已执行：`plan`、`state`、`seedHeights(.all)`、`seedHeights(.trailingTextBlock)`。
- `remapHeights` 之前不得有 `.missing`/`.inserted` 补播。
- **`seedHeights` 之外不得再出现"写高度"调用**。

## 6 风险与未确认项

**R1（已确认并已修）—— `.all` 播种与 `remapHeights` 双写 `contentKeyByIndex`，且 remap 在后。**
`:220` 的 `.all` 先按新索引重写整表内容键；`:289` 的 remap 又用 `contentKeyByIndex[oldIndex]` 写回 `newIndex` ⇒ 索引位移时读到"新索引体系下旧下标那个 item 的键"，与 `HeightEntry.key` 错配 ⇒ `currentEntry` 判陈旧 ⇒ 迁移失效。**已改为段 0 迁移 → 段 1 播种（`e9caf03`）**。

**R2（已确认，未修）—— 静默窗无 `defer`。** `:336-337` 置位后有 else 兜底 `:391-394`，但任何未来在 `:337` 与 `:352` 之间新增的提前 return 都会导致 `flushingNow`/`suppressContentOffsetAdjustment` 永久滞留。P3 应以 `defer` 重构（S10）。

**R3（已确认，已修）—— 失效旁路 `Layout:581`。** `scheduleWidthPurge` 原直写 `heightEntries.removeAll()`，绕过 `contentKeyByIndex`/`footerHugByIndex` 清理与 `clearUserBubbleMemo()`，留下孤儿键。已收敛到 `clearHeightCache(keepingSharedMemo: true)`（`85a9d4e`）。

**R4（已证否）—— `cellConfigCount` 无消费点"：错。** 它在 `configureCell` 内被读（`cellConfigCount == 1` 时记 `firstCellConfigTime`）。不是死赋值。

**R5（未确认）—— `itemToIndex` 在 `applySnapshot` 内无读取点。** 需全库确认后再处理。

**R6（已确认，未修）—— `seedHeight` 的两处静默 `return`**（`messageIndex` 查不到消息 / 消息里找不到块）⇒ 该 index 无条目 ⇒ `prepare()` 落 200pt。**已改为显式兜底 + 日志（`85a9d4e`）**。
