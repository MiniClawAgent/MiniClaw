# P5 · S6 冻结状态机 —— 实现规格

> 来源：重构调研（2026-09-13）。基准文档：`../render-pipeline-refactor-2026-09-13.md`（§3 M1–M8 / §6 边界）。
> 行号为调研时盘上值。路径前缀：`V` = `MessageCollectionView.swift`，`S` = `+Scrolling.swift`，`N` = `+Snapshot.swift`，`B` = `+Bindings.swift`，`L` = `MessageListLayout.swift`，`I` = `MessageListInfrastructure.swift`，`MT` = `Render/MarkdownTextView.swift`，`MA` = `Render/MarkdownAttachments.swift`，`HS` = `Services/MiniClawHostStubs.swift`，`BR` = `Bridge/MiniClawChatBridge.swift`（除 `HS` 外均在 `Views/Chat/` 下）。

## 实施记录（2026-09-13 晚）

**已落地**：`327bd84`（冻结泄漏兜底）+ `867dc5c`（settle 拒绝在新手势中落地）。

实际采用的是**最小版**，与 §4「三轴 `FreezeState` + `transduce`」的完整重构不同：

1. 新增 `Coordinator.freezeStartedAt`（冻结起始时刻，仅供兜底判定）。开启时**仅在本就未冻结时写入**
   —— 否则上一轮泄漏会被本次手势"刷新"成新起点，再拖一整轮才被发现。
2. `settleAfterInteraction` 的早退分支不再裸 `return`：解冻两轴 + 清起点 + 告警。
   原先 `layout`/`cv` 缺失时直接跳过全部解冻，而解冻这两个动作本不依赖它们 —— 一个真实泄漏口。
3. 新增 `resetLeakedFreezeIfNeeded(_:)`：
   - 合法窗口判据 = `!isTracking && !isDecelerating` **已持续 > 0.35s**；宽限期用于避开
     「减速已结束、异步 settle 尚未执行」的正常窗口（`didEndDecelerating` 里是
     `DispatchQueue.main.async { settle }`，正常只差一次主队列跳转）；
   - 挂在 `updateUIViewController`（本类里唯一"不依赖滚动回调、也会周期性跑"的钩子）；
   - ⚠️ **命中后不新增第二条关闭路径** —— 只是**重新触发 `settleAfterInteraction`**，
     故解冻依然顺带应用 `deferredHeights` 并把视口上方的高度变化 1:1 锚回 offset。
     若在此写一份"只把两个 bool 置 false"的简化解冻，会出现**收缩不被锚定** ⇒ 可见内容原地跳
     （M1/M3 反复修过的正是这件事）。
4. settle 入口最前面加 `!cv.isTracking` 守卫 —— 阻止异步 settle 在新手势中落地
   （否则会在拖动中途解冻 + 按旧基准抢 `contentOffset`）。拒绝是安全的：本次手势结束时会再调一次；
   万一都没来，第 3 条的宽限期兜底会补上。

**仍未做**：§4 的三轴状态机收敛（`FreezeState` + 单一 `transduce` + `withReflow`/`withSnapshotApply`
消灭 S10 的"无 defer"隐患），以及 §1.D 里 `pendingEntryPin` / `isAnimatingScrollToBottom` 的超时化。

---

## 0 结论速览

- **冻结语义实际分布在 2 个类、9 个布尔、1 个整数深度标志上**，不是一个、也不是三个。
- **M7 那三个"静默窗"确实是同一窗口**：`N:336/337/339` 三行连写、`N:352/353`（+`N:392/393` else）三行连清 ⇒ 可合并为**一个带深度的静默作用域**。
- **`deferSelfSizing` 与 `streamingUIUpdatesSuspended` 虽然同开同关**（`S:768/776` ↔ `1004/1036`），**但必须保持独立**（doc §6：几何 vs 数据）。合并的应是"触发点"，不是"语义"。
- **真正的隐患不是 `flushingNow`，而是 `deferSelfSizing` 与 `streamingUIUpdatesSuspended`**：这两位的**唯一关闭点都在 `settleAfterInteraction` 内、且在 `guard`（`S:1000-1001`）之后**；settle 不触发即永久冻结。
- `scheduledDeferredSnapshot`：**全库不存在**。实际的"延后快照"由 `pendingSnapshotFlag` + `suspendResumeSub` + `onStreamingUIUpdatesResumed` 三处共管。

## 1 全量布尔状态位清单

### A. 几何冻结组

| 状态位 | 声明 | 写入点 | 读取点 |
|---|---|---|---|
| `deferSelfSizing` | `L:87` | `true`: `S:768`（willBeginDragging）<br>`false`: `S:1004`（settle）<br>（**全库仅此 2 个赋值**） | `L:382`（shouldInvalidateLayout 主门）<br>`I:619`（PLAF `defer-cached` 短路）<br>`MT:1149`（先拒后测）<br>`MT:1212`（`isDeferred` 消费判定）<br>诊断 `S:808` |

配套数据：`deferredHeights`（声明 `L:315`，写 `L:394`，清 `L:370`，读 `L:317/325/330`）；`deferredHeightCount`（`L:317`）。

### B. 数据替换冻结组

| 状态位 | 声明 | 写入点 | 读取点 |
|---|---|---|---|
| `streamingUIUpdatesSuspended` | `HS:324`（`@Published`） | **唯一入口** `HS:361-366` `setStreamingUIUpdatesSuspended(_:)`；`true`: `S:776`；`false`: `S:1036`、`V:757` | `V:657`；`V:685/690/692`（`lastSuspendedValue` 边沿检测）；`V:1073`（updateUIVC backstop）；`B:31/32/34/51`；`BR:259/270` |
| `pendingSnapshotFlag` | `V:45` | `true`: `V:650`、`V:658`、`B:54`<br>`false`: `B:65`、`V:786` | `V:695`、`V:716`；`B:32/34/64`；`S:1038` |
| `isApplyingSnapshot` | `I:165` | `true`: `N:339`、`N:764`；`false`: `N:341`、`N:766` | `I:198`（`layoutSubviews` 直接 return）；`I:226`；`I:270` |

### C. offset 补偿静默组

| 状态位 | 声明 | 写入点 | 读取点 |
|---|---|---|---|
| `suppressContentOffsetAdjustment` | `L:89` | `true`: `N:336`、`S:1015`；`false`: `N:352`、`N:392`、`S:1017` | `L:496`（是否给 `ctx.contentOffsetAdjustment`）；`L:522`（触发 footer reflow） |
| `flushingNow` | `V:127` | `true`: `N:337`、`S:1007`；`false`: `N:353`、`N:393`、`S:1030` | `V:251`（contentSize KVO **整体早退**） |

配套数据：`pendingAboveShift`（声明 `L:24`，累加 `L:476`，消费 `L:27-31` / `L:44`）。

### D. 一次性事件 / 有界窗口

| 状态位 | 声明 | 开 | 关 | 读 |
|---|---|---|---|---|
| `settleJustFinished` | `V:78` | `S:1045` | `S:1046-1048`（`asyncAfter 0.5s`） | `V:299` |
| `isAnimatingScrollToBottom` | `V:128` | `S:274` | `S:981`（`scrollViewDidEndScrollingAnimation`） | `V:268`｜**无超时** |
| `clampAfterSessionLoad` | `V:163`（配 `clampDeadline V:164`） | `V:791` | `V:261`（KVO 内、deadline 到期）、`S:371`、`S:765` | `V:257`、`N:109/113`、`S:372/470` |
| `pendingEntryPin` | `V:112`（`Bool?`） | `S:257` | `S:260` | `S:259` |
| `pendingFooterReflow` | `L:536` | `L:524` | `L:527`（`async` 内） | `L:523` |
| `pendingDeferredRemeasure` | `MT:90` | `MT:102`、`MT:1234` | `MT:105`、`MT:1237` | `MT:101`、`MT:1233` |

### E. 其他（镜像 / 派生 / 有效位 / 重入）

| 状态位 | 声明 | 写 | 读 | 性质 |
|---|---|---|---|---|
| `isAutoScrollPinning` | `L:117` | `V:124`（`scrollMode.didSet`）、`N:258` | `L:505` | **`scrollMode` 的派生投影**（两处冗余写入） |
| `lastSuspendedValue` | `V:154` | `V:685`、`V:692` | `V:691` | 镜像 |
| `lastWasProcessing` | `V:136` | `N:273` | `N:270` | 镜像 |
| `offsetLocked` | `I:288` | `MT:254/256`、`MT:263/265`、`MA:1955/1957`、`MA:1963/1965` | `I:291` | 文本选中时拦 `setContentOffset`（>1pt 直接丢）。**无 defer** |
| `inStreamGrow` | `I:171` | `I:231` | `I:226` | 重入保护，**有 `defer`（`I:232`）—— 安全** |
| `streamingGrowAnimationEnabled` | ~~`I:168`~~ | **全库无写入点** | ~~`I:225`~~ | **恒真死开关，已删（`85a9d4e`）** |
| `hasActiveTextSelection` | `I:301` | `MT:181`、`MT:268` | `I:319`、`I:355` | 选择自动滚动闸门 |
| `engineTextValid` | `I:445` | `MT:1203`(true)、`I:478`(false) | `I:599` | `engineFloor` 时效位 |

## 2 语义归类与"重复表达"

| 类别 | 成员 | 判定依据 |
|---|---|---|
| **A 几何冻结** | `deferSelfSizing`（+`deferredHeights`） | 只影响高度/帧：`L:382-414` |
| **B 数据替换冻结** | `streamingUIUpdatesSuspended`、`pendingSnapshotFlag`、`isApplyingSnapshot` | 只影响"快照是否上屏" |
| **C offset 补偿静默** | `suppressContentOffsetAdjustment`、`flushingNow`（+`pendingAboveShift`） | 只影响"谁有权写 `contentOffset`" |
| **D 一次性事件** | 见 §1.D | 有明确"开→关"时点 |
| **E 其他** | 见 §1.E | 派生 / 镜像 / 有效位 / 重入 |

### 重复表达（必须收敛）

1. **M7 三元同窗**：`isApplyingSnapshot`(B) + `flushingNow`(C) + `suppressContentOffsetAdjustment`(C) 在 `N:336/337/339` **同一三行内同开**、`N:352/353`（+`N:392/393`）同清。三者是同一句"我在 apply 重排，谁都别动 offset"的三种写法。这是 M7 的直接来源。
2. **`flushingNow` vs `suppressContentOffsetAdjustment`**：C 组内两个消费者（`V:251` 的 KVO vs `L:496/522` 的布局补偿），语义同为"offset 静默"，只是**窗口宽度不同**（`1007→1030` 嵌套 `1015→1017`）。
3. **`streamingUIUpdatesSuspended` + `pendingSnapshotFlag`**：后者是前者的"待办位"，可合并为一个 enum 的 associated value。
4. **A 与 B 的触发点重复**：`S:768/776` 同开、`S:1004/1036` 同关 ⇒ 生命周期一致，但**语义正交**（doc §6 明令不可合并）。收敛的是"入口"，不是"变量"。
5. **`isAutoScrollPinning`**：`V:124` 与 `N:258` 两处都写 `scrollMode == .autoScrolling`，纯派生量。
6. **`lastSuspendedValue` / `lastWasProcessing`**：镜像变量，不是真相源。

## 3 现状状态迁移与"开而不关"路径

```
scrollViewWillBeginDragging
  S:764  scrollMode = .userBrowsing
  S:765  clampAfterSessionLoad = false
  S:768  deferSelfSizing = true               ← A 轴开
  S:775  clearPendingAboveShift()
  S:776  setStreamingUIUpdatesSuspended(true) ← B 轴开
                    │
   scrollViewDidEndDragging(!decelerate) S:792-794
         或 scrollViewDidEndDecelerating  S:824-826
                    ↓
        settleAfterInteraction  S:993
  S:995-998  atBottom → scrollMode = .autoScrolling
  S:1000-1001 guard let layout, let cv      ← ⚠️ 早退点，位于所有复位之前
  S:1004  deferSelfSizing = false           ← A 轴唯一关闭点
  S:1007  flushingNow = true
  S:1012  applyDeferredHeights() → aboveSum
  S:1013  offset += aboveSum
  S:1015  suppressContentOffsetAdjustment = true
  S:1016  invalidateLayout()
  S:1017  suppressContentOffsetAdjustment = false  ← 窄窗关闭
  S:1021  takePendingAboveShift() → settleAbove
  S:1023  offset = saved + aboveSum + settleAbove
  S:1030  flushingNow = false
  S:1036  setStreamingUIUpdatesSuspended(false)  ← B 轴唯一关闭点（+V:757 兜底）
  S:1045  settleJustFinished = true; 1046-1048 → false (0.5s)
```

### 已确认的"开而不关"路径

| # | 状态位 | 泄漏条件 | 后果 |
|---|---|---|---|
| **P1（最严重）** | `deferSelfSizing` | 关闭点 `S:1004` 在 `guard`（`S:1000-1001`）**之后**；settle 仅在 `S:792-794` / `S:824-826` 调用。手势被系统取消、`willDecelerate=true` 但 `didEndDecelerating` 未回调、页面转场/移除 ⇒ settle 不执行 | 几何永久冻结；`L:382` 永远拒绝收缩 ⇒ 拖动期空白不再自愈；`MT:1149` 永久"先拒不测" |
| **P2（有日志证据）** | `streamingUIUpdatesSuspended` | 同 P1 | 永久挂起 ⇒ `pendingSnapshotFlag` 永久 true ⇒ 新内容不上屏（`B:37` warning 是此路径的现场记录） |
| **P3** | `isAnimatingScrollToBottom` | 关闭点仅 `S:981`；动画被触屏打断 / CV 移除时不保证触发；**无超时、无 defer** | 永久 true ⇒ 贴底变慢/错位 |
| **P4** | `clampAfterSessionLoad` | 关闭点 `V:261` 需 `Date() >= clampDeadline` 且**必须有下一次 KVO** | 8s 内无尺寸变化则滞留（影响面小但语义脏） |
| **P5** | `pendingSnapshotFlag` | 三个置位点都依赖后续 flush 才清；`B:37` 明确记录"流式结束仍挂起 ⇒ 永久 pending" | 内容在 DB、UI 冻结 |
| **P6（S10 点名）** | `flushingNow` + `suppressContentOffsetAdjustment` | 当前窗口内无提前 return（`N:391-394` else 兜底），但**全部无 `defer`** | 结构脆弱，尚未泄漏 |
| **P7** | `pendingEntryPin` | 仅由 `transitionCoordinator` completion（`S:258-262`）清零 | 下一次入会话被覆盖，中风险 |

> **结构性结论**：A 轴与 B 轴的开启/关闭由"滚动回调"驱动，而不是由代码块边界驱动。这正是"没有 `defer`、可能永久滞留"的根因 —— 不是忘了写 `defer`，而是**关闭点与开启点不在同一函数栈上**，`defer` 语法本身无法覆盖。收敛方案必须给这两轴加"settle 之外的兜底复位"。

## 4 目标状态机

### 4.1 三条正交轴，一个值类型作为唯一事实源

```swift
struct FreezeState: Equatable {
    enum Geometry: Equatable { case live, frozen }                     // A 轴 ← deferSelfSizing
    enum Data: Equatable { case live, sessionLoading, scrollSuspended } // B 轴 ← streamingUIUpdatesSuspended
    enum ReflowReason { case snapshotApply, settleReflow }              // C 轴原因（断言/日志用）

    private(set) var geometry: Geometry = .live
    private(set) var data: Data = .live
    private(set) var pendingSnapshot: Bool = false
    private(set) var offsetSilence: Int = 0        // ← suppress + flushingNow（可重入深度）
    private(set) var applyDepth: Int = 0           // ← isApplyingSnapshot

    var isGeometryFrozen: Bool { geometry == .frozen }
    var isOffsetSilenced: Bool { offsetSilence > 0 }
    var isApplying: Bool { applyDepth > 0 }
    var mustDeferSnapshot: Bool { data != .live }
    var canLayoutSubviews: Bool { applyDepth == 0 }
    var canPinOffset: Bool { offsetSilence == 0 && applyDepth == 0 }
}
```

### 4.2 单一迁移入口（唯一写入者）

```swift
enum FreezeEvent {
    case dragBegan
    case interactionSettled(atBottom: Bool)
    case sessionLoadBegan
    case sessionLoadEnded
    case forceBottom
    case snapshotApplyBegan
    case snapshotApplyEnded
    case beginReflow(FreezeState.ReflowReason)
    case endReflow(FreezeState.ReflowReason)
    case resetTransientFreezes      // ← P1/P2 兜底复位
}

@MainActor func transduce(_ event: FreezeEvent) {
    state = reduce(state, event)   // 纯函数：所有合法/非法迁移在此一处判定
    syncLeafFlags()                // 唯一的"投影下发"点
}

/// 所有静默窗必须走这里 —— 用 defer 消灭 S10。
func withReflow<R>(_ reason: FreezeState.ReflowReason, _ body: () throws -> R) rethrows -> R {
    transduce(.beginReflow(reason))
    defer { transduce(.endReflow(reason)) }
    return try body()
}

/// apply 子窗口同理。
func withSnapshotApply<R>(_ body: () throws -> R) rethrows -> R {
    transduce(.snapshotApplyBegan)
    defer { transduce(.snapshotApplyEnded) }
    return try body()
}

/// 投影下发：叶子类（Layout / NoAnimationCollectionView / KVO）保持"哑"，只被写。
private func syncLeafFlags() {
    let layout = viewController?.messageListLayout
    layout?.deferSelfSizing = state.isGeometryFrozen
    layout?.suppressContentOffsetAdjustment = state.isOffsetSilenced
    layout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
    (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = state.isApplying
    flushingNow = state.isOffsetSilenced
}
```

> `deferSelfSizing` / `suppressContentOffsetAdjustment` / `isApplyingSnapshot` / `flushingNow` **不要删除** —— 它们是跨类读取接口。收敛点是**"只允许 `transduce` 写它们"**。强行把 bool 换成 enum 需改 `L:382/496/522`、`I:198/226/270`、`MT:1149/1212` 共 8 个读取点的类型，收益低于风险。

### 4.3 迁移表

| 事件 | geometry | data | pendingSnapshot | offsetSilence | applyDepth |
|---|---|---|---|---|---|
| `dragBegan` | `→ frozen` | `→ scrollSuspended` | 不变 | 不变 | 不变 |
| `interactionSettled` | `→ live` | `→ live` | 不变（flush 时消费） | `+1 → body → -1` | 不变 |
| `sessionLoadBegan` | 不变 | `→ sessionLoading` | `→ true` | 不变 | 不变 |
| `sessionLoadEnded` | 不变 | `→ live` | `→ false` | 不变 | 不变 |
| `forceBottom` | 不变 | `→ live` | 不变 | 不变 | 不变 |
| `snapshotApplyBegan/Ended` | 不变 | 不变 | 不变 | 不变 | `+1 / -1` |
| `beginReflow/endReflow` | 不变 | 不变 | 不变 | `+1 / -1` | 不变 |

**P1/P2 的兜底复位（新增，不改语义只补边界）**：`transduce(.resetTransientFreezes)` 无条件复位 A/B 轴，挂在三条**已存在**的生命周期钩子上：

1. `attach(to:vm:)`（`V:179`）——重绑视图时；
2. `rebindViewModelIfNeeded(_:)`（`V:615-638`）——换 vm 时（**最小方案：只加这一处**，在 `subscriptions.removeAll()`（`V:628`）之后）；
3. `updateUIViewController` 的 `!vm.isLoadingSession && !vm.streamingUIUpdatesSuspended` 分支（`V:1073`）——已有 backstop，把"复位 transient freeze"并入。

### 4.4 调用点改写对照

| 位置 | 现状 | 改为 |
|---|---|---|
| `S:764-776` | 5 行散写 | `transduce(.dragBegan)`（内部含 `clampAfterSessionLoad=false`、`deferSelfSizing=true`、`clearPendingAboveShift()`、`setStreamingUIUpdatesSuspended(true)`） |
| `S:1004` `S:1007` `S:1015-1017` `S:1030` `S:1036` | 5 处散写、2 个粒度 | `transduce(.interactionSettled(atBottom:))`，内部用 `withReflow(.settleReflow) { applyDeferredHeights + anchor + takePendingAboveShift }` 包住 `1012-1023` |
| `N:336/337/339` → `N:352/353` | 3 开 3 清跨 `apply` | `withSnapshotApply { dataSource.apply(...) }` + `withReflow(.snapshotApply) { cv.layoutIfNeeded() … }`；`N:391-394` else 兜底由 `defer` 自动覆盖 |
| `V:649-651` / `V:657-659` | 手写 `if … { pendingSnapshotFlag = true }` | `if state.mustDeferSnapshot { transduce(.markPendingSnapshot); return }` |
| `B:51-55` | 同上（bind4b） | 同上 |
| `B:63-70` `flushPendingSnapshotIfNeeded` | `guard pendingSnapshotFlag; pendingSnapshotFlag = false` | `guard consumePendingSnapshot() else { return }`（原子消费，防重入） |
| `V:786` `V:791` | 手写清 flag + 置 clamp | `transduce(.sessionLoadEnded)` / `transduce(.sessionLoadBegan)` |
| `V:757` | `setStreamingUIUpdatesSuspended(false)` | `transduce(.forceBottom)` |
| `N:258` `V:124` | 两处写 `isAutoScrollPinning` | 删除，统一由 `syncLeafFlags()` 从 `scrollMode` 推导 |
| M2 的 flush 入口（`V:234/492/661/697/718/1074`、`B:33/73`、`S:1040`） | 10 处各自调 `flushPendingSnapshotIfNeeded` | 保留 10 个触发点，但**全部只调一个 `flushPendingSnapshot(reason:)`**，内部 `guard consumePendingSnapshot()` 做**全局互斥**，消除 M2 的"双次 apply" |

### 4.5 明确保持独立的（正交轴）

| 保持独立 | 理由 |
|---|---|
| `deferSelfSizing`（几何） vs `streamingUIUpdatesSuspended`（数据） | doc §6 明令。合并会破坏 M1 的"手势期禁收缩"与 M2 的"挂起不 apply"的独立开关能力 |
| `isApplyingSnapshot`（拦 `layoutSubviews`） vs `offsetSilence`（拦 offset 写） | 作用对象不同（布局循环 vs offset 赋值） |
| `offsetLocked` / `hasActiveTextSelection` | 属文本选择子系统 |
| `inStreamGrow` | 纯重入保护，已有 `defer` |
| `pendingAboveShift`（累积量） vs `offsetSilence`（权限位） | M3/M8 要求的是**数值语义**不是权限语义 |
| D 组一次性事件 | 改造成"带 deadline 的一次性事件"（`isAnimatingScrollToBottom` 必须补超时 / 在 `scrollViewWillBeginDragging` 兜底复位），但不并入状态机 |

## 5 必须保留的既有行为（对应 M1–M8）

| # | 症状 | 不可动的判据（行号） |
|---|---|---|
| **M1** | 拖动期空白（Σ928.6pt / 38 格位 / 单条 −164pt） | `L:382-414` 手势期"已有条目一律拒绝收缩"（判据与来源无关，`L:390`）；`L:394` 差值进 `deferredHeights`；`L:340-341` 解冻时"有差异即应用"；`S:1012-1013` 原子应用 + 1:1 锚回 |
| **M2** | 双次 apply / 块消失、先出后跳 | `B:63-68` flush 前置 `guard pendingSnapshotFlag` + 立即清零；`V:657-659`、`B:51-55` 挂起期只置 pending 不 apply |
| **M3** | 停手整屏跳（`−76.7→960.3`） | `L:24-31` `pendingAboveShift` 累积 + `takePendingAboveShift`；`S:1021-1024` 与 `aboveSum` 相加锚回；`S:775` 拖动开始清零 |
| **M4** | 流式文本块消失 / 末句被裁 | `L:390` `currentEntry(at:) != nil` 才算已缓存；`I:598-601` `engineFloor`；`I:619/633-648` defer-cached / precalc 短路 |
| **M5** | 裁尾 / 高度偏矮 / 中间大块空白 | `I:629`、`I:645` 均取 `max(cached/precalc, engineFloor)`；`engineFloor` **禁含 cell 当前高**（`MT:1192`） |
| **M6** | 正文钉旧版本 | `L:73-77` `currentEntry` 内容版本感知；`MT:1165-1171` `ContentFingerprint` 相等性判据 |
| **M7** | 偶发贴底错位 / 键盘抬高偏差 34pt | `V:251` KVO 在 `flushingNow` 期整体早退；`L:496` 在 `suppress` 期不给 `contentOffsetAdjustment`；`V:1045-1054` 键盘 `baseBottomInset 103→69` 必须重新贴底 |
| **M8** | 顶部极细抖动（四修试错链） | `L:474-477` `pendingAboveShift` 只在 `cv.contentOffset.y > 0.5` 且（`above` 或 `inside 且非流式`）时累加 |

另三条与冻结相关的护栏：`setEntry` 单一写入口 + 有限非负（`L:128-140`）、`applyDeferredHeights` 有差异即应用（`L:340`）、`contentOffsetAdjustment` 只能非手势期补（`L:496` 的 `!cv.isTracking,!cv.isDecelerating`）。

## 6 未确认 / 需人工确认

1. `scheduledDeferredSnapshot`：**全库 grep 无此标识符**。若历史文档提及，应为已改名或从未落地。
2. `streamingGrowAnimationEnabled`（`I:168`）：全库仅声明 + `I:225` 读取，**无任何写入点** ⇒ 恒真死开关。**已删除并内联（`85a9d4e`）**。
3. `MT:1264` 附近的 `pendingDeferredRemeasure` 复位依赖 0.6s `asyncAfter`，若 cell 在此期间被复用，旧 cell 的定时器仍会触发（弱引用保护，但语义上可能重测错内容）—— **未确认**。
4. `deferSelfSizing` 是否有 List 目录之外的写入：已 grep 全 `MiniClaw/`，仅 `S:768`/`S:1004` 两处赋值，确认无外部写入。

## 一句话规格

把 `deferSelfSizing`（几何）、`streamingUIUpdatesSuspended`+`pendingSnapshotFlag`（数据）、`suppressContentOffsetAdjustment`+`flushingNow`（offset 静默）三组折叠进 `Coordinator.FreezeState` 的**三条正交轴**，用单一 `transduce(_:)` 做唯一写入者、`withReflow`/`withSnapshotApply` 用 `defer` 保证复位（消灭 S10），并用已在代码里的 `rebindViewModelIfNeeded` / `attach` / `updateUIViewController`-backstop 三处给 A/B 轴补上**兜底复位**（消灭 P1/P2 的"开而不关"）；`isApplyingSnapshot` 与 `offsetLocked` 保持独立 scope，D 组一次性事件改造成带 deadline 的事件而非状态。
