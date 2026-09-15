# MiniClaw 工程纪律（Engineering Discipline）

> 基于公开工程实践 + 2026-08-03 五轮崩溃修复循环的实战教训。
> 最后更新：2026-08-04

---

## 一、项目结构

MiniClaw 采用清晰的分层布局：

```
MiniClaw/
├── MiniClaw/                  # iOS app 主代码（Swift / SwiftUI）
│   ├── App/                   # App 入口、容器、环境注入
│   ├── Views/                 # 视图层（按功能分子目录）
│   │   ├── Home/             # 首页、会话列表
│   │   ├── Chat/             # 聊天界面
│   │   └── Settings/         # 设置页
│   ├── Models/                # SwiftData 模型 + 数据定义
│   ├── Services/              # 业务逻辑层（无 UI 依赖）
│   ├── Utils/                 # 工具类、扩展
│   └── Resources/             # 资源文件
├── MiniClawCLI/               # CLI 工具
├── MiniClawWidget/            # Widget 扩展
├── ShareExtension/            # 分享扩展
├── 第三方源码/                 # 第三方代码（仅源码，不提交二进制）
├── project.yml                # XcodeGen 项目定义（唯一 source of truth）
└── MiniClaw.entitlements      # 权限声明（**高敏感，改动须审查**）
```

### 规则

| # | 纪律 | 来源 |
|---|------|------|
| S1 | **第三方代码只放 `第三方源码/`**，禁止在主代码目录放 vendored 二进制或副本 | 第三方源码隔离惯例 |
| S2 | **`project.yml` 是项目定义的唯一来源**，手动修改 `.xcodeproj/pbxproj` 会被 `xcodegen generate` 覆盖 | 项目既有实践 |
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
# 完整构建（产物不进项目）
cd /Users/neartop/MiniClowDevelopment/MiniClaw && \
xcodebuild build -project MiniClaw.xcodeproj -scheme MiniClaw \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-disable-sandbox" \
  -derivedDataPath /tmp/miniclaw-build
```

### 2.2 构建规则

| # | 纪律 | 说明 |
|---|------|------|
| B1 | **每次代码修改后必须执行完整构建并确认 BUILD SUCCEEDED**，方可向用户汇报 | 防止"改了但没编译就交付" |
| B2 | **构建产物必须放在 `-derivedDataPath /tmp/miniclaw-build`**，绝不放进项目目录 | 避免污染 git / Xcode 索引 |
| B3 | **沙盒 workaround (`-disable-sandbox`) 只通过命令行传参**，不写进 `project.yml` | 保持 project.yml 干净可移植。⚠️ 必须作为 `OTHER_SWIFT_FLAGS`（Swift 前端开关）传入；当成顶层 xcodebuild 选项会直接报 `invalid option '-disable-sandbox'` |
| B4 | ~~**XcodeGen 先于 xcodebuild**~~ **【已作废 2026-09-15】**：源文件增删/移动**不要**跑 `xcodegen generate`——它会直接产出编不过的工程；`project.pbxproj` 是权威，在其上直接改 | 更正依据：`.workbuddy/memory/2026-09-15.md` 记忆核对结论（原条目与工作区笔记相反） |
| B5 | **Xcode 工程相关操作一律优先走 Xcode MCP 通道**——构建、编译诊断、运行/安装、抓日志、调试、设备交互、工程/方案/目标/目的机查询、测试、崩溃与性能；**能走 MCP 就不得**改用 `xcodebuild` / `devicectl` / 手工读工程文件替代 | MCP 与 Xcode 状态**同源**（同一个 workspace/scheme/目的机），且不受外部进程沙箱干扰——CLI 构建会因 `sandbox-exec` 与 Swift 宏插件被拒而炸出上千条假错误（实测 `SwiftUIMacros.StateMacro … malformed response`） |

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

- [ ] `xcodegen generate && xcodebuild build` → **BUILD SUCCEEDED**
- [ ] 构建产物在 `/tmp/miniclaw-build`（不在项目内）
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
