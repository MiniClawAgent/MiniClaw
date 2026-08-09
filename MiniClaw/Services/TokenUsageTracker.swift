import Foundation

/// 词元 用量统计的持久化与查询入口。
///
/// 数据来源：每次 LLM 调用的真实用量（服务商在流式响应中上报），或本地估算值（兜底）。
/// 存储位置：`SettingsStore.shared.settings.tokenUsage`，随 settings.json 落盘，跨会话全局累计。
///
/// 约定：所有读写在**主线程**进行（与 SettingsStore 的线程约定一致）。
enum TokenUsageTracker {

    // MARK: - 写入

    /// 记录一次调用的用量。必须在主线程调用。
    /// - Parameters:
    ///   - modelId: 模型 ID（如 "deepseek-chat"）
    ///   - input: 输入 词元 数（含缓存命中部分）
    ///   - output: 输出 词元 数
    ///   - cachedRead: 缓存读取 词元 数（可选）
    ///   - cachedWrite: 缓存写入 词元 数（可选）
    static func record(modelId: String, input: Int, output: Int, cachedRead: Int = 0, cachedWrite: Int = 0) {
        guard input > 0 || output > 0 else { return }
        var stats = SettingsStore.shared.settings.tokenUsage ?? TokenUsageStats()

        let dayKey = dayString(Date())
        var day = stats.daily[dayKey] ?? TokenUsageStats.DayStat()
        day.input += max(0, input)
        day.output += max(0, output)
        day.cachedRead = (day.cachedRead ?? 0) + max(0, cachedRead)
        day.cachedWrite = (day.cachedWrite ?? 0) + max(0, cachedWrite)
        stats.daily[dayKey] = day

        var model = stats.byModel[modelId] ?? TokenUsageStats.ModelStat()
        model.input += max(0, input)
        model.output += max(0, output)
        model.calls += 1
        model.cachedRead = (model.cachedRead ?? 0) + max(0, cachedRead)
        model.cachedWrite = (model.cachedWrite ?? 0) + max(0, cachedWrite)
        stats.byModel[modelId] = model

        SettingsStore.shared.settings.tokenUsage = stats
        SettingsStore.shared.save()
    }

    /// 累计一次调用到指定会话的用量（按 sessionID 索引）。必须在主线程调用。
    static func recordSession(sessionID: UUID, modelId: String, input: Int, output: Int,
                               cachedRead: Int = 0, cachedWrite: Int = 0,
                               agentLoops: Int = 0, outputDurationMs: Double = 0) {
        // 纯耗时报告（run 结束时由 emitRunOutputDuration 上报，input/output/agentLoops 均为 0、
        // 仅 outputDurationMs 有值）也必须放行，否则会话级输出速度永远拿不到耗时、显示「—」。
        guard input > 0 || output > 0 || agentLoops > 0 || outputDurationMs > 0 else { return }
        var map = SettingsStore.shared.settings.sessionTokenUsage ?? [:]
        let key = sessionID.uuidString
        var d = map[key] ?? SessionTokenUsageData()
        d.input += max(0, input)
        d.output += max(0, output)
        d.cachedRead = (d.cachedRead ?? 0) + max(0, cachedRead)
        d.cachedWrite = (d.cachedWrite ?? 0) + max(0, cachedWrite)
        d.agentLoops += agentLoops
        d.outputDurationMs += max(0, outputDurationMs)
        map[key] = d
        SettingsStore.shared.settings.sessionTokenUsage = map
        SettingsStore.shared.save()
    }

    /// 读取指定会话的累计用量（无记录时返回 nil）。
    static func sessionUsage(_ id: UUID) -> SessionTokenUsageData? {
        SettingsStore.shared.settings.sessionTokenUsage?[id.uuidString]
    }

    /// 清空全部用量统计（今日 / 本月 / 按模型）。
    static func reset() {
        SettingsStore.shared.settings.tokenUsage = TokenUsageStats()
        SettingsStore.shared.save()
    }

    // MARK: - 查询

    static func today() -> (input: Int, output: Int) {
        guard let day = SettingsStore.shared.settings.tokenUsage?.daily[dayString(Date())] else {
            return (0, 0)
        }
        return (day.input, day.output)
    }

    static func month() -> (input: Int, output: Int) {
        guard let stats = SettingsStore.shared.settings.tokenUsage else { return (0, 0) }
        let prefix = monthPrefix(Date())
        var input = 0, output = 0
        for (key, day) in stats.daily where key.hasPrefix(prefix) {
            input += day.input
            output += day.output
        }
        return (input, output)
    }

    /// 按模型累计，按总 词元 降序排列。
    static func byModel() -> [(model: String, input: Int, output: Int, calls: Int)] {
        guard let stats = SettingsStore.shared.settings.tokenUsage else { return [] }
        return stats.byModel
            .map { (model: $0.key, input: $0.value.input, output: $0.value.output, calls: $0.value.calls) }
            .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
    }

    /// 全局累计总量（跨所有模型、所有时间）。
    /// - Returns: (input 含缓存, output, cachedRead, cachedWrite)
    static func globalTotals() -> (input: Int, output: Int, cachedRead: Int, cachedWrite: Int) {
        guard let stats = SettingsStore.shared.settings.tokenUsage else {
            return (0, 0, 0, 0)
        }
        var input = 0, output = 0, cr = 0, cw = 0
        for m in stats.byModel.values {
            input += m.input
            output += m.output
            cr += m.cachedRead ?? 0
            cw += m.cachedWrite ?? 0
        }
        return (input, output, cr, cw)
    }

    /// 是否已有任何用量记录。
    static func hasData() -> Bool {
        !(SettingsStore.shared.settings.tokenUsage?.daily.isEmpty ?? true)
    }

    // MARK: - 日期键

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone.current
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func monthPrefix(_ date: Date) -> String { monthFormatter.string(from: date) }
}
