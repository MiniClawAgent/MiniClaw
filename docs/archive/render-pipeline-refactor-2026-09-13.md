# 会话绘制链路 · 逻辑重排重构结论与计划

- **日期**：2026-09-13
- **范围**：`MiniClaw/MiniClaw/Views/Chat/{List,Render,Bridge}` = **17,127 行 / 24 文件**
- **依据**：5 个子代理只读排查报告（守卫清点 / 高度全景 / 数据流时序 / 渲染缓存 / 事故账本）+ 本人真机实测数据
- **要求**：**同样的逻辑**（行为等价），做到可维护性最高；不改语义、只重排结构与判据

---

## 0 结构性病根（一句话）

> **同一语义事实被表示在 4–15 个地方，且「谁先写、谁后写」由注释而非结构保证。**

于是每次修 bug 都要在 6 张高度表之间手工推理，新守卫极易与旧守卫条件相反；**38 个条件门**里已确认 **8 组互斗**。这不是"守卫太多"，而是**缺少单一事实源与单一顺序入口**。

### 量化证据（均来自真机日志/代码实测）

| 症状 | 数字 | 出处 |
|---|---|---|
| 高度真相来源 | **6 张表**：`heightEntries`(index) / `lastHeightByKey`(内容键，**全库无写入点**) / `_sharedMeasuredHeights` / `deferredHeights` / `_userBubbleMemo` / `MarkdownRenderCache.heights` | 高度全景 |
| 缓存层级 | **15 处**（含 `rendererCache` 按 messageId 无淘汰、`TableAttachment.sharedLayoutCache` cap 256） | 渲染缓存 |
| 同一块的宽度口径 | **4 种**：`lastCalcW`(边界宽) / `cv.bounds.width` / `cvW−32` / `usableTextWidth` | 高度全景 |
| 内容指纹口径 | **2 种**：字符数 vs 全量哈希 ⇒ **等长改写被判「未变」** | 高度全景 |
| 同义判据多版本 | 「终态」写 **3 遍** · 「含附件」**3 版** · 「CT+inset」**5 处**（其一用 `+12`，同语义差 4pt） · `isStreaming` 定义后又内联重写 | 渲染缓存 |
| 同义逻辑多入口 | 「补播」**5 个** + 重播种 2 个 · 「失效」**6 种口径** · 「未知高度」**7 个常量** | 守卫清点 |
| 顺序敏感点 | **15 个**（S1–S15），全靠注释维护 | 数据流时序 |

### 三个"仪表盘级"缺陷（这才是排查慢的直接原因）

1. **70 处内联 `AppLogger(category:).xxx(...)`** ⇒ 实例级攒批、只塞 1 条即释放 ⇒ **整行日志永久丢失**。同一条路径上"改过的行"和"没改的行"混排 ⇒ 日志时有时无 ⇒ 多次得出错误否定结论。**✅ P0 已修**
2. **热路径探针无差别打印**：`traceSet`/`tracePLAF` 每次 cell 配置/测量各一行，实测 **12 分钟 15k 行**，把真异常（`UNDER-HEIGHT`/`HOST-FLOOR`/`SEED-FLOOR`）淹没。**✅ P0 已修**
3. **`lastHeightByKey` 无写入点**（声明/读取/清空都在，**没有任何赋值**）⇒ 注释承诺的"按键兜底"恒不执行，`prepare()` 实际只有 条目→memo→类型常量 三级。**待 P3 处理**

> 附：`#if DEBUG` 在 Debug 下**确已定义**（`( DEBUG, ISH_ENABLED )`，Release 仅 `ISH_ENABLED`），故 41 处 DEBUG 块**是编译的**。工程已有一条**可用**的规范诊断通道：`ScrollMetricsRecorder`（定长环、不走日志 I/O、`logs/.scroll-metrics-on` 哨兵开关）。

---

## 1 目标结构（6 项收敛）

| # | 收敛 | 消灭什么 | 主要落点 |
|---|---|---|---|
| **S1** | `HeightEntry` 带**内容版本键**；取高时键不一致即**视为无条目** | 陈旧 `.measured`（I11）/陈旧 `.precalc`/`contentKeyByIndex` 哑指纹；顺带治「上滑回看裁尾」 | `MessageListLayout` ✅ **已完成** |
| **S2** | 内容指纹统一为**一处确定性指纹**（长度+全量哈希），渲染/缓存/尺寸/块缓存四处共用 | 等长改写被判"未变"（`flapping`/`liveShrink` 族） | `RenderModels` / `MarkdownView` / `MarkdownTextView` / `AssistantBlockView` |

### 1.1 S2 的执行纪律：**先判类型，不要机械替换**（本轮实测得出）

收敛"长度指纹"时，必须先判该判据属于哪一类 —— 三类里只有第一类该换：

| 类型 | 例子 | 处置 |
|---|---|---|
| **① 相等性**（"内容是否变了"） | `cachedAttrContentCount` / `cachedSizeMarkdownCount` / `lastSizedStorageLen` | → 换 `ContentFingerprint.of(_:)` |
| **② 序关系**（`<` / `>`，"谁更短/更旧"） | `lastStreamPendingSourceLen < markdown.count`（快照落后判定） | → **保持长度比较不动**（换指纹会直接破坏语义） |
| **③ 长度代理**（"两处文本是否等量"，不是"内容是否相同"） | `bindingLen == storageLen`（存储一致性检查） | → **保持长度**；若同一变量兼任①②③中的两类，**必须拆成两个变量** |

**已实测的两个坑**：① 差点把"序关系"一起换（清点站点时才发现语义不同）；② `bindingLen` **一变量两语义**（代际键 + 长度代理），必须拆开而非整体替换 —— 这正是本轮"语义落点统一"要消掉的典型坏味道。
| **S3** | 「含附件」判据统一为**结构判据** | `MCH:286` 的 `+12`、`MCS:630` 走 CT 回写高度两个不一致落点 | `RenderModels` / `MCH` / `MCS` |
| **S4** | 「补播/重映射/失效」收敛为**单一顺序入口**（把 S1–S15 写进结构） | 15 个顺序敏感点靠注释维护 | `+Snapshot` / `MessageListLayout` |
| **S5** | 流式 block 集合构建收敛为**一个纯函数** | 两套构建不等价（尾部 order `Int.max-1` vs `maxEventOrder+0.5`；`.file` 拆分只在终态）；thinking 幂等两套（前缀匹配 vs `seg.id`，**同前缀命错段**） | `MiniClawChatBridge` / `MiniClawChatAdapter` |
| **S6** | 三组冻结布尔量合并为**显式状态机** | 8 组互斗矩阵；三标志无 `defer` ⇒ 提前 return 会永久滞留（I7） | `+Scrolling` / `+Snapshot` / `MessageCollectionView` / `MessageListInfrastructure` |

---

## 2 顺序敏感点（重排时的**不可动清单**）

| # | 约束 | 换错会怎样 |
|---|---|---|
| S1 | 补播必须在 `dataSource.apply` **之前** | `prepare()` 读不到条目 → 落 200 兜底 → 手势期拒绝收缩 → **拖动期大片空白** |
| S2 | `reseedTextBlock(before:)` 同 S1 | 同上 |
| S3 | `reseedTrailingTextBlock` 必须在 `itemIdentifiers` 早退**之前** | 终态那次身份集合不变 ⇒ 最终回复少字/少行不修 |
| S4 | `remapHeights` 必须在"缺失全扫补播"**之前** | 把新播条目换成错位旧条目 / 部分 index 回落兜底 |
| S5 | `updateCacheForSnapshot` 在 `remapHeights` 之前 | 中间窗口 contentKey 口径滞后 |
| S6 | Bridge 流式合并必须在**指纹/节流 return 之前** | 合并永不执行 ⇒ **无流式输出** |
| S7 | Bridge 挂起门必须在"推进指纹/赋值 messages"之前 | 被跳过的内容永不补回 |
| S8 | `isProcessing/canResume` 镜像必须在节流判定之前 | 思考块 `isStreaming` 永为 true ⇒ 自动折叠永不触发 |
| S9 | `commitReasoningBuffer` 必须在 `commitStreamBuffer` 之前 | 轮次边界锚点偏早 ⇒ 思考块插进上一轮回复中间并随落盘固化 |
| S10 | `suppressContentOffsetAdjustment`/`flushingNow` 必须包住 apply→layoutIfNeeded 且之后复位 | **无 `defer`**，任一路径提前 return ⇒ 永久滞留 |
| S11 | offset 锚定必须在 `takePendingAboveShift` 之后 | `aboveSum` 与 `settleAbove` 未相加 ⇒ 停手整屏跳 |
| S12 | `clearPendingAboveShift` 必须在拖动开始 | 跨交互累积 ⇒ 停手整屏跳（实测 `pendingΣ=+1037`） |
| S13 | Bridge attach 必须先清 `bridgeCache`+`lastFingerprint` 再 force refresh | 复用流式中途乱序 blocks |
| S14 | settle 内 `deferSelfSizing=false` 与 `applyDeferredHeights` 的先后 | 唯一消费点；此后新写入的延后项要等下一次 settle |
| S15 | `.measured` 条目必须随内容变化被显式失效（**当前无任何路径**） | 旧实测值永久滞留 ⇒ 拖动期被冻结成空白（S1 已补上该路径） |

---

## 3 互斗矩阵（8 组）

| # | 冲突 | 症状 |
|---|---|---|
| M1 | `deferSelfSizing`「手势期不改几何」 vs 补播「必须重排」 | 拖动期空白（实测 Σ928.6pt / 38 格位 / 单条 −164pt），settle 才落盘 |
| M2 | `streamingUIUpdatesSuspended` 的 **6 个**独立 flush 入口互不排斥 | 双次 apply / 第二次 apply 时 ranges 与 heights 已变 ⇒ 块消失、先出后跳 |
| M3 | `pendingAboveShift` 与 `applyDeferredHeights.aboveSum` 两套锚定并存 | 停手整屏跳（`offset −76.7→960.3`） |
| M4 | `hasMeasuredHeight` 早退 vs 流式重播种 vs `streamingCellRanges` 陈旧 | 流式文本块消失 / 末句被裁，下一轮才自愈 |
| M5 | `engineFloor`（最新覆盖） vs `lastCalcH` keep-shorter vs `defer-cached` max | 裁尾 / 高度偏矮 / 消息中间大块空白（1365→1455 类） |
| M6 | prebuilt 采用 vs 内容"变了"的两套判据 | 正文钉旧版本，重进会话才恢复 |
| M7 | `isApplyingSnapshot` / `flushingNow` / `suppressContentOffsetAdjustment` 三"静默窗"语义重叠 | 偶发贴底错位 / 键盘抬高偏差 34pt |
| M8 | `pendingAboveShift` 的 `offset>0.5` 前置 vs 布局补偿条件 | 顶部极细抖动（四修试错链） |

---

## 4 守卫 ↔ 历史事故等价表（**重构必须保留**，27 项）

> 逐条对应见子代理归档；此处列关键 12 条。**重排后这张表必须仍然成立。**

| 守卫 | 保护的 bug | 等价保留要点 |
|---|---|---|
| `setEntry` 单一写入口 + 有限非负 | 2026-09-09 NaN/`−40` 负高度崩溃 | 禁旁路直接赋字典 |
| 手势期「已有条目」禁收缩 | C `liveShrink −160.3/−164.0 ×19` | 判据与条目来源无关；解冻后原子应用 |
| `applyDeferredHeights` 有差异即应用 | 「延后即丢弃」 | 不能退回"仅 nil 才应用" |
| aboveSum 返回 + settle 锚回 | C `aboveΣ=−648.6` 整屏平移 | 视口上方高度变化必须 1:1 锚回 |
| `pendingAboveShift` + `offset>0.5` 前置 | 顶部极细抖动（四修） | 只补 above + 视口内非流式双向；`offset==0` 不锚 |
| 拖拽开始清零累积 | `pendingΣ=+1037` 整屏跳 | 累积语义 =「本次手势内」 |
| 类型化兜底 + 内容键解析 | G 行间/工具卡空白 | 前缀与量级、`w:` 附件数末段不可单边改 |
| `engineFloor` | A/I/J 裁尾、流式末句截 | 下限 = 视图自测 + 固定装饰；**禁含 cell 当前高** |
| `storeHeightIfAbsent` | I 预热异源覆盖 1712→1699 | 预热只能补缺失 |
| `contentWidth` 透传 | A 理想 pass 按屏幕宽 | 测量宽 = 渲染宽 = cell 宽 − 32，单一 `blockHPadding` |
| prebuilt 内容指纹 | A 截短锁死 | 指纹 = 渲染输入身份；不匹配即弃用并覆盖追赶 |
| 按 id 幂等（禁按内容去重） | E 中间块消失（+8 位移） | 身份判定只能用 `block.id` |

> 另有「已回退 / 禁止再加回」**11 项**（含 09-13 `!deferSelfSizing` 门控收窄、`FIRST-MEASURE purgeIndexEntry` 死循环、`engineMinHeight` 大块空白、F3(b) 三步、后台渲染、给 `hasRichSyntax` 加 `$` 等），详见事故账本归档。

---

## 5 分阶段计划与进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0** | **仪表盘恢复**：68 处内联 logger → `AppLogger.shared`；热路径探针挂哨兵开关 | ✅ **完成**（`049c816` / `97b21f9`） |
| **P1** | **S1 第一刀**：`HeightEntry` + 内容版本键 + `currentEntry` 版本感知（`prepare`/defer 门/三个访问器全改走它） | ✅ **完成**（`049c816` 含） |
| **P2** | **S2 指纹统一**：建立 `ContentFingerprint.of(_:)` 唯一入口，收敛三处**相等性**判据（详见 §1.1）——✅ 屏上引擎去重指纹（6 处）· ✅ `sizeThatFits` 桶指纹（并拆开「一变量两语义」的 `bindingLen`）· ✅ 块级渲染指纹（跨 3 文件的回调链） | ✅ **完成**（`cefe165`/`c422c33`） |
| **P3-α** | **出入口统一**（P3 的前置）：播种 / 失效 / 重映射各收敛为**唯一入口** | ✅ **完成**（`f73a679` 失效两入口合一 · `373cd2f` 预取第 4 条播种旁路并入 `seedHeights(.indices:)` · `85a9d4e` 静默降级改显式兜底 · 宽度失效改为语义专用入口 `purgeIndexHeightsForWidthChange()`，见 §7.3） |
| **P3** | **S4 顺序管线显式化**：把"补播/重映射/失效"收敛为单一入口，S1–S15 由注释变结构断言 | 🔄 **部分完成**：✅ 段化「段 0 身份迁移 → 段 1 播种」（`e9caf03`，修 R1 键错配）· ✅ `seedHeight` 两处静默降级改显式兜底（`85a9d4e`）· ✅ **`setEntry` 优先级闸门改按 `currentEntry` 判**（`e8b2972`，S15 真正闭环）· ⬜ 剩余为纯维护性分段（见 §7.4） |
| **P4** | **S5 流式 block 集合构建收敛为一个纯函数**（保留孤儿清理 + `.file` 拆分，尾部 order 参数化） | 🔄 **缺陷已修**：✅ 两套尾部 order 收敛为同一规则（`b85f03a`）· ✅ 排序补 `id` 次键与渲染层对齐（`4f21976`）· ✅ 子序步长 `0.05 → 0.005`（`58c14f7`，消除"≥5 个文件引用即与事件 order 撞档"）· ⬜ 纯函数收敛（维护性，见 §7.4） |
| **P5** | **S6 冻结状态机**：三组布尔量合并，消除 M1–M8 | 🔄 **缺陷已修**：✅ 冻结泄漏兜底（`327bd84`）· ✅ settle 拒绝在新手势中落地（`867dc5c`）· ✅ 兜底补**时间驱动**第二触发点，不再只靠 `updateUIViewController`（`e8b2972`）· ⬜ 三轴 `FreezeState` 收敛（维护性，见 §7.4） |
| **P6** | **S3 附件判据统一到结构判据**（含 `+12` 与 `MCS:630` 口径） | 🔄 **部分完成**：✅ 估高同源两笔（`d723027` assistant 文本宽 `−32`、`839b9c7` 附件瓦片区改用渲染真构成）· ✅ 富语法判据收口为唯一入口 `hasRichSyntaxOrAttachment`（`27a3820`）· ✅ 用户气泡补外层 6pt 间距（`58c14f7`）· ⬜ `inputAttachments` 存废裁决（见 §7.4） |

### 阶段纪律（不变）
1. **行为等价**：每步只做"搬位置 / 合并判据 / 改接口"，不改语义；
2. **可回退**：每阶段一个 commit 边界（基线与检查点见 §5 表）；
3. **验证**：增量编译自验；需要真机时用 `logs/.scroll-metrics-on` 哨兵取全量明细；
4. **同文件多处 Edit 必须串行**（两个子代理独立实测：单条消息内并行 Edit 会**静默丢改动而工具仍报 success**），改完以 Read/Grep 逐处复核盘上内容。

---

## 6 风险与边界（重排时不动）

- **`engineFloor` 不得含"cell 当前高"**（含则 1365→1455 跑飞）；
- **`contentOffsetAdjustment` 只能非手势期补**（否则回归历史抖动）；
- **`deferSelfSizing` 与 `streamingUIUpdatesSuspended` 不可合并**（正交轴：几何 vs 数据）；
- **不放宽手势期禁收缩门来消空白**（那会把 −160pt 抖动放回来）；
- 不可合并：`MarkdownRenderCache`（进程级/全哈希/宽桶，三路互认）、`_userBubbleMemo`（键不同源）、cell 实例级 `lastCalcH/seedH/engineText*`、`rendererCache`（持附件、须与消息同源）；
- 两棵源码树都要 grep；`第三方源码/`、`Kit/` 只读；`项目不可跑 xcodegen`（pbxproj 与 project.yml 已漂移，重生成会产出编不过的工程）。

---

## 7 P3–P6 实现规格（分册）与 `applySnapshot` 段图

> 四份实现规格已归档为**分册**（含逐条 `文件:行号` 证据与「不能改的行为」清单）：
> `docs/refactor-specs/` 下 `P3-order-pipeline.md`、`P4-block-builder.md`、`P5-freeze-state-machine.md`、`P6-attachment-criteria.md`。实施某阶段前先读对应分册。

### 7.1 `applySnapshot` 现行段结构（P3 第一步已落地）

| 段 | 内容 | 为什么必须在此 |
|---|---|---|
| 前置 | 过滤 `isInternalBridge`；`lastJumpedUserId = nil`；懒装 2 个通知订阅；重建 `messageIndex`；建 `newRows` | `seedHeight` 依赖 `messageIndex`；`newRows` 是后续一切的基础 |
| **段 0** | **身份迁移**：`identityUnchanged` / `oldRows` / `inserted` 一次算好 → `remapHeights`（未变则跳过） | **必须早于任何播种** —— 播种会按新索引重写 `contentKeyByIndex`，迁移在后就读不到旧键 ⇒ 迁移失效（见 §7.2） |
| **段 1** | **播种**：`seedHeights(.all)` | 必须早于 `dataSource.apply`（S1）；身份不变时也要刷新估高 |
| 状态提交 | `itemToIndex`；`streamingCellRanges`；`isAutoScrollPinning`；`oldCount`；`snapshotMessages` | `streamingCellRanges` 必须早于 apply（`prepare()` 读它）；`oldCount` 必须早于 `prevSnapshotIds` 覆写 |
| 终态节律 | 整轮结束 → `reseedTrailingTextBlock`（S3） | 终态那次身份集合通常不变，放到早退之后就不执行 |
| 早退 | `if identityUnchanged { return }` | 上面各段是「身份不变也要跑」的语义 |
| **段 2** | **失效/补播**：`reseedTextBlock(before:)`（S2）→ `seedHeights(.inserted)` → `seedHeights(.missing)` | S1/S2/S4：全部必须早于 `apply`（否则 `prepare()` 落 200pt 兜底 ⇒ 空白） |
| **段 3** | **apply**：置 `suppressContentOffsetAdjustment` / `flushingNow` / `isApplyingSnapshot` → `dataSource.apply` → `layoutIfNeeded` → 复位 | S10：静默窗必须包住 apply→`layoutIfNeeded` |
| **段 4** | **reconcile**：收缩 clamp / 贴底 / `applySubViewportCompensation` / `syncScrollFlags` / 条件 `scheduleHeightPrewarm` | 依赖段 3 之后稳定的 `contentSize` |

### 7.2 P3 第一步修掉的 R1（键错配）

`seedHeights(.all)` 与 `remapHeights` **都写 `contentKeyByIndex`**，而原顺序是「先播种、后迁移」：

1. `.all` 播种按**新索引**重写整表内容键（`seedHeight` 内 `setContentKey`）；
2. `remapHeights` 用 `contentKeyByIndex[oldIndex]` 写 `newIndex` —— 读到的是「新索引体系下**旧下标**那个 item 的键」。

⇒ 被搬移的 `HeightEntry` 自带键与 `contentKeyByIndex[newIndex]` 错配 ⇒ `currentEntry` 判 `stored != cur` ⇒ 刚迁移来的 `.measured` **整体降级为陈旧** ⇒ 迁移等于白做；`footerHugByIndex` 同样搬错。
⇒ **只在发生索引位移时暴露**，而「在末尾追加」（恒等映射）长期掩盖它 —— 这正是「插入 / 压缩 / 重排」场景更难复现的结构性原因。已改为「段 0 迁移 → 段 1 播种」（`e9caf03`）。

### 7.3 同类已修（本轮）

- **播种第 4 条旁路**：`prefetchItemsAt` 原把 `maxContentWidth` 当测量宽 —— 而它的唯一构造点是 `ChatView` 传入的 `0`，语义为「不设内容宽上限」的**哨兵**（`BridgedCellViews` 已写明）⇒ 预取按 0 宽估高（文本可用宽被兜到 100pt）⇒ 系统性虚高 ⇒ S1 所说「虚高帧 ⇒ 手势期收缩被拒」的原料；且直写 `.estimated` 不写内容键。已并入 `seedHeights(.indices:)`（`373cd2f`）。
- **失效第 5 条旁路**：`scheduleWidthPurge` 原直写 `heightEntries.removeAll()`，留孤儿键且不清宽度相关的 `_userBubbleMemo`。已并入 `clearHeightCache(keepingSharedMemo: true)`（`85a9d4e`）。
- **静默降级**：`seedHeight` 的 `.assistantBlock` 原有两处静默 `return`（查不到消息 / 查不到块 ⇒ 该 index 无条目 ⇒ `prepare()` 落 200pt）⇒ 改为显式兜底 + 日志（`85a9d4e`）。
- **注释卫生**：跨文件/跨段引用一律改**符号名**，废弃行号引用 —— 行号本身就是反复过期的根因。
- **冻结泄漏（P5 第一/二刀）**：`deferSelfSizing` / `streamingUIUpdatesSuspended` 的开启点（`scrollViewWillBeginDragging`）与关闭点（`settleAfterInteraction`）**不在同一函数栈上**，`defer` 覆盖不到；且 settle 的早退分支原先裸 `return`，会跳过全部解冻。已补：`freezeStartedAt`、settle 早退分支强制解冻、`resetLeakedFreezeIfNeeded`（**重新触发唯一关闭点 settle，不新增第二条关闭路径**）、settle 入口 `!isTracking` 守卫（`327bd84`/`867dc5c`）。**仍未做**：三轴 `FreezeState` 收敛。
- **★估高同源（已修，两笔）**：同一病根的**两处**表现，均已修复。
  ① `estimateTextBlockHeight` 的可用宽原为 `hPad = 80`，而渲染真相是「cell 宽 − 2×`blockHPadding`(=16) = **cell 宽 − 32**」（`BridgedCellViews:12` 的**同一个** `blockHPadding`）⇒ 窄 48pt ⇒ 每行少算约 15% 字数 ⇒ 行数多算 ⇒ **高度系统性偏高**。已对齐为 `-32`（`d723027`）。
  ② 附件瓦片区把媒体与文档**一并**按「每行 70pt 网格」估，而渲染是「媒体 4×64 网格 + 文档每条 40pt + 段间 6pt」⇒ 估 76 / 实 64（1 张图，**+12pt**）、估 76 / 实 40（1 个文档，**+36pt**）。已收敛为唯一入口 `attachmentStripHeight(_:)` 与渲染同源（`839b9c7`）；并顺带修掉一处**因该改动才暴露**的 memo 键缺失 —— 键原只含附件**数量**，而新高度依赖**媒体/文档构成**，同数量不同类型会撞键算错高。
  **★原理（值得记住）**：手势期策略是「**只拒绝收缩**、增长放行」⇒ **凡系统性高估都会变成拖动期可见空白、松手才消失**；低估只会在首次实测时增长（放行、无空白）。故一切"预测量"的取向都应取「**宁短勿长**」。

### 7.3.1 独立复验发现并已修的 5 处（两轮复验、按文件切分、互不重叠）

> 复验的价值在于：以下 5 处**编译都是绿的**，只有读代码才看得出来。其中第 1 处是**我自己引入的回归**。

| # | 问题 | 方向 | 修法 |
|---|---|---|---|
| 1 | 宽度变更（旋转/分屏）改走 `clearHeightCache(keepingSharedMemo:true)` —— 该入口是给「会话切换/字体变更」的，会**连内容键与 hug 表一起清**；而宽度变更**不改内容身份**，清完**没有重播种路径**（旋转不触发 `applySnapshot`）⇒ 离屏 item 连「按内容键前缀选类型常量」的兜底都拿不到 ⇒ **全部落默认 200pt** | 高估（→空白） | 新增语义专用入口 `purgeIndexHeightsForWidthChange()`（`e8b2972`） |
| 2 | `setEntry` 的优先级闸门比的是**裸条目**：内容已变的陈旧 `.measured` 在 `currentEntry` 眼里已不是条目、`hasMeasuredHeight` 为 false、播种照常算新值 —— 但闸门仍按 rank 3 比较 ⇒ **新值被静默拒绝**，陈旧高度永久压住新内容，`.missing` 每轮重试每轮失败 | 陈旧值滞留 | 闸门改按 `currentEntry` 判（`e8b2972`，**S15 真正闭环**） |
| 3 | 冻结兜底只挂在 `updateUIViewController`（事件驱动），而它恰在「流式挂起 ⇒ 无 `@Published` 变化 ⇒ body 不重算」时不跑 —— 正是泄漏的定义场景 | 兜底失效 | 补时间驱动第二触发点 `scheduleFreezeWatchdog()`（`e8b2972`） |
| 4 | 用户气泡漏算附件区与气泡之间的 **6pt 外层间距**（渲染侧两者是同一个 `VStack(spacing:6)` 的两个 child） | 低估（→跳变） | 三条返回路径统一补 `(attachH>0 ? attachH+6 : 0)`（`58c14f7`） |
| 5 | `splitFileBlocks` 子序步长 `0.05` **无上界**：≥5 个文件引用即 `baseOrder+10*0.05 == eventOrder` ⇒ 文件块与事件块 order 撞档。此前靠"排序不稳定"随机决定（本身是 bug），**补了 `id` 次键后会被固化成"确定但可能错"** | 块序错 | 步长拆为命名常量 `0.005`（`58c14f7`） |

> 教训：**"补确定性"之前必须先确认那个不确定分支的正确答案** —— 否则只是把随机错变成稳定错。

### 7.4 剩余项（三类：维护性 / 待裁决 / 已知残留）

**A. 维护性重构（无用户可见影响，**未做**；建议真机验证通过后再动，以免污染验证基线）**

- **P3 剩余**：把 `applySnapshot` 的 9 个段（前置 / 段 0 / 段 1 / 状态提交 / 终态节律 / 早退 / 段 2 / 段 3 / 段 4）提取为**具名分段函数** + 一个 `SnapshotPlan` 值类型，使 S1–S15 从注释变成结构断言。当前顺序已**全部显式化**并逐段注明"为什么必须在此"（§7.1），故此刻动它的风险收益比不划算。
- **P4 剩余**：把 4 条 block 构建路径（终态重建 / 流式增量 / 终态就地合并 / 子代理平行语义）收敛为**一个纯函数** `buildBlocks(...)`（分册已给签名与"差异 → 参数"映射表）。**缺陷已全部修完**（尾部 order、排序次键、子序步长），剩的纯是去重。
- **P5 剩余**：三轴收敛为 `Coordinator.FreezeState` + 单一 `transduce(_:)` + `withReflow` / `withSnapshotApply`（用 `defer` 消灭 S10 的"无 defer"结构脆弱）。注意 `deferSelfSizing`（几何）与 `streamingUIUpdatesSuspended`（数据）**保持正交、不合并**。附带：`pendingEntryPin` / `isAnimatingScrollToBottom` 应改造成"带 deadline 的一次性事件"（后者的关闭点唯一且**无超时**）。

**B. 待裁决（是决策问题，不是技术问题）**

- **`inputAttachments` 存废**：全库有声明 / 读取 / 回退，**无任何赋值点**，且 `QueuedAttachmentPreview.body == EmptyView()`（空桩）。判断它**不是疏漏**，而是「排队中消息的附件预览」这一**未接线的功能预留位** —— 故**没有按"死代码"删除**。两选一：(a) 现在删，将来随功能重建（3 行字段）；(b) 保留至该功能落地。**建议 (b)**，需拍板。

**C. 已知残留（分册逐条有据，均可接受）**

- **布局侧内容键 `w:<mid>:<字数>:<附件数>` 只带附件**数量**、不带**媒体/文档构成**。本轮把**气泡 memo 的键**补上了构成（`Int(attachH)`），但布局侧内容键**没动** —— 它与「按键末段反解 → 118/48 兜底」**成对耦合**（分册 §2.6 明确警告），单边改会破兜底。可达性：需要「同一消息在附件数量**与文本长度都不变**的前提下换成不同构成」，而落盘消息的附件类型不会变 ⇒ **实际不可达**。
- **两处"偏矮"口径未统一**（有意保留）：`estimateItemHeight` 的 user 回退用 `tw = width-80`（比真实的 `-120` 更**宽** ⇒ 偏短）；`estimateItemHeight` 对文本块**无条件走 CT**（`ctFramesetterHeight + 12`，无附件判据）。二者失真方向均为偏矮 ⇒ 需增长 ⇒ 手势期放行 ⇒ **不产生空白**，按「最少代码」保留。
- `RenderModels` 中 `timelineOrder` 的**默认值**仍是 `Double(Int.max - 1)`（语义 = "无时间线信息的正文排最后"）。本轮尾块改为 `maxEventOrder + 0.5` 后，该默认值**确定性地**排在尾块之后 —— 与注释语义一致，比此前"相等 ⇒ 按 id 随机"更好。
- `MarkdownRenderCache` 若将来被**持久化**，其内的 CT 矮值会绕过新判据（当前为纯内存，无影响）。
