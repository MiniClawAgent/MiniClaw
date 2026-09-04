import SwiftUI
import Foundation


enum ModelGroupPurpose {
    case main
    case secondary
    case speechInput
    case speechOutput
    /// 子代理委派池（P1-3）：dispatch_subagent 派生的子引擎专用。
    case subagent
}

/// 单个可执行模型端点。组级策略随端点携带，便于故障转移到下一组时切换策略。
struct ModelRouteEndpoint {
    let providerId: UUID
    let modelConfigId: UUID
    let url: String
    let apiKey: String
    let format: APIFormat
    let usesAzureAPIKey: Bool
    let modelId: String
    let modelName: String
    /// 所属模型分组名称；直接选择的全局默认模型为 nil。
    let groupName: String?
    let fallbackStrategy: String
    let contextLimitTokens: Int
    let thinkingLevel: String
    let supportsDeepThinking: Bool
    /// 单次最大输出 词元：用户设置 > 模型目录默认 > nil（服务端默认）。
    /// 传递到 LLMClient 真正约束 max_output_tokens / max_tokens。
    let maxOutputTokens: Int?
    /// 输入模态能力（文本/图片/音频/视频）：来自模型配置（用户可改，默认取模型目录）。
    /// 发送链路据此过滤附件——不支持的模态不随请求发送，避免服务端 4xx。
    /// 文本为通用基线（supportsTextInput 恒为 true）；文档不再作为独立输入模态，
    /// 文档类附件统一经 read_document 工具读取，不入原生请求体。
    let supportsImageInput: Bool
    let supportsAudioInput: Bool
    let supportsVideoInput: Bool
    /// OpenAI Organization ID（多组织计费）
    let organizationId: String
    /// OpenAI Project ID
    let projectId: String
    /// 服务商类型
    let providerType: ProviderType
    /// 用户自定义请求头（由 provider 透传）
    let customHeaders: [String: String]

    var displayName: String {
        guard let groupName = groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else {
            return modelName
        }
        return "\(groupName)·\(modelName)"
    }
}

/// 一次推理的有序候选端点。Agent Loop 依次尝试，首个成功端点继续完成整轮工具循环。
struct ModelRoutingPlan {
    let endpoints: [ModelRouteEndpoint]
    let usesModelGroups: Bool
}

