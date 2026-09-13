# MiniClaw 代码库系统性清洗报告

- **日期**：2026-09-13
- **分支**：`main`（HEAD `edec5ec`）
- **执行**：爪爪 + 3 个子代理（重复识别 / 命名与出入口一致性 / 死代码与类型分类）
- **准入标准**：本轮**只做零行为改动**；凡「可能引入不可估量风险」一律停手并转汇报
- **结论**：单次编译起点已 green，本轮 **4 次增量编译全绿**，可交付

---

## 0 交付摘要

| 指标 | 数值 |
|---|---|
| 删除代码 | **696 行** |
| 删除资源 | **876 KB / 24 文件** |
| 重复实现收敛 | **4 处**（详见 §2.2–2.5） |
| 悬空 i18n 键清理 | 2 个 |
| 增量编译 | 4 次，**0 错误**（末次 7.4s） |
| 主动停手（转待决策） | **2 项**（详见 §3） |
| 改动文件 | 16 个（`MiniClaw/` + `project.yml`）+ KaTeX 资源 24 个 |

---

## 1 分工与交叉复核

| 子代理 | 职责 | 关键产出 | 我的交叉复核结论 |
|---|---|---|---|
| **A** 重复识别 | 找同体方法/重复序列/双轨实现 | 14 项，按收益/风险排序；明确标出 ⑪⑫⑬ 为**禁止合并** | 全部逐条自验；采纳 A/B 类，回避 C 类 |
| **B** 命名与出入口一致性 | 同名不同义、同义不同名、可访问性 | 43 个 `private` 类型仅文件内使用；4 处日志类别命名不一致；口径修正为 **15 文件**（初报 9 文件） | **推翻其一项**：「阶段二 6 文件」中 3 个实为活路径（§4.2） |
| **C** 死代码与类型分类 | 零引用类型与整文件资源 | 15 项零引用清单；D16 = 休眠渲染栈 576 行 | **推翻其一批**：5 个"整文件删除"目标**根本不存在**（§4.1） |

三方独立复核收敛一致的关键结论：休眠渲染栈 = **3 文件 / 576 行**（非 6 文件），且**不可直接删除**。

---

## 2 已执行的修复

### 2.1 KaTeX 整条死链（最大单项：-314 行代码 / -876 KB 资源）

**四重证据链**（缺一不可，任一不成立就不能删）：

| # | 证据 | 方法 |
|---|---|---|
| 1 | `KaTeXRenderer` / `KaTeXRenderResult` / `KaTeXRenderer.shared` **全库仅自引用** | Grep 全仓（排除 `第三方源码/`） |
| 2 | `isKaTeXPending` 声明 `= false` 后**全库从未写为 true**（仅 3 处读 + 1 处日志） | 说明接线是**被主动拆掉的残骸**，非"暂未启用" |
| 3 | **资源根本没进包**：`.xcode-sym/Debug-iphoneos/MiniClaw.app` 内无 `katex-render.html`、无字体 | 而 `KaTeXRenderer` **代码却编进了二进制**（203 处符号 / 9 处字符串）⇒ 一条已断掉、还白占体积的死链 |
| 4 | `project.yml:244` 声明了 `resources: MiniClawKit/KaTeX`，但**入库 pbxproj 无对应条目** | 再次印证 pbxproj 与 project.yml 漂移 |

**逐行对比**：

```diff
- MiniClaw/Views/Chat/Render/KaTeXRenderer.swift            （-314 行，整文件）
- MiniClawKit/KaTeX/                                        （-24 文件，-876 KB）
- project.yml
-       excludes:
-         - KaTeX                    ← sources 排除项
-     resources:
-       - path: MiniClawKit/KaTeX   ← 资源声明
-         type: folder
- MiniClaw.xcodeproj/project.pbxproj                        （-4 条目：buildFile / fileRef / group child / sources）
```

配套清理 `MarkdownAttachments.swift` 的残留标志位：

```diff
  private var didAttemptRender = false
- private var isKaTeXPending = false

- guard renderedImage == nil,!didAttemptRender,!isKaTeXPending else { return }
+ guard renderedImage == nil,!didAttemptRender else { return }

- if renderedImage == nil && !didAttemptRender && !isKaTeXPending {
+ if renderedImage == nil && !didAttemptRender {
```

> 效果：`MiniClawKit/` 目录由 876 KB 降至 **32 KB**；一个基于 WKWebView 的整条渲染栈（含其异步回调、脚本消息处理、缓存对象）从二进制中消失。

### 2.2 附件存在性扫描 **4 处 → 1 处**

原状：同一段「是否有任意 `NSTextAttachment`」扫描在 4 个位置逐字重复（子代理 A 只报出 3 处，**我复核补出第 4 处** `MarkdownView.swift:728`）。任一处判据漂移都会让「带附件块」走错测量路径（CT 快路径不调用 `attachmentBounds` ⇒ 高度塌陷 ⇒ 上滑抖动），属高危重复。

```diff
  // 新增唯一入口（MarkdownSupport.swift）
+ extension NSAttributedString {
+     var hasAnyAttachment: Bool {
+         guard length > 0 else { return false }
+         var found = false
+         enumerateAttribute(.attachment,
+                            in: NSRange(location: 0, length: length),
+                            options: []) { value, _, stop in
+             if value != nil { found = true; stop.pointee = true }
+         }
+         return found
+     }
+ }
```

四个调用点统一为：`!attributed.hasAnyAttachment` / `!pending.hasAnyAttachment` / `!liveStorage.hasAnyAttachment` / `!attrStr.hasAnyAttachment`，并删除 `+Heights.swift` 内的 `private static func hasAttachment(_:)`。

### 2.3 `findCollectionView()` **2 处 → 1 处**

`MarkdownTextView` 与 `TableCellTextView`（两个 `UITextView` 子类）各写了一份逐字相同的 superview 链查找，内侧共 8 个调用点。上提为：

```diff
+ extension UITextView {
+     func findCollectionView() -> NoAnimationCollectionView? {
+         var view: UIView? = superview
+         while let v = view {
+             if let cv = v as? NoAnimationCollectionView { return cv }
+             view = v.superview
+         }
+         return nil
+     }
+ }
```

### 2.4 `precalcHeight(at:)` 与 `cachedHeight(at:)` 逐字相同

```diff
  public func cachedHeight(at index: Int) -> CGFloat? {
      heightEntries[index]?.height
  }
-
- public func precalcHeight(at index: Int) -> CGFloat? {
-     heightEntries[index]?.height
- }
```

唯一调用点（`MessageListInfrastructure.swift:619`，流式 precalc 短路）改为 `cachedHeight(at:)`。同时修掉一处**已失效的注释**（原文写"cachedHeight/precalcHeight 对任意来源返回值"，现已单数）。

顺带清理 `[Collapse]` 诊断日志里恒等于 `beforeLayout` 的冗余字段 `beforePrecalc`（旧三字典时代残骸）。

### 2.5 文件内遗留私有死类型（4 个）

| 位置 | 类型 | 行数 |
|---|---|---|
| `AssistantBlockView.swift:479` | `private struct ToolCopyButton` | 21 |
| `ToolLiveSheet.swift:2155` | `private struct FloatingToolPreviewContainer` | 16 |
| `StorageSettingsViews.swift:422` | `struct StorageUsageRow` | 18 |
| `UnifiedFileBrowser.swift:394` | `func uniqueCopyName(for:in:)` | 14 |

四者全库引用数均为 **1（仅声明自身）**，且前两者为 `private`（文件内作用域，爆炸半径为零）、全部经编译器硬验证。

### 2.6 悬空 i18n 键

`uniqueCopyName` 删除后，`copy_of_format` / `copy_ext_format` 代码侧引用降为 0 → 从 `Localizable.xcstrings` 移除（2222 → 2220 键，diff 收敛为 **0 增 / 58 删**，零重排，四语同步）。

### 2.7 文档内最后一处第三方痕迹

`docs/ish-arm64-customization.patch:212` 的 `-` 行（记录上游原值的 queue label）仍含第三方组织名——该文件的其余部分此前已中性化，此处为**漏网一行**。已改为 `com.<vendor>` 并加注说明（注记用 `;;` 前缀，避免 `---` 被 `git apply` 误判为文件头）。

**全库复验**：Grep `openminis|minis\b`（排除 `第三方源码/`，大小写不敏感）→ **0 命中**。

---

## 3 主动停手（按纪律转待决策，未动一行）

### 3.1 休眠渲染栈：3 文件 / 576 行 —— ✅ 已于第二轮**执行删除**（见 §8）

`MarkdownRenderedText.swift`(178) / `MarkdownRenderView.swift`(307) / `MarkdownAttachmentViewFactory.swift`(91)

**为什么停手**：代码注释明确写着

> `[2026-09-08 17:00 止血回退] 双轨分流（MarkdownRenderedText）暂下线：…组件保留（MarkdownRenderView.swift / MarkdownRenderedText.swift），待完整真机回归后按专项计划重新接入。`

即这是**有明确书面计划的有意保留**，不是"完成迁移后的残骸"。技术上它确为零引用（编译可验证），但删除属于**替唐唐取消一个已记录的决策**，超出本轮授权。

> ⚠️ 三处子代理报告口径不一（A 报 576 行、B 一度按 6 文件分组、C 报 D16），**正确口径为 3 文件 / 576 行 / 7 处命中（1 定义 + 6 注释）**——各代理重复计。
> ⚠️ 同批文件中 `MarkdownSurface` / `MathRenderScheduler` / `MarkdownPrepRegex` **是活路径**，绝不可删（见 §4.2）。

### 3.2 未接线屏幕：5 个文件 / 约 378 行

| 文件 | 行数 | 全库引用数 |
|---|---|---|
| `Views/Settings/SyncSettingsView.swift` | 158 | 1（仅声明） |
| `Views/Home/SettingsMenuView.swift` | 82 | 1 |
| `Views/Settings/FeedbackSettingsView.swift`（`FeedbackView`） | 51 | 1 |
| `Views/Settings/SharedFolderSettingsView.swift` | 45 | 1 |
| `Views/Home/SearchView.swift` | — | 1 |

**为什么停手**：这**不是死代码，而更像产品 bug**——「已实现 + 零入口」意味着对应的设置页/搜索页**在 App 里根本进不去**。直接删除等于**把 bug 藏起来**，而唐唐的指令是「请修复所有排查出的隐藏 bug」。正确处置是补入口或明确废弃，需唐唐定夺。五项均 git 已跟踪，可随时恢复。

---

## 4 排查过程中的错误与纠正（必须记录）

### 4.1 ⚠️ 子代理 C 臆造了 5 个不存在的文件

C 报告「整文件删除 5 个，约 1040 行」：`PermissionGuideView.swift` / `GlassCard.swift` / `MessageListSnapshot.swift` / `AgentBlock.swift` / `TextBubbleMaterial.swift`。

**这 5 个文件磁盘上从未存在**：

| 检查 | 结果 |
|---|---|
| `git cat-file -e HEAD:<path>` | 5 个全部「不在 HEAD」 |
| `git log --all -- <path>` | 无任何历史记录 |
| pbxproj / project.yml | 零引用 |
| 构建产物 `.o` | 不存在 |
| **父目录 mtime** | `Views/Shared`=**09-08**、`Models`=**09-02**、`Views/Settings`=**09-11** —— **没有一个是今天** |

最后一条是决定性反证：**若刚才删过文件，父目录 mtime 必然是现在**。

⇒ **结论：无数据丢失。** 但这暴露了一个更危险的问题：子代理 B 的「词边界独立复核」对这 5 个不存在的文件**同样返回 0 命中**，于是两个代理**互相背书把幻觉"验证"成了事实**。若我未亲自复核文件存在性，就会照着删一批不存在的东西，并把"已清理 1040 行"写进交付报告。

### 4.2 ⚠️ 子代理 B 把活路径误判为待删新轨

B 一度把「阶段二 6 文件」整组归为待删新轨。经我独立验证：

| 文件 | 验证结论 |
|---|---|
| `MarkdownSurface.swift` | **活**：`MessageBubbleView.swift` ×3 + `DocumentView.swift:26` |
| `MathRenderScheduler.swift` | **活**：`MarkdownAttachments.swift:130` |
| `MarkdownPrepRegex.swift`（`prepareMarkdownForRender`） | **活**：`RenderModels.swift:396`、`+Heights.swift:142`、`MarkdownView.swift:588/1083` |
| 其余 3 个 | 确为休眠（见 §3.1） |

B 后续自行收回并收敛到 3 文件。三个代理最终结论一致。

### 4.3 ⚠️ 我自己的事故：xcstrings 整表重排

改 `Localizable.xcstrings` 时，我只校验了「语义等价 + 键顺序不变」，**漏掉工程笔记里那条最关键的前置断言**——`dump(原) == 原文件`（字节级往返）。结果 `separators` 写错（`: ` 与 ` : ` 之差）⇒ **41,608 行新增 / 41,666 行删除**，整张 2222 键的四语目录被重排。

**处置**：发现 diff 规模异常后立即 `git checkout --` 回退（确认 diff 归零），用候选格式探测确定原格式为 `indent=2, separators=(',', ': ')` + 尾换行，补齐**四条断言**（① 字节级往返 ② 新文本往返 ③ 仅少目标键 ④ 键顺序不变）后重做 ⇒ diff 收敛为 **0 增 / 58 删**。

**教训**：涉及格式敏感的生成式文件，**必须先断言"往返无差"再动内容**；只看语义等价不足以保护评审可读性。

### 4.4 ⚠️ BSD grep 静默漏检，本轮又踩 3 次

| 场景 | 症状 |
|---|---|
| `grep "A\|B"` ×2 | BSD grep 不支持 `\|` 交替 → **静默返回空**（我一度据此判定"无引用"） |
| `grep "\bName\b"` ×1 | BSD grep 不支持 `\b` → 7 个名字**全部返回 0**，差点被读成"全部是死代码" |

⇒ 铁律执行：一律改用 Grep 工具（ripgrep）；shell grep 的结论**不得直接采信**，必须有编译或第二证据兜底。

---

## 5 验证清单

| # | 验证项 | 命令/方法 | 结果 |
|---|---|---|---|
| 1 | KaTeX 链清除后增量编译 | `BuildProject` | ✅ 02:04:13，0 错误 |
| 2 | 附件扫描 + findCollectionView 收敛后编译 | `BuildProject` | ✅ 02:07:44，0 错误 |
| 3 | precalcHeight 合并 + 4 个私有死类型删除后编译 | `BuildProject` | ✅ 02:16:49，0 错误 |
| 4 | i18n 键清理后编译 | `BuildProject` | ✅ 02:18:53（7.4s），0 错误 |
| 5 | 全库残留扫描 | Grep `KaTeX` in `MiniClaw`/`MiniClawKit`/`pbxproj` | ✅ 0 命中 |
| 6 | pbxproj 结构完整 | 编译通过（工程可解析） | ✅ |
| 7 | 删除项可恢复性 | 全部经 `git rm`（已入库、可恢复） | ✅ |
| 8 | 运行目标无漂移 | `XcodeListRunDestinations` → 切 `唐唐的iPhone 16Pro` | ✅（默认被切回模拟器，已纠正） |
| 9 | 第三方源码未改动 | 全程只读 | ✅ |
| 10 | i18n 目录无重排 | `git diff --numstat` = `0 58` | ✅ |

---

## 6 明确未动（高风险，按纪律回避）

| # | 项 | 不动的理由 |
|---|---|---|
| ⑪ | `setEstimatedHeight` / `setPrecalcHeight` | 优先级语义**不同**，合并会改变「谁覆盖谁」——直接影响高度体系 |
| ⑫ | `updateCacheForSnapshot` / `remapHeights` | 同一 old→new 映射被连续执行两次，**正是历史"条目丢失"的来源**，触碰需完整回归 |
| ⑬ | `MarkdownView.sizeThatFits` 两段 ~50 行测量序列 | 两段缓存写入门控不同，合并会改变命中率 |
| — | 文本块 728.7↔735.0 振荡（±6.3pt / 0.9%） | 已知未修，按「不要改坏」取向判定不动 |
| — | `第三方源码/`、`Kit/` | 第三方内容，只读 |

---

## 7 下一轮建议

1. **`DEBUG` 编译条件从未定义**（`SWIFT_ACTIVE_COMPILATION_CONDITIONS` 只有 `ISH_ENABLED`）⇒ 全工程 43 处 `#if DEBUG` 块、约 547 行代码**从未参与编译**，其中含整个 `ScrollMetricsRecorder`。补齐会连锁暴露从未编译过的真实错误——**必须是独立整改任务**。
2. **待决策两项**（§3）：休眠渲染栈 3 文件 576 行；未接线屏幕 5 个（疑似产品 bug）。
3. **`第三方源码/` 53 MB 入库**：应确认已进 `.gitignore`，避免仓库持续膨胀。
4. **命名收敛**（子代理 B）：43 个 `private` 类型仅文件内使用；4 处 `fileprivate` 行构造常量在复制粘贴路径重复；4 处日志类别命名不一致。边界口径已修正为 15 文件。

---

# 第二轮：休眠渲染栈切割（已执行，唐唐授权）

**目标**：源码内 Markdown 渲染栈**只保留一套**，以存活链为标准；多余重复直接清除。**4 个子代理**并行排查后由我合成并执行。

## 8.1 路线裁决（决定"移植什么"）

4 个子代理之一（`approach-diff`）做了方法级对比，我的独立复核与其一致：**休眠栈在每个维度都是存活链的退化子集，无一项值得移植。**

| 做法 | 裁决 | 关键证据 |
|---|---|---|
| 自绘 TextKit1 承载视图 | **丢弃** | 存活链已在增量路径绕开 `UITextView` setter（`MarkdownView:781-784` `beginEditing/replaceCharacters/endEditing`）+ 同内容跳过赋值（`:792-796`） |
| `sizeThatFits = usedRect+8` | **丢弃（一票否决）** | 与 `Heights.swift:32-46` 真机证伪的「裸 `NSLayoutManager` 栈」**逐字同款**（同 `lineFragmentPadding=0`/`widthTracksTextView=false`/`usedRect+8`）→ 矮 12.3pt → 尾部半行永久被裁 |
| `invalidateCellSizeIfNeeded` 朴素失效 | **丢弃（一票否决）** | **不接** `MessageListLayout.deferSelfSizing`（存活链在 `MarkdownTextView:1146` 接了）——**"与 collection 自 sizing 未解回归"的根因就在这一个缺失的钩子** |
| 流式节流「窗内复用」 | **丢弃** | 存活链是超集：同 0.15s 窗 + 落后置脏（`MarkdownView:656-668`）+ 显式追赶 `scheduleStreamCatchUp`（`:1463-1473`）+ 脏态禁写高度缓存（`:1170-1185`） |
| 附件对账 | **丢弃** | 存活链严格超集：staleness 探测、防误删 `newViewSet`、`isRefreshingAttachments` 重入锁、表格拖拽延后、指纹短路 |
| `RenderOutputBox` / 离屏释放 | **丢弃** | 存活链已有等价物（`Measured*Box`、`MarkdownTextView:997-1003`） |
| **后台渲染 attributed**（`Task.detached`） | **仅记录为 backlog** | 存活链确实缺失（正文渲染恒在主线程，仅靠后台**高度预热**规避）；但不正交——需先解决「后台独立 TextKit 栈 vs 附件实例有状态测量」的锁覆盖（`MarkdownAttachments:13-26` 现锁只护字段存取）+ 补「渲染完成→主线程自 sizing 收敛」链路。**建议单独立项 + 真机验证，不顺手做。** |

⇒ **手术定为纯删除、零移植。** 移植那两个一票否决项 = 把已修复的裁尾/抖动回归重新引进。

## 8.2 执行内容

| # | 动作 | 量 |
|---|---|---|
| 1 | 删除休眠栈 3 文件 | **-576 行** |
| 2 | `project.pbxproj` 移除 12 处条目（3 文件 × buildFile/fileRef/group child/sources） | -12 行 |
| 3 | 改写 3 处悬空注释（`AssistantBlockView` 的 `textBlockView` / `MessageListInfrastructure` ×2），改为记录"该路线为何被否决"，不留被删类型名 | 3 处 |
| 4 | 清理孤儿：`AssistantBlockView` 内零引用的 `@Environment(\.openURL) openURLAction`、零引用的 `static func hasRichAttachmentSyntax`、以及上方一段描述已消失类型（"帧间隔监视器"）的孤儿文档注释 | -26 行 |
| 5 | **修复 R4 真实 bug**（见 §8.3） | 2 处 |
| 6 | **收敛 R2 重复**（见 §8.4） | 1 处 |

**⚠️ 关键纪律执行**：`cut-scope` 子代理建议"删文件 → `xcodegen generate` → 条目自动移除"，依据是 `ENGINEERING_DISCIPLINE.md:37`。**我没有采纳**——本工程入库 pbxproj 已与 `project.yml` 漂移（`ISH_ENABLED` 只存在于 pbxproj、KaTeX 资源只存在于 project.yml），重生成会产出**编不过的工程**（`cmark_gfm_extensions` 模块遮蔽）。故手工精确删除 12 行。

**防误删判定**：`MarkdownTextView` 里的同名物是**不同标识符**，全程保留并经 Grep + 编译双重验证：

| 休眠栈（已删） | 活路径（保留） |
|---|---|
| `rebuildAttachmentViews` | `rebuildAttachViews`（`:960`） |
| `refreshAttachmentFrames` | `refreshAttachViews`（`:675`） |
| `invalidateCellSizeIfNeeded` | `invalidateCellSizeIfChanged`（`:1131`，含 `deferSelfSizing` 钩子 `:1146`） |

## 8.3 🔴 修复的隐藏 bug（R4）：行内公式导致共享缓存串味

**根因**：同一个 `MarkdownRenderCache` 上有**两套互不相容的守卫**——
- 结构派：对**渲染产物**判 `hasAnyAttachment`（`MarkdownView:1148`）
- 启发式派：对**源文**判 `hasRichSyntax`（`RenderModels:411`、`Snapshot:431`）

而 `hasRichSyntax`（`RenderModels.swift:361-368`）只查 `$$`，**不查行内 `$...$`、也不查 `\(`**；但 `MiniClawMarkdownParser.swift:262-268` 明确会为行内 `$...$` 产出 `MathSpan(isBlock: false)` ⇒ `MathAttachment`。

**后果**：只含行内公式的块被判"无富语法" → 拿到 cacheKey → **把带 `MathAttachment` 的渲染产物写进进程级共享缓存**。而附件实例与 renderer/视图上下文**身份耦合**，共享即串味——这正是代码里反复警告的禁忌。且 `store` 首写胜出，**进会话时 `cacheRenderedContent` 通常先写 = 投毒**。

**修法（治本，最小）**：在两处启发式写入口补**结构判据**，对渲染产物本身再判一次，使写入口径统一：

```diff
  // RenderModels.swift:411
- if let cacheKey, let attr = cachedAttributedString {
+ if let cacheKey, let attr = cachedAttributedString, !attr.hasAnyAttachment {
      MarkdownRenderCache.shared.store(attributed: attr, key: cacheKey)
  }

  // MessageCollectionCoordinator+Snapshot.swift:392
- let rich = AssistantBlock.hasRichSyntax(c)
+ let rich = AssistantBlock.hasRichSyntax(c) || attr.hasAnyAttachment
```

复用本会话建立的单一入口 `NSAttributedString.hasAnyAttachment`（`MarkdownSupport.swift`）。**不采用**"给 `hasRichSyntax` 加 `$` 判断"的方案——`$` 在普通文本（如价格）中极常见，会给大量无附件块摘掉缓存资格，伤及该缓存存在的意义（消除"进会话白屏"）。

## 8.4 收敛的重复（R2）

`MessageCollectionCoordinator+Heights.swift:25-31` 内联重写了一份 `CTFramesetter` 测量，而 `MarkdownView.ctFramesetterHeight`（`:957`）已被其余 4 处调用。已改为复用：

```diff
- let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
- let ctHeight = CTFramesetterSuggestFrameSizeWithConstraints(
-     framesetter, CFRange(location: 0, length: attrStr.length), nil,
-     CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
- return ceil(ctHeight) + 8
+ return MarkdownView.ctFramesetterHeight(for: attrStr, width: width) + 8
```

等价性：共享实现用 `CFRange(length: 0)`（Apple 语义 = 整串）而内联版用 `length: attrStr.length`，二者同义；`+8` 由调用点承担，与 `:151`、`Snapshot:637` 口径一致。

## 8.5 明确未动（记账 backlog，非本次范围）

| 项 | 理由 |
|---|---|
| 后台渲染 attributed | 正交但需先解决锁覆盖与自 sizing 收敛链路（§8.1）——**单独立项 + 真机验证** |
| `MarkdownTextView.refreshAttachViews` 内部 3 条同构类型分发链 + 2 份逐字相同的 `onOpenURL` 闭包（`approach-diff` 认定） | 抽取会改变 stale 分支的类型覆盖范围（audio/file/thematicBreak 当前不走重建）——那是**行为修复**而非纯去重，须真机回归，故不混进本次切割 |
| 存活链自身缺陷线索：同 3 条链类型覆盖不一致（疑漏建） | 同上，转为独立修复项 |
| `+Heights.swift` 的 `measureAttributedStringHeight` 与静态 `measureTextView` 合流 | 属**前置重构**（`MarkdownView` 的 `ctFramesetterHeight` 也是 `@MainActor`，需先分清哪些调用点本就在主线程/本就持有 `@MainActor` 上下文），改动面大 |
| `MarkdownSupport.swift` 杂物袋拆分（9 处可迁出） | 本工程**不能跑 xcodegen**，新增文件需手改 pbxproj，纯目录/分类整理收益低、构建风险非零 |
| `MessageBubbleView`（SwiftUI，子代理会话）vs `MessageCollectionView`（UIKit，主聊天）双活 | 两条**都活着**且已实证漂移；收敛方向为使 `SubagentChatView` 改走 UIKit 路径。但属**产品取舍 + 新适配层**，非死代码——需唐唐定方向后单独立项 |

## 8.6 第二轮验证

| # | 验证项 | 结果 |
|---|---|---|
| 1 | 删除后增量编译 | ✅ 0 错误（149.3s） |
| 2 | R4 + R2 改动后增量编译 | ✅ 0 错误（26.9s） |
| 3 | 休眠栈 4 个符号全库残留 | ✅ 0 命中 |
| 4 | 活路径同名物完好（`invalidateCellSizeIfChanged` / `rebuildAttachViews` / `refreshAttachViews` / `deferSelfSizing`） | ✅ 全部在位 |
| 5 | 工程可解析（pbxproj 手工删除 12 行后） | ✅ 编译通过 |
| 6 | 本轮累计改动 | 19 文件，**+94 / −1228** |

