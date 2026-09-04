import Foundation
import UIKit
import PDFKit

struct MemoryWriteTool: AgentTool {
    /// 复盘分身等后台 Agent 使用免确认实例，避免触发（当前仅元数据的）确认策略。
    private let bypassConfirmation: Bool
    var resumePolicy: ResumePolicy { bypassConfirmation ? .retryable : .requiresUserConfirmation }
    let name = "memory_write"

    init(bypassConfirmation: Bool = false) {
        self.bypassConfirmation = bypassConfirmation
    }

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "memory_write",
            description: String(localized: "memory_write_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "content": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_memory_content")),
                    "target": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_memory_target_desc"), enum: ["long_term", "daily"]),
                    "mode": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_mode_append_replace_edit"), enum: ["append", "replace", "edit"]),
                    "old_string": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_edit_old_string")),
                    "new_string": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_edit_new_string")),
                ],
                required: ["target", "mode"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 设置快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let settings = await SettingsStore.shared.snapshot()
        // 记忆总开关：关闭时任何记忆写入都被拒绝（含后台复盘分身）。
        guard settings.memory.isEnabled else {
            return ToolResult(success: false, text: String(localized: "err_memory_disabled_write"))
        }
        guard let target = parameters["target"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_target_long_daily"))
        }

        let modeString = parameters["mode"] as? String ?? "append"

        do {
            switch target {
            case "long_term":
                switch modeString {
                case "append", "replace":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters(String(format: String(localized: "core_missing_content_for_mode"), modeString))
                    }
                    let mode: LongTermMemoryWriteMode = modeString == "replace" ? .replace : .append
                    let path = try MemoryManager.shared.writeLongTermMemory(content, mode: mode, settings: settings)
                    return ToolResult(success: true, text: String(format: String(localized: "long_term_memory_written"), path))
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters(String(localized: "err_mode_edit_need_strings"))
                    }
                    let path = try MemoryManager.shared.editMemory(target: .longTerm, oldString: oldString, newString: newString, settings: settings)
                    return ToolResult(success: true, text: String(format: String(localized: "long_term_memory_updated"), path))
                default:
                    throw ToolError.invalidParameters(String(localized: "err_mode_invalid"))
                }
            case "daily":
                // 「自动保存每日记忆」开关：关闭时不写入每日记忆文件（不影响每日记忆的读取）。
                guard settings.memory.autoSaveDaily else {
                    return ToolResult(success: false, text: String(localized: "daily_memory_save_disabled"))
                }
                switch modeString {
                case "append":
                    guard let content = parameters["content"] as? String else {
                        throw ToolError.invalidParameters(String(localized: "err_mode_append_need_content"))
                    }
                    let path = try MemoryManager.shared.writeDailyMemory(content, settings: settings)
                    return ToolResult(success: true, text: String(format: String(localized: "daily_memory_written"), path))
                case "edit":
                    guard let oldString = parameters["old_string"] as? String,
                          let newString = parameters["new_string"] as? String else {
                        throw ToolError.invalidParameters(String(localized: "err_mode_edit_need_strings"))
                    }
                    let path = try MemoryManager.shared.editMemory(target: .daily, oldString: oldString, newString: newString, settings: settings)
                    return ToolResult(success: true, text: String(format: String(localized: "daily_memory_updated"), path))
                default:
                    throw ToolError.invalidParameters(String(localized: "err_daily_modes"))
                }
            default:
                throw ToolError.invalidParameters(String(localized: "err_target_invalid"))
            }
        } catch {
            return ToolResult(success: false, text: error.localizedDescription)
        }
    }
}

// MARK: - Memory Get Tool

struct MemoryGetTool: AgentTool {
    let name = "memory_get"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "memory_get",
            description: String(localized: "memory_search_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "keyword": JSONSchema.JSONProperty(type: "string", description: String(localized: "search_keyword_param")),
                    "scope": JSONSchema.JSONProperty(type: "string", description: String(localized: "search_scope_param"), enum: ["long_term", "daily", "all"]),
                ],
                required: ["keyword"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        // 设置快照：后台线程不裸读 SettingsStore（2026-08-13 竞争修复）。
        let settings = await SettingsStore.shared.snapshot()
        // 记忆总开关：关闭时禁止检索记忆（与 memory_write 一致）。
        guard settings.memory.isEnabled else {
            return ToolResult(success: false, text: String(localized: "err_memory_disabled_search"))
        }
        guard let keyword = parameters["keyword"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_keyword"))
        }

        let scopeStr = parameters["scope"] as? String ?? "all"
        let scope: MemorySearchScope
        switch scopeStr {
        case "daily": scope = .daily
        case "long_term": scope = .longTerm
        case "all": scope = .all
        default: throw ToolError.invalidParameters(String(localized: "err_scope_invalid"))
        }

        let results = await MemoryIndexer.shared.search(keyword: keyword, scope: scope)

        if results.isEmpty {
            return ToolResult(success: true, text: String(localized: "memory_not_found"))
        }

        return ToolResult(success: true, text: results.joined(separator: "\n\n---\n\n"))
    }
}

