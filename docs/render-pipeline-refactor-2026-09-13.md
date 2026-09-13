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
| **P2** | **S2 指纹统一**：加 `ContentFingerprint`（长度 + 确定性全量哈希），替换三处"仅长度"判据（块级渲染指纹 / sizeThatFits 桶指纹 / 屏上引擎去重指纹）。**注：`lastStreamPendingSourceLen` 是长度"序"比较（`<`），语义不同，不动** | 🔄 进行中 |
| **P3** | **S4 顺序管线显式化**：把"补播/重映射/失效"收敛为单一入口，S1–S15 由注释变结构断言 | ⬜ |
| **P4** | **S5 流式 block 集合构建收敛为一个纯函数**（保留孤儿清理 + `.file` 拆分，尾部 order 参数化） | ⬜ |
| **P5** | **S6 冻结状态机**：三组布尔量合并，消除 M1–M8 | ⬜ |
| **P6** | **S3 附件判据统一到结构判据**（含 `+12` 与 `MCS:630` 口径） | ⬜ |

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
