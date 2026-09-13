# P4 · S5 流式 block 集合构建收敛为一个纯函数 —— 实现规格

> 来源：重构调研（2026-09-13）。基准文档：`../render-pipeline-refactor-2026-09-13.md`。
> 行号为调研时盘上值。

## 0 结论摘要

「构建一条 assistant 消息的 block 集合」目前有 **4 条真实实现路径 + 1 条渲染层排序兜底**。它们对**同一段正文**用**两套尾部 order**（`Int.max-1` vs `maxEventOrder+0.5`）、**两套 thinking 幂等**（前缀匹配 vs 全量重建）、**一套 `.file` 拆分只在终态**、**一套孤儿清理只在流式**。P4 的目标就是把这些差异显式化为**参数**或**删除**，收敛为 `MiniClawChatAdapter` 里一个无副作用的 `static func buildBlocks(...)`。

- 唯一 `.file` 拆分实现：`MiniClawChatAdapter.swift:206-248`（全库 1 份，2 个调用点）。
- 唯一孤儿清理实现：`MiniClawChatBridge.swift:186-193`（全库 1 份，仅清 `.text`）。

## 1 全部实现/分支

### 路径 A — 终态全量重建（权威源）
- **函数**：`MiniClawChatAdapter.buildBlocks(_:)`，`MiniClawChatAdapter.swift:61-160`
- **入口**：`convert(_:)` `:17-37`（`:21` 调用）
- **输入**：`ChatMessage`（落盘 `content` / `reasoningSegments` / `toolCalls` / `isStreaming` / `reasoning`）
- **输出**：`[AssistantBlock]`（新对象）
- **特殊处理**：
  - 旧数据降级：`reasoningSegments` 空但 `reasoning` 非空 → 造 1 个 thinking 块 `:69-74`
  - 事件收集与排序：`reasoningSegments` → `.thinking` `:76-85`；`toolCalls` → `toolKind` `:87-94`；有 timeline 按 `order,position`，否则按 `position`（order=position+1）`:96-106`
  - position 越界告警 `:114-123`，clamp `:127`
  - 按 position 切正文，事件前片段 order = `eventOrder-0.5` `:124-141`
  - **`.file` 拆分**：事件前片段 `:135`
  - **尾部片段** `tailBase = maxEventOrder + 0.5` `:142-157`（`:153`），并拆 `.file` `:154`
  - 末尾 `items.sorted { $0.order < $1.order }` `:159` —— **无 tiebreak（非稳定排序）**
- **无孤儿清理**（全量重建即权威）。

### 路径 B — 流式增量合并（热路径）
- **位置**：`MiniClawChatBridge.refresh(force:)` 内联块 `:138-229`（函数本体 `:87-283`）
- **触发**：runtime 5 个 `@Published` 合并订阅 `:298-314`，0.25s 节流 `:248`
- **输入**：路径 A 产出的 `messages`（取最后一条 assistant `:140`）+ `runtime.streamingContent / streamingReasoningSegments / streamingToolExecutions`
- **输出**：就地修改 `lastAI.blocks`
- **特殊处理**：
  - ① 正文目标集切分 `:170-185`（与终态同构，但**尾部 order = `Double(Int.max - 1)`** `:184`）
  - **孤儿清理** `:186-193`
  - 按 id `upsert` `:194-200`
  - ② thinking **前缀匹配幂等** `:205-218`
  - ③ tool **引用挂载幂等**（按 `toolUseId`/`block.id` 跳过）`:222-228`
  - 前置条件 `runtime.isResponding && lastAI 存在` `:138-140`
  - **必须在指纹/节流 return 之前执行** `:136`（doc S6）

### 路径 C — 终态就地合并（缓存对象身份复用）
- **函数**：`MiniClawChatBridge.bridgedMessage(for:allowsSyncRender:)` `:323-453`
- **分支 C1 流式**（`model.isStreaming`）`:348-351`：保留 cached，**不合并 blocks**
- **分支 C2 终态** `:352-428`：按 id 把 `fresh.blocks` 合并进 `cached.blocks` `:366-396`；不在 fresh 中的旧块被丢弃；同步 `timelineOrder` `:390`；内容变了清块级渲染缓存 `:375-379`
- **签名相同早退** `:334-336`
- 本质是「rebuild + reconcile」，与纯函数目标高度重叠。

### 路径 D — 子代理/旧气泡路径（平行语义，另一种类型）
- **函数**：`MessageBubbleView.assistantSegments(content:toolCalls:reasoningSegments:showThinking:)` `:296-358`
- **消费**：`interleavedRenderItems()` `:361-371` + `effectiveContent/effectiveToolCalls/effectiveReasoningSegments` `:99-139`
- **唯一使用点**：`SubagentChatView.swift:43`
- **输出**：`[AssistantSegment]`；**无 `.file` 拆分、无孤儿清理**，id 用 `ordinal/index`（`AssistantSegment.swift:16-22`）
- 与主链路是**第三套同语义实现**（排序 `:326-332` 与 Adapter `:96-106` 同规则）。

### 路径 E — 渲染层排序兜底（非构建，但强依赖 order）
- `MessageCollectionCoordinator+Snapshot.swift:191-194`：`message.blocks.sorted { timelineOrder, 次 id }`
- 含义：**纯函数若不写对 order，渲染层会兜底重排**。

## 2 孤儿清理对照

| 路径 | 位置 | 判据 | 一致性 |
|---|---|---|---|
| B 流式 | `MiniClawChatBridge.swift:186-193` | `kind == .text && !targetIDs.contains($0.id)`，`targetIDs` 由 `textBlockID(mid,startOffset)` 生成 `:189` | **唯一显式实现** |
| A 终态 | 无 | 全量重建天然无残留 | 等价（结构性） |
| C 终态合并 | `:366-396` | 只保留 `fresh.blocks` 中的 id | **等价但隐式**（第二份"清理"语义） |
| D 子代理 | 无 | 纯重建 | 等价（结构性） |

- 一致判据内核：**身份 = `block.id`**，绝不按内容。
- 仅覆盖 `.text`（`:187-188` 注释显式排除 thinking/tool）。
- **缺口**：`.file` 不在流式孤儿清理范围 —— 若 P4 让流式也拆 `.file`，必须把 `kind == .file` 一并纳入 id 差集清理。

## 3 `.file` 拆分

- **实现份数：1 个函数**，`MiniClawChatAdapter.splitFileBlocks(markdown:messageID:baseOrder:startOffset:)` `:206-248`
- 辅助判据：`mediaExts` `:166-170`；`isFileReference(_:)` `:173-182`（排除 `http://`/`https://`，去 `?`/`#` 后扩展名非空且不在 `mediaExts`）；`canonicalFileURL(_:)` `:185-187`（当前恒等）
- **调用点 2 个，均在终态**：`:135`（`baseOrder = eventOrder - 0.5`）、`:154`（`baseOrder = tailBase`）
- 判据正则 `` `!\[[^\]]*\]\(([^)\s]+)\)|\[[^\]]*\]\(([^)\s]+)\)` `` `:208`
- 子序 `baseOrder + Double(sub) * 0.05` `:225, :234, :243`
- file 块身份：id = `det(mid, startOffset + matchLocation)` `:233`；content = `lastPathComponent`（URL 解码）`:231-232`
- **流式路径 0 份**

## 4 尾部 order 参数化

### 赋值点
| 位置 | 语义 |
|---|---|
| `RenderModels.swift:219` | `timelineOrder` 默认 `Double(Int.max - 1)` |
| `Adapter.swift:126` | 事件块写回 `block.timelineOrder = order` |
| `Adapter.swift:153` | **终态尾部基准** `tailBase = maxEventOrder + 0.5` |
| `Adapter.swift:200` | `makeTextBlock` 写 `b.timelineOrder = order` |
| `Adapter.swift:225/234/243` | `.file` 子序 `baseOrder + 0.05*k` |
| `Adapter.swift:235` | file 块写回 order |
| `Bridge.swift:184` | **流式尾部基准** `Double(Int.max - 1)` |
| `Bridge.swift:483` | `insertBlock` 写 `block.timelineOrder = order` |
| `Bridge.swift:547` | `upsertTextBlock` 就地更新 order |
| `Bridge.swift:390` | 终态合并同步 `timelineOrder` |
| `ChatSessionRuntime.swift:283-285` | 思考段 `order = nextTimelineOrder++`（`:120` 初值 1） |
| `ChatSessionRuntime.swift:108` | 工具事件 `timelineOrder = order(for: callID)` |
| `ChatView.swift:1738 / 1751-1752` | 断点恢复回填 order、`nextTimelineOrder = lastOrder+1` |
| `AgentLoopEngine.swift:2408, 2417` | 子代理 `order.next()` |

### 依赖点
- `Bridge.swift:490-495`：`insertBlock` 按 `b.timelineOrder > order` 定位插入位
- `Bridge.swift:484-487`：`order <= 0` 降级插到最前
- `Adapter.swift:99-105`：事件排序 `order || (order==position)`
- `Adapter.swift:159`：`items.sorted { $0.order < $1.order }`（**无 tiebreak**）
- `Snapshot.swift:191-194`：渲染层兜底排序（order 相同再比 id）
- `MessageBubbleView.swift:326-332`：子代理路径排序

### 为什么必须参数化
1. **同一 canonical 块拿到两个 order**：尾部正文段的 `id` 由 `(messageID, startOffset)` 决定（`Adapter:255-257`），与 order 无关。流式给 `Int.max-1`（`Bridge:184`），终态给 `maxEventOrder+0.5`（`Adapter:153`），只能靠 `Bridge:390` 事后同步 → 排序跳变、diffable 抖动。
2. **`Double` 在 `Int.max` 量级 ulp = 2048**：`baseOrder + 0.05*k` 的子序**全部被吞**（`Adapter:145-152` 有实测注释）。这正是 2026-09-12「文件指示器总在最终回复上面」的根因 —— 正文与 file 块 order 相等 → 非稳定 `sorted` 乱序。
3. 参数化后尾部基准由调用方显式传入（推荐流式与终态统一取 `maxEventOrder + 0.5`），使子序保留、两路径同构、可单测。

## 5 目标纯函数

```swift
struct BlockTimelineEvent {
    let order: Double          // 事件全局序号
    let position: Int          // 正文锚点
    let block: AssistantBlock  // 已构造好的事件块；流式下为共享引用
}

enum BlockBuilder {
    /// - previous == nil  → 全量重建（终态、首次入列）
    /// - previous != nil  → 增量合并（流式）：按 id 复用对象；不在结果集中的 .text/.file 旧块被清理（孤儿）
    /// 无副作用：不渲染、不读 runtime、不写缓存（cacheRenderedContent 由调用方在拿到结果后执行）。
    nonisolated static func buildBlocks(
        messageID: UUID,
        content: String,
        events: [BlockTimelineEvent],
        previous: [AssistantBlock]?,
        isStreaming: Bool,
        tailOrder: Double,                    // ← 参数化：尾部正文段基准
        splitFileReferences: Bool = false     // ← 参数化：是否做 .file 拆分
    ) -> [AssistantBlock]
}
```

### 差异 → 参数 / 删除 映射

| 现状差异 | 出处 | 处置 |
|---|---|---|
| 尾部 order `Int.max-1` vs `maxEventOrder+0.5` | `Bridge:184` vs `Adapter:153` | **变参数 `tailOrder`**；两处都传 `maxEventOrder+0.5`，删除 `Int.max-1` 用法 |
| `.file` 只在终态拆 | `Adapter:135,154` | **变参数 `splitFileReferences`**；P4 为行为等价：流式 `false`、终态 `true`。统一为 always 属后续阶段（会改变流式观感） |
| thinking 幂等：前缀匹配 | `Bridge:206-207` | **删除**，改为 `previous` 中按 `seg.id` 精确复用（终态块 id 即 `seg.id`，`Adapter:79`） |
| tool 幂等：按 `toolUseId`/`block.id` | `Bridge:224`；`Adapter:87-94` | 统一为 `previous` 按 `toolUseId ?? id` 复用（流式必须保留 `exec.block` 引用身份） |
| 孤儿清理只在流式 | `Bridge:186-193` | **收进纯函数** |
| 排序无 tiebreak | `Adapter:159` | 内部排序加 `id` 次键，与 `Snapshot:191-194` 一致 |
| 全量重建 vs 增量 upsert | A vs B | 统一为「算 target 集 → 与 previous 求差 → 复用/新建/删除」一条流水线 |
| 缓存对象合并 | C `:366-396` | 被 `previous` 复用吸收；C 退化为「调纯函数 + 执行 cacheRenderedContent」 |
| 旧数据降级（order==0 / reason 单串） | `Adapter:69-74,102-106`；`Bridge:484-487` | 保留，作为纯函数内部分支 |
| 渲染缓存注入 | `Bridge:403-418,433-450` | **移出**纯函数（有副作用、@MainActor、与 P2 指纹耦合） |

### 调用方收敛后形态
- A：`buildBlocks(…, events: 从 ChatMessage 构造, previous: nil, isStreaming: false, tailOrder: maxEvent+0.5, splitFileReferences: true)`
- B：`buildBlocks(…, events: 从 runtime 构造, previous: lastAI.blocks, isStreaming: true, tailOrder: maxEvent+0.5, splitFileReferences: false)`
- C：`buildBlocks(…, previous: cached.blocks, …)` + 原有 cacheRenderedContent 循环
- D（子代理，`AssistantSegment`）：类型不同，**P4 不改**。

## 6 不能改的行为

1. **幂等只按 `block.id`，禁止按内容去重**（`Bridge:514-530` 的删除记录 + doc §4 表）。最近修的 bug：多轮工具循环里出现多个逐字相同的正文块（如 9 个 4 字块），按内容去重会互相删除只剩 1 个 → 流式中整屏只显示 1 个、`endTransition` 时块索引后移 8（=9−1）。纯函数内的差集必须用 id。
2. **`commitReasoningBuffer` 必须在 `commitStreamBuffer` 之前**（`ChatSessionRuntime.swift:256-257`，doc S9）。锚点 = `streamingContent.count + pendingText.count`（`:282`）。**注意（未确认）**：终态/边界调用点顺序相反 —— `AgentRunService.swift:360-361 / 432-433 / 481-482 / 544-545`、`ChatView.swift:1578-1579`、`ChatSessionRuntime.swift:140-141 / 152-153` 都是 stream 先。P4 **不动**这些边界点，仅在规格中登记为待确认项。
3. **thinking 强制折叠**：`isThinkingExpanded=false` + `thinkingUserToggled=false`（`Adapter:71-72, 82-83`；`Bridge:213-216`）。
4. **确定性 id 算法**：`det(messageID, startOffset)` FNV-1a 64 v4 位（`Adapter:255-281`）；流式与终态共用（`Bridge:521`）；`.file` 块同源（`Adapter:233`）。id 一改，diffable 全量重建 + 高度缓存连坐失效。
5. **`.file` 判据**：排除 http/https、排除媒体扩展名、去 `?/#`、文件名去百分号编码（`Adapter:166-182, 231-232`）。
6. **position clamp + 越界告警**：`min(max(position,0),content.count)`（`Adapter:127`、`Bridge:174`）；越界 warn（`Adapter:114-123`）。
7. **流式合并在指纹/节流 return 之前**（`Bridge:138` vs `:249`）—— doc S6，否则无流式输出。
8. **挂起门不得推进指纹/替换 messages**（`Bridge:263-273`）—— doc S7。
9. **`isProcessing/canResume` 镜像在节流判定之前**（`Bridge:100-110`）—— doc S8，否则思考块 `isStreaming` 永为 true。
10. **旧数据降级**：`timelineOrder <= 0` 排最前（`Bridge:484-487`）、无 timeline 按 position 排（`Adapter:102-106`）。
11. **排序 tiebreak 与渲染层一致**（`Snapshot:191-194`）。
12. **tool 块引用身份**：流式下 `exec.block` 是 `ToolExecution` 持有的同一个 `AssistantBlock`，`@Published` 自驱动 cell（`Bridge:219-228`）—— `previous` 复用必须按 `toolUseId`/id 命中并**返回原对象**，不能重建。

## 7 未确认 / 风险

- **未确认**：`.file` 是否应在**流式**阶段也拆分。若统一 `splitFileReferences = true`（流式），必须同步扩展孤儿清理到 `.file`，且会改变流式观感 —— 建议 P4 保持参数化、行为等价，另开阶段。
- **未确认**：`MessageBubbleView.assistantSegments`（子代理）是否纳入同一纯函数。类型不同，跨类型收敛成本较大，建议 P4 暂不纳入。
- **未确认**：边界处 `commitStreamBuffer/commitReasoningBuffer` 的顺序是否需按 S9 统一；doc 只对 flush 窗口有明文约束。
- **风险**：`Adapter:159` 的 `.sorted` 在 Swift 中**不保证稳定**且当前无 tiebreak，是 order 相等的直接暴露点；收敛时务必加 id 次键。

## 关键行号速查
- 流式合并主体：`Bridge.swift:138-229`；孤儿清理 `:186-193`；尾部 order `:184`；upsert `:511-553`；insertBlock `:482-497`
- 终态重建：`Adapter.swift:61-160`；尾部 order `:153`；`.file` 拆分 `:206-248`；确定性 id `:255-281`
- 终态就地合并：`Bridge.swift:352-428`（合并 `:366-396`）
- 子代理平行语义：`MessageBubbleView.swift:296-358`
- 渲染层排序兜底：`Snapshot.swift:191-194`
- S9 锚点：`ChatSessionRuntime.swift:256-257, 270-290`
