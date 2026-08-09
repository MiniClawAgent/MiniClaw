# MiniClaw 术语表(canonical glossary)

> 本文档是 MiniClaw 的**规范词汇表**(借鉴成熟项目的术语纪律):代码注释、UI 文案、规则文件、开发文档、记忆条目,对同一概念**永远只用一个词**。
> 用户可见文案可以更口语化,但**不得与本文档矛盾**。新增概念或发现混用时,先更新本文档再动手。

---

## 产品与整体

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **MiniClaw / miniclaw** | 产品名;代码标识符、工具名、序列化 key 一律用此前缀 | minis、Minis、其他项目名 |
| **万能 agent 应用** | 产品定位:通用智能体应用,非编程专用 | 编程助手、代码工具 |

## 会话与对话

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **会话** | 一段连续对话的容器(ChatSession / SessionManager)。UI 与代码统一 | 对话、聊天窗口、thread、conversation |
| **首页** | 会话列表页(HomeView) | 主界面、会话列表页(口头可,文档统一「首页」) |
| **消息** | 会话内一条记录(ChatMessage) | 气泡(「气泡」仅指渲染样式)、记录 |
| **回复** | assistant 角色消息的内容;「最终答复」= agent 循环最后一轮正文 | 回答、响应(响应=网络层) |
| **气泡** | 消息的 UI 渲染样式(MessageBubbleView) | 卡片(卡片=工具卡/消息卡) |

## 智能体体系

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **Agent / 智能体** | 主对话循环的执行体(AgentLoopEngine) | bot、机器人、AI 助手(泛称) |
| **主引擎 / 子代理引擎** | isSubagentEngine 区分的两类引擎 | 分身引擎(「复盘分身」是复盘特指,保留) |
| **子代理** | 由主 Agent 派发的独立子任务执行体(subagent;dispatch_subagent) | 分代理、副代理、sub-agent(连字符)、子智能体 |
| **子代理角色(Profile)** | 子代理的人设档案(SubAgentProfile,general/research/writer/planner) | 子代理技能、技能档案 |
| **复盘** | 会话结束后后台跑一次受限 Agent 整理记忆(SessionReviewService) | 回顾、总结(总结=摘要) |
| **后台任务** | 无 UI 的 headless 运行(快捷指令/AppIntent 派发,openAppWhenRun=false) | 无人值守任务、静默任务 |

## 记忆体系

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **记忆** | 跨会话持久信息的总称(memory 目录) | 记忆库、回忆、笔记 |
| **长期记忆** | MEMORY.md,跨会话;memory_write target "long_term" | 全局记忆、主记忆 |
| **每日记忆** | YYYY-MM-DD.md,当日日志;target "daily" | 日志(日志=App 调试日志)、日报 |
| **记忆开关 / 向量开关** | 「启用记忆」总开关 / 「向量召回」开关(embeddingEnabled) | 语义搜索开关 |
| **向量检索 / 嵌入** | embedding 检索与索引(MemoryIndexer / EmbeddingClient) | 词向量、语义匹配(口头可,文档统一) |
| **摘要** | 会话要点(summary / crossSessionSummarySection) | 总结、纪要 |
| **检查点** | 引擎恢复用的落盘任务状态(AgentTaskStore) | 存档、断点(断点=缓存断点) |

## 模型与厂商

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **厂商** | 模型供应商的技术概念(ProviderType / LLMProvider;代码、注释、规则文件统一) | 供应商 |
| **服务商** | 「厂商」的用户可见文案(设置页「AI 服务商」;仅 UI 使用) | 厂商(UI 内)、插件 |
| **适配器** | 单厂商协议实现(OpenAIProviderAdapter 等;LLMProviderAdapter 协议) | 适配层(口头可)、bridge(桥=iSH 桥) |
| **端点** | 请求地址解析结果(endpoint / ModelRouteEndpoint) | 接口地址、URL(泛称) |
| **能力表** | 厂商能力单一事实来源(ProviderType.responsesPath / embeddingSupport / supportsReasoningNone) | 白名单、配置表(口头可) |
| **主模型 / 副模型** | 主用途模型 / 后台用途模型(resolveBackgroundModelEndpoint) | 主模型组、后台模型 |
| **思考 / 思考档位** | reasoning 与档位(thinkingLevels;「深度思考」= 用户可见档位文案) | 推理(推理=reasoning 的技术名,可并存但文档统一「思考」) |
| **缓存断点** | 前缀缓存截断位置(稳定段/易变段边界,resolveVolatile / cache_control) | 断点(检查点语境禁用) |

## 工具与文件

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **工具** | Agent 可调用的能力单元(ToolRouter / AgentTool) | 函数、插件、技能(技能=SKILL.md) |
| **技能** | SKILL.md 驱动的可加载能力包(SkillManager) | 插件、技能包 |
| **规则文件** | BundledRules 注入 AI 的 Markdown(GLOBAL.md 等) | 指令文件、规范文件(口头可) |
| **挂载** | 用户外部文件夹挂载(MountStore;mounts 目录) | 映射、外挂目录 |
| **工作区 / 共享 / 转存** | 会话目录三子目录:workspace / shared / offloads | 工作目录、公共目录、缓存(缓存=系统缓存) |
| **附件** | 用户随消息附带的文件(attachments 目录) | 资源(资源=Assets)、文件(泛称) |
| **rootfs / 容器** | iSH Linux 运行环境(第三方源码/ish-arm64) | 虚拟机、模拟器、沙箱(沙箱=App 沙盒) |

## 生命周期与状态

| 术语 | 定义 | 禁用词(Avoid) |
|---|---|---|
| **运行中 / 已暂停 / 已中断 / 已完成 / 已取消** | Agent 五态(与 SubagentStatus 对齐) | 处理中(口头可)、停止(停止=用户操作) |
| **深链** | miniclaw:// URL 唤起(AppState deepLink / 快捷指令 x-success) | 链接(链接=回复中 http 链接) |
| **快捷指令** | iOS Shortcuts 集成(AppIntent:新建任务 / 继续会话) | 捷径、自动化 |

---

## 使用纪律

1. 写新代码/注释/文案前,先查本表;表中「禁用词」不要用在对应概念上。
2. 发现混用(代码注释、UI、文档、记忆不一致)时:**改代码侧对齐术语表**,术语表本身是单一事实来源。
3. 新增概念:先在本文档登记(定义 + Avoid),再写代码。
4. 用户可见文案允许口语化,但不得与定义矛盾(如 UI 写「服务商」不写「厂商」,技术文档写「厂商」不写「供应商」)。
5. 规则文件(GLOBAL.md 等)对 AI 的用词同样遵循本表(AI 输出里的「会话」「子代理」「技能」等与用户看到的一致)。
