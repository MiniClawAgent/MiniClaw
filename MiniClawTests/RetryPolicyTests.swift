import XCTest
@testable import MiniClaw

/// 统一重试机制：错误分类（RetryPolicy）正确性测试。
/// 用户语义（2026-08-08）：任何非主动中断的错误走同一套重试；
/// fatal（必错）类直接输出错误不重试；retryable 类自动重试 5 次 × 3s。
final class RetryPolicyTests: XCTestCase {

    // MARK: - fatal（必错，不重试）

    func testEncodingFailedIsFatal() {
        XCTAssertEqual(RetryPolicy.classify(LLMError.encodingFailed), .fatal)
    }

    func testDecodingFailedIsFatal() {
        XCTAssertEqual(RetryPolicy.classify(LLMError.decodingFailed), .fatal)
    }

    func testAuthErrorsAreFatal() {
        for code in [400, 401, 403, 404, 405, 413, 422] {
            XCTAssertEqual(RetryPolicy.classify(LLMError.invalidResponse(code)), .fatal, "HTTP \(code) 应为 fatal")
        }
    }

    func testProviderRejectedIsFatal() {
        // 唯一来源是「未找到供应商适配器」（配置缺失），重试必败。
        XCTAssertEqual(RetryPolicy.classify(LLMError.providerRejected("未找到适配器")), .fatal)
    }

    // MARK: - retryable（自动重试）

    func testRateLimitIsRetryable() {
        XCTAssertEqual(RetryPolicy.classify(LLMError.rateLimited), .retryable)
    }

    func testServerErrorsAreRetryable() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(RetryPolicy.classify(LLMError.invalidResponse(code)), .retryable, "HTTP \(code) 应为 retryable")
        }
    }

    func testStreamTruncatedIsRetryable() {
        XCTAssertEqual(RetryPolicy.classify(LLMError.streamTruncated), .retryable)
    }

    func testNoDataIsRetryable() {
        XCTAssertEqual(RetryPolicy.classify(LLMError.noData), .retryable)
    }

    func testURLErrorIsRetryable() {
        let urlError = URLError(.notConnectedToInternet)
        XCTAssertEqual(RetryPolicy.classify(urlError), .retryable)
    }

    func testUnknownErrorIsFatal() {
        struct Unknown: Error {}
        XCTAssertEqual(RetryPolicy.classify(Unknown()), .fatal)
    }

    // MARK: - RetryState 语义

    func testCanRetryOnlyWhileRetryingAndNotExhausted() {
        let retrying = RetryState(phase: .retrying, attempt: 2, total: 5, lastError: LLMError.noData)
        XCTAssertTrue(retrying.canRetry)

        let lastAttempt = RetryState(phase: .retrying, attempt: 5, total: 5, lastError: LLMError.noData)
        XCTAssertFalse(lastAttempt.canRetry, "最后一次尝试等待中不应允许手动重试")

        let exhausted = RetryState(phase: .exhausted, attempt: 5, total: 5, lastError: LLMError.noData)
        XCTAssertFalse(exhausted.canRetry)
    }
}
