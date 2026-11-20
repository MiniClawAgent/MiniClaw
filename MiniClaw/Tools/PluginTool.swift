import Foundation

// MARK: - 插件管理工具（AI 自主安装/启停插件）
//
// TopFlow 2026-09-01 拍板的 AI 自主闭环：AI 可用 plugin-creator 技能打包 .mpk 后，
// 通过本工具自主安装并启用，无需用户在插件页手动操作。
//
// 安全边界（用户可控制）：
// - 「通用设置 → 默认行为 → AI 安装插件需确认」（默认开）：install 动作先经
//   ToolConfirmationBridge 弹窗，用户允许才落盘；关闭则直接安装。
// - 密钥永远不由 AI 经手：model 插件导入后供应商模板出现，Key 仍由用户填写。
// - 同名 id 重复导入跳过（不覆盖内置/已有插件，防误删语义与手动导入一致）。

struct PluginTool: AgentTool {
    let name = "miniclaw-plugin"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "miniclaw-plugin",
            description: String(localized: "miniclaw_plugin_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "plugin_tool_param_action"),
                        enum: ["list", "install", "enable", "disable"]),
                    "path": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "plugin_tool_param_path")),
                    "id": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "plugin_tool_param_id")),
                ],
                required: ["action"]
            )
        )
    )

    let currentSessionID: UUID?

    init(currentSessionID: UUID?) {
        self.currentSessionID = currentSessionID
    }

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_missing_action"))
        }
        switch action {
        case "list": return await list()
        case "install": return try await install(parameters)
        case "enable": return try await setState(parameters, enabled: true)
        case "disable": return try await setState(parameters, enabled: false)
        default:
            return ToolResult(success: false, text: String(localized: "plugin_tool_unknown_action") + " \(action)")
        }
    }

    // MARK: - list

    private func list() async -> ToolResult {
        var lines: [String] = [String(localized: "plugin_tool_list_header")]
        // [P2-8] 快照只用取一次：工具在后台 Task 里跑，裸读 @Published 设置会和主线程写并发。
        let settingsSnapshot = await SettingsStore.shared.snapshot()
        for dir in FileSystemManager.shared.allPluginDirectories() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data)
            else { continue }
            let key = m.name.isEmpty ? dir.lastPathComponent : m.name
            let enabled = settingsSnapshot.skillEnabledStates[key] ?? m.enabledByDefault
            let state = enabled ? String(localized: "plugin_tool_state_enabled") : String(localized: "plugin_tool_state_disabled")
            lines.append("- \(key) [\(m.type)] v\(m.version) — \(state)（id: \(dir.lastPathComponent)）")
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    // MARK: - install

    private func install(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let rawPath = parameters["path"] as? String, !rawPath.isEmpty else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_missing_path"))
        }
        let url = try FileSystemManager.shared.resolveAgentPath(rawPath, sessionID: currentSessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_path_not_found") + " \(rawPath)")
        }

        // 确认开关（通用设置 → 默认行为，默认开）：弹窗请求用户批准。
        let snapshotForPlugin = await SettingsStore.shared.snapshot()
        if snapshotForPlugin.defaults.aiPluginInstallRequiresConfirmation {
            let title = await MainActor.run {
                currentSessionID.flatMap { SessionManager.shared.session(id: $0)?.title }
                    ?? String(localized: "unknown_session")
            }
            let summary = String(localized: "plugin_tool_confirm_summary") + " \(url.lastPathComponent)"
            let approved = await ToolConfirmationBridge.shared.request(
                toolName: name, summary: summary,
                sessionID: currentSessionID ?? UUID(), sessionTitle: title)
            guard approved else { return ToolResult(success: false, text: String(localized: "plugin_tool_install_denied")) }
        }

        let result = await MainActor.run { SkillManager.shared.importSkillFile(from: url) }

        // 安装即启用（AI 安装的语义就是直接使用）；soul 例外——排他单选由用户
        // 在详情页显式启用（启用即应用人格，属高影响操作）。
        var enabledNames: [String] = []
        for dirName in result.imported {
            let dir = FileSystemManager.shared.allPluginDirectories()
                .first { $0.lastPathComponent == dirName }
            guard let dir,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  m.type != "soul"
            else { continue }
            let key = m.name.isEmpty ? dirName : m.name
            await MainActor.run { SkillManager.shared.setEnabled(key, true) }
            enabledNames.append(key)
        }

        var text = result.message
        if !result.imported.isEmpty {
            text += "\n" + String(format: String(localized: "plugin_tool_installed_and_enabled"), result.imported.joined(separator: ", "))
            if !enabledNames.isEmpty {
                text += "\n" + String(localized: "plugin_tool_enabled_list") + " " + enabledNames.joined(separator: ", ")
            }
            if !result.skipped.isEmpty {
                text += "\n" + String(localized: "plugin_tool_skipped_same_id") + " " + result.skipped.joined(separator: ", ")
            }
        }
        return ToolResult(success: true, text: text)
    }

    // MARK: - enable / disable

    private func setState(_ parameters: [String: Any], enabled: Bool) async throws -> ToolResult {
        guard let id = parameters["id"] as? String, !id.isEmpty else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_missing_id"))
        }
        // setEnabled 的键是 manifest.name（空则目录名）；用户/AI 传 id 或 name 均可。
        let dirs = FileSystemManager.shared.allPluginDirectories()
        guard let dir = dirs.first(where: { $0.lastPathComponent == id })
            ?? dirs.first(where: {
                guard let data = try? Data(contentsOf: $0.appendingPathComponent("plugin.json")),
                      let m = try? JSONDecoder().decode(PluginManifest.self, from: data)
                else { return false }
                return m.name == id
            })
        else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_unknown_id") + " \(id)")
        }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plugin.json")),
              let m = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            return ToolResult(success: false, text: String(localized: "plugin_tool_unknown_id") + " \(id)")
        }
        let key = m.name.isEmpty ? dir.lastPathComponent : m.name
        await MainActor.run { SkillManager.shared.setEnabled(key, enabled) }
        let verb = enabled ? String(localized: "plugin_tool_enabled_done") : String(localized: "plugin_tool_disabled_done")
        return ToolResult(success: true, text: verb + " \(key)")
    }
}
