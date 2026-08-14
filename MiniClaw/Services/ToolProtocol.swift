import Foundation

// MARK: - Tool Protocol

/// 工具在「暂停后恢复 / 重试」场景下的幂等策略。
///
/// v1 的暂停只在安全点生效（流式回合结束，或某个工具执行完），
/// 恢复时开一个全新 Loop 从检查点重放上下文，**不会**在工具执行中途重试，
/// 因此本策略在 v1 仅作为声明元数据存在，真正用于 v2 的「工具执行中途暂停 / 自动重试」。
enum ResumePolicy: String, Codable {
    /// 可安全自动重试（只读、查询类工具默认）。
    case retryable
    /// 重试前先向用户确认意图（如联网请求）。
    case queryBeforeRetry
    /// 任何重试都必须经用户显式确认（高副作用：写文件、执行命令、改设备状态等）。
    case requiresUserConfirmation
    /// 绝不自动重试（一次性、不可逆副作用）。
    case neverRetry
}

protocol AgentTool {
    var name: String { get }
    var schema: ToolSchema { get }
    func execute(_ parameters: [String: Any]) async throws -> ToolResult
    /// 该工具的恢复/幂等策略，默认 `.retryable`（只读/查询类）。
    /// 高副作用工具应覆盖为 `.requiresUserConfirmation` 或 `.neverRetry`。
    var resumePolicy: ResumePolicy { get }
    /// MiniClaw 注入到模型参数中的本地活动描述字段。
    /// 远端协议工具可覆盖为不会与服务端 schema 冲突的保留名。
    var activityParameterName: String { get }
}

extension AgentTool {
    var resumePolicy: ResumePolicy { .retryable }
    var activityParameterName: String { "activity" }
}

struct ToolSchema: Codable {
    let type: String
    let function: FunctionDef

    struct FunctionDef: Codable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}

/// 可无损承载任意 JSON 的递归值，同时供 MCP JSON-RPC、工具 schema 与各 LLM 协议复用。
indirect enum JSONSchemaValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case object([String: JSONSchemaValue])
    case array([JSONSchemaValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONSchemaValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONSchemaValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(jsonObject: Any) throws {
        switch jsonObject {
        case _ as NSNull:
            self = .null
        case let value as Bool:
            self = .boolean(value)
        case let value as Int:
            self = .integer(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try JSONSchemaValue(jsonObject: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try JSONSchemaValue(jsonObject: $0) })
        default:
            throw ToolError.invalidParameters(String(format: L10n.l("tool_json_convert_failed"), String(describing: type(of: jsonObject))))
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .object(let value): return value.mapValues(\.jsonObject)
        case .array(let value): return value.map(\.jsonObject)
        case .null: return NSNull()
        }
    }
}



struct ToolResult: @unchecked Sendable {
    let success: Bool
    let text: String
    var data: [String: Any]?
    var attachments: [URL]?
}

// MARK: - Tool Router

final class ToolRouter {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func execute(name: String, parameters: [String: Any]) async throws -> ToolResult {
        guard let tool = tools[name] else {
            throw ToolError.unknownTool(name)
        }
        return try await tool.execute(parameters)
    }

    /// 为所有工具统一注入 activity 元数据，要求模型描述本次调用的具体业务行为。
    /// 工具实现无需单独解析该字段；它仅用于会话页工具指示器展示。
    func allSchemas() -> [ToolSchema] {
        tools.values.map { tool in
            let original = tool.schema
            let activityParameterName = tool.activityParameterName
            var parameters = original.function.parameters
            var properties = parameters.properties ?? [:]
            properties[activityParameterName] = JSONSchema.JSONProperty(
                type: "string",
                description: "必填。用6-16字中文描述本次调用的具体行为，供工具指示器展示。例如：读取配置文件、搜索昨日记忆、创建日历事件、查询当前天气。不要填写工具名或原始 action。"
            )

            var required = parameters.required ?? []
            if !required.contains(activityParameterName) {
                required.append(activityParameterName)
            }
            parameters.properties = properties
            parameters.required = required

            return ToolSchema(
                type: original.type,
                function: ToolSchema.FunctionDef(
                    name: original.function.name,
                    description: original.function.description,
                    parameters: parameters
                )
            )
        }
    }

    func allToolNames() -> [String] {
        Array(tools.keys)
    }

    /// 查询某个已注册工具的恢复/幂等策略（未注册或默认返回 `.retryable`）。
    func resumePolicy(for name: String) -> ResumePolicy {
        tools[name]?.resumePolicy ?? .retryable
    }
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case executionFailed(String)
    case invalidParameters(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return String(format: L10n.l("tool_unknown"), name)
        case .executionFailed(let message), .invalidParameters(let message):
            return message
        }
    }
}

