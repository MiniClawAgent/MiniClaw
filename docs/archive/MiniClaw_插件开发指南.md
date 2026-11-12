# MiniClaw 插件开发指南

> 面向第三方开发者的最小可用文档：包格式、各类型清单字段、**tool 类型开放接口与依赖**、打包与调试。
> 规范主文档见 `Doc/MiniClaw_插件化架构重做_构思报告_2026-08-26.md`。
> 更新：2026-08-31（含 tool 插件类型，Stage-6a/6b）。

---

## 一、插件是什么

`.mpk` = 标准 zip 压缩包，内含**一份强制清单 `plugin.json`** + 按类型组织的内容文件。没有 `plugin.json` 的包一律拒绝加载（无兼容路径）。

布局（内置包统一用 `<plugin-id>/` 子目录；导入包根布局亦可，二者都能识别）：

```
<plugin-id>/plugin.json          ← 强制
<plugin-id>/tools/*.json         ← type=tool 时：一包多工具，主键 = 文件名
<plugin-id>/SKILL.md             ← type=skill
<plugin-id>/<name>.md            ← type=subagent / rule（按语言子目录）
<plugin-id>/servers.json         ← type=mcp（业界 mcpServers 格式）
<plugin-id>/providers.json       ← type=model
```

## 二、`plugin.json` 字段

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `id` | ✅ | — | 全局唯一，用作沙盒目录名（`/` `\` 会被替换为 `-`） |
| `name` | ✅ | — | 展示名（插件列表用） |
| `type` | ✅ | `skill` | skill / subagent / rule / soul / mcp / model / theme / tool |
| `description` | 内置必填 | 空 | ≤30 字一句话；第三方缺省显示"无描述" |
| `version` | | `1.0.0` | |
| `category` | | = type | |
| `enabledByDefault` | | `true` | 对导入包无效——**用户导入的插件一律默认关闭** |
| `icon` | | 按 category | SF Symbols 名；常见映射：skill=wrench.and.screwdriver、rule=checklist、subagent=person.2、soul=brain.head.profile、theme=paintpalette、mcp=link、model=cpu、tool=hammer |
| `author` / `license` / `minCoreVersion` / `dependsOn` / `conflictsWith` | | | 可选 |

**容错解码**：所有字段缺失即取默认值（`decodeIfPresent`），不会因为少写一个可选字段而整体加载失败。

## 三、tool 类型：开放接口

### 3.1 工具声明 `tools/<name>.json`

一包多工具，**主键 = 文件名**（建议与 `name` 一致）：

```json
{
  "name": "sandbox_now",
  "description": "返回沙箱当前时间（BusyBox date）。无参数。",
  "parameters": {
    "type": "object",
    "properties": {},
    "required": []
  },
  "command": "date '+%Y-%m-%d %H:%M:%S'",
  "timeout": 30,
  "backend": "shell"
}
```

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `name` | ✅ | — | 工具名，仅允许 `[A-Za-z0-9_-]`；与内置/其他插件/MCP 重名时**拒绝注册** |
| `description` | ✅ | — | 模型可见的工具说明（作者撰写，不走 App 本地化） |
| `parameters` | | `{"type":"object"}` | 标准 JSON Schema；未知字段（`oneOf`/`$defs`/`additionalProperties` 等）**原样透传**给模型 |
| `command` | shell 后端必填 | — | shell 命令模板（POSIX sh 语法） |
| `timeout` | | `120` | 秒 |
| `backend` | | `shell` | `shell` = 声明式命令工具；`builtin` = 内置工具登记（**仅供内置包使用，第三方不可用**） |

### 3.2 参数如何传给命令（关键）

模型产出的参数对象序列化为 **JSON，经 stdin** 喂给命令。引擎的实际包装：

```sh
cat <<'MINICLAW_IN_<随机>' | <command>
{"param":"value", ...}          ← 参数 JSON（sortedKeys，逐次同参同字节）
MINICLAW_IN_<随机>
```

- 脚本侧直接 `read`/`cat` 读 stdin 即可，例如 `command: "python3 -c 'import sys,json; ...'"`
- 参数**不进命令行**，因此无需转义、无命令注入面
- 命令模板请按 POSIX sh 写（BusyBox ash）；bash 特有语法需先 `apk add bash` 再以 `bash -lc` 调用

### 3.3 可用运行环境与依赖（第三方工具的能力边界）

| 依赖/能力 | 说明 |
|---|---|
| **执行环境** | iSH（Alpine Linux 用户态）；基础命令 = BusyBox（`sh`/`cat`/`sed`/`awk`/`date`/`curl` 等） |
| **包管理** | `apk add <pkg>` 可按需安装（如 `bash`、`jq`、`python3`）；安装发生在会话沙箱内 |
| **工作目录** | 每次调用落在会话专属目录 `/var/MiniClaw/sessions/<uuid>`（相对路径文件都在这里）；`cd` 不跨调用保留 |
| **环境变量** | 用户在「设置-环境变量」配置的所有变量会注入进程环境；命令里可直接 `$VAR` |
| **网络** | 跟随系统代理（App 侧 `NSURLSession` 同款代理设置），可直接 `curl` 公网/内网 API |
| **输出** | stdout + stderr 合并作为工具结果；超阈值自动转存 offloads 并回链 |
| **超时** | `timeout` 字段（默认 120s），超时杀进程组 |
| **安全** | 与内置 `shell_execute` 同一沙箱面；无 iOS 原生能力（剪贴板/通知/日历等）；受「设置-通用-每次工具调用前确认」全局阀门约束 |

### 3.4 当前限制（重要，规划中的改进项）

- **包内脚本不可达**：iSH 只能看到会话目录，`command` 里引用包内 `scripts/x.py` 取不到。当前可行做法：①用沙箱自带/可安装命令写一行流；②让 AI 先用 `file_write` 把脚本写进会话目录再调用。
- **无状态、非交互**：每次调用起新进程，无 TTY、无持久会话。
- **不能调用 iOS 原生能力**（剪贴板/通知/健康/日历）——那是内置 `builtin` 后端的地盘。

## 四、示例：一个可发布的 API 工具包

```
weather-tools/plugin.json
weather-tools/tools/current.json
```

`plugin.json`：
```json
{
  "id": "com.example.weather",
  "name": "天气查询",
  "version": "1.0.0",
  "type": "tool",
  "enabledByDefault": false,
  "author": "you",
  "icon": "cloud.sun",
  "description": "按城市查询当前天气"
}
```

`tools/current.json`：
```json
{
  "name": "weather_current",
  "description": "查询指定城市的当前天气，返回温度与天气现象。",
  "parameters": {
    "type": "object",
    "properties": {
      "city": { "type": "string", "description": "城市名，如 Beijing" }
    },
    "required": ["city"]
  },
  "command": "curl -s \"https://wttr.in/$1?format=j1\" | head -c 2000",
  "timeout": 30
}
```

> 提示：命令里不要直接拼参数（参数走 stdin）。需要参数时，让脚本从 stdin 读 JSON：
> `"command": "python3 -c \"import sys,json,urllib.request; d=json.load(sys.stdin); print(urllib.request.urlopen('https://wttr.in/%s?format=j1' % d['city']).read()[:2000].decode())\""`
>
> ⚠️ **运行环境默认不含 Python3**：用到 Python 的命令模板必须先安装依赖再执行，例如
> `"command": "apk add python3 >/dev/null 2>&1 && python3 -c \"...\""`。
> 已安装的软件包跨会话保留，因此安装与执行串在同一条命令里即可（首次稍慢，后续直接命中）。

## 五、打包与安装

**打包**：zip，**不要包含目录条目**（Apple 的 `zip` 会写入目录条目；用 Python `zipfile.ZipInfo` 逐文件写最干净）：

```python
import zipfile, json
with zipfile.ZipFile("weather-tools.mpk", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo("plugin.json"), open("plugin.json","rb").read())
    z.writestr(zipfile.ZipInfo("tools/current.json"), open("tools/current.json","rb").read())
```

**安装**：把 `.mpk` 交给 MiniClaw 导入（设置 → 插件 → 导入）。导入后**默认关闭**，需手动开启；按 `type` 分发到 `plugins/<type>/<id>/`。同名 id 已存在时跳过（不覆盖）。

## 六、调试

- App 日志关注 `[ToolPlugin]` 前缀：非法定义、缺 `command`、工具名非法、重名拒绝、执行失败（含 exit code）都会记录。
- 工具是否注册成功：看日志 `[Cache指纹]` 的 tools 段估算 token 与哈希——启用/停用一个工具插件，该数字会随之变化。
- 参数是否正确到达：让命令先 `cat` 回显 stdin（如示例包的 `echo_tool`）做连通性验证。

## 七、各类型一句话速查

| 想扩展什么 | 用什么 type | 内容文件 |
|---|---|---|
| 给 AI 一套流程/规范 | `skill` | `SKILL.md`（frontmatter name/description + 正文） |
| 加一个可派发的角色 | `subagent` | `<角色>.md`，一包多角色 |
| 注入项目规则 | `rule` | `zh-Hans/`、`en/` 语言子目录 |
| 换人格 | `soul` | `SOUL.md` 模板（排他单选） |
| 接外部服务 | `mcp` | `servers.json`（`mcpServers` 格式，导入即合并） |
| 加模型供应商 | `model` | `providers.json`（密钥用户自填） |
| 换背景主题 | `theme` | `theme.json` + 图片（外观页选用） |
| **加工具** | `tool` | `tools/*.json`（声明式 shell 命令） |
