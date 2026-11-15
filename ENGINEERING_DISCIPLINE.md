# MiniClaw 工程纪律（Engineering Discipline）

> 基于公开工程实践 + 2026-08-03 五轮崩溃修复循环的实战教训。
> 最后更新：2026-09-18（派生目录定案为持久路径 `~/.miniclaw-build`；对齐 S2/B4/§2.1/§6.1 的过期 xcodegen 与派生目录口径）

---

## 一、项目结构

MiniClaw 采用清晰的分层布局：

```
MiniClaw/                      # git 仓库根
├── MiniClaw/                  # iOS app 主代码（Swift / SwiftUI）
│   ├── App/                   # App 入口、容器、环境注入
│   ├── Views/                 # 视图层（按功能分子目录）
│   │   ├── Home/             # 首页、会话列表
│   │   ├── Chat/             # 聊天界面
│   │   └── Settings/         # 设置页
│   ├── Models/                # 数据模型
│   ├── Services/              # 业务逻辑层（无 UI 依赖）
│   └── Resources/             # 资源文件
├── MiniClawKit/               # 被 embed 的 framework（渲染核心）
├── MiniClawCLI/               # CLI 工具
├── MiniClawWidget/            # Widget 扩展
├── ShareExtension/            # 分享扩展
├── docs/                      # 文档唯一入口：见 docs/README.md
│   ├── CURRENT_STATE.md       # 当前状态（单一事实源）
│   ├── ISSUES.md              # 开放问题台账（单一事实源）
│   ├── archive/               # 历史报告（只读，见 archive/README.md）
│   └── refactor-specs/        # 重构规格
├── project.yml                # 工程定义（⚠️ 已与入库 pbxproj 漂移；**禁止**跑 xcodegen，见 S2/B4）
└── MiniClaw/MiniClaw.entitlements  # 权限声明（**高敏感，改动须审查**）
```

> 工作区级（**不在 git 内**）：`../Kit/`（SwiftMath + swift-cmark）、`../第三方源码/`（iSH 真身与上游参考）。

### 规则

| # | 纪律 | 来源 |
|---|------|------|
| S1 | **第三方代码只放 `第三方源码/`**，禁止在主代码目录放 vendored 二进制或副本 | 第三方源码隔离惯例 |
| S2 | **入库的 `project.pbxproj` 是项目定义的权威**；`project.yml` 已与其漂移，**禁止跑 `xcodegen generate`**（见 B4）。增删/移动源文件用 Python 直改 pbxproj（格式见团队记忆 §0），删文件用 `XcodeRM` | 2026-09-15 更正（原「project.yml 是唯一来源」已作废） |
| S3 | **entitlements 文件是最高敏感配置**——CloudKit / iCloud / Push 等能力的增删必须关联模型适配方案，不可单独改 | 2026-08-03 崩溃教训 |
| S4 | **第三方源码严格只放 `第三方源码/`**——禁止在主代码目录放 vendored 二进制、副本或框架；用 project.yml 相对路径引用（`$(SRCROOT)/../第三方源码/...`），项目自己的桥接包装收敛在显式桥接层 | 2026-08-04 用户纪律 |
| S5 | **一切 bug 修复必须从源头解决，禁止补丁/兼容/特例分支治标**——判定：Q1 追问过上游机制？Q2 同类问题在别处不再犯？Q3 减少而非新增特例分支？Q4 符合架构分层？防御性编程（针对外部不可控因素的明确架构边界）不算补丁 | 2026-08-04 用户纪律 |
| S6 | **项目内不出现任何其他作者的项目/产品名**——注释、文档、UI 文案、资源文件一律不得引用，防止侵权与影响上架；厂商/模型名（OpenAI、Claude、Gemini、Grok 等）是功能标识，必须保留。检查方式：按团队记忆中的禁用词清单全库检索应无命中 | 2026-08-04 用户纪律 |
| S7 | **命名一律使用本产品（MiniClaw / miniclaw）命名**——工具名、参数名、标识符、序列化 key 不得使用任何第三方名或其变体（任何非本产品前缀，含曾用/上游项目名）；新命名以 `MiniClaw`/`miniclaw` 为前缀（例：`miniclawConfigWrite`、`MiniClawOpenTool`）。厂商适配文件名（OpenAIProviderAdapter 等）与 OAuth 服务名（OpenAIOAuthManager）是功能标识例外 | 2026-08-04 用户纪律 |

---

## 二、构建纪律（Build Discipline）

### 2.1 标准构建命令

```bash
# CLI 回退路径（仅在 Xcode MCP 不可用时使用；首选见 B5）
# 完整构建（产物进 ~/.miniclaw-build，不进项目）。固定复用同一派生目录 —— B2 / B6。
# 模块缓存必须一并重定向，否则沙箱下报：
#   unable to write module session file at .../ModuleCache.noindex/...: Operation not permitted
cd /Users/neartop/MiniClowDevelopment/MiniClaw && \
CLANG_MODULE_CACHE_PATH=/Users/neartop/.miniclaw-build/modulecache \
SWIFT_MODULECACHE_PATH=/Users/neartop/.miniclaw-build/modulecache \
MODULE_CACHE_DIR=/Users/neartop/.miniclaw-build/modulecache \
xcodebuild build -project MiniClaw.xcodeproj -scheme MiniClaw \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox" \
  -derivedDataPath /Users/neartop/.miniclaw-build
```

### 2.2 构建规则

| # | 纪律 | 说明 |
|---|------|------|
| B1 | **每次代码修改后必须执行完整构建并确认 BUILD SUCCEEDED**，方可向用户汇报 | 防止"改了但没编译就交付" |
| B2 | **构建产物必须放在 `-derivedDataPath /Users/neartop/.miniclaw-build`**（持久），绝不放进项目目录 | 避免污染 git / Xcode 索引 |
| B3 | **沙盒 workaround (`-disable-sandbox`) 只通过命令行传参**，不写进 `project.yml` | 保持 project.yml 干净可移植。⚠️ 必须作为 `OTHER_SWIFT_FLAGS`（Swift 前端开关）传入；当成顶层 xcodebuild 选项会直接报 `invalid option '-disable-sandbox'` |
| B4 | ~~**XcodeGen 先于 xcodebuild**~~ **【已作废 2026-09-15】**：源文件增删/移动**不要**跑 `xcodegen generate`——它会直接产出编不过的工程；`project.pbxproj` 是权威，在其上直接改 | 更正依据：`.workbuddy/memory/2026-09-15.md` 记忆核对结论（原条目与工作区笔记相反） |
| B5 | **Xcode 工程相关操作一律优先走 Xcode MCP 通道**——构建、编译诊断、运行/安装、抓日志、调试、设备交互、工程/方案/目标/目的机查询、测试、崩溃与性能；**能走 MCP 就不得**改用 `xcodebuild` / `devicectl` / 手工读工程文件替代 | MCP 与 Xcode 状态**同源**（同一个 workspace/scheme/目的机），且不受外部进程沙箱干扰——CLI 构建会因 `sandbox-exec` 与 Swift 宏插件被拒而炸出上千条假错误（实测 `SwiftUIMacros.StateMacro … malformed response`） |
| B6 | **编译默认只做增量；只有用户明确要求时才做全量**——必须**固定复用同一个派生目录**（主线 `/Users/neartop/.miniclaw-build`，**持久**）：**不得**每个步骤/每次验证/每次二分都新建 `-derivedDataPath`，**不得**删除或清理已有派生目录（清缓存须先问）。改动分散在多个提交上做对照时，也复用同一目录靠增量重编 | 2026-09-16 用户纪律。当晚反面教训（实测）：每步换新派生目录 + 每步"施工一次/复核一次"双份构建 + 目的机被系统切回模拟器未先确认，单次白等 **211s / 245s / 885s**，一整晚十几次构建里至少两次纯属浪费 |
| B7 | **每次构建前先确认 active run destination** | 同上事故：目的机被自动切回模拟器后照旧构建，得到的是链接错误（预编译库 `libish.a … built for 'iOS'` 而目标为 `iOS-simulator`），211s 白做 |

**派生目录定案（2026-09-18，唐唐批准）**

**派生目录 = `/Users/neartop/.miniclaw-build`（持久）。**

记录 —— 为什么改：

- B6 的核心承诺是「**固定复用同一个派生目录**」，靠增量避免白等。原主线 `/tmp/miniclaw-build` 与这个承诺
  **自相冲突**：macOS 会定期清理 `/tmp`，**重启必然清空** ⇒ 每次重启后首建都是冷构建，恰好落在 B6 要避免的情形里。
- 选持久路径而非工作区内：编译产物一律不进工程树（§1 / B2），也**不进 DSH 工作区**，避免被工程检索与 git 视作内容。
- 目录内容：派生数据根 + `modulecache/`（模块缓存三变量全部指向 `<派生目录>/modulecache`）。
- ⚠️ 自本日起**第一次构建为冷构建**（目录新建），此后一律增量；**不得**清空或删除该目录（清缓存须先问）。

历史沿革：`/tmp/miniclaw-build`（B2/B6 原文）→ 本次改为 `~/.miniclaw-build`；更早的
`$WS/.xcode-sym` + `-alltargets` + `SYMROOT`/`OBJROOT` 是**另一套机制**，与 `-derivedDataPath` **互斥**
（报 `The flag -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath`）。

走 CLI 时**一律以 §2.1 那条命令为唯一版本**，不要再各写一套。

### 2.3 Xcode MCP 通道对照表（B5 的执行细则）

| 任务 | 走 MCP | 不再使用 |
|---|---|---|
| 构建 / 编译验证 | `BuildProject`；单文件诊断 `XcodeRefreshCodeIssuesInFile` | `xcodebuild build` |
| 构建日志 | `GetBuildLog`（severity / pattern / glob 过滤） | 读构建日志文件 |
| 安装 + 运行 | `DeviceInteractionStartWorkspaceSession` → `DeviceInteractionInstallAndRun`（或 `RunProject`） | `devicectl install/launch` |
| 运行时日志 | `GetConsoleOutput`（stdio + oslog，支持正则与上下文行；`AppLogger` 经 `print` 进控制台，`[Cache命中]`/`[Cache指纹]` 可直接过滤） | `devicectl … copy from Documents/MiniClaw/logs` |
| 调试 | `InvokeDebuggerCommand`（lldb：`bt` / `po` / 断点 / 单步，与 Xcode 调试台同一会话） | — |
| 设备 UI 操作 | `DeviceInteractionSynthesize`（tap / swipe / type，附截图与 UI 层级） | 人工手点后口述现象 |
| 工程 / 目标 / 方案 / 目的机 | `XcodeListWorkspaces/Schemes/Targets/RunDestinations`、`GetTargetBuildSettings`、`XcodeLS/Read/Grep/Glob`、`XcodeMakeDir/MV/RM` | `find` / `grep` 工程文件 |
| 测试 | `GetTestList` + `RunAllTests` / `RunSomeTests` | `xcodebuild test` |
| 崩溃 / 性能 | `GetTopCrashIssues` / `GetCrashIssueLogs`、`GetTopFieldPerformanceIssues` | — |
| Info.plist / 权限 | `AddInfoPlist` / `AddEntitlement`（**不直接编辑 plist / entitlements 文件**） | 直接改文件 |

**前置条件（不满足就先做）**
1. **必须先有打开的 workspace**：MCP 的构建/运行/日志/调试工具都要求 workspace + scheme + 目的机已就位；没有就先用 `XcodeOpenWorkspace` 打开 `MiniClaw.xcodeproj`。
2. **调用方授权有有效期**：Xcode 首次会弹窗批准「哪个 agent 可访问哪个工程目录」（当前 `/bin/bash` 这条授权到 2026-09-16 13:11 UTC）。过期或换调用方时，第一次工具调用要在 Xcode 里点一次允许。
3. 目的机用 `XcodeSwitchRunDestination` 切换（真机调试/抓日志前务必确认不是模拟器）。

**已知缺口（MCP 未覆盖，需另行处理且先问用户）**
- MCP **没有**「从 App 容器拷文件」的工具 ⇒ `Documents/MiniClaw/logs/reqdump_*.json` 这类**沙盒文件**目前没有 MCP 通道。首选解法是**在 App 内算好结果再用 `AppLogger` 打到控制台**（例如相邻两次请求体的首个不同字节偏移 + 上下文 + 所属段），这样抓日志全程可走 MCP；在此之前若确需容器文件，先征得用户同意再临时用 `devicectl`。

---

## 三、SwiftData / 持久化铁律（Persistence Rules）

> 这是 2026-08-03 五轮崩溃修复循环中代价最高的教训区。

| # | 纪律 | 违反后果 | 教训来源 |
|---|------|---------|---------|
| P1 | **启动期构造 ModelContainer 绝不可同步打开可能损坏的存储文件**——SwiftData 打开格式不兼容 SQLite 会触发内部 fatalError（非可抛 Error，`try?` 捕获不住）→ launch 崩溃 | App 直接打不开 | 第 4-5 轮 |
| P2 | **`modelContext.save()` / `modelContext.insert()` 禁止用 `try?` 静默吞错**——必须 `do { try ... } catch { log }` 并记录具体错误 | save 失败被静默吞掉 → 数据只在内存 → 切后台全空 | 第 1-3 轮 |
| P3 | **`@Query` 在 NavigationStack + push/pop 场景下不可靠**——首页会话列表用显式 `fetch` + 主动 reload 替代 | 新建会话返回后看不到 | 第 2 轮 |
| P4 | **reload 合并方向：优先保留内存活对象**，存储只补充内存没有的。切勿反向（以存储为准会回退 AI 已生成的标题/图标） | 标题/图标反复回退默认值 | 第 3 轮修正 |
| P5 | **entitlements 声明 CloudKit 时 SwiftData 会强制按 CloudKit 规则校验模型**（关系全可选 + 禁 unique）——加 CloudKit 必须同时适配模型，否则 fatal error | 闪退（第 5 轮最终根因） | 第 5 轮 |
| P6 | **禁同进程第二 ModelContainer 指同批 Model**——启动即崩 | 崩溃 | 既有知识 |
| P7 | **使用独立命名存储文件**（如 `miniclaw.sqlite`）而非默认存储路径——绕开可能的损坏/CloudKit 遗留文件 | 自愈能力 | 第 4-5 轮 |

---

## 四、代码质量规则（Code Quality）

### 4.1 修复纪律（Bug Fix Discipline）

| # | 纪律 | 说明 |
|---|------|------|
| Q1 | **先定位根因证据再改代码**——崩溃必须有崩溃日志/堆栈；行为异常必须有复现步骤和日志输出。禁止"猜一个原因然后改代码试" | 避免第 1-3 轮的"猜→改→无效→再猜"循环 |
| Q2 | **每次修复迭代必须清理上一次遗留的冗余代码**——注释掉的旧代码、过时的注释块、废弃的 import 一并删除 | 避免代码堆积成"考古现场" |
| Q3 | **诊断 print 与生产代码严格分离**——诊断信息用独立 `print`/`AppLogger` 行，绝不把截断/掩码塞进生产逻辑 | 既有编码铁律 |
| Q4 | **单一修复只解决一个问题**——不要在一次编辑中混入"顺便清理"和"顺便优化"，保持 diff 可审查 | 代码审查友好性 |

### 4.2 注释与文档

| # | 纪律 |
|---|------|
| Q5 | **注释解释"为什么"（why），不是"做什么"（what）**——代码本身应清晰表达 what |
| Q6 | **删除已解决问题的长篇注释**——如"对齐 XXX 的说明"在修复完成后应移除，不留在代码里 |
| Q7 | **MARK 注释用于分区导航**，不用于记录历史决策（历史决策进 git log 和 memory） |

### 4.x S5 反例库（每条都要能被 Q1–Q4 判出来）

> 目的：S5 是原则，容易"知道却不用在自己身上"。这里放**具体反例与其合格解法**，
> 以后提出任何修复方案，先拿最近的同类反例对照一遍。

**反例 #1（2026-09-17，用户当场驳回）——"把常数改准"= 补丁**

- 现象：流式期块高虚高 ⇒ 屏上空白，回复完成后消失。真机量化：被拒收缩 52 条全部 `pos=inside`，
  `Σ|delta| = 844pt`，最坏 `205.2 → 32.0`（虚高 6.4 倍）。
- 我提的方案 A：把 `seedFallbackHeight` 的 `36/40/20+n*16` 改成实测值 `26`。
- **S5 判定：不合格。**
  - **Q1 追问上游机制？** ❌ 只问了"数应该是多少"，没问"为什么高度会有两份定义"。
  - **Q3 减少而非新增特例分支？** ❌ 那张表仍然是**手抄的第二份常数**，与胶囊真实布局
    （字体/内边距/行高/图标）**没有任何同步机制** ⇒ 下次改样式立刻重新失准，且**无人会察觉**。
  - **Q4 符合架构分层？** ❌ 布局事实（胶囊多高）**应由视图定义给出**，而不是由布局层另抄一份。
- **合格解法（治本）**：**消除重复事实** —— 胶囊高度只有一处定义，视图布局与播种**读同一个来源**；
  并把"**播种 ≤ 真值（宁短勿长）**"确立为**不变式**（偏矮 ⇒ 增长 ⇒ 手势期放行 ⇒ 不产生空白；
  偏高 ⇒ 收缩 ⇒ 被延后 ⇒ 空白留到 settle）。只要该不变式成立，这类空白**在构造上不可能出现**。
- **可判定性**：不变式可被探针守住（`seed > measured` 即报点），不依赖任何人记得核对一张表 ——
  这才叫"从源头"。

**反例 #2（同源，2026-09-17）——"两张同值表各自维护"**

- §6.2 的 R7 把两张 per-kind 表**收口成一处**（这一步是对的：消除重复）。
- 但**收口后从未拿实测校验过那张表的数值** ⇒ 重复消除了，**错误留下了**。
- 教训：**消除重复 ≠ 校验正确性**。消除重复是必要步骤，之后必须用实测校验一次，
  否则只是把"两处都可能错"变成"一处确定错"。

---

## 五、变更管理（Change Management）

### 5.1 高风险变更清单

以下变更属于**高风险**，修改前必须：

1. 明确列出影响范围
2. 提供回滚方案
3. 修改后立即构建验证

| 变更类型 | 风险 | 示例 |
|----------|------|------|
| entitlements 修改 | 可能触发 SwiftData schema 校验崩溃 | 加/删 CloudKit |
| 模型属性变更 | 可能触发迁移失败 | 加/删 `@Attribute` |
| 容器配置变更 | 可能影响所有持久化操作 | 改存储路径/文件名 |
| 启动路径代码（`App.init()` / 属性初始化） | 崩溃 = App 打不开 | 在 `init` 里做 IO 或 throw |

### 5.2 同步相关（当前暂停）

| # | 状态 | 说明 |
|---|------|------|
| iCloud / CloudKit | **已完全移除** | entitlements 已清理，后续重做须从零规划 |
| SyncBootstrap | **保留但未激活** | `iCloudEnabled` 默认 false，`setup()` 仅注册空桩 |
| SyncSettingsView | **已隐藏** | 入口保留，结构体不动 |

---

## 六、验证与交付（Verification & Delivery）

### 6.1 修改后检查清单

每次代码修改完成、向用户汇报前，逐项确认：

- [ ] 构建验证 → **BUILD SUCCEEDED**（**优先走 Xcode MCP `BuildProject`**，见 B5；CLI 回退命令只此一份，见 §2.1）
- [ ] 构建是**增量**、且**复用了同一派生目录**（B6）；未清缓存、未换目录
- [ ] ⚠️ **没有**跑 `xcodegen generate`（已作废，见 B4）
- [ ] 构建产物在 `/Users/neartop/.miniclaw-build`（不在项目内）
- [ ] 无新增 warning（既有 warning 可忽略，但需知晓）
- [ ] 若涉及持久化：save/fetch 路径都是 `do/catch` + 日志，无裸 `try?`
- [ ] 若涉及 UI 列表：reload 方向正确（内存优先）
- [ ] 无遗留的注释掉代码 / 过时注释
- [ ] memory 文件已更新（当日日志 + 长期记忆如有新事实）

### 6.2 用户交付格式

汇报包含：
1. **根因**（带证据：崩溃日志 / 控制台输出 / 代码行号）
2. **改了什么**（具体文件 + 改动摘要）
3. **编译结果**（BUILD SUCCEEDED + 命令）
4. **验证步骤**（用户需要在真机上做什么来确认）
5. **影响范围**（对缓存命中率 / 其他功能的影响）

---

## 七、参考实践对照

| 实践 | 参考做法 | MiniClaw 对应 |
|------|------------|--------------|
| 清晰分层目录 | `src/ios/` 下按 Views/Models/Services 分层 | ✅ 已对齐 |
| 原生依赖从源码构建 | `deps/build_*.sh` 脚本化，不提交二进制 | ✅ `第三方源码/` 约定 |
| 构建顺序依赖管理 | FFmpeg 依赖 LAME，必须按序构建 | ⚠️ 当前依赖简单，暂不需要 |
| 构建时配置注入 | xcconfig 模板，`.example` 入仓库 | ⚠️ 可考虑引入 |
| 子模块管理第三方 | iSH/proot 作为 git submodule | ⚠️ 当前用目录存放，可行 |
| 多 Target 结构 | app + share + widget + file-provider + tests | ✅ 已有 |
| Simulator vs Device 架构意识 | 文档明确说明 simulator 构建限制 | ✅ 编译命令指定 generic/platform=iOS |

---

## 八、禁止事项（Never Do List）

1. **不要**在 `try?` 后面写"应该不会失败"的注释——如果真的不会失败，用 `try!` 并说明理由；如果可能失败，用 `do/catch`
2. **不要**在 entitlements 里加 CloudKit 除非模型已经全部适配 CloudKit 规则（关系可选 + 无 unique 约束）
3. **不要**在 `App.init()` 或属性初始化里做任何可能 throw 的 IO 操作
4. **不要**用 `@Query` 做需要即时刷新的列表（导航栈内场景）
5. **不要**猜测 bug 原因——读崩溃日志、看控制台输出、追踪数据流
6. **不要**留下上一轮修复失败的残留代码（注释掉的旧实现、过时的说明注释）
7. **不要**在没编译通过的情况下告诉用户"修好了"
8. **不要**用"把常数/阈值改准"的方式修 bug —— 那是补丁。先问"这个事实为什么会有两份定义/为什么会被猜"，
   消除重复与猜测本身；**无法用不变式或单一来源表达"修好了"的方案，视为无效调整**（S5 / 反例 #1）

---

## 纪律增补（2026-09-17）：引用 `#if DEBUG` 里的符号必须同样 gate，**并验 Release**

**事故**：给日志降噪时，把几处探针打点包进 `if ScrollMetricsRecorder.shared.isEnabled { … }`，
但 `ScrollMetricsRecorder` **自身声明在 `#if DEBUG` 里** ⇒ **Release 编译失败**
（用户在 Xcode 里构建 Release 时暴露：`Cannot find 'ScrollMetricsRecorder' in scope`）。

**我为什么没发现**：我的构建**全部走 MCP**，而 MCP 的 `RunProject`/`BuildProject`
只驱动 **scheme 当前配置（Debug）**，**无法切 Release** ⇒ 这类错误在我的验证通道里**天然隐形**。

**纪律**：
1. 改动**任何**与被 `#if DEBUG` 包裹的符号相关的代码后，**必须**确认 **Release 也能编译**；
2. MCP 无法表达时（如切 Release）：**要么**请用户在 Xcode 里验，**要么**跑一次
   `xcodebuild -configuration Release` —— 但那属**全量编译，必须先征得同意**；
3. 用**穷举校验**代替抽样：把所有引用某符号的地方**逐条**判断是否在 `#if DEBUG` 内。
   本次就是既有代码里**还有一处**（`MarkdownView:1005`）同样未 gate —— 只检查自己改的几行会漏掉它。

---

## 九、协议、流式与数据边界纪律（T1–T16）

> **来源**：2026-11-14 对 DeepSeek 官方 `chat-demo`（MIT）的工程实践评估。
> **适用范围**：**任何**模型接入、流式解析、会话渲染、持久化与导入导出的改动 —— 不只是"重写时用"。
> **立规动机**：近三天三个真机 bug（I-39 `browser` 参数形状、I-40 纯空白块占高、I-41 `</tool_call>` 泄漏）
> 全部不是"写错了"，而是**没有一条纪律强制把话说清楚**。规则在此固化，评审时逐条对照。

### 9.1 规则总表

| # | 规则 | 一句话判据 |
|---|---|---|
| **T1** | **协议类型单一真相源** | 每种外部协议只有一个类型模块；业务代码禁止用 `[String: Any]` 摸外部 JSON 的键 |
| **T2** | **未知/畸形块显式丢弃且可观测** | 解析器返回 `nil` 而不是抛；调用方跳过时**必须**留一条带块类型的日志，禁止 `default: break` 静默吞 |
| **T3** | **SSE 解析是纯函数并有单测** | CRLF/CR/LF、多行 `data`、注释行、末尾 CR、无 `[DONE]` 的终止事件，全部覆盖 |
| **T4** | **错误分类与文案分离** | 适配器只产出 condition 枚举（401/402/413/429/5xx/网络/其它）；文案由 UI 按场景给 |
| **T5** | **可重试判定集中一处** | 网络、429、5xx 可重试；401/402/413 与参数类**不重试**。禁止各适配器各写一套 |
| **T6** | **流式渲染按实测耗时自适应节流** | 冷却 = 上次渲染耗时 × 2，封顶 2s；越贵的渲染，下次越晚 |
| **T7** | **同一语义只有一个生产者** | 判空、高度、状态这类事实，全库只有一个函数产出；禁止两处各写一份 |
| **T8** | **会话是树，不是线性表** | `parentId` + `selectedChildId`；展示与请求上下文**共用同一条当前路径** |
| **T9** | **稳定身份，禁止全量重建** | 流式更新时未变化的历史节点必须复用原对象；重建等于每帧重绘全历史 |
| **T10** | **上下文档位规则显式化** | 哪些消息能进请求、哪些能续写，写成纯函数 + 单测，不靠"约定" |
| **T11** | **持久化：脏集合 + 串行 + 可重试** | 只写脏的；写入串行；失败可重试；淘汰内存缓存时保护未落盘数据 |
| **T12** | **导入导出：版本化 + 先验后换 + 事务** | manifest 首条带版本；先校验再暂存；最后一次事务替换；失败保留原数据 |
| **T13** | **导出永不含密钥** | 导出包不得包含 API Key、令牌、密码；数据范围在文档里明示 |
| **T14** | **不做旧格式迁移** | 只支持当前数据格式，不写迁移器（与"未上架 = 零兼容"一致） |
| **T15** | **边界归一化在单一入口完成** | 外部输入形状可变（字符串化对象、参数写到顶层）时，在**一个**入口按白名单归一并记录；禁止逐 case 打补丁 |
| **T16** | **失败必须留痕** | 任何工具/协议失败都要有一条可检索日志（名字、顶层键、参数类型、错误码）；只有 UI 文案没有日志 = 不可诊断 |

### 9.2 逐条落地（原生 iOS 的对应写法）

**T1 / T2 —— 协议层**
- 每块一个 `struct XxxBlock: Decodable`，`init(from:)` 里逐字段 `decodeIfPresent`；解码失败返回 `nil`（`init?`），**不抛**。
- 解析入口返回 `[ParsedBlock]`，未识别类型记 `AppLogger.warn("[Stream] 未识别块 type=\(rawType)")` 后跳过。
- 反例（现行代码）：`AnthropicStreamDelegate.content_block_start` 只认 `tool_use`，其余 `default: break` —— 服务端搜索/引用块进流后**无声消失**，线上无从判断。

**T3 —— SSE**
- `SSEDecoder` 做成 `struct` + `mutating func push(_ text: String) -> [SSEEvent]`，无 UI/无网络依赖，单测覆盖 CR/LF/CRLF 与多行 data。
- 终止条件按协议走（Anthropic 用 `message_stop`，OpenAI 用 `[DONE]`），**不要假设有 `[DONE]`**。

**T4 / T5 —— 错误**
- `enum LLMErrorCondition { case unauthorized, insufficientBalance, tooLarge, rateLimited, serverBusy, network, other }`
- `classify(status:)` 与 `isRetryable(_:)` 各一个函数，适配器只映射、不造文案。

**T6 —— 渲染节流**
- 参考实现：起始时刻 → 提交后按"本次耗时 × 2（封顶 2s）"计算下次允许更新时间；期间到达的内容合并为最新一份。
- 与现有 `ScrollMetricsRecorder` 哨兵并用：先量后调，别拍一个固定毫秒数。

**T7 —— 单一生产者**
- 例：文本块可见性 = `AssistantBlock.hasVisibleText`；高度播种必须满足 `播种 ≤ 真值`；`executionTimeout` 的 `nil` 只有一个含义。
- 反例：I-40 就是"判空"有两份定义（`isEmpty` vs 语义上空）而漂移。

**T8 / T9 —— 会话树与稳定身份**
- `Message { id, parentId, selectedChildId }`；`visiblePath(root)` 是展示与请求上下文的**唯一**取数入口。
- 版本列表（兄弟分支）未变化时复用旧对象；`blocks` 更新只替换变化的那个块，不动其余。

**T10 —— 上下文档位**
- 两条纯函数：`isUsableReply(_:)`（能否进请求）与 `canContinueReply(_:)`（能否续写）。规则至少覆盖：报错轮次不进上下文、拒答不进上下文、含服务端工具块的回复不可续写、模板文案不进上下文。

**T11 / T12 / T13 / T14 —— 数据**
- 脏集合 + 串行写 + `retrySave`；删缓存/session 前确认已落盘。
- 导出：`manifest.json` 首条、版本号、会话树、附件；导入先校验版本→暂存→事务替换；失败保留原库。
- 导出白名单里**没有** Key/令牌字段；文档写明"导出不含 API Key"。

**T15 / T16 —— 外部边界**
- 例：`BrowserTool.normalizedActionParams`（字符串化 params 还原 + 顶层参数按白名单并入，结构键永不迁移）。
- 失败日志至少要能回答："调用的是什么、收到的顶层键是什么、参数是什么类型、失败码是什么"。

### 9.3 改动自检清单（协议/流式/存储类改动，逐条打勾）

- [ ] 新增的外部字段有对应类型，业务层没有 `[String: Any]` 取值
- [ ] 未知块/未知字段有日志，能在线上一眼看出"忽略了什么"
- [ ] SSE 分片边界（`\r\n` 被切成两段、`data` 跨行）有测试或手工验证记录
- [ ] 新增错误码已归入 condition 枚举，且重试策略明确（可重试/不可重试）
- [ ] 流式路径上的昂贵计算位于节流**之后**，并有用实测数字支撑的间隔
- [ ] 同一事实（判空/高度/状态）只有一个产出函数；没有第二份定义
- [ ] 流式更新没有重建未变化的历史节点
- [ ] 新增/修改的落盘路径是增量且幂等的；中途失败可重试
- [ ] 涉及导出的改动，导出内容不含密钥
- [ ] 任何新增失败分支都有一条可检索日志（不是只有 UI 文案）

### 9.4 明确不适用的部分

`chat-demo` 是 Web 前端，以下**不搬**：DOM 虚拟滚动与 CSS Modules、`zustand`/`IndexedDB`/`localStorage`、
`file://` 静态分发、`rspack` 构建链。它们的原生等价物是 UICollectionView/SwiftUI + TextKit、
`@Observable`/SwiftData/SQLite、`.xcassets`/`xcconfig` —— 只借"组织方式"，不借实现。

---

## 十、命名与可读性纪律（N1–N9）

> 起因：MCD 迁移过程中出现"同一批工具里既有 `file_read` 又有 `apple-image`"的混用，
> 以及日志 scope、i18n key、目录名各写一套的情况。命名不一致的代价不是丑，是**找不到、改错地方、重复实现**。

### 10.1 四条总原则

| 原则 | 要求 | 反例 |
|---|---|---|
| **可读优先** | 名字要能让半年后的自己一眼看懂，不用缩写（除公认：URL / ID / API / JSON） | `Svc`、`Mgr2`、`tmpX` |
| **同类同形** | 同一类东西必须同一种形态，不允许 A 用下划线、B 用连字符 | `file_read` vs `apple-image` |
| **层次一致** | 目录、类型、方法、日志、文案 key 各有固定结构，不即兴发挥 | 日志 scope 一会儿 `parse` 一会儿 `protocol` |
| **改一处** | 名字只在一处定义，其他地方引用 | 工具名散落在 schema 与注册表两处手写 |

### 10.2 各层命名规则

| 对象 | 规则 | 示例 |
|---|---|---|
| 文件 / 目录 | `UpperCamelCase.swift`；目录按**职责**（单数、UpperCamel） | `Services/Tools/FileTools.swift`、`Views/Chat/MessageRow.swift` |
| 类型 | `UpperCamelCase`，名词或"名词+职责" | `AgentRunner`、`SystemPromptBuilder`、`SandboxFileManager` |
| 协议 | 名词，不加 `Protocol` 后缀 | `AgentTool`、`ShellRuntime` |
| 方法 | `lowerCamelCase`，动词开头 | `makeRegistry(settings:)`、`appendBlock(_:sessionID:messageID:)` |
| 属性 / 局部变量 | `lowerCamelCase`；布尔用 `is/has/can/should` 开头 | `isStreaming`、`hasAPIKey` |
| 常量 | `lowerCamelCase`（Swift 惯例），不用全大写 | `maxToolRounds` |
| 日志 scope | **固定枚举**，见 10.3 | `llm`、`tool`、`chat` |
| i18n key | `区域.对象.动作/属性`，全小写点分 | `chat.placeholder`、`error.rateLimited` |
| 沙盒目录 | 全小写单数名词 | `sessions/`、`workspace/`、`memory/` |
| JSON 字段（落盘） | `lowerCamelCase`（Swift 侧）；外部协议按其规范 | `searchQueries`、`toolIsError` |

### 10.3 日志 scope 白名单（禁止新增即兴 scope）

| scope | 覆盖范围 |
|---|---|
| `llm` | 请求组装、流式帧、结束统计 |
| `tool` | 工具执行开始/结束/失败 |
| `chat` | 会话状态机（发送、结束、空回复） |
| `agent` | 智能体循环（轮次、上限） |
| `storage` | 会话读写 |
| `sandbox` | 沙盒目录 |
| `keychain` | 密钥 |
| `parse` | 协议数据解析失败 |
| `runtime` | 命令运行时（Alpine） |
| `probe` | 启动自检 / 连通性探测 |

新增 scope 必须先加进本表，否则视为违反 N3。

### 10.4 外部契约例外（唯一允许的"不统一"）

**工具名是外部契约，必须与 MiniClaw 逐字一致**，即使 MiniClaw 自身混用 `_` 与 `-`。
理由：改名会让模型侧、历史会话、以及将来双向迁移全部错位，代价远大于视觉统一。

处理方式：
- 工具名**不动**；
- 但在 `docs/TOOL-PARITY.md` 中标注每一处不规范命名，作为已知债务；
- 新增工具（MCD 独有）一律 `lower_snake_case`，向多数派靠。

### 10.5 自检清单（改完代码照着过）

1. 新增文件是否在正确的职责目录、文件名是否 `UpperCamelCase`；
2. 新增类型名是否能不看实现猜出职责；
3. 是否出现同类不同形（`a_b` 与 `c-d` 并存）；
4. 日志 scope 是否在白名单内；
5. i18n key 是否符合 `区域.对象.动作`；
6. 文案是否全部走 String Catalog，无硬编码；
7. 名字是否只定义一次、其他地方引用而非复制。

### 10.6 不适用

- 对接第三方协议字段（如 OpenAI 的 `tool_calls`、DeepSeek 的 `reasoning_content`）**保持原样**，不做本地化改写；
- 系统 API 命名（`URLSession`、`FileManager`）不参与本规范。

### 10.7 落地检查（可自动化）

```sh
# 1) 工具名混用检查（只应出现在外部契约处）
grep -rn 'name = "[a-z0-9_]*-[a-z0-9_-]*"' MiniClawDemo/ios/Sources | grep -v TOOL-PARITY
# 2) 日志 scope 越界检查
grep -rn 'Diagnostics\.\(note\|dropped\)("' MiniClawDemo/ios/Sources | grep -vE '"(llm|tool|chat|agent|storage|sandbox|keychain|parse|runtime)"'
# 3) 硬编码中文检查（UI 目录内不应出现中文字面量）
grep -rn '[一-龥]' MiniClawDemo/ios/Sources/Views | grep -v '//'
```
