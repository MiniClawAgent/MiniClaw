import Foundation

// MARK: - 统一重试机制：错误分类（单一事实来源）

/// 错误分类：决定「直接报错」还是「进入统一重试循环」。
/// 用户语义（2026-08-08 定）：
/// - **fatal（必错）**：请求构造/认证/端点不存在等自身或配置类错误，重试必败 → 直接输出错误，不显示重试指示器。
/// - **retryable**：网络/限流/服务端 5xx/流截断等一切非主动中断的错误 → 统一自动重试 5 次 × 3s，带可视指示器。
/// - 用户主动取消（cancel）不在分类内：引擎在重试循环外单独处理，是唯一豁免。
enum RetryClass {
    case fatal
    case retryable
}

/// 分类器：任何 Error 都归入 fatal / retryable 二类。
/// 既有散落的瞬时网络错误判定（isTransientNetworkError）已并入此处，
/// 保证「任何问题都走同一套重试机制」（除 fatal 与用户主动中断）。
enum RetryPolicy {
    static func classify(_ error: Error) -> RetryClass {
        if let llm = error as? LLMError {
            switch llm {
            case .encodingFailed, .decodingFailed:
                // 请求体构造 / 响应解析自身错误：重试必败。
                return .fatal
            case .invalidResponse(let code):
                switch code {
                case 400, 401, 403, 404, 405, 413, 422:
                    // 请求格式 / 认证失败 / 端点不存在 / 请求体超长 / 内容策略拒绝：重试必败。
                    return .fatal
                default:
                    // 408 请求超时 / 429 限流 / 5xx 服务端错误：可重试。
                    return .retryable
                }
            case .noData, .rateLimited, .streamTruncated:
                // 空响应 / 限流 / 流截断：可重试（半截输出重试时丢弃重新生成）。
                return .retryable
            case .providerRejected:
                // 当前唯一来源是「未找到供应商适配器」（配置缺失），重试必败。
                return .fatal
            }
        }
        if error is URLError {
            // 网络层错误（超时/断连/无网络等）：可重试。
            return .retryable
        }
        // 其他（引擎内部错误，如未配置模型）：直接报错。
        return .fatal
    }

    /// 是否属于「必错」——调用方据此决定直接 emitError 还是进入重试循环。
    static func isFatal(_ error: Error) -> Bool {
        classify(error) == .fatal
    }
}

// MARK: - 重试状态（引擎 → UI 指示器）

/// 重试阶段：重试中 / 已耗尽（最终失败）。
enum RetryPhase: Equatable {
    case retrying
    case exhausted
}

/// 重试状态快照：UI 重试指示器的唯一数据来源。
struct RetryState: Equatable {
    /// 当前阶段
    let phase: RetryPhase
    /// 当前第几次尝试（1...total）
    let attempt: Int
    /// 总重试次数上限（当前策略 5）
    let total: Int
    /// 最近一次失败的错误（指示器展开可见）
    let lastError: Error

    /// 重试中且未耗尽：允许手动立即重试
    var canRetry: Bool {
        phase == .retrying && attempt < total
    }

    static func == (lhs: RetryState, rhs: RetryState) -> Bool {
        lhs.phase == rhs.phase && lhs.attempt == rhs.attempt && lhs.total == rhs.total
            && lhs.lastError.localizedDescription == rhs.lastError.localizedDescription
    }
}
