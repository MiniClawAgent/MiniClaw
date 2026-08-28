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
`Info.plist` 声明了以下用途描述，但经全库检索，**对应能力未真实落地**：
- `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` → 无 `HKHealthStore` / `import HealthKit` 代码路径（仅 `PermissionManager.swift` 引用字符串，无真实读写）。
- `NSHomeKitUsageDescription` → `AppleFrameworkTools` 仅有 homekit action schema，无真实 HomeKit 调用。
- `NSPhotoLibraryUsageDescription` → 无 `PHPhotoLibrary` / `import Photos` 调用。
- `NSRemindersUsageDescription` → 路线图 v1.2 才规划，当前未实现。
- `NSBluetoothAlwaysUsageDescription` / `NFCReaderUsageDescription` → 仅有 schema，无真实 CoreBluetooth/CoreNFC 调用链路。

**判定（对照 App Store Review Guidelines）**：
- 指南无"仅声明描述即拒"的明文条款，但 **2.3.1(a)（禁止休眠/未文档化功能）** 与 **5.1.1(ii)(iv)（目的字符串须准确对应实际使用、不得诱导不必要授权）**、**5.1.1(iii) Data Minimization** 共同约束：声明了用途却无对应功能，会被判定为"误导性目的字符串 / 未文档化功能"，审核常因此要求移除或补充。
- **整改方向（二选一，需你确认）**：
  - **方案 A（推荐，最小风险）**：移除当前无对应代码路径的用途描述（Health/HomeKit/Photos/Reminders/Bluetooth/NFC/Apple Music），仅保留确有调用或即将上线的（Camera/Microphone/Location/LocalNetwork/Notifications）。审核按"最小权限"原则通过率最高。
  - **方案 B**：在 v1.0 真的把这些工具补齐并接线（工程量大、引入新框架依赖与权限弹窗，且偏离"辅助上架"主线，不推荐）。

### 风险 R2 — 隐私营养标签须与 PrivacyInfo.xcprivacy 一致
`PrivacyInfo.xcprivacy` 已声明收集 Health/Photos 等数据类型，但 App Store Connect 上的**隐私营养标签（App Privacy）是独立填的**，须人工保持一致。若清单声明了 Health 收集、但用途描述（R1）又要移除 Health，则营养标签也需同步下调。**R1 与营养标签须联动处理。**

### 风险 R3 — Required Reason API（必填理由 API）
若代码使用了 `UserDefaults`、文件系统、`System Boot Time`、`Disk Space` 等必填理由 API，PrivacyInfo 必须附带对应 reason code。当前工程大量使用 SwiftData/SQLite（`/var/MiniClaw/`）、`UserDefaults`（SettingsStore），**计划落地时需逐项核对是否触发 Required Reason API，并补全 reason code**（否则上传时 Xcode 告警、可能卡审核）。

### 风险 R4 — 后台模式真实性
`UIBackgroundModes` 含 `audio` / `processing`，对应后台 Agent 执行（TaskPipController / BGTask）。须确认：
- 后台 Agent 执行是真有代码路径（否则 `processing` 模式违反 2.5.4 后台滥用条款）；
- `audio` 模式确有录音/播放场景（否则违反 Guidelines 最小化原则）。
**核查结论将决定 `UIBackgroundModes` 是否需要精简。**

### 风险 R5 — shell_execute 真机占位
`HostExecutor` 在 iOS 真机为占位（iSH 未接入），`shell_execute` 真机返回"不可用"。上架物料/审核备注须如实说明，避免被问到"为何有 shell 能力却不可用"时无法自圆。当前作为占位保留不影响上架（不弹窗、不静默采集），但**审核备注（Notes for Review）须诚实描述**。

---

## 四、计划步骤（按优先级，标注影响范围）

### P0 — 上架合规收敛（先于一切）
1. **R1 权限声明整改**：确认方案 A 或 B → 若 A，清理 `Info.plist` 无对应能力的用途描述。
   - 影响范围：`Info.plist`（纯声明，无逻辑改动）；需同步检查 `PermissionManager.swift` 是否依赖这些 key。
   - 回滚：`git` 还原 Info.plist 即可。
2. **R2 营养标签联动**：输出一份「PrivacyInfo.xcprivacy ↔ App Store Connect 隐私问卷」对照清单，供你在 Connect 后台逐项填写。
3. **R3 Required Reason API 核对**：扫描 `UserDefaults` / 文件 API / 系统启动时间 / 磁盘空间使用，列出需补 reason code 的项，补入 PrivacyInfo.xcprivacy。
4. **R4 后台模式核查**：确认 `processing`/`audio` 后台路径真实性；必要时精简 `UIBackgroundModes`。

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
