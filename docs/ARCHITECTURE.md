# MiniClaw 架构说明

本文描述仓库的模块划分与关键数据流，面向准备阅读或修改代码的贡献者。
产品介绍见根目录 [README](../README.md)，术语见 [MiniClaw术语表](MiniClaw术语表.md)。

---

## 1. 总体结构

```
MiniClaw.xcodeproj          主 App（iOS 16+，Swift 5）
├─ MiniClaw/                主 App 源码
│  ├─ App/                  入口、生命周期、后台任务
│  ├─ Views/                SwiftUI 界面（聊天、设置、插件市场…）
│  ├─ Services/             引擎与系统能力（Agent、工具、MCP、浏览器、记忆…）
│  ├─ Models/               领域模型（消息、块、插件、MCP 配置…）
│  ├─ Tools/                内置工具实现
│  ├─ AppIntents/           Siri / 快捷指令入口
│  └─ Resources/            本地化、内置插件包（.mpk）、规则
├─ MiniClawWidget/          Widget Extension
├─ ShareExtension/          分享扩展（把内容丢进会话）
├─ MiniClawKit/             跨 target 共用的轻量组件（日志、公式渲染）
├─ MiniClawCLITools/        CLI 侧工具 target
└─ Shared/                  主 App 与扩展共享代码
```

一次对话的最小闭环：

```
用户输入 → AgentLoopEngine → LLM Provider（流式）
                ↓ tool_calls
          ToolRouter → 具体工具（文件/Shell/浏览器/MCP…）
                ↓ 结果
       消息模型（RenderMessage / AssistantBlock）→ 列表高度管线 → UICollectionView 渲染
```

---

## 2. 核心模块

### 2.1 Agent 循环（`Services/AgentLoopEngine.swift`）

- 负责拼请求、跑工具、回填结果、判断收敛。
- 工具循环上限 50 轮；连续无效工具调用会触发熔断，避免空转。
- 每轮把模型输出解析成两类：正文（流式）与 `tool_calls`。

### 2.2 提示词装配（`Services/AgentRunService+SystemPrompt.swift`）

system prompt 分两段拼装，目的是保住 KV 缓存前缀：

| 段 | 内容 | 特点 |
|---|---|---|
| **stable** | 共享前缀、人格（`SOUL.md`）、项目规则、技能元数据、记忆说明、子代理指南 | 每轮字节一致，进缓存 |
| **volatile** | 工具清单、环境变量、挂载、记忆、环境快照、子代理清单 | 放在缓存断点之后 |

共享前缀（工具铁律、文件系统布局等）定义在 `Services/AgentPromptCore.swift`，
主代理与子代理逐字节共用，否则多代理无法复用缓存。

排查提示词时可在「设置 → 关于 → 连点图标 10 次 → 开发者选项」打开**提示词转储**，
每轮会把实际发出的 system 原样写到 `logs/prompt-<时间>.txt`。

### 2.3 工具系统（`Services/ToolProtocol.swift`、`Tools/`）

- `AgentTool` 协议：`name` + `parameters` schema + `execute`。
- `ToolRouter` 是唯一注册表，**工具名统一 kebab-case（连字符）**：

  ```
  shell-execute, file-read, web-search, skill-load, ask-user,
  dispatch-subagent, close-subagent …
  ```

  `ToolRouter.canonical(_:)` 是唯一规范化入口（把 `_` 映射为 `-`），
  注册、校验、派发三处都必须经过它，不得各自造规则。

- MCP 工具的注册名由 `RemoteMCPTool.providerSafeName` 生成：

  ```
  mcp--<server>-<key8>--<tool>-<hash8>
  ```

  名字里带 hash 是为了在同一服务器重命名/重建后仍保持稳定（缓存友好）。

### 2.4 插件体系（`plugins/`，运行时在 App 沙盒内）

运行时目录 `/var/MiniClaw/plugins/<type>/<id>/`，类型包括：

| 类型 | 作用 |
|---|---|
| `skill` | 技能包（`SKILL.md` + `scripts/ references/ assets/ evals/`） |
| `rule` | 规则包（Markdown，按语言分目录，启动时自动注入提示词） |
| `tool` | 工具插件 |
| `model` | 模型 / 网关插件 |
| `soul` | 人格插件 |
| `mcp` | MCP 服务器配置 |

内置插件以 `.mpk` 形式放在 `MiniClaw/Resources/BundledPlugins/`，首次启动同步进沙盒。

### 2.5 MCP（`Services/RemoteMCPTool.swift`、`Services/MCP*`）

- 支持 Streamable HTTP / SSE / STDIO 三种传输。
- 工具发现结果落盘缓存，冷启动免握手。
- 工具名在注册时统一规范化（见 2.3），避免"模型调用名"与"注册名"分叉。

### 2.6 消息模型与列表渲染（`Views/Chat/`）

这是本项目最"重"的一块，因为流式长文本 + 高度自适应 + 滚动锚定很难同时满足。

| 组件 | 职责 |
|---|---|
| `RenderMessage` / `AssistantBlock` | 消息与块的领域模型；块有 `timelineOrder` 决定展示顺序 |
| `MessageListItem` | 行身份（整条消息 / 头像行 / 块 / 状态行） |
| `MessageListLayout` | 自定义 `UICollectionViewLayout`，按行高度布局 |
| `MessageHeightCache` | 行高缓存，带 `contentKey` 与来源等级（estimated < precalc < measured） |
| `MarkdownRenderCache` | Markdown 渲染结果缓存（引擎 > CoreText > 预热） |
| `MarkdownTextView` | 文本测量与裁剪防护（`usedRect` 优先、宽度不稳不许变矮） |

高度管线有三条入口，改动时必须同时覆盖：

1. 进会话时的**播种**（`seedHeight`）
2. 布局中的**估算 / 预算**（`estimateItemHeight`、`precalc`）
3. 渲染后的**实测**（`MarkdownTextView` 上报、`engineTextHeight`）

### 2.7 后台与画中画（`Services/Background/`）

- `BackgroundScheduler`：申请后台执行时间，按任务优先级续期。
- `TaskPipController`：用 `AVPictureInPictureVideoCallViewController` 做任务进度悬浮窗
  （16:9 面板 + App 图标 + 会话标题 + 工具状态）。

### 2.8 记忆（`Services/Memory*`、`memory/`）

- `SOUL.md`：人格，仅设置页可写。
- `MEMORY.md`：长期记忆，只能通过 `memory-write` 工具读写。
- `YYYY-MM-DD.md`：每日记忆，由模型追加。

### 2.9 Shell 与 iSH（`docs/` 之外，运行于 App 内）

- 内置 iSH（Alpine）作为 Shell 运行时，`shell-execute` 直接落到该环境。
- `/var/MiniClaw/` 是 App 暴露给模型的"工作目录"，映射到沙盒内对应目录。

---

## 3. 关键约束（改代码前请先看）

1. **工具名**只能有一个规范化出口（`ToolRouter.canonical`）。
2. **提示词**稳定段必须逐字节稳定，任何会变的内容都要放到 volatile 段。
3. **高度**只能在布局路径里提交，禁止在诊断探针里改几何。
4. **流式渲染**挂起期间不要 applySnapshot；恢复时按"真的跳过过"判断是否补刷。
5. **文件路径**统一 `/var/MiniClaw/...` 绝对路径，禁止目录穿越。

---

## 4. 构建

```bash
xcodebuild -project MiniClaw.xcodeproj \
  -scheme MiniClaw \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

需要 Xcode 15+、iOS 16+ 真机或模拟器；签名请在 Xcode 里选择你自己的 Team。