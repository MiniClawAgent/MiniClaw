import Foundation

// MARK: - 工具空转断路器（对齐 ToolLoopDetector 哲学，自研实现）

/// 工具空转断路器（对齐 ToolLoopDetector 哲学，自研实现，非代码复刻）。
///
/// 防止 Agent 陷入「反复调同一工具却毫无进展」的死循环——这是后台态被系统节流拖到 iOS 看门狗
/// 阈值（闪退/审核红线）的主要诱因之一。参考 的多策略思路：
/// - 指纹化：工具名 + 归一化参数 作为去重键；
/// - 易变剥离(stripVolatile)：比较前去掉时间戳/UUID 等噪声，避免「pending 12:00:01」这类每次不同的
///   输出误导检测器以为「有进展」；
/// - 多策略：
///   ① 通用重复：同一 (工具+参数) 连续调用 N 次（不论成败、不论结果是否相同）即预警/熔断；
///   ② 轮询无进展：轮询类工具（名称含 poll/status/check/wait 或结果含「未完成/pending」等）反复返回
///      「未完成」即熔断；
/// - 两级处理：先 warn（记日志 + 由引擎注入提示让模型换思路），再 critical（由引擎直接终止以防挂死）。
///
/// 设计为「每个有效工具执行结果后喂一次」的无状态累积器，引擎持有实例并在每轮 run/resume 时 reset()。
final class ToolLoopBreaker {

    struct Config {
        /// 通用重复预警阈值（连续相同调用达到此数给出 warn）。
        var genericRepeatWarn = 6
        /// 通用重复熔断阈值（达到此数直接 break）。
        var genericRepeatCritical = 10
        /// 轮询无进展熔断阈值。
        var pollRepeatCritical = 6
    }

    enum Action {
        case none
        case warn(reason: String)
        case `break`(reason: String)
    }

    private struct Bucket {
        var genericCount = 0
        var pollCount = 0
        var lastResultHash: String?
    }

    private var buckets: [String: Bucket] = [:]
    private let config: Config

    init(config: Config = Config()) { self.config = config }

    func reset() { buckets.removeAll() }

    /// 每个（有效）工具执行结果后调用。返回应触发的动作。
    func observe(toolName: String, argumentsJSON: String, resultText: String, success: Bool) -> Action {
        let fp = fingerprint(toolName: toolName, argumentsJSON: argumentsJSON)
        var bucket = buckets[fp] ?? Bucket()
        bucket.genericCount += 1

        // 轮询判定：工具名像轮询 或 结果文案像「未完成」。
        let isPoll = isPollTool(toolName) || resultLooksPending(resultText)
        if isPoll {
            bucket.pollCount += 1
        } else {
            bucket.pollCount = 0
        }

        // 易变剥离后哈希：若与上次实质不同，视为「有进展」。
        let rHash = volatileStrippedHash(resultText)
        let progressed = bucket.lastResultHash != nil && bucket.lastResultHash != rHash
        bucket.lastResultHash = rHash

        // 确有实质进展且非纯轮询 → 不计为重复（允许合法的多轮推进，例如不同内容的多次读取）。
        if progressed && !isPoll {
            bucket.genericCount = 1
            bucket.pollCount = 0
        }

        buckets[fp] = bucket

        if bucket.pollCount >= config.pollRepeatCritical {
            return .break(reason: "轮询工具「\(toolName)」连续 \(bucket.pollCount) 次返回「未完成」，疑似空转")
        }
        if bucket.genericCount >= config.genericRepeatCritical {
            return .break(reason: "工具「\(toolName)」连续 \(bucket.genericCount) 次以相同参数调用，疑似空转循环")
        }
        if bucket.genericCount == config.genericRepeatWarn {
            return .warn(reason: "工具「\(toolName)」已连续 \(bucket.genericCount) 次以相同参数调用")
        }
        return .none
    }

    // MARK: 指纹 / 归一化

    private func fingerprint(toolName: String, argumentsJSON: String) -> String {
        // 参数归一化：解析后按 key 排序重序列化，消除 LLM 输出中无关紧要的字段顺序差异。
        let norm = normalizeArgs(argumentsJSON)
        return "\(toolName)#\(norm)"
    }

    /// 去掉时间戳、UUID 等易变片段，仅保留语义骨架用于「是否实质相同」判断。
    /// 故意【不】剥离数字/百分比/序号——「Step 3/10」与「Step 4/10」确属进展，不应判为相同。
    private func stripVolatile(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{1,2}:\d{2}:\d{2}\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, with: "", options: .regularExpression)
        return s
    }

    private func volatileStrippedHash(_ text: String) -> String {
        let stripped = stripVolatile(text)
        var hash: UInt64 = 5381
        for byte in stripped.utf8 {
            hash = 127 &* hash &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func normalizeArgs(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return json }
        guard let norm = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: norm, encoding: .utf8) else { return json }
        return s
    }

    private func isPollTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("poll") || lower.contains("status") || lower.contains("check")
            || lower.contains("wait") || lower.contains("progress")
    }

    private func resultLooksPending(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = ["pending", "in progress", "not ready", "not done", "still running", "queued",
                      "等待", "进行中", "未完成", "未就绪", "处理中", "排队中"]
        return markers.contains { lower.contains($0) }
    }
}
