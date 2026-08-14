import Foundation

enum AgentError: LocalizedError {
    case notConfigured
    case requestFailed
    case toolExecutionFailed(String)
    case iterationLimitReached

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.l("err_no_model_configured")
        case .requestFailed: return L10n.l("err_model_request_failed")
        case .toolExecutionFailed(let message): return message
        case .iterationLimitReached: return L10n.l("err_tool_call_limit")
        }
    }
}

