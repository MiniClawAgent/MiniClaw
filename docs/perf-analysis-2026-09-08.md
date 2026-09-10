# 会话页流式卡顿：UICollectionView + Diffable + TextKit 清单对照分析

- 日期：2026-09-08　现象：超长上下文 + 流式输出时滑动抖动/卡顿
- 本次**只读分析，未改任何代码**（早前误按 SwiftUI 栈分析的版本已作废，本文为对照真实栈的重写版）
- 标注：✅ 已核实（附源码位置）｜⚠️ 待验证（需 Instruments / 真机）

## 〇、先确认 MiniClaw 流式期的真实机制（决定哪些建议有效）

| 环节 | 实现 | 位置 |
|---|---|---|
| 流式文字更新 | **不 apply snapshot**，走 `layout.invalidateLayout()` + cell 重配置 | `Coordinator+Bindings.swift:143` |
| 节流 | **自适应**：autoScrolling 100ms / 用户上滑 3s，带 trailing fire 防丢 | `Bindings.swift:113-131` |
| snapshot apply | 仅消息/块增删时；`animatingDifferences: false` | `Coordinator+Snapshot.swift:320/578`、`MessageCollectionView.swift:1179` |
| 自动滚动 | 80ms 合并 + 仅 autoScrolling + 非 tracking 才滚 | `Bindings.swift:153-163` |
| 持久化 | **流式期不落盘**（persist 只在 run 起止/出错/停止） | `AgentRunService` 384/457/562 |
| 高度 | `heightEntries`(measured/precalc/estimated) + 进程级 memo + PLAF + `deferSelfSizing` | `MessageListLayout` |
| 流式测量 | 未 finalized 走 **CTFramesetter 快路径**；finalized 且 ≤8000 字符才用真实 TextKit 测量 | `MarkdownView.swift:1079-1090` |

## 一、清单逐条对照

### 1. 频繁 apply 快照（清单称头号元凶）→ **已做对大半，剩下的是等价变形**

- ✅ 流式期的文字更新**不驱动数据源**（符合清单核心思想：dataSource 只管"有几条消息"）。
- ⚠️ 但等价成本改由 **`invalidateLayout()` + cell 重配置** 承担：每 100ms 一次 invalidate → 可见 cell 走 PLAF 重测 + `configureCell` → **`mtv.attributedText = pending`（全量富文本重建）**。
- 结论：不是"apply 太频繁"，而是**"每 100ms 让可见 cell 全量重建一次富文本并重测高度"**。改动方向不在 apply，而在第 2/5 条（富文本成本）。

### 2. Cell 复用 + attributedText 全量赋值 → **⚠️ 核心痛点，高度适用**

- ✅ 已有保护：`lastRenderedContentHash` 内容级去重；`setAttributedText` skip 分支（`MarkdownView.swift:1416` 注释明确为避开昂贵赋值 + ensureLayout）。
- ⚠️ 但流式期内容持续变化，哈希必然不命中 → 每 100ms 走一次 **全量 `renderer.render(blocks:)`**（`MarkdownView.swift:1043`）+ 全量 `attributedText` 赋值。成本随**单条消息长度**增长。
- ❌ 清单的"流式期 `textView.text += chunk`"**不能照搬到 MiniClaw**：正文是 Markdown 富文本（代码块、表格、图片附件、KaTeX、行内代码），纯文本 append 会丢样式。
- ✅ 可采纳其**精神**：流式期降低富文本重建成本（见第五节）。

### 3. Snapshot 坑（动画 / id 稳定）→ **已满足** ✅

- 全部 `apply(snapshot, animatingDifferences: false)`（无动画排队）。
- item identity = message/block id 稳定；唯一例外（气泡内分段 `ForEach` 用 `\.offset`）已于 09-07 修为稳定 id。

### 4. 自动滚动 → **已做且优于清单建议** ✅

- 80ms 合并滚动 + 仅 `scrollMode == .autoScrolling` + `isTracking` 排除用户手势；非"每 token scrollToItem"。

### 5. 富文本解析在主线程 → **⚠️ 部分适用，是收益点**

- `renderMarkdownBlocks` 标了 `@MainActor`（`MarkdownSupport.swift:1502`），渲染在主线程；SwiftUI 侧（子代理页）反而已有 `Task.detached` + 300ms 防抖。
- 清单给的正是可行解：**流式期先用纯文本/轻量富文本，结束后再渲染完整富文本并赋值一次**。这是本次清单里**最值得采纳的一条**。
- 另一条（把 NSAttributedString 构造整体挪后台）收益更大但风险高：涉及 `UIFont`/`UIColor` dynamic 解析与附件，需谨慎验证。

### 6. 逐 token 落盘 → **已满足** ✅

- 流式期内存维护，run 边界才持久化。

### 7. 布局计算（PLAF 高频）→ **已做，但有一处已知隐患**

- ✅ PLAF + `deferSelfSizing`（滚动期推迟重测）+ 高度 memo + precalc 体系。
- ⚠️ 已知隐患（09-05 审计记录，未复现未改）：`SelfSizingCell` 的 PLAF **50ms dedup 短路无流式豁免**——注释声称有豁免，实际豁免只在下层 `deferSelfSizing` 分支。极快流式时 cell 高度可能滞后一拍 → 与"抖动"相关，**建议优先真机核实这一处**。

## 二、MiniClaw 专属、清单没覆盖的问题

**`MiniClawChatBridge.refresh()` 每 token 白付一次全量排序**（09-07 审计 P2-7）
- `Views/Chat/Bridge/MiniClawChatBridge.swift`：先 `session.messages.sorted{}`（:90）→ `sorted.map{bridgedMessage}`（:118）→ 指纹遍历（:210-224），**最后**才在 :226 判 0.25s 节流、:227 return。
- 节流挡住了下游，却没挡住前面 O(n log n) 的排序与映射。消息条数越多，每 token 白烧越多 —— 与"**超长会话**才卡"直接对应。
- 修法很小：节流前置，用轻量指纹（条数 + 末条内容长度 + isResponding）先短路。

## 三、结论：可采纳项按性价比排序

| 优先级 | 项目 | 对应清单 | 改动量 | 说明 |
|---|---|---|---|---|
| **P0** | A. `bridge.refresh()` 节流前置短路 | （清单未覆盖） | 小 | 直击"超长会话"，低风险 |
| **P1** | B. 流式期富文本降级：流式用纯文本/轻量，结束后渲染完整富文本 | 第 2 + 5 条 | 中 | 收益最大；需评估观感（流式期无 markdown 样式） |
| **P1** | C. 核实 PLAF 50ms dedup 的流式豁免隐患 | 第 7 条 | 小（若属实） | 与"抖动"直接相关 |
| P2 | D. 渲染时间节流（流式期 render 限频 120~200ms） | 第 2 条 | 小 | 比 B 保守的替代方案，可先试 |
| P2 | E. 富文本构造后台化 | 第 5 条 | 大、风险高 | 需先验证 dynamic color/附件线程安全 |
| — | 1 / 3 / 4 / 6 | — | — | **已做对，不动** |

## 四、动手前必须先量（避免盲改回归）

1. **Instruments → Time Profiler**（不只 Core Animation）：超长会话 + 流式 + 同时滑动，抓主线程热点。
2. 看热点落在哪个符号，对应不同结论：
   - `MiniClawChatBridge.refresh` → 确认 A
   - `MarkdownNSRenderer.render` / `MarkdownContent.blocks` / `setAttributedText` → 确认 B/D
   - `MessageListLayout` / `sizeThatFits` / `preferredLayoutAttributesFitting` → 确认 C
3. **在拿到热点前不动高度体系**（`heightEntries` / PLAF / memo）——历史回归高发区。

## 五、关于"流式期降级为纯文本"的取舍（B 方案细节）

- 收益：流式期每 100ms 的重渲染从"全量 markdown 解析 + 富文本构造"降为"追加字符串"，成本几乎不随消息长度增长。
- 代价：流式过程中代码块不高亮、表格不成型、图片不渲染；结束后一次性变为完整样式（一次跳变）。
- 折中：仅对**超长单条消息**（如 > 4000 字符）启用降级，短消息保持富文本——既避开"越长越卡"，又不影响绝大多数消息的观感。
- 必须保证：降级期间的高度估算与最终渲染的高度口径一致，否则结束瞬间会跳高（要在 precalc/measured 体系内处理）。

## 五之二、唐唐补充后（流式时才卡 + 单条长消息为主）的源码下钻结论

**现象锁定**：不是条数多，是**单条很长**。→ 主攻"随消息长度增长的每帧成本"，A（refresh 排序）降级为次要。

### 已排除（这些不是瓶颈，都已优化）

| 环节 | 证据 |
|---|---|
| PLAF 高度测量 | 流式 cell 命中 **precalc 短路**直接返回、跳过 `super`/`systemLayoutSizeFitting`（`MessageListInfrastructure.swift:726-738`）；且已修过"按值判空→按来源判定"的回归（只认 `.precalc` 来源） |
| 测量算法 | 流式期强制 **CTFramesetter**（0.3ms），明确避开 TextKit1 的近 O(n²)（1.4–11ms），注释见 `MarkdownView.swift:1139-1176` |
| 50ms dedup | 存在（`Infrastructure.swift:639-648`），且 `applyContentConfiguration` 会清缓存保证内容变化仍重测 |
| 非流式 cell | 流式期间**也短路**（`Infrastructure.swift:717-725`，即 crash 修复 e9d167c2 的 A 扩展） |

### 真瓶颈：每个 chunk 的三份 O(消息长度) 工作

位置全在 `MiniClawKit/MarkdownView.swift` 的同一段（prepare/render 路径）：

1. `:1040` `MarkdownContent(preparedPrefix).blocks` — **整篇重新 Markdown 解析**
2. `:1043` `coord.renderer.render(blocks:)` — **整篇重新构造 NSAttributedString**（含代码块/表格/附件/行内样式）
3. `:1083/:1120` `attributedText = pending` — **TextKit 重新排版整篇**

三者都随"单条消息长度"线性（甚至超线性）增长，每 ~100ms（autoScrolling 节流）全来一遍。单条 1 万字时，主线程每 100ms 被占用几十毫秒 → 滑动掉帧。滑动时还要叠加 cell 复用与布局，所以"流式 + 滑动"最明显。

**一句话**：测量已经很便宜了，**贵的是"内容准备"本身**（解析 + 构造 + 排版），且它是全量、非增量的。

### 对应方案（针对单条长消息，按性价比）

| 方案 | 做法 | 收益 | 风险/代价 |
|---|---|---|---|
| **D（先试）** | 流式期 render 节流 100ms → 200~300ms（改常量） | 成本降 1/2 ~ 1/3，立刻验证瓶颈假设 | 极低；单次仍 O(长度)，超长消息可能仍卡 |
| **B（根治）** | 流式期**跳过富文本管线**，textView 走纯文本增量；结束一次性渲染完整富文本 | 每 chunk 成本从 O(长度) 降为 O(增量) | 中：流式期无 markdown 样式（代码块不高亮、表格不成型）；需处理结束时的高度口径切换（precalc→measured 现有机制可承接） |
| B 变体 | 仅对**超长单条**（如 >3000~4000 字符）启用降级 | 兼顾观感与性能 | 需一个阈值与分支 |
| 进阶 | 增量渲染尾部脏段 | 观感与性能兼得 | 高：要处理跨 chunk 未闭合结构（`**bold`、表格未收尾） |

### 额外待确认（可能是隐藏的第四份成本）

`prepare()` 预取路径同样走 `:1043` 的全量 render —— 若 prefetch 未跳过"正在流式的 item"，则同一 chunk 会**渲染两次**（预取一次 + 显示一次）。建议核实 prefetch 是否排除流式 item。

## 五之三、唐唐新线索：思考指示器运行时掉帧（09-08 追加）

**结论：很可能是它，而且找到了两处「无限动画 + 状态层级过高」的结构性问题。**

### 现场：三处 `repeatForever` 无限动画

| 位置 | 驱动状态 | 状态所属层级 | 影响面 |
|---|---|---|---|
| `AssistantBlockView.swift:150-162`（工具/流式三点弹跳） | `dotsOn` | **`AssistantBlockView` 自身**（:27） | ⚠️ **大** —— 该 View 包含 `MarkdownView`（:812），每帧重算整个块视图 |
| `AssistantBlockView.swift:508-546` `TypingIndicator`（"正在思考…"+三点） | `dotOffsets` | 独立小 View 自身 | 中 —— 只重算自己，但每帧在长消息 cell 内提交渲染 |
| `BridgedCellViews.swift:160-181` footer 呼吸点 | `replyBreathing` | `BridgedAssistantFooter`（小组件） | 小 —— 只含状态行 |

### 关键机制（为什么"长消息 + 思考"最明显）

1. `TypingIndicator()` 挂在 **`ChatMessageRow`**（`ChatMessageRow.swift:367-369`，整条消息视图，含全部 block 与 Markdown）内，条件 `isActiveMessage && (!hasVisibleBody || isAwaitingModelResponse)`。
2. SwiftUI 的 `repeatForever` 动画每帧修改 @State：
   - `TypingIndicator` 状态自持 → 只失效自身 body（小），**但动画仍使该 cell 的 hosting view 每帧提交渲染更新**；
   - 而 cell 内含**大段 TextKit 文本**时，每帧的渲染/合成成本 ∝ 文本长度 → **长消息掉帧**。
3. 更严重的是 `dotsOn`：它是 `AssistantBlockView` 的 @State，而该 View 的 body 里就有 `MarkdownView`。工具执行/流式期间，三点动画**每帧重算包含富文本的整个块视图**，并每帧驱动 `MarkdownView.updateUIView`。
4. 叠加前面定位的"每 chunk 三份 O(长度) 工作"：思考阶段 token 速率通常远高于正文，内容增长更快，重建更频繁 → 思考时最卡。

### 最小代价的验证方法（先证伪再改）

- 临时把 `TypingIndicator` 的 `withAnimation(...repeatForever...)` 去掉（或设 `animation(nil)`），真机看思考时是否还掉帧。
- 同理暂停 `AssistantBlockView` 的 `dotsOn` 动画，看工具执行/流式时是否改善。
- 两者分别验证，可区分各自占比。

### 优化方向（待拍板）

| 顺序 | 方案 | 说明 |
|---|---|---|
| 1 | **降低状态层级**：把 `dotsOn` 抽成独立小 View 自持状态 | 最该做；避免每帧重算含 Markdown 的 body（同 `TypingIndicator` 的写法） |
| 2 | **动画下沉到 layer**：改用 `CABasicAnimation` / `CAReplicatorLayer` 做点动画 | 彻底避免 SwiftUI body 每帧重算 |
| 3 | **滚动时暂停**：`isTracking`/`isDecelerating` 时停掉 dots/呼吸动画 | 滑动优先，直接改善"滑动时卡" |
| 4 | `TypingIndicator` 降频或隔离 | 若验证后它仍是主因：改用低频 `TimelineView`，或移出长文本 cell（独立 cell/overlay） |

## 五之四、唐唐的三个场景 → 一个统一根因（09-08 追加）

### 关键结构事实（决定一切）

1. **每个 block 是一个独立 cell**：diffable item 是 `.assistantBlock(msgId, blockId)`（`estimateItemHeight` 的 switch 分支可见）。十多条消息 = 几十个 block cell，可见区同时有 5~15 个。
2. **`block.cachedAttributedString` 是内存属性**（`ChatModels.swift` 的 @Published，不进 SQLite）。命中时 `MarkdownView.swift:1020` 直接复用、**跳过全量 render**；未命中则走 `:1040/:1043` 的整篇解析 + 构造 NSAttributedString。
3. 因此：**块"首次配置"的成本 = O(块长度) 的全量 Markdown 渲染**，之后才便宜。

### 三个场景如何各自命中它

| 场景 | 命中方式 | 额外因素 |
|---|---|---|
| **1. 思考期间** | 思考块/文本块内容持续变化，缓存**永远不可用** → 每 chunk 全量重建（前面定位的 :1040/:1043/:1120 三份 O(长度) 工作） | **叠加三处 `repeatForever` 动画**（`dotsOn` 在含 Markdown 的 `AssistantBlockView` 上，每帧重算整个块视图） |
| **2. 一轮完毕后上滑历史** | 历史中**从未显示过**的 block，`cachedAttributedString` 仍为 nil → 每滑过一个就全量渲染一次 | 工具卡/图片等复杂子视图重建；未命中 seed 时还要 `systemLayoutSizeFitting`（2.5–3.8ms/个） |
| **3. 首页重进会话（十多条）** | 重进时 `loadSession` **重建 ChatMessage/AssistantBlock 对象**（`Coordinator+Snapshot.swift:292-299` 注释明确提到 "freshly created … new UUIDs"）→ **所有 block 的富文本缓存全部丢失** → 首屏每个可见 block 都全量渲染 | 播种/清洗链路已修（`:344-347` purgeIndexEntry + 重播种子），不是抖动原因，但**冷渲染成本仍在** |

### 已排除（别再往这些方向查）

- **prefetch 估算已优化**：`estimateItemHeight` 的文本块走 **CTFramesetter**（`Heights.swift:285`，70–700× 于 boundingRect），且有 measured/precalc 守卫跳过（`Scrolling.swift:974-975`）。
- **重进的抖动机制已修**：09-06 的 `purgeIndexEntry` + 重播种子（不是本次卡顿主因）。
- **高度测量不算贵**：流式走 CT 快路径，已测 cell 走 seed 短路。

### 统一优化方向（按性价比）

1. **让富文本缓存跨会话存活**（治本，直击场景 3 + 缓解 2）：把 `cachedAttributedString` 改为**进程级缓存，key = contentKey（messageId+blockId 或内容哈希）**，而不是挂在会被重建的 block 对象上。重进/复用都能命中。
2. **滑动时限制新渲染块数**（场景 2）：每帧/每窗口最多做 N 个块的全量渲染，其余先用估算高度占位、空闲时补渲染（类似 lazy image decoding 的思路）。
3. **流式期降级为纯文本**（场景 1，前面方案 B）：内容在变 → 缓存不可能命中，只能降低单次成本。
4. **动画修复**（场景 1 专属）：`dotsOn` 抽成独立小 View / 动画下沉 layer / 滚动时暂停。

### 验证优先级

- 场景 3 最容易验证：重进会话时给 `:1043` 的 render 打点（次数 + 耗时），若十多条消息触发几十次全量 render 且总耗时数百毫秒 → 根因确认。
- 场景 2：上滑时同样打点，看未浏览过的 block 是否各触发一次全量 render。
- 用 Instruments Time Profiler 抓 `MarkdownNSRenderer.render` 的累计耗时即可量化。

## 七、打点已就位 + 外部同类实现参考（09-08 追加）

### 打点已实施（编译通过，可真机验证）

- `MarkdownView.traceRender(hit:markdownCount:ms:finalized:blockId:)`：
  - **HIT**（命中 `cachedAttributedString`）只计数不打印；**MISS**（全量解析+构造）终态逐条打、流式期每 30 次汇总一行（防刷屏）
  - 每行含：序号、字符数、耗时 ms、累计 ms、HIT 累计、finalized、blockId 前 8 位
  - `MessageCollectionView` 首次加载（重进/首开）时 `resetRenderTrace()` 清零 → **日志读数即"本次重进"的统计**
- **验证读法**：重进会话 → 看 `[RenderTrace] MISS` 的条数与 total ms。若十多条消息触发几十次 MISS、累计数百 ms → 根因坐实（场景 3）；上滑历史看新 MISS 是否随滑过的未浏览块递增（场景 2）。
- **验证完删除**：`traceRender`/`resetRenderTrace` 及两处调用点。

### 外部同类实现研究（只学方法）

**外部同类实现的分层与我们一致**（MessageListLayout / MarkdownRenderView / KaTeXRenderer / TextFadeAnimator / ContextPolicy 一一对应），流式节流策略我们已对齐：autoScrolling 0.1s / userBrowsing 3.0s + trailing fire。三个可借鉴点：

1. **`PaginatedMarkdownView`（255 行，直击"单条超长消息"）**：
   - 阈值分页：≤50K 字符单次渲染；超限按 `\n\n` 段落边界切分（**fence 感知**，代码块不被切断），每段独立渲染进 LazyVStack
   - **CJK 感知阈值**：CJK 字符的 CoreText 排版成本远高于拉丁（per-char script pass），CJK 占比 >30% 时阈值降为 20K —— **对中文为主的 MiniClaw 极重要**，我们现在的 8000 字符闸门没有 CJK 感知
   - 切分 O(n) 单趟无正则、后台执行（Task.detached）
2. **`StreamingHangLogger`（559 行诊断基建，Debug+Release 可用）**：
   - 主线程 Hang 检测（流式期间激活，≥2s 捕栈）+ **流式内容 ring buffer**（200 条：msgId/blockId/总长/尾 200 字符/finalFlush）→ hang 发生时能回答"**卡住时正在渲染什么**"
   - attributedText 赋值 ring buffer（捕获 `_fillLayoutHole` 的实际输入）
   - 非流式零开销；比我们的临时打点更完善，可作长期现场诊断
3. **V3 架构对齐确认**：cell-per-block、三层高度、两态滚动模型我们全有 → **不必重构列表，差异全在渲染层细节**

### 结合三个场景的落地方案（段级缓存，解开"增量渲染"难题）

之前认为"增量渲染尾段"难在跨 chunk 未闭合结构——同类方案的段落切分给了可行路径：

- **长块（超阈值，CJK 感知）按段落切分**（fence 感知），**每段独立渲染 + 段级缓存（key=段内容哈希）**
- 流式时**只有尾段重建**（前面段落已定型、缓存全命中）→ "每 chunk 全量 O(长度)" 降为 "每 chunk O(尾段)"
- 结束后整篇渲染一次（现有 finalized 机制承接）
- 短块（≤阈值）保持现状，零影响

配合：① `cachedAttributedString` 进程级缓存（key=contentKey，治场景 3/2）；② dotsOn 动画降层级（场景 1 的动画部分）。

## 六、待唐唐确认的两个问题（已答复）问题

1. 卡顿是**接收流式文字时滑动**才卡，还是**不接收、单纯翻历史**也卡？（前者 → A/B/C；后者 → 复用/测量/预取链路，与流式无关）
2. "超长"是**会话条数多**（数百条）还是**单条消息特别长**（上万字）？（前者 → A；后者 → B）
