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
    /// 工具描述（模型可见，作者撰写，不走 App L10n——同技能正文）。
    var description: String = ""
    /// 参数 JSON Schema（对象），原样下发给模型。
    var parameters: JSONSchema = JSONSchema(type: "object")
    /// shell 命令模板：在会话沙箱 shell 中执行，参数 JSON 经 stdin 传入。
    /// POSIX sh 语法（BusyBox ash）；执行复用 shell_execute 同一运行时与安全面。
    var command: String = ""
    /// 执行超时（秒），缺省 120（与工具调用铁律一致）。
    var timeout: Int = 120

    private enum CodingKeys: String, CodingKey {
        case name, description, parameters, command, timeout
    }

    init(
        name: String = "",
        description: String = "",
        parameters: JSONSchema = JSONSchema(type: "object"),
        command: String = "",
        timeout: Int = 120
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.command = command
        self.timeout = timeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? d.description
        parameters = try c.decodeIfPresent(JSONSchema.self, forKey: .parameters) ?? d.parameters
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? d.timeout
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
        let delimiter = "MINICLAW_IN_\(UUID().uuidString.prefix(8))"
        let wrapped = "cat <<'\(delimiter)'\n\(jsonInput)\n\(delimiter)\n| \(definition.command)"

        do {
            let result = try await ShellRuntimeFactory.runtime.execute(
                command: wrapped,
                environment: environment,
                workingDirectory: nil,
                timeout: TimeInterval(definition.timeout),
                onLine: nil,
                sessionID: currentSessionID
            )
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n\(result.stderr)")
            let full = output.isEmpty ? L10n.l("no_output") : output
            // 隐私掩码与超限转存：与 shell_execute 同口径（同一份设置快照）。
            var text = full
            if settings.envvarsPrivacyMode {
                for v in settings.envvars where !v.value.isEmpty {
                    text = text.replacingOccurrences(of: v.value, with: "***")
                }
            }
            let thresholdBytes = settings.files.autoOffloadThresholdKB * 1024
            let final = FileSystemManager.shared.offloadIfLarge(text, thresholdBytes: thresholdBytes, sessionID: currentSessionID)
            return ToolResult(success: result.exitCode == 0, text: final)
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Tool 插件管理器

/// 扫描已启用的 tool 类型插件（`plugins/tool/<id>/tools/*.json`），
/// 产出声明式工具定义供 buildToolRouter 注册。
/// 无缓存：buildToolRouter 每轮重建，扫描为量级极小的目录 IO；
/// loadSkills 自带缓存，此处只做轻量目录遍历。
/// @MainActor：与 SkillManager 同隔离域（buildToolRouter 在 MainActor 上调用）。
@MainActor
final class ToolPluginManager {
    static let shared = ToolPluginManager()
    private init() {}

    /// 已启用插件的全部声明式工具定义（自动跳过非法项并日志）。
    func enabledToolDefinitions() -> [ToolDefinition] {
        let packages = SkillManager.shared.loadSkills().filter { $0.type == "tool" && $0.isEnabled }
        guard !packages.isEmpty else { return [] }
        let fm = FileManager.default
        var result: [ToolDefinition] = []
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
                guard def.isValidName, !def.command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    AppLogger.shared.warn(
                        "[ToolPlugin] 工具名非法或缺 command，跳过: \(pkg.directoryName)/\(def.name)",
                        category: "Plugin", subsystem: "Tool"
                    )
                    continue
                }
                result.append(def)
            }
        }
        return result
    }
}
