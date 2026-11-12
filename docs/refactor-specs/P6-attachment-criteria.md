# P6 · S3 附件判据统一到结构判据 —— 实现规格

> 来源：重构调研（2026-09-13）。基准文档：`../archive/render-pipeline-refactor-2026-09-13.md`。
> 行号为调研时盘上值。

## 0 语义前提：「附件」在本工程里是**两个互不相干的概念**

混为一谈是口径不一致的根源。

- **① 消息级附件**：`RenderMessage.attachments: [AttachmentMeta]`（`RenderModels:291`）/ `inputAttachments: [RenderAttachment]`（`RenderModels:292`）。渲染为 **user 气泡上方的瓦片**（`Stubs:723 UserAttachmentList`）。**只管 user 消息**。
- **② 富文本附件**：`NSAttributedString` 里的 `NSTextAttachment`（表格 / 代码块 / 内嵌图片 / 公式 / 音视频 / 分隔线）。由 `MDSupport:1306 hasAnyAttachment` 判定。影响**能否走 CT 快路径**，与 user 附件毫无关系。

doc §1 表 S3 行说的「`+12` 与 `MCS:630` 两个不一致落点」属于 **②/CT 口径**；「含附件 3 版」（§0 行 24）同时横跨 ① 和 ②。

## 1 穷举：所有「有无附件 / 几个 / 多高」的判据

### 1.1 消息级附件（user 气泡瓦片）

| # | 位置 | 表达式 | 语义 |
|---|---|---|---|
| A1 | `MCH:91-92` | `let attachCount = message.attachments.isEmpty ? message.inputAttachments.count : message.attachments.count` | **计数**（高度侧，含 input 回退） |
| A2 | `MCH:100` | `if attachCount>0 {` | **有无** |
| A3 | `MCH:101` | `let tilesPerRow = max(1,Int((cvWidth-32-60)/70))` | 每行瓦片数（**70** 基数） |
| A4 | `MCH:102-103` | `rows = ceil(count/tilesPerRow)`；`attachH = rows*70+6` | **高度公式 A** |
| A5 | `MCH:107` | `return attachCount>0 ? attachH : nil` | **有无** |
| A6 | `MCH:110` | `key = "\(text.count)\|\(Int(usableTextWidth))\|\(Int(fontSize))\|\ (attachCount)\|\(text.hashValue)"` | memo key 含附件数 |
| A7 | `MCH:211` | `let a = msg(id)?.attachments.count ?? 0` | **计数**（内容键，**只数 attachments**） |
| A8 | `MCH:212` | `return "w:\(id.uuidString):\(n):\(a)"` | 内容键格式 `w:<id>:<字数>:<附件数>` |
| A9 | `MCH:250` | `let attachCount = msg.attachments.count` | **计数**（回退，只数 attachments） |
| A10 | `MCH:251-255` | `tilesPerRow = max(1,Int(tw/70))`；`rows = ceil(...)`；`imgH = rows*70` | **高度公式 B**（**无 `+6`**） |
| A11 | `MCH:259` | `return imgH+44` | 回退总高 |
| A12 | `Row:185` | `if !message.attachments.isEmpty {` | **有无**（主链路渲染） |
| A13 | `Row:186` | `UserAttachmentList(attachments: message.attachments)` | 渲染来源 |
| A14 | `Row:187` | `} else if !message.inputAttachments.isEmpty {` | **有无**（渲染回退，死分支见 §2.2） |
| A15 | `Row:188` | `QueuedAttachmentPreview(attachments: message.inputAttachments)` | 渲染回退来源 |
| A16 | `Bubble:189` | `if !message.attachments.isEmpty {` | **有无**（子代理链路渲染） |
| A17 | `Bubble:213` | `let paths = message.attachments` | 子代理链路来源 |
| A18 | `Layout:244-252` | `case "w:":`；`let parts = key?.split(separator: ":")`；`h = (Int(parts.last ?? "0") ?? 0) > 0 ? 118 : 48` | **内容键末段反解附件数** |
| A19 | `Snapshot:736` | `att=\(msg.attachments.count)\|inAtt=\(msg.inputAttachments.count)\|tag=…` | 诊断日志 |
| A20 | `Stubs:725` | `private let tileSize: CGFloat = 64` | 渲染**真实**瓦片边长（非 70） |
| A21 | `Stubs:741` | `let perRow = 4` | 渲染**真实**每行媒体数（固定 4） |
| A22 | `Stubs:739,744` | `VStack(…, spacing: 6)` / `LazyVGrid(columns:…, spacing: 6)` | 渲染真实间距 6 |
| A23 | `Stubs:791` | `.frame(height: 40)` | 文档文件**每行 40pt** |
| A24 | `Stubs:164-167` | `struct QueuedAttachmentPreview { var body: some View { EmptyView() } }` | 排队附件预览是**空桩** |

### 1.2 富文本附件（NSTextAttachment / 富语法）

| # | 位置 | 表达式 | 类型 |
|---|---|---|---|
| B1 | `MDSupport:1306-1315` | `var hasAnyAttachment: Bool { … enumerateAttribute(.attachment, …) }` | **产物判据**（全库唯一实现） |
| B2 | `RenderModels:358-365` | `hasRichSyntax`：``content.contains("```") \|\| content.contains("\|") \|\| content.contains("![") \|\| content.contains("$$") \|\| [audio]/[video]/[file] \|\| "\n---" / hasPrefix("---")`` | **源文启发式（完整 7 类）** |
| B3 | `MCH:148` | `if text.contains("```") \|\| text.contains("\|") {` | **源文启发式（残缺 2 类！）** |
| B4 | `MCH:25` | `if attrStr.length <= 8000, !attrStr.hasAnyAttachment {` | 产物判据（测量快路径门） |
| B5 | `RenderModels:390` | `let hasAttachmentSyntax = Self.hasRichSyntax(content)` | 源文判据（进缓存门） |
| B6 | `RenderModels:412` | `if let cacheKey, let attr = cachedAttributedString, !attr.hasAnyAttachment {` | 产物判据（缓存写入兜底） |
| B7 | `Snapshot:440` | `let rich = AssistantBlock.hasRichSyntax(c) \|\| attr.hasAnyAttachment` | 源文 **OR** 产物 |
| B8 | `Snapshot:669` | `if AssistantBlock.hasRichSyntax(block.content) {` | 源文判据（种子 CT/TextKit 分派） |
| B9 | `MDView:731` | `if !attributed.hasAnyAttachment {` | 产物判据（渲染写缓存） |
| B10 | `MDView:1144` | `if !pending.hasAnyAttachment {` | 产物判据（sizeThatFits 分支） |
| B11 | `MDView:1218` | `if !liveStorage.hasAnyAttachment {` | 产物判据（live 分支） |

### 1.3 CT + inset / padding 口径

| # | 位置 | 表达式 | 说明 |
|---|---|---|---|
| C1 | `MCH:30` | `MarkdownView.ctFramesetterHeight(...) + 8` | CT **+8** |
| C2 | `MCH:151` | `ceil(ctFramesetterHeight(...)) + 8` | CT **+8** |
| C3 | `MCH:286-287` | `let textH = ctFramesetterHeight(...)`；`return textH+12` | CT **+12**（**全库唯一**） |
| C4 | `Snapshot:468` | `heights[w] = ceil(lm.usedRect(for: tc).height) + 8` | 裸 NSLayoutManager **+8** |
| C5 | `Snapshot:682` | `ctFramesetterHeight(...) + 8` | CT **+8** |
| C6 | `MDView:1182-1184` | `textHeight + (textContainerInset.top + .bottom)` | CT **+动态 inset(=8)** |
| C7 | `MDView:1243-1245` | 同 C6（`liveStorage` 路径） | CT **+动态 inset(=8)** |
| C8 | `MCH:284` | `uH+SelfSizingCell.assistantBlockVerticalChrome` | 统一缓存高 **+chrome(4)** |
| C9 | `Snapshot:690` | `setPrecalcHeight(height+assistantBlockVerticalChrome, at: i)` | **+chrome(4)** |
| C10 | `MDText:131` | `textContainerInset = UIEdgeInsets(top: 4,left: 0,bottom: 4,right: 0)` | inset(=8) 定义源 |
| C11 | `Infra:416` | `static let assistantBlockVerticalChrome: CGFloat = 4` | chrome(=4) 定义源 |
| C12 | `MCH:139` | `ceil(bounds.height)+20+attachH+1` | user 气泡 cheap 路径 |
| C13 | `MCH:157` | `measured+20+attachH+1` | user 气泡精确路径 |
| C14 | `MCH:107` | `attachCount>0 ? attachH : nil` | user 气泡纯附件路径 |

## 2 口径不一致清单

### 2.1 附件高度公式有两套，且都与渲染不符 ★核心

- **公式 A**（`MCH:100-104`，主路径）：`tilesPerRow = Int((cvWidth-32-60)/70)`，`attachH = rows*70 + 6`。
- **公式 B**（`MCH:250-259`，回退）：`tw = max(width-80,100)`，`tilesPerRow = Int(tw/70)`，`imgH = rows*70`（**无 +6**）。

差异：可用宽基数 **`cvWidth-92` vs `cvWidth-80`（差 12）**、行间距 **+6 vs 0**。二者对同一消息可能算出不同行数。

**但与真实渲染比，两套都不对**（`Stubs:723-799`）：真实瓦片 `tileSize = 64`（非 70）、媒体**固定 4 列**（非按宽除）、文档文件**每行 40pt**、`spacing 6` 是**行间**间距（N 行只有 N−1 个）。

**判据**：渲染是唯一真相（`UserAttachmentList`）。

✅ **已修（`839b9c7`）**：按渲染真构成收敛为唯一入口 `MessageCollectionCoordinator.attachmentStripHeight(_:)`：

```
渲染真相（逐行读出）：VStack(alignment:.trailing, spacing: 6) {
    媒体(image/video/audio) → LazyVGrid(GridItem(.fixed(64), spacing: 6) × max(1, min(media.count, 4)))
    文档(非媒体)            → ForEach **每条一行**，frame(height: 40)
}
⇒ 媒体段 = rows*64 + (rows-1)*6（rows = ceil(media.count / min(media.count,4))）
⇒ 文档段 = n*40 + (n-1)*6
⇒ 两段之间再计一次 6pt
```

原先的 `rows*70+6` 把两类附件一并处理，误差是结构性的：
纯图片 1 张 估 76 / 实 64（**+12**）；纯文档 1 个 估 76 / 实 40（**+36**）；纯文档 2 个 估 76 / 实 86（−10，安全侧）。
因手势期策略是「只拒绝收缩」，前两类**高估会变成拖动期可见空白**、松手才消失。

⚠️ **该修复顺带暴露的一处正确性缺失（已一并修）**：`measureUserBubbleHeight` 的进程级 memo 键原先只含附件**数量**（`attachCount`），而新高度依赖**媒体/文档构成** ⇒ 同为 1 个附件时「1 张图」(64) 与「1 个文档」(40) 会算出不同高度却撞同一个键、命中旧值算错高。键中已加入算好的 `Int(attachH)`。

> 未动：`estimateItemHeight` 的 user 回退分支（`MCH:250-259`）—— 仅在空文本且无附件时到达；且其 `tw = width-80` 比真实 `-92` 更宽 ⇒ 偏短 ⇒ 安全侧，按「最少代码」保留。

### 2.2 附件计数有两套，`inputAttachments` 疑似"第二个 `lastHeightByKey`"

- 高度侧 A1 用 `attachments.isEmpty ? inputAttachments.count : attachments.count`（**双数组**）。
- 内容键 A7 与回退 A9 只用 `attachments.count`（**单数组**）。
- memo key A6 用双数组版。

**关键事实**：全仓 `inputAttachments` 仅 4 处 —— 声明 `RenderModels:292`、读取 `MCH:92`、`Row:187/188`、日志 `Snapshot:736`，**没有任何赋值点**；桥接层 `Adapter:31-35` 只桥接 `attachments`；且 `QueuedAttachmentPreview.body == EmptyView()`。

⇒ `inputAttachments` **恒为空**，A1 的三元与 `Row:187-188` 的 else-if **当前都是死分支**，数值上 A1≡A7≡A9。这与 doc §0 病根 3（`lastHeightByKey` 无写入点）**同型**。

**判据**：单一口径更正确。但统一前必须先裁决 `inputAttachments` 的存废（删除 / 或明确它是"排队态"并由 Bridge 正式桥接）。**未确认**：是否存在仓外写入方（`@Published public` 理论可被外部赋值，全仓 grep 为零）。

### 2.3 富语法清单两套，`MCH:148` 是残缺失真版 ★真 bug 风险

- `MCH:148` 只查 `` ``` `` 和 `|`；`RenderModels:358 hasRichSyntax` 查 7 类（多 `![`、`$$`、`[audio]/[video]/[file]`、`---`）。

**后果**：一条 user 消息若含 `![x](...)` 或 `$$...$$` 或 `---` 但**不含**代码块和 `|`，`MCH:148` 判 false → 走 CT 快路径 → CTFramesetter 不调用 `attachmentBounds` → 高度塌陷。这正是 `MCH:20-25` 与 `MDView:1160-1168` 注释反复警告的 bug（`MCH:24` 原话："MarkdownView 的 sizeThatFits 早有同款 hasAnyAttachment 门，此处漏了"）。

**判据**：优先级应为 **产物 `hasAnyAttachment`（B1）> 源文 `hasRichSyntax`（B2）**。`MCH:148` 必须改掉。

**★该残缺清单有第二处（2026-09-13 补）**：`MessageCollectionCoordinator+Heights.swift:195` ——
`measureUserBubbleHeight` 的精确路径用 `if text.contains("```") || text.contains("|")` 决定
「走 TextKit 精测」还是「走 CTFramesetter 快路径」。同一条残缺清单、同一后果（CT 不调用
`attachmentBounds` ⇒ 含图片/公式/分隔线的用户消息高度失真）。

**失真方向是偏矮** ⇒ cell 需要**增长** ⇒ 手势期放行 ⇒ **不产生空白**，但会造成首次实测时的一次
可见跳变。故优先级**低于**已修的估高同源两笔（那两笔是高估 ⇒ 直接变空白）。
修法同上：换成 `AssistantBlock.hasRichSyntax(text)`。

### 2.4 `hasRichSyntax` 自身漏判行内 `$...$`

`RenderModels:407-408` 注释自认：源文启发式只查 `$$`，漏了行内 `$...$`（parser 会产出 MathAttachment）⇒ 源文启发式**永远只能保守**，权威是产物判据 B1。`Snapshot:440` 已用 `hasRichSyntax(c) || attr.hasAnyAttachment` 打补丁。

### 2.5 CT 补偿 `+12` vs `+8`，且疑似漏加 chrome

- `+8` = `textContainerInset(4+4)`（`MDText:131`、`MCH:28`、`MCH:144`、`Snapshot:663`）。
- `+12`（`MCH:287`）语义是 **CT 与屏上渲染引擎的高度差补偿**（`MCH:274-277`：矮 12.3pt；`MDView:1163-1164`：CT 1699 vs TextKit 1712），**不是** inset。
- assistant 块还需额外 `assistantBlockVerticalChrome = 4`（`Infra:416`），在 `MCH:284` 与 `Snapshot:690` 明确相加。

**推断（未确认，需真机核对）**：若 CT 与 TextKit 的真实差约 12.3pt，则 `MCH:287` 的 `textH+12 ≈ TextKit 高`，**漏掉了 +4 chrome**；而缓存命中路径 `MCH:284` 给的是 `TextKit+4`。建议统一为一个函数，且 assistant 块内 chrome 只加一次。

### 2.6 内容键 `w:` 与回退常量 118/48 成对耦合

`Layout:244-252` 用 `parts.last`（附件数）决定兜底 118/48，注释明确"与 `contentKey(for:)` 格式成对耦合，改格式须同步"。任何改 A8 格式的动作必须同时改 A18。

### 2.7 子代理链路独立实现

`Bubble:189/213` 与 `Row:185-188` 同义但不同代码；`SubagentChatView:10` 注释明说"仅子代理详情页仍走 MessageBubbleView，两侧缓存/分段逻辑独立"。统一时要么同步，要么在规格里显式标注为**有意独立**（建议后者，避免扩大 P6 面）。

### 2.8 用户文本剥离 `<user-attached-files>` 两份

`MCH:83-89` 与 `Row:169-178` 是逐字同款的两份实现（不属"计数"但属"同一事实多处表示"）。可顺带收口。

### 2.9 ★新增发现（2026-09-13 晚）：估算器可用宽比真实渲染窄 48pt ⇒ 系统性**高估**

`estimateTextBlockHeight`（`MCH:324-326`）用 `let hPad: CGFloat = 80` ⇒ `tw = max(width-80,100)`，
再由 `cpl = tw/(scale*0.5)` 估每行字数。而**真实渲染与精确测量的可用宽是 `width-32`**
（`Snapshot:677`、`Snapshot:693` 等一律 `max(cvWidth-32,100)`）。

⇒ 估算的每行字数偏少约 15%（390pt 宽 CV：310 vs 358）⇒ 行数偏多 ⇒ **高度系统性偏高**。

**为什么这条值得单独标注**：`deferSelfSizing` 的手势期策略是「**只拒绝收缩**、增长放行」
（`L:390-414`）。于是**任何系统性高估都会在拖动期间变成可见空白** —— 帧比内容高出的那一截就是空白，
而收缩被拒 ⇒ 只有松手 settle 才消失。这与原始症状（「手不离开屏幕就出现空白，一松手就没了」）
**完全同构**。

**同类的其它口径**：用户气泡回退路径 `MCH:250-255` 用 `cvWidth-80`，主路径 `MCH:101` 用
`cvWidth-32-60`（＝−92）；`estimateItemHeight` 的 user 分支也用 `hPad = 80`（`MCH:239-240`）。
⇒ **三套可用宽基数（−80 / −92 / −32）并存**，属 §2.1 同一病根。

✅ **已修（`d723027`）**：`hPad` 已由 `80` 改为 `32`，即与渲染真相 `cell 宽 − 2×blockHPadding` 同源。
改动只落在这一个函数（全库唯一调用点是 `estimateItemHeight` 的 `.text` 分支）。
**未一并改的**：`estimateItemHeight` 的 user 回退（`-80`，比真实的 `-120` 更**宽** ⇒ 偏短 ⇒ 安全侧）
与 user 瓦片基数（`-92`，已与 `measureUserBubbleHeight` 一致）。

**取向纪律（可复用）**：本函数的估算应取「**宁短勿长**」—— 低估的高度会在首次实测时**增长**
（手势期放行、不产生空白），而高估会被冻结成空白。

## 3 `+12` 与 `MCS:630` 的真实身份

### 3.1 `+12`

`MCH:286-287`：assistant 文本块在统一高度缓存 miss 时的**估算回退**（命中走 `MCH:283-284`）。
**不是间距、不是 padding、不是行高系数**；是 **CTFramesetter 结果 → 屏上渲染引擎高度的经验补偿**（`MCH:274-277` 记为 12.3pt）。与 `+8`（= `textContainerInset`）**严格不同义**；与 `chrome=4` 的关系见 §2.5，**倾向漏加，标未确认**。

### 3.2 `MCS:630`

**文档行号已漂移**。当前 `MCS:630` 原文是 `lastMessageBlockCountSub?.cancel(); lastMessageBlockCountSub = nil`，与附件/CT 无关（`MCS` 的重构已把代码拆到 `+Heights` / `+Snapshot`）。文档所指「走 CT 回写高度的落点」真实位置是：

- **`Snapshot:682`**：`height = ctFramesetterHeight(...) + 8`，随后 **`Snapshot:686-687` 回写统一缓存**（`MarkdownRenderCache.shared.store(height:key:width:)`），再 **`Snapshot:690`** `setPrecalcHeight(height + chrome, at: i)`。← "CT 测量 → 回写高度表"的完整落点。
- 对照落点：**`MCH:287`**（CT+12、**不回写缓存**，直接 return 作为估算）。

两者同源不同口径（一个 +8 回写、一个 +12 不回写），正是 S3 要消的"两个不一致落点"。

## 4 统一后的结构判据建议

### 4.1 落点与签名

**(a) 消息级 —— 落在 `RenderMessage`（`RenderModels:283`）**

```swift
extension RenderMessage {
    /// 唯一附件来源（主链路 user 气泡瓦片；与 ChatMessageRow / 高度估算共用）
    var displayAttachments: [AttachmentMeta] { attachments }
    var attachmentCount: Int { attachments.count }
    var hasAttachments: Bool { !attachments.isEmpty }
}
```

> 明确以 `attachments` 为唯一口径。`inputAttachments` 需先裁决存废（§2.2）；若保留排队语义，应正式在 Bridge 写入并统一展示数组，否则删除死回退。

**(b) 附件瓦片高度 —— 唯一函数（先保持数值等价）**

```swift
enum AttachmentTileMetrics {
    // 现有估算口径（P6 保持不变，保证行为等价）
    static let estimatedTile: CGFloat = 70
    static let estimatedRowSpacing: CGFloat = 6
    static func estimatedHeight(count: Int, availableWidth: CGFloat) -> CGFloat  // rows*70 + 6

    // 渲染真实口径（独立待办：对齐 UserAttachmentList；改它会动高度数值）
    static let renderTile: CGFloat = 64          // Stubs:725
    static let renderPerRow = 4                  // Stubs:741
    static let renderRowSpacing: CGFloat = 6     // Stubs:739/744
    static let renderDocumentHeight: CGFloat = 40 // Stubs:791
}
```

**(c) 富文本附件 —— 落在 `AssistantBlock`（`RenderModels:336` extension）**

```swift
extension AssistantBlock {
    /// 统一结构判据：渲染产物优先（权威），源文启发式兜底（保守）。
    var hasRenderableAttachment: Bool {
        if let a = cachedAttributedString, a.length > 0 { return a.hasAnyAttachment }
        return Self.hasRichSyntax(content)
    }
}
```

### 4.2 调用点改用它

| 原判据 | 改为 |
|---|---|
| `MCH:91-92`、`MCH:100`、`MCH:110` | `message.attachmentCount` + `AttachmentTileMetrics.estimatedHeight(...)` |
| `MCH:211` | `msg(id)?.attachmentCount ?? 0` |
| `MCH:250-255` | 调同一 `AttachmentTileMetrics.estimatedHeight(...)`（或整段删除） |
| `MCH:148` | `AssistantBlock.hasRichSyntax(text)`（或 `block.hasRenderableAttachment`） |
| `Snapshot:669` | `block.hasRenderableAttachment` |
| `Snapshot:440` | `blk.hasRenderableAttachment`（把 OR 收进去） |
| `RenderModels:390`、`412` | 收敛进 `hasRenderableAttachment`（产物优先） |
| `Row:185-188` | `if !message.displayAttachments.isEmpty { UserAttachmentList(...) }`（回退分支按 §2.2 裁决） |
| `MCH:25`、`MDView:731/1144/1218` | **保持 `hasAnyAttachment` 不动**（手里已有产物，最权威） |
| `MCH:284`、`Snapshot:682/690` | 统一到"CT/TextKit 高 + chrome"单一入口（chrome 只加一次） |
| `Layout:244-252` | 与 `contentKey` 编码/解码成对；建议把 `w:` 的 encode/decode 收进同一类型（如 `ContentKey`），杜绝单边改 |

### 4.3 应删除（成为冗余）

1. `MCH:148` 的内联残缺清单 ``text.contains("```") || text.contains("|")`` —— 被 `hasRichSyntax` / `hasRenderableAttachment` 取代。
2. `MCH:250-259` 的第二套 `imgH` 公式 —— 与 `MCH:100-104` 合并为单一函数（当前只在 `measureUserBubbleHeight` 返回 nil 时到达，数值等价）。
3. `MCH:91-92` 的 `inputAttachments` 三元回退 —— **前提**是确认 `inputAttachments` 废弃。
4. `RenderModels:390` 的中间布尔 `hasAttachmentSyntax` —— 并入 `hasRenderableAttachment`。
5. （可选）`MCH:83-89` 与 `Row:169-178` 两份 `<user-attached-files>` 剥离 —— 抽为一个共享函数。

## 5 不能改的行为（错误判据的后果）

| 不可动 | 位置 | 破坏后果 |
|---|---|---|
| 内容键末段**必须是附件数** `w:<msgId>:<字数>:<附件数>` | `MCH:212` 生成 + `Layout:251-252` 反解 | 附件异步挂载 `0→1` 时新键无条目/无 memo → 落 200 兜底，真值 118 → **顶部整块差 82pt（肉眼顶部抖动）**（`Layout:245-249` 实测） |
| 附件数变化必须使**内容键变化** | `MCH:211` | 附件张数算错 → 键不变 → memo 命中旧高 → **附件挂载后高度不更新** |
| 含附件块**不得进进程级共享缓存** | `MDView:731/1144/1218`、`RenderModels:407-414`、`Snapshot:473-474` | 附件实例与 renderer 身份耦合，进缓存即**串味**（`RenderModels:351-352`） |
| **CT 不得用于含附件的字符串** | `MCH:20-25`、`Snapshot:665-668` | CT 不调用 `attachmentBounds` → 高度塌陷 → 首帧矮一大截 → **流式结束跳高 + 上滑抖动** |
| `assistantBlockVerticalChrome = 4` 只加**一次** | `Infra:416`；`MCH:284`、`Snapshot:690` | 漏加 → 高度偏矮/裁尾；重复加 → 高度偏大/空白 |
| 已完结块必须走同源 TextKit，CT 仅限流式 | `MDView:1160-1168`、`MCH:283-284`、`Snapshot:651-689` | CT 值被 `.fixedSize(vertical:true)` 钉死 → **尾部半行永久被裁** |
| user 气泡三态总高 | `MCH:107`（纯附件）、`MCH:139`（cheap）、`MCH:157`（精确） | 附件高度算错 → **拖动期空白 / 上滑抖动**（M1、M5） |
| memo key 的附件数须与内容键同口径 | `MCH:110` vs `MCH:211` | 两者分叉 → memo 命中与内容键失效不一致 → 高度时对时错 |
| `hasRichSyntax` 的**保守性**不可"优化" | `RenderModels:358-365` | 漏判 → 放行附件产物进缓存 → 串味 |
| 手势期禁收缩门（与附件高度估计耦合） | doc §4/§6；`MCH` 用户气泡路径 | 放宽会把 −160pt 抖动放回来 |

## 6 不确定 / 未确认

1. **`+12` 是否已含 chrome=4**：代码证据指向"含 CT→TextKit 差(≈12.3)但不含 chrome"，需真机对同一块比对 `MCH:284` 与 `MCH:287` 两条路径的实际值确认。**未确认**。
2. **`inputAttachments` 是否有仓外写入方**：全仓 grep 无赋值点，判定**高置信恒空**；不排除外部模块通过 public 属性赋值。
3. **`Stubs:166 QueuedAttachmentPreview.body == EmptyView()`**：若该桩将来被替换为真实预览，A15 的高度口径会立刻变成 bug。
4. **`Layout:252` 的 118/48 常量**：属 A18 兜底，P6 不应改动其数值。

## 一句话结论

先把「附件计数」和「附件高度」各收敛为**一个**消息级计算属性/函数（`RenderMessage.attachmentCount` + `AttachmentTileMetrics`），把「富文本附件判据」收敛为**产物优先的单一谓词**（`AssistantBlock.hasRenderableAttachment`），并把 `+8/+12/chrome(4)` 的 CT 换算收进**一个**入口；同时**冻结** `w:` 内容键格式、`hasAnyAttachment` 的缓存门与「CT 禁用于附件串」三条等价性护栏。删除 `MCH:148` 残缺清单、`MCH:250-259` 重复公式、`inputAttachments` 死回退是净收益；而「70→64、动态列→固定 4 列、文档每行 40pt」会改变高度数值，属**独立 bug 修复**，须在 P6 之外另开一笔。
