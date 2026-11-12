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
    /// 单次执行超时（秒），nil = 不限时长。默认 120；长时编排工具（如 dispatch_subagent）
    /// 覆盖为 nil——子代理整轮回复可达分钟级，120s 竞速会误杀正常任务。
    var executionTimeout: TimeInterval? { get }
}

extension AgentTool {
    var resumePolicy: ResumePolicy { .retryable }
    var activityParameterName: String { "activity" }
    var executionTimeout: TimeInterval? { 120 }
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

extension JSONSchemaValue {
    /// 转为 Foundation 类型（供 JSONSerialization 组装请求体；model 插件行为声明用）。
    var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .integer(let i): return i
        case .boolean(let b): return b
        case .object(let o): return o.mapValues { $0.foundationValue }
        case .array(let a): return a.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }
}

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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(localized: "err_unsupported_json_value"))
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
            throw ToolError.invalidParameters(String(format: String(localized: "tool_json_convert_failed"), String(describing: type(of: jsonObject))))
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

// MARK: - Tool Progress Scope

/// 工具执行过程流上报通道（执行中直写 block.content）：
/// 引擎在调用 toolRouter.execute 时用 TaskLocal 注入 reporter，
/// 工具体内部（如 shell 的 stdout 逐行回调）读取并上报——TaskLocal 沿异步调用链自动继承。
enum ToolProgressScope {
    @TaskLocal static var reporter: (@Sendable (String) -> Void)? = nil
}

// MARK: - Tool Router

final class ToolRouter {
    private var tools: [String: AgentTool] = [:]

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    /// 工具名是否已被占用（内置/已注册）：tool 插件注册时的重名冲突判定。
    func contains(_ name: String) -> Bool {
        tools[name] != nil
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
        // [2026-09-15 缓存稳定性·治本] **必须按工具名排序输出**。
        //
        // `tools` 是 `[String: AgentTool]` 字典，而 Swift 字典的遍历顺序**不保证稳定**：
        // 同任务内（同一实例、无增删）恰好一致，但**每次新建 router / 跨进程**时插入顺序
        // 与哈希种子都不同 ⇒ 工具段排列抖动 ⇒ 上下文缓存**从 tools 段整段失效**。
        // 真机实证：同一会话内 `tools=` 指纹恒定，每换一个任务即变（用户未改任何工具）。
        //
        // 排序后顺序只由「工具集内容」决定 ⇒ 缓存指纹只反映真实内容差异。
        tools.keys.sorted().compactMap { tools[$0] }.map { tool in
            let original = tool.schema
            let activityParameterName = tool.activityParameterName
            var parameters = original.function.parameters
            var properties = parameters.properties ?? [:]
            properties[activityParameterName] = JSONSchema.JSONProperty(
                type: "string",
                description: String(localized: "tool_indicator_desc")
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

    /// 查询某个已注册工具的执行超时。
    ///
    /// 语义（2026-11-12 修 ISSUES I-04）：`nil` 表示「引擎不设超时」，由工具自行治理；
    /// 只有**未注册**的工具才回落默认 120s。
    /// 旧实现 `tools[name]?.executionTimeout ?? 120` 会被可选链扁平化——
    /// 「工具存在但显式返回 nil」与「工具不存在」变成同一个 nil 后再被 `?? 120` 吞掉，
    /// 导致 `dispatch_subagent` 的「不限时」与 `shell_execute` 的 900s 全部失效。
    func executionTimeout(for name: String) -> TimeInterval? {
        guard let tool = tools[name] else { return 120 }
        return tool.executionTimeout
    }
}

// MARK: - 引擎作用域（引擎保留工具的统一执行通道）

/// 引擎弱引用盒：AgentLoopEngine 非 Sendable，包一层以通过 TaskLocal 的 Sendable 检查
/// （与 SubagentSlotCounter 的 @unchecked Sendable 先例一致）。
final class EngineBox: @unchecked Sendable {
    weak var engine: AgentLoopEngine?
    init(_ engine: AgentLoopEngine?) { self.engine = engine }
}

/// 引擎保留工具（dispatch_subagent / close_subagent）经 ToolRouter 统一执行时，
/// 由 `AgentLoopEngine.executeTool` 以 TaskLocal 注入**当前执行引擎**——
/// 同一 router 实例被父子引擎共享，工具体据此解析到自己所属的引擎（深度/会话状态才正确）。
enum ToolEngineScope {
    @TaskLocal static var box: EngineBox? = nil
    static var engine: AgentLoopEngine? { box?.engine }
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case executionFailed(String)
    case invalidParameters(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return String(format: String(localized: "tool_unknown"), name)
        case .executionFailed(let message), .invalidParameters(let message):
            return message
        }
    }
}

