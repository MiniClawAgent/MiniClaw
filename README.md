# MiniClaw

**在 iPhone 上运行一个能自己动手干活的 AI 助手。**

MiniClaw 是一个 iOS 原生的 AI Agent 客户端：它不只是聊天，还能读写文件、跑 Shell 命令、操作浏览器、调用 MCP 服务、跨会话记忆，并在后台继续干完活。模型由你自己接——OpenAI、Anthropic、Gemini、DeepSeek，或任何 OpenAI 兼容端点。

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/Platform-iOS%2016%2B-lightgrey)
![Language](https://img.shields.io/badge/Language-Swift%205-orange)

> English: MiniClaw is a native iOS AI agent app. It runs a full agent loop on-device: file tools, a real shell (iSH/Alpine), browser automation, MCP servers, skills/rules plugins, long-term memory, subagents, and background execution with Picture-in-Picture progress. Bring your own model provider.

---

## 目录

- [它是什么](#它是什么)
- [能做什么](#能做什么)
- [仓库组成](#仓库组成)
- [架构一览](#架构一览)
- [构建](#构建)
- [插件](#插件)
- [贡献](#贡献)
- [许可证](#许可证)

---

## 它是什么

市面上的 AI App 大多停在"对话"这一层：你问，它答，仅此而已。MiniClaw 的目标是把**执行**也交给它——像桌面上的 Agent 那样，给它一个工作目录、一套工具、一个能持续跑的环境。

为此做三件事：

1. **把工具做真**：文件读写、Shell（内置 iSH/Alpine）、浏览器自动化、日历提醒、图像 OCR、语音、MCP。
2. **把上下文做稳**：长对话的流式渲染、高度自适应、滚动锚定、提示词缓存分层——这些"不性感"的工程决定了长时间使用会不会崩。
3. **把扩展做开**：技能、规则、工具、人格、模型、MCP 全部是插件，用 Markdown + JSON 就能写。

---

## 能做什么

### 对话与渲染
- 流式 Markdown：代码高亮、表格、公式（LaTeX）、图片/音视频内联
- 深度思考块可折叠，工具调用以圆点形式挂在对应轮次旁，点开看详情
- 会话列表高度自适应，滚动不跳、不裁行
- 长回复结束自动重测，避免末行被输入框挡住

### Agent 能力
- **多轮工具循环**（上限 50 轮，带空转熔断）
- **子代理**：把任务拆给独立上下文的小助手，可续派、可关闭
- **记忆**：长期记忆 `MEMORY.md` + 每日记忆，可检索
- **提问**：需要用户决策时弹授权式对话框，不打断消息流

### 工具
| 类别 | 工具 |
|---|---|
| 文件 | `file-read` `file-write` `file-edit` `list-dir` `read-document` |
| 执行 | `shell-execute`（iSH / Alpine，支持后台轮询） |
| 联网 | `web-search`（插件，可接多种搜索源）、`browser`（导航/点击/读取/截图） |
| 系统 | `apple-calendar` `apple-reminders` `apple-contacts` `apple-maps` `apple-healthkit` `apple-homekit` `apple-notification` `apple-speak` `apple-speech` `apple-vision` `apple-image` `apple-photos` `apple-media` `apple-location` `apple-clipboard` `apple-nlp` `apple-device` `apple-open` |
| 其它 | `memory-get` `memory-write` `skill-load` `ask-user` `dispatch-subagent` `close-subagent` `miniclaw-plugin` `miniclaw-config` `sessions-cli` `remote-host` |

### 扩展
- **MCP**：Streamable HTTP / SSE / STDIO，工具自动发现 + 落盘缓存
- **插件**：技能 / 规则 / 工具 / 人格 / 模型 / MCP 六类，`.mpk` 打包
- **技能**：`SKILL.md` + `scripts/ references/ assets/`，按需加载正文，不占常驻上下文

### 后台
- 后台任务续期，切后台不中断
- **画中画进度条**：任务在跑时显示 16:9 悬浮窗，带会话标题与当前工具

---

## 仓库组成

MiniClaw 由三部分构成，主仓库是 iOS 客户端，另外两块是它依赖的运行时与扩展。

| 部分 | 位置 | 说明 |
|---|---|---|
| **iOS 主项目** | [`MiniClaw/`](MiniClaw) · [`MiniClaw.xcodeproj`](MiniClaw.xcodeproj) | SwiftUI + UIKit 混合的 App 本体（iOS 16+） |
| **插件体系** | [`MiniClaw/Resources/BundledPlugins/`](MiniClaw/Resources/BundledPlugins) | 内置插件包（`.mpk`）；运行时解包到沙盒 `plugins/` |
| **iSH 运行时** | 外部依赖 | 内置的 Alpine Shell；arm64 静态库与 rootfs 不入库 |

### iOS 主项目

```
MiniClaw/
├─ App/            入口、生命周期、后台任务
├─ Views/          聊天、设置、插件市场
├─ Services/       Agent 循环、工具路由、MCP、浏览器、记忆、后台
├─ Models/         消息、块、插件、MCP 配置
├─ Tools/          内置工具实现
├─ AppIntents/     Siri / 快捷指令
└─ Resources/      本地化、内置插件、规则
MiniClawWidget/    Widget Extension
ShareExtension/    分享扩展
MiniClawKit/       跨 target 共用组件
```

### 插件

插件是 MiniClaw 的扩展单位，六种类型放在同一个目录下：

```
plugins/
├─ skill/<id>/   SKILL.md + scripts/ references/ assets/ evals/
├─ rule/<id>/    规则 Markdown（按语言分目录，启动注入提示词）
├─ tool/<id>/    工具插件
├─ model/<id>/   模型 / 网关
├─ soul/<id>/    人格
└─ mcp/<id>/     MCP 服务器配置
```

内置插件以 `.mpk`（zip）形式随包分发，首次启动同步进沙盒。写一个技能只需要一个带 frontmatter 的 `SKILL.md`：

```markdown
---
name: my-skill
description: 一句话说明什么时候用它
---

正文：模型按需加载后遵循的指令。
```

### iSH 运行时

Shell 能力来自 [iSH](https://github.com/ish-app/ish)（Alpine Linux 用户态）。本仓库**不包含** iSH 的源码与 rootfs：

- 上游：<https://github.com/ish-app/ish>
- 本项目使用自行编译的 arm64 版本（含 `sessionFsContext` 定制，用于把 `/var/MiniClaw` 映射进 Shell）
- 构建前需自备静态库与 rootfs，放置位置见 `MiniClaw/Services/iSH/`

> 如果你只想跑通聊天与插件部分，可以先不接 Shell；`shell-execute` 会返回不可用，其余工具不受影响。

---

## 架构一览

```
用户输入 → AgentLoopEngine → LLM Provider（流式）
               ↓ tool_calls
         ToolRouter → 工具（文件 / Shell / 浏览器 / MCP）
               ↓ 结果
      消息模型 → 高度管线 → UICollectionView
```

几个值得先知道的设计点：

- **提示词分 stable / volatile 两段**，稳定段逐字节不变以复用 KV 缓存。
- **工具名统一 kebab-case**，`ToolRouter.canonical` 是唯一规范化出口。
- **行高有三条入口**（播种、估算、实测），改动必须三处同步。
- **流式渲染挂起期间不 applySnapshot**，恢复时按"是否真的跳过"决定补刷。

细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，术语见 [docs/MiniClaw术语表.md](docs/MiniClaw术语表.md)。

---

## 构建

要求：Xcode 15+、iOS 16+ 设备或模拟器。

```bash
git clone https://github.com/TopFlowFox/MiniClaw.git
cd MiniClaw
open MiniClaw.xcodeproj
```

在 Xcode 的 *Signing & Capabilities* 里选择你自己的 Team，然后运行 `MiniClaw` scheme。

命令行构建：

```bash
xcodebuild -project MiniClaw.xcodeproj \
  -scheme MiniClaw \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

首次启动会在沙盒内生成工作目录：

```
/var/MiniClaw/
├─ attachments/  workspace/  shared/  offloads/  browser/
├─ memory/       SOUL.md / MEMORY.md / YYYY-MM-DD.md
├─ plugins/      skill / rule / tool / model / soul / mcp
└─ mounts/       外部挂载
```

---

## 贡献

- 提交前请先读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 的「关键约束」一节。
- 改动高度管线、提示词装配、工具命名这三块时，请同时检查它们的所有入口（见文档）。
- Issue / PR 用中文或英文都可以。

---

## 许可证

本项目采用 **GNU General Public License v3.0**，详见 [LICENSE](LICENSE)。

iSH 及其组件遵循其自身许可证（LGPL-2.1），见上游仓库。