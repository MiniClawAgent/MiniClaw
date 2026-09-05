import Foundation

// MARK: - Tool 插件（Stage-6a：声明式 shell 工具包）

/// 声明式工具定义（`tools/<name>.json`，一包多工具，主键=文件名）。
/// 工具 = JSON Schema + 一条 shell 命令模板：模型调用时参数以 JSON 从 stdin
/// 喂给命令，stdout 即工具结果——与 dsh 的脚本工具同构。
///
/// **容错解码铁律（同 PluginManifest 2026-08-27）**：显式 init(from:) 全字段
/// decodeIfPresent 落默认值；"导入判定"与"加载判定"必须用同一套解析口径。
struct ToolDefinition: Codable {
    /// 工具名（模型可见）。仅允许 [A-Za-z0-9_-]，与内置/MCP 重名时拒绝注册。
    var name: String = ""
    /// 工具描述（模型可见，作者撰写，不走 App 本地化查表——同技能正文）。
    var description: String = ""
    /// 参数 JSON Schema（对象），原样下发给模型。
    var parameters: JSONSchema = JSONSchema(type: "object")
    /// shell 命令模板：在会话沙箱 shell 中执行，参数 JSON 经 stdin 传入。
    /// POSIX sh 语法（BusyBox ash）；执行复用 shell_execute 同一运行时与安全面。
    var command: String = ""
    /// 执行超时（秒），缺省 120（与工具调用铁律一致）。
    var timeout: Int = 120
    /// 执行后端："shell"（默认，声明式脚本）| "builtin"（内置 Swift 工具的插件化声明，
    /// Stage-6b 内置迁移用——包只做声明载体，schema/执行仍在 Swift 侧单一真相源）。
    var backend: String = "shell"

    private enum CodingKeys: String, CodingKey {
        case name, description, parameters, command, timeout, backend
    }

    init(
        name: String = "",
        description: String = "",
        parameters: JSONSchema = JSONSchema(type: "object"),
        command: String = "",
        timeout: Int = 120,
        backend: String = "shell"
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.command = command
        self.timeout = timeout
        self.backend = backend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? d.description
        parameters = try c.decodeIfPresent(JSONSchema.self, forKey: .parameters) ?? d.parameters
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? d.timeout
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
    }

    /// 工具名合法性：模型调用靠名字精确匹配，只允许安全字符。
    var isValidName: Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

/// 声明式 shell 工具：把 `ToolDefinition` 适配为 AgentTool 挂进 ToolRouter。
/// 执行复用 shell_execute 的运行时与会话隔离；参数 JSON 经 heredoc（单引号定界符，
/// 内容零展开零转义）从 stdin 传入命令；stdout/stderr 即结果，隐私掩码/超限
/// offloads/cwd 标注与内置 shell 同口径。
struct DeclarativeShellTool: AgentTool {
    var resumePolicy: ResumePolicy { .requiresUserConfirmation }
    let definition: ToolDefinition
    let currentSessionID: UUID?

    var name: String { definition.name }

    var schema: ToolSchema {
        ToolSchema(
            type: "function",
            function: ToolSchema.FunctionDef(
                name: definition.name,
                description: definition.description,
                parameters: definition.parameters
            )
        )
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let settings = await SettingsStore.shared.snapshot()
        let environment = EnvVarStore.environmentDictionary(using: settings.envvars)

        // 参数 → stdin JSON（sortedKeys：同参同字节，保证请求与历史可复现）。
        let jsonInput: String
        if JSONSerialization.isValidJSONObject(parameters),
           let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]) {
            jsonInput = String(decoding: data, as: UTF8.self)
        } else {
            jsonInput = "{}"
        }
        // heredoc 单引号定界符：内容零展开零转义；分隔符带随机后缀，与 JSON 内容无碰撞面。
        // 管道必须与 cat 同一行（'| ' 开头的独立行是 sh 语法错误——2026-08-31 真机实测翻车点）。
        let delimiter = "MINICLAW_IN_\(UUID().uuidString.prefix(8))"
        let wrapped = "cat <<'\(delimiter)' | \(definition.command)\n\(jsonInput)\n\(delimiter)"

        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: wrapped,
                environment: environment,
                workingDirectory: nil,
                timeout: TimeInterval(definition.timeout),
                // 2026-09-05：接过程流 reporter——插件 shell 工具的执行输出
                // 与 shell_execute 同口径实时写入工具快照（此前 onLine: nil 全丢）。
                onLine: { line, _ in ToolProgressScope.reporter?(line) },
                sessionID: currentSessionID
            )
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n\(result.stderr)")
            let full = output.isEmpty ? String(localized: "no_output") : output
            // 隐私掩码与超限转存：与 shell_execute 同口径（同一份设置快照）。
            var text = full
            if settings.envvarsPrivacyMode {
                for v in settings.envvars where !v.value.isEmpty {
                    text = text.replacingOccurrences(of: v.value, with: "***")
                }
            }
            let thresholdBytes = settings.files.autoOffloadThresholdKB * 1024
            let final = FileSystemManager.shared.offloadIfLarge(text, thresholdBytes: thresholdBytes, sessionID: currentSessionID)
            if result.exitCode != 0 {
                // 失败诊断：退出码 + 结果前 200 字（已掩码）——工具卡报错时日志可定位。
                AppLogger.shared.warn(
                    "[ToolPlugin] 工具执行失败: \(definition.name) exit=\(result.exitCode) out=\(final.prefix(200))",
                    category: "Plugin", subsystem: "Tool"
                )
            }
            return ToolResult(success: result.exitCode == 0, text: final)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Tool 插件管理器

/// 扫描已启用的 tool 类型插件（`plugins/tool/<id>/tools/*.json`），
/// 按后端产出可注册的 AgentTool 实例：
/// - backend == "shell"：声明式脚本工具（DeclarativeShellTool）
/// - backend == "builtin"：内置 Swift 工具的插件化声明——按 name 从工厂注册表
///   构建实例（Stage-6b：系统能力类工具迁移为 builtin 包声明，启停由插件开关驱动）
/// 无缓存：buildToolRouter 每轮重建，扫描为量级极小的目录 IO；
/// loadSkills 自带缓存，此处只做轻量目录遍历。
/// @MainActor：与 SkillManager 同隔离域（buildToolRouter 在 MainActor 上调用）。
@MainActor
final class ToolPluginManager {
    static let shared = ToolPluginManager()
    private init() {}

    /// 记忆工具包 id：其启用态不以插件开关为准，而是与「设置-记忆-启用记忆」
    /// 同一个状态（单一真相源），避免两套开关各说各话。
    static let memoryPluginID = "com.miniclaw.builtin.memory"

    /// 记忆工具是否启用 = 记忆总开关（记忆设置页与插件列表共用此状态）。
    static func memoryToolsEnabled() -> Bool {
        SettingsStore.shared.settings.memory.isEnabled
    }

    /// 记忆开关写入（插件列表开关与记忆设置页共用）：与 MemorySettingsView.persist 同口径。
    static func setMemoryToolsEnabled(_ on: Bool) {
        SettingsStore.shared.settings.memory.isEnabled = on
        SettingsStore.shared.save()
    }

    /// 某个包是否为记忆工具包（按沙盒目录名判定）。
    static func isMemoryPlugin(directoryName: String) -> Bool {
        directoryName == memoryPluginID
    }

    /// 内置工具工厂注册表（Stage-6b 迁移的系统能力类工具）。
    /// name → 工具构造器：包内 `{"name": "...", "backend": "builtin"}` 声明按此映射；
    /// schema/执行逻辑仍是 Swift 侧单一真相源，包只承载「归属 + 启停」。
    /// 未列出的 builtin 声明按非法项跳过并日志。
    private static let builtinFactories: [String: (UUID?) -> AgentTool] = [
        "memory_write": { _ in MemoryWriteTool() },
        "memory_get": { _ in MemoryGetTool() },
        "apple-clipboard": { _ in AppleClipboardTool() },
        "apple-device": { _ in AppleDeviceTool() },
        "apple-nlp": { _ in AppleNLPTool() },
        "apple-notification": { _ in AppleNotificationTool() },
        "apple-open": { _ in AppleOpenTool() },
        "open-in-safari": { _ in SafariOpenTool() },
        "apple-speak": { _ in AppleSpeakTool() },
        "miniclaw_config": { _ in ConfigTool() },
        "miniclaw-model-use": { _ in MiniClawModelUseTool() },
        // 2026-08-31 新增：健康与定位。二者都是 iOS 原生能力，无法用 shell 后端表达。
        "apple-healthkit": { _ in AppleHealthKitTool() },
        "apple-location": { _ in AppleLocationTool() },
        // 2026-08-31 新增：日历 / 提醒 / 相册 / HomeKit。
        // 这四个原本是「有 schema、有 i18n、execute 却返回 not_implemented」的占位工具，
        // 与本轮补齐的四个真实现同名，故删占位后在此按同名注册即可。
        "apple-calendar": { _ in AppleCalendarTool() },
        "apple-reminders": { _ in AppleRemindersTool() },
        "apple-photos": { _ in ApplePhotosTool() },
        "apple-homekit": { _ in AppleHomeKitTool() },
        // 2026-09-01 新增：通讯录 / 地图 / 媒体播放 / 语音识别。
        "apple-contacts": { _ in AppleContactsTool() },
        "apple-maps": { _ in AppleMapsTool() },
        "apple-media": { _ in AppleMediaTool() },
        "apple-speech": { _ in AppleSpeechTool() },
        // 2026-09-01 新增：图片读取 / 端侧视觉分析。
        // 二者原名 read_image / vision_analyze，从 AgentRunService 的 toolRouter 迁来——
        // 归入 `apple-` 前缀族后应出现在插件列表。它们需要 sessionID 解析会话隔离路径，
        // 工厂闭包的入参就是 sessionID，故直接透传即可。
        "apple-image": { ReadImageTool(currentSessionID: $0) },
        "apple-vision": { VisionAnalyzeTool(currentSessionID: $0) },
    ]

    /// 已启用插件的全部工具实例（shell 与 builtin 后端统一产出；非法项跳过并日志）。
    func enabledPluginTools(sessionID: UUID?) -> [AgentTool] {
        let allToolPackages = SkillManager.shared.loadSkills().filter { $0.type == "tool" }
        // 首启时序兜底：bundled 同步是后台任务，同步未完成前沙盒里还没有内置 tool 包。
        // 此时按「内置能力全量可用」处理（与迁移前行为一致）——绝不能让内置工具
        // 因同步时序而消失。同步完成后缓存已失效（syncBundledPlugins 末尾），
        // 此后由包内声明与启用状态驱动。
        if allToolPackages.isEmpty {
            // 兜底：内置能力全量提供；但记忆工具仍受记忆总开关约束（单一真相源，
            // 总开关关闭时绝不注册记忆工具——否则与「设置-记忆」的语义打架）。
            return Self.builtinFactories.keys.sorted().compactMap { name in
                if (name == "memory_write" || name == "memory_get") && !Self.memoryToolsEnabled() {
                    return nil
                }
                return Self.builtinFactories[name]?(sessionID)
            }
        }
        // 记忆工具包的启用态取记忆总开关；其余包按插件开关。
        let packages = allToolPackages.filter { pkg in
            if Self.isMemoryPlugin(directoryName: pkg.directoryName) {
                return Self.memoryToolsEnabled()
            }
            return pkg.isEnabled
        }
        guard !packages.isEmpty else { return [] }
        let fm = FileManager.default
        var result: [AgentTool] = []
        for pkg in packages {
            let dir = FileSystemManager.shared.pluginTypeDir("tool")
                .appendingPathComponent(pkg.directoryName)
                .appendingPathComponent("tools")
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file),
                      let def = try? JSONDecoder().decode(ToolDefinition.self, from: data) else {
                    AppLogger.shared.warn(
                        "[ToolPlugin] 跳过非法工具定义: \(pkg.directoryName)/tools/\(file.lastPathComponent)",
                        category: "Plugin", subsystem: "Tool"
                    )
                    continue
                }
                guard def.isValidName else {
                    AppLogger.shared.warn(
                        "[ToolPlugin] 工具名非法，跳过: \(pkg.directoryName)/\(def.name)",
                        category: "Plugin", subsystem: "Tool"
                    )
                    continue
                }
                switch def.backend {
                case "builtin":
                    guard let factory = Self.builtinFactories[def.name] else {
                        AppLogger.shared.warn(
                            "[ToolPlugin] builtin 声明无对应工厂，跳过: \(pkg.directoryName)/\(def.name)",
                            category: "Plugin", subsystem: "Tool"
                        )
                        continue
                    }
                    result.append(factory(sessionID))
                case "shell":
                    guard !def.command.trimmingCharacters(in: .whitespaces).isEmpty else {
                        AppLogger.shared.warn(
                            "[ToolPlugin] shell 工具缺 command，跳过: \(pkg.directoryName)/\(def.name)",
                            category: "Plugin", subsystem: "Tool"
                        )
                        continue
                    }
                    result.append(DeclarativeShellTool(definition: def, currentSessionID: sessionID))
                default:
                    AppLogger.shared.warn(
                        "[ToolPlugin] 未知后端 \(def.backend)，跳过: \(pkg.directoryName)/\(def.name)",
                        category: "Plugin", subsystem: "Tool"
                    )
                }
            }
        }
        return result
    }
}
