# Scene #17 — 辅助 MiniClaw「Agent 应用」上架（计划）

> 状态：计划阶段（暂不动代码）
> 生成日期：2026-08-25
> 依据：仓库当前真实状态（git HEAD = v1.0.0-build8）+ App Store Review Guidelines 核查

---

## 一、背景与目标

MiniClaw 的产品定位是「万能 Agent 应用」（术语表原文）。截至本次接手：
- 工程已到 **v1.0.0-build8**，主线收尾（i18n 备案号跳转、滚动抖动修复、版本号读 `Bundle.main` 真实值）已落在 git HEAD。
- Agent 运行时 / 工具 / 子 Agent / MCP / Skills / 后台执行 / 多 Provider·OAuth / 全量 i18n **均已基本实现并编译通过基线**。

Scene #17 的目标是 **辅助把 MiniClaw 送审上架**，而非继续堆功能。核心工作 = 上架合规盲点排查 + 多 target 编译验证 + 物料自检。

---

## 二、上架现状盘点（已核实）

| 项 | 状态 | 证据 |
|----|------|------|
| 版本号 / Build | ✅ 已就绪（1.0 / 8），关于页读 `Bundle.main` | commit `eb0e192` v1.0.0-build8 |
| 工信部 ICP 备案号 | ✅ 已加，可点跳转 beian.miit.gov.cn | `SettingsView.swift:177` |
| 隐私清单 PrivacyInfo.xcprivacy | ⚠️ 已声明 Location/Health/Photos/Audio/Camera/Calendar 等数据类型 | `PrivacyInfo.xcprivacy` |
| 出口加密声明 | ✅ `ITSAppUsesNonExemptEncryption = NO` | `Info.plist:34` |
| Info.plist 权限用途描述 | ⚠️ 声明了 12+ 敏感权限（见第三节） | `Info.plist:38-76` |
| 后台模式 / BGTask | ✅ audio/fetch/processing/remote-notification + 2 个 BGTask id | `Info.plist:79-90` |
| 多 target | ✅ MiniClaw / MiniClawKit / MiniClawWidget / ShareExtension / MiniClawTests | `project.yml:47` |
| MCP（HTTP/SSE + STDIO） | ✅ 真实实现，非占位 | `MCPClient.swift` / `StdioMCPClient.swift` |
| 子 Agent | ✅ 已实现（派发/读取结果/关闭/Profile/设置） | `SubAgent/` + `Tools/` |
| i18n | ✅ 全量本地化（中英文） | `Localizable.xcstrings` |

---

## 三、核心风险点（上架前必须先收敛）

### 风险 R1 — 权限用途描述与实际功能不符（最高优先级）
> **2026-08-31 复核更新**：原始清单已与现状不符，以下为重新全库检索后的判定。
> 关键区分——「**有授权链路**」（`PermissionManager` 会真发系统授权请求）≠「**有真实功能**」（真的读写数据），二者对本风险的判定不同。

- ✅ `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` → **已落地，退出本风险项**。`Tools/HealthKitTools.swift` + `PermissionManager` 构成完整读写链路（读 24 项 / 写 8 项白名单），见 `f2f19e3`。
- ⚠️ `NSPhotoLibraryUsageDescription` → **仅有授权链路，无实际读写**。`requestPhotos()` 会真发 `PHPhotoLibrary.requestAuthorization`，但全库无 `UIImagePickerController` / `PHPickerViewController`。
- ⚠️ `NSRemindersUsageDescription`（及 `NSCalendarsUsageDescription`）→ **仅有授权链路，无实际增删改**。`requestEK()` 会真发 `requestFullAccessToReminders`，但全库无 `EKEvent` / `EKReminder`。
- ❌ `NSHomeKitUsageDescription` → 无 `HMHomeManager` 引用，入口保持隐藏。
- ❌ `NSBluetoothAlwaysUsageDescription` / `NFCReaderUsageDescription` / `NSAppleMusicUsageDescription` → 无 `CBCentralManager` / `NFCNDEFReaderSession` / `MPMediaLibrary` 引用。

**判定（对照 App Store Review Guidelines）**：
- 指南无"仅声明描述即拒"的明文条款，但 **2.3.1(a)（禁止休眠/未文档化功能）** 与 **5.1.1(ii)(iv)（目的字符串须准确对应实际使用、不得诱导不必要授权）**、**5.1.1(iii) Data Minimization** 共同约束：声明了用途却无对应功能，会被判定为"误导性目的字符串 / 未文档化功能"，审核常因此要求移除或补充。
- **整改方向（沿用原二选一框架，但清单已按三分类重划）**：
  - **方案 A（推荐，最小风险）**：移除**零引用**的用途描述（HomeKit / Bluetooth / NFC / Apple Music），保留确有调用或即将上线的（Camera / Microphone / Location / LocalNetwork / Notifications）。
    - 注：Health **已从原清单剔除**——它已真实落地，属"有功能"，不在移除范围。
    - Photos / Reminders / Calendars 属**中间态**（有授权链路、无读写），见下方独立处理。
  - **方案 B**：在 v1.0 把这些工具补齐并接线（工程量大、引入新框架依赖与权限弹窗，且偏离"辅助上架"主线，不推荐）。
- **中间态的处置（Photos / Reminders / Calendars）— 需你定夺**：
  - 现状：授权弹窗会真弹（`requestPhotos()` / `requestEK()`），但弹完之后**没有任何功能消费这批数据**。
  - 风险性质：比"零引用"轻（毕竟有真授权动作），但比"有功能"重——审核若追问"你要这个权限干什么"，目前答不上来。
  - 两个可选动作：① 一并移除描述 + 撤掉授权入口（与方案 A 一致，最省事）；② 保留描述但**先补一个最小可用功能**（如照片读取 / 提醒创建），让声明与功能对得上。
  - 建议：走 ①。v1.0 主线是过审，不为未规划的功能预留权限。

### 风险 R2 — 隐私营养标签须与 PrivacyInfo.xcprivacy 一致

> **2026-08-31 复核**：`PrivacyInfo.xcprivacy` 实际声明 **9 项** `NSPrivacyCollectedDataTypes`、**4 项** `NSPrivacyAccessedAPITypes`。下表把它与 R1 的落地状态逐一对照——这是填 Connect 隐私问卷时的唯一依据。

| 声明的收集类型 | R1 落地状态 | 结论 |
|---|---|---|
| Location | ✅ 有真实功能（`LocationTools.swift` + 显著位置变化） | 保留 |
| Health | ✅ 有真实功能（读 24 / 写 8） | 保留 |
| Camera | ✅ 有入口 | 保留 |
| AudioData | ✅ 有真实功能（`SFSpeechRecognizer` 语音输入） | 保留 |
| UserContent | ✅ 会话内容即用户内容 | 保留 |
| Diagnostics | ✅ 崩溃日志 | 保留 |
| PhotosOrVideos | ⚠️ 仅有授权链路，无读写 | **随 R1 定夺：若移除描述则同步下调** |
| Calendar | ⚠️ 仅有授权链路，无增删改 | 同上 |
| Reminders | ⚠️ 仅有授权链路，无增删改 | 同上 |

- 全部 9 项均为 `Linked=false` / `Tracking=false` / `Purpose=AppFunctionality`，**无追踪、无第三方共享**，与营养标签填写口径一致。
- R1 提议移除的 HomeKit / Bluetooth / NFC / Apple Music **未声明任何收集类型**，故移除描述**不牵动营养标签**——这是把它们列为首选清理项的原因之一。
- **R1 与营养标签必须联动**：任何从 `Info.plist` 摘掉的权限，其对应收集类型也要从清单与 Connect 问卷同步摘掉，否则出现"清单说收集、App 说不要"的自相矛盾。

### 待办（R2 收尾，需你在 Connect 后台操作）
1. 按上表在 App Store Connect → App Privacy 逐项勾选（Health 需**展开到具体数据类型**：步数、心率、睡眠、体重…）。
2. 若 R1 最终摘掉 Photos / Calendar / Reminders，先改本清单、再填问卷，顺序不可颠倒。

### 风险 R3 — Required Reason API（必填理由 API）

> **2026-08-31 复核**：已全库扫描，四类必填理由 API 的声明**均已存在**，逐项核对如下。

| 类别 | 声明的 reason | 实测使用情况 | 结论 |
|---|---|---|---|
| FileTimestamp | `C617.1` | ✅ 大量使用 `.contentModificationDateKey`（`MemoryIndexer` / `BackgroundScheduler` / `ZipArchive` / `CrashReporter` 等 10+ 处） | 匹配 |
| DiskSpace | `E174.1` | ✅ `InfraTools.swift:197` 用 `.volumeAvailableCapacityKey` 展示磁盘余量 | 匹配 |
| UserDefaults | `CA92.1` | ✅ `SettingsStore` 使用**标准** `UserDefaults`；全库 `UserDefaults(suiteName:)` **零命中**（无 App Groups 共享 suite）→ 标准 `CA92.1` 正确，**不需要** `1C8F.1` | 匹配 |
| SystemBootTime | `35F9.1` | ⚠️ 全库 `systemUptime` / `mach_absolute_time` / `clock_gettime` / `sysctl(KERN_BOOTTIME)` **零命中** | **声明了但找不到使用点**，见下 |

- **SystemBootTime 存疑项**：未删也未加，待你定夺。两种可能：① 遗留声明（早期写过启动时间逻辑，后已删）→ 可安全移除；② 由 vendored 预编译库（iSH `libish.a` 等）内部使用 → **必须保留**，因为第三方静态库自身不携带 PrivacyInfo 时，使用行为要算在宿主 App 头上。
  - 判定方法：若最终 archive 的二进制里能 `nm` 到 `mach_absolute_time` / `clock_gettime` 符号，走 ②；否则走 ①。
  - 风险提示：**多声明不会导致拒审，漏声明才会**。故在核实前倾向保留。
- **CoreLocation / HealthKit 不在 Required Reason 四类之列**，无需 reason code。

### 风险 R4 — 后台模式真实性 ✅ 已闭环（2026-08-31）

**结论：`UIBackgroundModes` 精简为三项，全部有真实能力支撑。**

| 模式 | 结论 | 依据 |
|---|---|---|
| `fetch` | ✅ 保留 | `BackgroundScheduler.swift` 注册 `BGAppRefreshTask`（过期文件维护） |
| `processing` | ✅ 保留 | 同上，注册 `BGProcessingTask`（记忆整理） |
| `remote-notification` | ✅ 保留 | 通知链路完整 |
| `audio` | ❌ 已移除（`dd8183d`） | 无对应持久音频功能，**实测导致 2.5.4 拒审** |
| `location` | ❌ 已移除（`e204790`） | 官方语义是给「标准定位服务 `startUpdatingLocation`」用的；本 App 只用显著位置变化 + `requestLocation`，且无面向用户的定位 UI，**与 `audio` 属同一条拒因** |

- **"保证任务在后台跑完"的正确机制**：`BackgroundTaskCoordinator` 用 `beginBackgroundTask` 取宽限期，过期前让 Agent 循环在**安全点**干净停下，回前台用 continuation 续跑。刻意不声明任何「可常驻」的后台模式——这类模式必须对应真实的持久功能，否则即触发 2.5.4 拒审。
- **补充事实**：仅声明 `location` 后台模式对「App 被系统终止」一幕**完全无效**——被杀后自动重启需要 **Always** 授权（且仅限显著位置变化/访问/区域监测三种服务），本 App 只申请 WhenInUse。
- **可复用核查程序**（日后每动 `UIBackgroundModes` 都走一遍）：① 查官方对该模式的语义定义 → ② 全库 grep 该模式专属 API 是否真被调用 → ③ 查有无**面向用户**的功能承载它。三项任一不成立即应移除。

### 风险 R5 — shell_execute 真机占位
`HostExecutor` 在 iOS 真机为占位（iSH 未接入），`shell_execute` 真机返回"不可用"。上架物料/审核备注须如实说明，避免被问到"为何有 shell 能力却不可用"时无法自圆。当前作为占位保留不影响上架（不弹窗、不静默采集），但**审核备注（Notes for Review）须诚实描述**。

---

## 四、计划步骤（按优先级，标注影响范围）

### P0 — 上架合规收敛（先于一切）
1. **R1 权限声明整改**：**已完成一半，剩余待你定夺**。
   - ✅ **已完成**：Health 从风险清单剔除（`f2f19e3` 已真实落地，读 24 / 写 8），用途描述已具体化并四语同步（`af18c3d`）。
   - ⏳ **待定夺**：① 移除**零引用**的四项描述（HomeKit / Bluetooth / NFC / Apple Music）；② Photos / Reminders / Calendars 三项目前「有授权链路、无读写功能」，建议一并移除。
   - 影响范围：`Info.plist`（纯声明）+ 4 份 `InfoPlist.strings` + `Localizable.xcstrings`；需同步检查 `PermissionManager.swift` 里 `requestPhotos()` / `requestEK()` 的入口是否一并撤掉。
   - 回滚：`git` 还原 Info.plist 即可。
2. **R2 营养标签联动**：对照清单**已产出**（见 R2 表格），剩余动作在你这边——按表在 Connect 后台逐项勾选，Health 需展开到具体数据类型。
3. **R3 Required Reason API 核对**：✅ **已核对完毕**（见 R3 表格）。`FileTimestamp` / `DiskSpace` / `UserDefaults` 三项声明与使用点完全匹配；仅 `SystemBootTime(35F9.1)` 找不到使用点，待你定夺保留或移除。
4. **R4 后台模式核查**：✅ **已完成**（`audio` 于 `dd8183d` 移除、`location` 于 `e204790` 移除；现仅保留 `fetch` / `processing` / `remote-notification` 三项，均有真实能力支撑）。结论详见风险 R4。

### P1 — 编译与真机验证（工程纪律 B1 强制）
5. **全 target 增量编译验证**：`xcodegen generate` → `xcodebuild build`（device destination，`CODE_SIGNING_ALLOWED=NO`，derivedData 走 `/tmp/miniclaw-build`），确认 MiniClaw / MiniClawKit / Widget / ShareExtension / Tests 全部 BUILD SUCCEEDED。
6. **真机 device build**：按纪律用真实签名目标跑一次 device build（用户选 Team），确认红构建不在。

### P2 — 上架物料自检
7. **截图 / 预览 / 关键词 / 描述**自检（中文语境，按 2.3.3 / 2.3.8 元数据准确性）。
8. **隐私政策链接**：5.1.1(i) 要求 App 内与元数据均提供隐私政策链接——核查 MiniClaw 内是否有隐私政策入口。
9. **审核备注（Notes for Review）**：起草诚实的能力说明（含 shell 占位、后台 Agent 范围、数据不共享第三方等），避免 2.3.1(a) 误判。

### P3 — 收尾（仅当 P0–P2 无阻塞）
10. 打 `v1.0.0-build9`（或你指定的 build）tag，准备上传 archive。

---

## 五、执行约束（工程纪律）
- 所有改动**先给影响范围分析** → 你确认后再动代码。
- 每次代码改动后**必须全 target 编译验证 BUILD SUCCEEDED**（B1），构建产物走 `/tmp/miniclaw-build`（B2）。
- 改动 `Info.plist` / entitlements / 模型属此类高风险项，须列影响范围 + 回滚方案（纪律第五章）。
- 不擅自加功能、不自由发挥（纪律第九章）。

---

## 六、待你确认的关键决策
- **R1 选方案 A（精简权限描述，推荐）还是方案 B（补齐工具）？** —— 直接决定上架风险与工作量。
- 是否需要我现在就**实际跑一次全 target 编译**（P1 第 5 步）来拿到真实基线？这步会触发构建，但不改代码，符合"暂不动代码"边界（仅验证）。
- 真机 device build 的 Team 是否由你在 Xcode 侧自选自填（按纪律 DEVELOPMENT_TEAM 不固定）？
