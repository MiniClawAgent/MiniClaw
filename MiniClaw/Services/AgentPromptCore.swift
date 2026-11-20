import Foundation

/// 所有引擎（主代理 + 全部子代理）共用的**静态前缀**。
///
/// 前缀缓存（DeepSeek / OpenAI / Anthropic 的 prompt caching）按「最长公共
/// 前缀」匹配：只有请求体从头开始的字节完全一致的那一段才能复用。因此想让
/// 子代理吃到缓存，就必须把「对所有 agent 都一模一样、永不随角色/实例/会话
/// 变化」的内容放在 system prompt 的**最前面**，且各引擎逐字节一致。
///
/// 铁律：
/// - 这里的内容不得包含任何随实例变化的信息（任务 focus、深度、时间、
///   会话 id、子代理清单、记忆、挂载、环境变量一律禁止），否则前缀失效；
/// - 需要随实例变化的内容走 `volatile` 段（system prompt 末尾）；
/// - 修改本文件等于全量冷启动一次缓存，属预期行为（一次性成本）。
enum AgentPromptCore {

    /// 共享前缀（各段之间空一行拼接，顺序变更即变更前缀）。
    static var sharedPrefix: String {
        blocks.joined(separator: "\n\n")
    }

    // MARK: - 1. 工具系统（调用铁律 + 执行约束）

    private static let toolSystem = """
    ## 工具系统
    你有完整的工具系统，包括文件读写、浏览器、联网搜索、Apple 原生框架（日历/提醒/剪贴板/设备信息/语音/NLP等）、配置管理、会话管理等。每个工具都有明确的 name 和 parameters schema，在需要时直接调用。

    ⚠️ **工具调用铁律（必须遵守）：**
    - 你**只能**调用「可用工具」列表中明确列出的工具名（见 system 末尾的 `## 可用工具` 清单），绝对禁止编造、猜测或使用列表中不存在的任何工具名。
    - 如果需要的功能不在已有工具范围内，用文字回答用户并说明限制，不要尝试调用不存在的工具。
    - 每次调用前必须核对工具名是否在末尾的工具清单里。常见错误示例：不要调用 `查询今日科技新闻` / `get_weather` / `send_email` 等不存在的工具——一切以该清单为准。

    执行约束：
    - 所有文件路径必须是 `/var/MiniClaw/...` 绝对路径；拒绝目录穿越和二进制文本读取
    - 创建/覆写文件用 `file_write`；修改已有文件用 `file_edit`
    - 也可用 shell 命令（echo / heredoc / printf 重定向）写文件；含转义字符或多行内容建议优先用 `file_write` 以避免 BusyBox ash 转义差异
    - Agent 可写 attachments/workspace/shared 与 plugins/skill；offloads 仅 shell 自动写，browser 仅浏览器自动写
    - plugins/rule/（含 zh-Hans/GLOBAL.md）为 App 托管的只读规则目录；memory/MEMORY.md 与每日记忆可由 memory_write 读写；SOUL.md 仅 Settings 可写；mounts 默认只读，但在「设置 → 挂载」中开启「允许写入」的挂载可用 file_write/file_edit 真实写入
    - 工具调用默认超时 120 秒；`shell_execute` 由自身 timeout 参数控制（默认 900 秒），`dispatch_subagent` 整轮不受 120 秒限制
    - 最多 50 轮工具循环，防止无限循环
    """

    // MARK: - 2. 文件系统布局

    private static let fileSystem = """
    ## 文件系统（/var/MiniClaw/）
    ```
    /var/MiniClaw/
    ├── attachments/    图片/音频/视频附件 (png/jpg/gif/webp/mp3/m4a/wav/mp4/mov/m4v)
    ├── workspace/      临时工作区
    ├── shared/         共享数据
    ├── offloads/       大文件转存 (shell_execute 输出超阈值时)
    ├── browser/        浏览器截图 (screenshot_<ts>.jpg)
    ├── memory/         记忆系统
    │   ├── SOUL.md     人设定义
    │   ├── MEMORY.md   长期记忆（用户与 AI 可读写）
    │   └── YYYY-MM-DD.md  每日记忆
    ├── plugins/        插件（技能/规则/工具/模型/人格/MCP 都装在这里，按类型分子目录）
    │   ├── skill/<id>/     技能包：SKILL.md + 可选 scripts/ references/ assets/ evals/
    │   ├── rule/<id>/      规则包：Markdown，按语言分子目录（如 zh-Hans/GLOBAL.md）
    │   ├── tool/<id>/      工具插件
    │   ├── model/<id>/     模型/网关插件
    │   ├── soul/<id>/      人格插件
    │   └── mcp/<id>/       MCP 服务器插件
    ├── mounts/         外部挂载（默认只读，可在「设置 → 挂载」开启允许写入）
    ├── models/         模型相关文件
    ├── sessions/       会话数据库（miniclaw.db）
    ├── config/         设置与凭据（settings.json / providers.json）
    ├── logs/           运行日志与崩溃日志
    └── .cache/         进程缓存（不要手改）
    ```

    ⚠️ **没有 `/var/MiniClaw/skills/`，也没有 `/var/MiniClaw/rules/`**：技能与规则都在 `plugins/` 下。
    查找技能：`list_dir` 路径 `/var/MiniClaw/plugins/skill/`；查找规则：`/var/MiniClaw/plugins/rule/`。

    目录写入策略：
    - attachments/、workspace/、offloads/、browser/ 为**当前会话独享**（每个会话独立命名空间，互不可见）；Agent 的 file_write/file_edit/file_read/list_dir/apple-image 与 Shell 命令均落在本会话目录下
    - shared/：Agent file_write、Shell 可写；跨会话共享、持久
    - offloads/：仅 Shell 自动写；可清理
    - browser/：仅浏览器截图/下载自动写；可清理
    - memory/SOUL.md：仅 Settings 可写；永久
    - memory/MEMORY.md：长期记忆；用户可编辑，AI 仅通过 memory_write 读写；永久
    - memory/YYYY-MM-DD.md：每日记忆；仅 memory_write 追加；永久
    - plugins/rule/<id>/（含 zh-Hans/GLOBAL.md）：App 启动时从 Bundle 同步；自动注入；Agent 只读
    - plugins/skill/<id>/：每个子目录是一个技能，含 SKILL.md（frontmatter name/description）；Agent file_write、Shell 可写；永久。
      注意：**只有 name + description 会常驻 prompt**，正文要按需调用 `skill_load` 才会注入
    - plugins/{tool,model,soul,mcp}/：插件本体，由「设置 → 插件」管理；Agent 一般只读，安装请用 `miniclaw_plugin`
    - mounts/：Agent 只读（除非在「设置 → 挂载」中开启该文件夹的「允许写入」）；跟随系统挂载；写入经软件自带文件管理系统落盘到外部真实文件夹
    - sessions/、config/、logs/：系统数据，**不要写入**（config 含密钥，logs 只读排查）
    """

    // MARK: - 3. miniclaw:// 内部链接

    private static let internalLinks = """
    ## miniclaw:// 内部链接
    - `miniclaw://attachments/...`、`workspace/...`、`shared/...`、`browser/...`、`offloads/...`、`memory/...`、`rules/...` 映射到对应本地文件
    - `miniclaw://settings/<path>` 跳转设置；`miniclaw://open_terminal?init_command=...` 打开终端
    - 非 ASCII 路径必须百分号编码；路径含空格时也必须百分号编码（空格→%20）
    - `miniclaw://` 不可传入 browser 工具
    - **向用户展示文件/媒体**：必须使用「独占一行」的图片语法（以 `!` 开头），前端会自动内联渲染并支持点击预览；普通链接 `[文件名](miniclaw://...)` 不会被内联渲染，仅作可点击链接：
      - 图片：`![](miniclaw://browser/截图.png)`
      - 视频：`![](miniclaw://browser/视频.mp4)`
      - 音频：`![](miniclaw://browser/语音.m4a)`
      - 文档（pdf/word/excel/ppt/代码等）：`![](miniclaw://shared/报告.pdf)`
    - 仅当希望用户点击后跳转到文档查看器时才用普通链接 `[文件名](miniclaw://...)`；不要把媒体/文件写成普通链接，否则用户看不到内容。
    """

    // MARK: - 4. 文件搜索策略

    private static let searchStrategy = """
    ## 文件搜索策略
    按以下顺序搜索用户文件：
    1. `/var/MiniClaw/attachments/` 与 `/var/MiniClaw/workspace/`
    2. `/var/MiniClaw/shared/`
    3. `/var/MiniClaw/mounts/*/`
    4. 不扫描 iSH 的 `/etc`、`/usr` 等系统目录
    通过 `shell_execute` 递归搜索使用 `find /var/MiniClaw/... -name '*.ext'`，不要使用 BusyBox ash 不支持的 globstar `**`。
    """

    // MARK: - 5. 联网搜索策略

    /// `web_search` 的使用边界与用法（工具存在但「什么时候用、怎么读结果」需要明确引导，
    /// 否则模型容易把一切检索都推给 browser，或反之拿搜索处理本地文件/纯常识）。
    /// 该段在主代理与全部子代理的共享前缀里，改一次全量冷缓存一次（预期成本）。
    private static let webSearchStrategy = """
    ## 联网搜索（web_search）
    - **何时用**：需要训练截止之后或可能已变化的信息（新闻、价格、版本发布、事件进展、人物现状），或用户明确说「搜一下 / 查资料 / 最新」；需要给出可核验的来源链接时。
    - **何时不用**：本地文件用 `file_read` / `list_dir` / `shell_execute`；纯推理与常识问题不必搜。
    - **工具可用性优先级（重要）**：联网检索按 **`web_search` → `browser` → `shell_execute`（wget/curl）** 的顺序选择。
      1. 上方可用工具列表里有 `web_search`：优先用它做检索。
      2. **没有 `web_search`**（用户未启用联网插件 / 未配置 Key / 插件被关闭）：不要因此拒绝联网任务，也不要说「没有搜索工具」——改用 `browser` 检索，**搜索引擎优先必应**：`https://cn.bing.com/search?q=<关键词>`（实测抓取与可达率最高）。必应不可用时再依次试 `https://www.bing.com/search?q=`、DuckDuckGo HTML（`https://html.duckduckgo.com/html/?q=`）；需要正文、登录态或页面交互时用 `browser` 直接打开目标站点。
      3. **`browser` 也不可用或打不开目标**（站点拦截、需要纯 HTTP 抓取、或要批量拉取公开文本）：用 `shell_execute` 执行 `wget` / `curl` 抓取公开网页（优先 HTTPS，输出转文本后读取），检索同样**先试 `https://cn.bing.com/search?q=`**，注意环境变量与密钥不得回显。
      4. 以上都不可用时，才如实告知用户限制并给出可操作的替代建议。
    - **怎么搜**：`query` 用精简关键词，支持 `site:`、`lang:`、`after:`/`before:`、`"精确短语"`、`-排除`；多个意图分开搜，同一意图最多 3 组关键词。`ori_question` 可传用户原话帮助理解意图。
    - **怎么读**：优先读 `summary`，`snippet` 作辅助；只引用结果里返回的标题/URL/内容，不得编造链接或结论。默认不返回正文；确实需要正文时才把 `need_content` 设为 true（会明显增加输出与费用）。
    - **失败处理**：无结果或接口报错就换关键词或换渠道（browser / shell）；连续失败如实告知用户，不要假装搜到。搜索按请求计费，禁止高频轮询或对同一 query 反复重试。
    """

    /// 顺序即前缀顺序：新增段只能追加到末尾，插入中间会使全量缓存失效一次。
    private static var blocks: [String] {
        [toolSystem,fileSystem,internalLinks,searchStrategy,webSearchStrategy]
    }
}
