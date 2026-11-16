# MiniClaw 缓存清单（只读盘点，2026-11-17）

> 状态：**仅盘点，未改任何代码**。
> 目的：需要时能一眼看清"哪里有缓存、存什么、怎么失效、有什么风险"，避免以后再靠 grep 重新发现一遍。
> 方法：逐文件阅读 + 关键字全量扫描（`NSCache` / `URLCache` / `cachesDirectory` / `UserDefaults` / `JSONEncoder` / 静态变量），行号均已核对。

---

## 0. 一句话结论

- 缓存分五类：**渲染文本**、**网络远端**、**持久化数据**、**图片媒体**、**状态单例**。
- 内存大头是**渲染缓存**（MarkdownRenderCache 1024 条 + 行高缓存）。
- 全 App **只有一处"持久化且无清理"的缓存**：图片尺寸表 `MiniClawImageSizes_v1`。
- **没有统一的缓存登记与清理中心**：存储页只能清浏览器/会话类，渲染类清不掉。

---

## 1. 渲染与文本（内存占用最大）

| 缓存 | 位置 | 键 → 值 | 生命周期 / 上限 | 失效方式 | 风险 |
|---|---|---|---|---|---|
| `MarkdownRenderCache` | `MiniClaw/Views/Chat/Render/MarkdownView.swift:23` | (块 id, 宽度) → 富文本 + 高度 + 来源等级 | 进程内，**上限 1024 条**，按时间戳 LRU 淘汰（`:184`） | 按 key 覆盖；低等级高度不得覆盖高等级（engine > ct > prewarm） | 按"条数"限流而非字节；超长回复单条可达数 MB |
| `MessageHeightCache` | `MiniClaw/Views/Chat/List/MessageHeightCache.swift:19` | 行身份 → 高度 + 内容键 + 来源 | 进程内 | 内容键不一致即过期；reset 整表清空（`:136`） | 键若不含状态，横幅/工具行变更后高度会陈旧（本次已踩过） |
| 布局测量 memo | `MessageListLayout`（`MiniClaw/Views/Chat/List/MessageListLayout.swift`） | 内容键 → 实测高度（进程级去重） | 进程内 | `invalidateHeight(at:)` 指定剔除 | 忘记失效就会一直用旧值 |
| 块级渲染缓存 | `AssistantBlock.cachedMarkdown / cachedAttributedString`（`MiniClaw/Views/Chat/List/RenderModels.swift:313`） | 单块的 Markdown / 富文本 | 块存在期间 | 内容变更时置 nil | 曾有"空串当有效值"导致空白死锁（已修） |
| `NativeMediaImageCache`（图） | `MiniClaw/Views/Chat/Render/MarkdownAttachments.swift:278` | URL → UIImage | 进程内 `NSCache`，**countLimit 50**（`:287`） | 系统内存压力 / 手动剔除 | 50 张限制对长图文会话偏紧，会反复解码 |
| `NativeMediaImageCache`（尺寸） | 同上 | URL → CGSize，存 **UserDefaults `MiniClawImageSizes_v1`** | **跨启动持久，无上限** | 无（只增不减） | 唯一"持久化且无清理"的缓存；换图/删图后旧 key 永久残留 |
| `NativeMediaImageCache`（负缓存） | 同上（`:310`） | 失败 URL → 时间戳 | 60 秒 TTL | 到期自动放行 | 失败一次后 60s 内不再重试（符合预期） |
| 附件排版键 | `MiniClaw/Views/Chat/Render/MarkdownAttachments.swift:1322` | 附件参数 → 布局 | 进程内 | 随 cell 复用 | — |
| 主题图片 | `MiniClaw/Services/Theme/ThemeManager.swift:62` | 主题图 | 进程内 `NSCache` | **未设 countLimit** | 只靠系统内存压力回收 |
| 气泡缩略图 | `MiniClaw/Views/Chat/MessageBubbleSubviews.swift:17` | 图片缩略图 | 进程内 `NSCache` | **未设 countLimit** | 同上 |

---

## 2. 网络与远端

| 缓存 | 位置 | 内容 | TTL / 策略 | 失效 | 风险 |
|---|---|---|---|---|---|
| OpenRouter 模型目录 | `MiniClaw/Services/Providers/OpenRouterCatalog.swift:187` | 模型/价格/能力索引（磁盘 JSON + `savedAt`） | **24 小时**（`maxAge`，`:22`） | 到期重拉；写盘失败仅记日志 | 新模型/调价最多延迟一天可见 |
| MCP 工具发现 | `MiniClaw/Services/RemoteMCPTool.swift:4` | 远端 MCP 工具列表（磁盘 JSON） | 失败 **60s** TTL（`:19`）+ stale-while-revalidate（`:80`） | 过期先返回旧列表再刷新 | 列表短暂陈旧属设计预期 |
| `URLCache.shared` | 清理点 `MiniClaw/Services/BrowserEngineAdapter.swift:123` | 系统 HTTP 缓存 | **未显式配置**，走系统默认 | 仅"清除浏览器缓存"时整体清空 | 行为随系统变化，无策略可查 |
| WebKit 缓存 | `MiniClaw/Services/BrowserEngineAdapter.swift:117` | 磁盘/内存/离线缓存 | 系统管理 | 同上；大小统计见 `MiniClaw/Views/Browser/BrowserSheetSettingsView.swift:142` | 体积不可控，仅能整体清 |
| 浏览器标签池 | `MiniClaw/Services/Browser/MiniClawTabPool.swift` | 复用 WKWebView | 数量受 `settings.browser.maxTabs`（`:157`） | 关标签即释放 | 标签多时内存线性增长 |
| Token 估算单槽 | `MiniClaw/Services/ContextUsageEstimator.swift:205` | 最近一次估算结果 | 单槽覆盖 | 下次估算替换 | 无 |

> ⚠️ **不要混淆**：`AnthropicCacheControl`（`MiniClaw/Services/AnthropicModels.swift:50`）与 `CachePrefixFingerprint`（`MiniClaw/Services/AgentLoopHelpers.swift:122`）是发给模型的 **prompt cache 标记**，不是本地缓存，不需要清理。

---

## 3. 持久化（是数据，不是缓存）

| 数据 | 位置 | 说明 |
|---|---|---|
| 会话与消息 | `MiniClaw/Services/Storage/SQLiteStore.swift` | SQLite；`SessionManager.load()` 后台异步（`MiniClaw/Services/SessionManager.swift:44`） |
| 设置 | `MiniClaw/Services/SettingsStore.swift:65` | JSON 落盘（原子写） |
| 浏览器历史 | `MiniClaw/Services/Browser/MiniClawHistoryStore.swift` | `Application Support/MiniClaw/lastVisit.json` |
| Cookie 备份 | `MiniClaw/Services/Browser/MiniClawCookieBackup.swift` | 登录态恢复用 |
| 工作区 / 附件 / 会话缓存目录 | `MiniClaw/Services/SessionFileRouter.swift` | `Documents/MiniClaw/...`，存储页可清 |
| 运行日志 | `Documents/MiniClaw/logs` | 受日志开关控制 |

---

## 4. 状态与单例（内存态）

| 名称 | 位置 | 内容 | 刷新时机 |
|---|---|---|---|
| `SoulStore.cachedMetadata` | `MiniClaw/Services/MiniClawHostStubs.swift:437` | 助手身份（名称等） | **未发现刷新点**：本次全库搜索只有声明与注释，实际可能恒为默认 "MiniClaw"（待确认） |
| `MiniClawHostStubs.marks` | `MiniClaw/Services/MiniClawHostStubs.swift:276` | 同会话字节标记（去重用） | 运行期累积 |
| `SessionManager.sessions` | `MiniClaw/Services/SessionManager.swift:7` | 全部会话对象 | 权威数据源，不是缓存 |
| `UserDefaults` | 共约 40 处引用 | 绝大多数是偏好；**唯一数据型缓存是 `MiniClawImageSizes_v1`** | 即时写 |

---

## 5. 风险排序（按"会不会真出事"）

1. **高 · 渲染缓存按条数限流**：1024 条上限，但单条富文本可能几 MB；长对话下有内存尖峰。
2. **高 · 图片尺寸表只增不减**：`MiniClawImageSizes_v1` 跨版本累积，无清理入口。
3. **中 · 两个 NSCache 没设上限**（主题图、气泡缩略图）：完全依赖系统回收。
4. **中 · `URLCache` 无显式策略**：现在能用，但不可控、不可解释。
5. **低 · 模型目录 24h 陈旧**：可接受，但用户"新模型看不到"时会困惑。

---

## 6. 结构性缺口（不是 bug，是缺基础设施）

- **没有缓存登记表**：每个缓存各写各的 key、各定各的上限，只能靠 grep 发现。
- **没有统一清理入口**：存储页只覆盖浏览器/会话类；渲染缓存、图片尺寸表、MCP 发现、模型目录都无法手动清。
- **命名不统一**：`cachedXxx` / `xxxCache` / `marks` / `memo` 混用。

---

## 7. 如果以后要动，建议顺序

1. 建**缓存登记表**（名称、key 前缀、上限、清理方式、归属模块）；
2. 渲染缓存改成**按字节**计上限；
3. `MiniClawImageSizes_v1` 加版本号 + LRU 上限；
4. 存储页扩成统一「清除缓存」面板，把上面各项挂进去；
5. 顺手统一命名与注释规范。

---

## 8. 自查命令（下次要复核时用）

```bash
cd MiniClaw
grep -rn "NSCache<" --include=*.swift .
grep -rn "URLCache" --include=*.swift .
grep -rn "cachesDirectory" --include=*.swift .
grep -rn "UserDefaults.standard.set" --include=*.swift . | head
grep -rn "static var .*Cache\|private static var" --include=*.swift Services Views
```

---

## 9. 置信度

- **已核对**：本文出现的所有文件与行号均为实际读取结果。
- **未覆盖**：Widget / Share Extension 跨进程共享数据的细节（App Group 在 entitlements 中声明，但 App 侧未发现 `UserDefaults(suiteName:)` 使用），如需确认需单独查扩展目标。
