import Foundation

// MARK: - 引擎支撑类型（2026-08 提取：与 AgentLoopEngine 实例解耦）

    /// 取消 的全部可变状态统一由 actor 保护。
    /// 因为 cancel() 从主线程调用，
    /// 而 run() 的循环在独立的 Task 上执行，两者并发访问这些字段；
    /// 用 actor 隔离既能满足 Swift 6 严格并发，又避开 NSLock 在异步上下文的禁用。
actor EngineState {
        var isRunning: Bool = false
        var cancelRequested: Bool = false
        /// 软暂停请求：用户在回复进行中点了「暂停」。
        /// 与 `cancelRequested` 独立——暂停不中止循环，而是让循环在下一个安全点
        /// （流式回合结束 / 某工具执行完）落地为 `.paused` 并退出，等待恢复重放。
        var pauseRequested: Bool = false
        var pendingUserInputs: [String] = []
        /// 手动立即重试请求（UI 点击重试按钮置位；等待循环消费）。
        /// 放 actor 内：等待循环在后台线程、requestImmediateRetry 在主线程，actor 消除竞争。
        var retryNowRequested: Bool = false

        func configureRunning() {
            isRunning = true
            cancelRequested = false
            pauseRequested = false
            pendingUserInputs.removeAll()
            // 清上一次 run 残留的手动重试标志（跨 run 不串扰）。
            retryNowRequested = false
        }
        func markStopped() { isRunning = false }
        func cancel() {
            cancelRequested = true
            isRunning = false
            pauseRequested = false
        }
        func requestPause() { pauseRequested = true }
        func clearPause() { pauseRequested = false }
        func enqueue(_ text: String) {
            pendingUserInputs.append(text)
        }
        func takeNextInput() -> String? {
            pendingUserInputs.isEmpty ? nil : pendingUserInputs.removeFirst()
        }
        func isCancelled() -> Bool { cancelRequested }
        func isPausedRequested() -> Bool { pauseRequested }
        func requestRetryNow() { retryNowRequested = true }
        func consumeRetryNow() -> Bool {
            let v = retryNowRequested
            retryNowRequested = false
            return v
        }
        func keepRunning() -> Bool { isRunning && !cancelRequested }
        func pendingInputs() -> [String] { pendingUserInputs }
    }


    /// 浏览器作用域（第 5 条要求：子代理浏览器与父代理隔离）。
    /// 主引擎（isSubagentEngine=false）不设置 → BrowserTool 回落其 currentSessionID（父会话 context）；
    /// 子代理引擎用自身 sessionID（= subID）→ BrowserContextManager 按 subID 建独立 BrowserContext，
    /// 标签组独立、页面数上限各自独立生效，不再与父代理互相挤占。
    /// 用 TaskLocal 而非共享可变状态：withTaskGroup 并行子代理各自持有自己的值，并发安全。
    enum EngineBrowserScope {
        @TaskLocal static var sessionID: UUID?
    }


    /// 会话级采样参数（由 ChatView 从 SessionSettings 传入）
    struct SamplingConfig {
        var topP: Double? = nil
        var frequencyPenalty: Double? = nil
        var presencePenalty: Double? = nil
        var seed: Int? = nil
        var parallelToolCalls: Bool? = nil
        var responseFormat: ResponseFormat? = nil
    }
