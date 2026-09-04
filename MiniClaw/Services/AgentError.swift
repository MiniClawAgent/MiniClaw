import Foundation

enum AgentError: LocalizedError {
    case notConfigured
    case requestFailed
    case toolExecutionFailed(String)
    case iterationLimitReached

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "err_no_model_configured")
        case .requestFailed: return String(localized: "err_model_request_failed")
        case .toolExecutionFailed(let message): return message
        case .iterationLimitReached: return String(localized: "err_tool_call_limit")
        }
    }
}

