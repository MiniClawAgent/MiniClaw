import Foundation
import HealthKit

// MARK: - 健康类型表

/// 单个健康指标的定义：模型侧名字 ↔ HealthKit 类型 + 单位 + 聚合方式。
///
/// 名字保持英文（数据字典性质，供模型精确引用并在 `types` 中自查），
/// 面向用户的中文由模型在回复时生成，故不进本地化表。
private struct HealthMetricDef {
    let key: String
    let objectType: HKObjectType
    /// category 时长型（睡眠 / 正念）无单位，取值 = end - start（秒）。
    let unit: HKUnit?
    /// 非 nil 表示该指标用统计量聚合（sum / avg）；nil 表示逐条取样本。
    let options: HKStatisticsOptions?
    /// 是否允许写入（白名单 8 项；医疗敏感项与分析型一律 false）。
    let writable: Bool
    let isDurationCategory: Bool
}

private enum HealthMetrics {
    private static func q(_ key: String,
                          _ id: HKQuantityTypeIdentifier,
                          _ unit: HKUnit,
                          _ options: HKStatisticsOptions?,
                          _ writable: Bool) -> HealthMetricDef? {
        guard let t = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return HealthMetricDef(key: key, objectType: t, unit: unit, options: options,
                               writable: writable, isDurationCategory: false)
    }

    private static func c(_ key: String,
                          _ id: HKCategoryTypeIdentifier,
                          _ writable: Bool) -> HealthMetricDef? {
        guard let t = HKCategoryType.categoryType(forIdentifier: id) else { return nil }
        return HealthMetricDef(key: key, objectType: t, unit: nil, options: nil,
                               writable: writable, isDurationCategory: true)
    }

    /// 全部可读指标（24 项）。可写子集见 `writableKeys`。
    static let all: [HealthMetricDef] = [
        q("step_count", .stepCount, .count(), .cumulativeSum, true),
        q("distance_walking_running", .distanceWalkingRunning, .meterUnit(with: .kilo), .cumulativeSum, false),
        q("active_energy", .activeEnergyBurned, .kilocalorie(), .cumulativeSum, true),
        q("basal_energy", .basalEnergyBurned, .kilocalorie(), .cumulativeSum, false),
        q("flights_climbed", .flightsClimbed, .count(), .cumulativeSum, false),
        q("heart_rate", .heartRate, HKUnit.count().unitDivided(by: .minute()), .discreteAverage, false),
        q("resting_heart_rate", .restingHeartRate, HKUnit.count().unitDivided(by: .minute()), .discreteAverage, false),
        q("hrv", .heartRateVariabilitySDNN, .secondUnit(with: .milli), .discreteAverage, false),
        q("body_mass", .bodyMass, .gramUnit(with: .kilo), .discreteAverage, true),
        q("bmi", .bodyMassIndex, .count(), .discreteAverage, false),
        q("height", .height, .meterUnit(with: .centi), .discreteAverage, true),
        q("body_fat", .bodyFatPercentage, .percent(), .discreteAverage, true),
        q("lean_body_mass", .leanBodyMass, .gramUnit(with: .kilo), .discreteAverage, false),
        c("sleep", .sleepAnalysis, false),
        q("blood_pressure_systolic", .bloodPressureSystolic, .millimeterOfMercury(), .discreteAverage, false),
        q("blood_pressure_diastolic", .bloodPressureDiastolic, .millimeterOfMercury(), .discreteAverage, false),
        // 血糖必须用质量/体积（mg/dL，HealthKit 原生单位）：mmol/L 是「物质的量/体积」，
        // 与 HealthKit 存储量纲不兼容，未给摩尔质量时 doubleValue(for:) 会直接抛异常。
        q("blood_glucose", .bloodGlucose, HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci)), .discreteAverage, false),
        q("oxygen_saturation", .oxygenSaturation, .percent(), .discreteAverage, false),
        q("respiratory_rate", .respiratoryRate, HKUnit.count().unitDivided(by: .minute()), .discreteAverage, false),
        q("body_temperature", .bodyTemperature, .degreeCelsius(), .discreteAverage, false),
        q("vo2_max", .vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), .discreteAverage, false),
        c("mindful", .mindfulSession, true),
        q("water", .dietaryWater, .liter(), .cumulativeSum, true),
        q("dietary_energy", .dietaryEnergyConsumed, .kilocalorie(), .cumulativeSum, true),
    ].compactMap { $0 }

    static let byKey: [String: HealthMetricDef] = {
        var d: [String: HealthMetricDef] = [:]
        for m in all { d[m.key] = m }
        return d
    }()

    /// 可写白名单（8 项）：只含「手动型」与「叠加型」，医疗敏感项与分析型不开放。
    static let writableKeys: [String] = all.filter(\.writable).map(\.key)

    /// summary 默认聚合的常用指标。
    static let summaryKeys = ["step_count", "distance_walking_running", "active_energy",
                              "sleep", "resting_heart_rate", "body_mass"]
}

// MARK: - 授权串行门

/// HealthKit 授权串行门。
///
/// iOS 同一时刻只允许呈现一个授权弹窗，**并发调用 `requestAuthorization` 会静默
/// 失败或被系统直接拒绝**（多次工具调用 / 后台复盘与前台会话重叠时极易触发）。
/// 用 actor 串行化每一次授权请求，保证同一时刻只有一个请求在飞。
///
/// 权限页（`PermissionManager`）与工具内部共用同一道门，避免两条链路同时弹窗。
actor HealthKitAuthGate {
    static let shared = HealthKitAuthGate()

    /// 剔除 HealthKit 永不允许作为写入类型的对象：放进 `toShare` 会让
    /// `requestAuthorization(toShare:read:)` 抛未捕获异常（SIGABRT）。
    /// 结构性只读的两类是 `HKCharacteristicType`（性别 / 血型 / 出生日期）与
    /// `HKActivitySummaryType`（活动圆环）。
    static func sanitizeShareTypes(_ types: Set<HKSampleType>) -> Set<HKSampleType> {
        types.filter { !($0 is HKCharacteristicType) && !($0 is HKActivitySummaryType) }
    }

    /// 请求授权。返回值只表示「授权流程正常结束」，**不代表用户已授权**——
    /// 读授权在 iOS 上不可探测（见 `AppleHealthKitTool` 头注释）。
    @discardableResult
    func request(read: Set<HKObjectType>, share: Set<HKSampleType>) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let sanitized = Self.sanitizeShareTypes(share)
        let store = HKHealthStore()
        return await withCheckedContinuation { cont in
            store.requestAuthorization(toShare: sanitized, read: read) { _, error in
                cont.resume(returning: error == nil)
            }
        }
    }
}

// MARK: - apple-healthkit

/// Apple 健康数据（HealthKit）读写工具。
///
/// **iOS 授权状态不可探测（重要）**：为防止「用授权状态反推用户健康状况」的侧信道，
/// 系统对**只读类型**的 `authorizationStatus(for:)` 永远返回 `.sharingDenied`，
/// 哪怕用户刚刚点了允许。因此本工具不依赖状态判断，而是：
/// - 读：直接查询，查不到即按「区间无数据或未授权」统一提示；
/// - 写：写入类型的授权**可以**探测（`.sharingAuthorized`），据此决定是否弹窗。
struct AppleHealthKitTool: AgentTool {
    let name = "apple-healthkit"
    /// 发起调用的会话：能力授权请求需按会话记账（见 `ToolConfirmationBridge.ensureCapability`）。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    /// 写入类操作具有设备外副作用（会改动用户健康记录），恢复时必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-healthkit",
            description: String(localized: "health_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_action"),
                        enum: ["summary", "query", "range_report", "write", "delete", "types", "workouts", "characteristic"]
                    ),
                    "metrics": JSONSchema.JSONProperty(
                        type: "array",
                        description: String(localized: "health_param_metrics"),
                        items: JSONSchema(type: "string")
                    ),
                    "metric": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_metric")
                    ),
                    "start_date": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_start")
                    ),
                    "end_date": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_end")
                    ),
                    "aggregate": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_aggregate"),
                        enum: ["auto", "sum", "avg", "min", "max", "none"]
                    ),
                    "limit": JSONSchema.JSONProperty(
                        type: "integer",
                        description: String(localized: "health_param_limit")
                    ),
                    "value": JSONSchema.JSONProperty(
                        type: "number",
                        description: String(localized: "health_param_value")
                    ),
                    "date": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_date")
                    ),
                    "sample_id": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_sample_id")
                    ),
                    "workout_type": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "health_param_workout_type")
                    ),
                ],
                required: ["action"]
            )
        )
    )

    // MARK: 入口

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return failure(String(localized: "health_unavailable"))
        }
        let action = (parameters["action"] as? String)?.lowercased() ?? ""
        // ── 能力守卫（单一入口：`ToolConfirmationBridge.ensureCapability`）──
        // 读类动作需 healthRead、写/删需 healthWrite：设置里持久开启，或本会话内用户经授权弹窗同意。
        // 未授权时弹一次授权窗（仅真实用户会话会弹）；拒绝则回报失败给模型。
        // `types` 只列举类型目录、不含用户数据，不做守卫。
        switch action {
        case "summary", "query", "range_report", "workouts", "characteristic":
            guard await ToolConfirmationBridge.shared.ensureCapability(.healthRead, sessionID: currentSessionID) else {
                return failure(AICapability.healthRead.unauthorizedMessage)
            }
        case "write", "delete":
            guard await ToolConfirmationBridge.shared.ensureCapability(.healthWrite, sessionID: currentSessionID) else {
                return failure(AICapability.healthWrite.unauthorizedMessage)
            }
        default:
            break
        }
        switch action {
        case "types":         return typesAction()
        case "summary":       return await summaryAction()
        case "query":         return await queryAction(parameters)
        case "range_report":  return await rangeReportAction(parameters)
        case "write":         return await writeAction(parameters)
        case "delete":        return await deleteAction(parameters)
        case "workouts":      return await workoutsAction(parameters)
        case "characteristic": return await characteristicAction()
        default:
            return failure(String(format: String(localized: "health_unknown_action"), action))
        }
    }

    // MARK: action - types

    /// 列出全部可读指标与其单位、是否可写。**供模型在 query / write 之前自查**，
    /// 避免凭猜测拼类型名导致无效调用。
    private func typesAction() -> ToolResult {
        let writableSet = Set(HealthMetrics.writableKeys)
        var lines: [String] = []
        for m in HealthMetrics.all {
            let unit = m.unit?.unitString ?? (m.isDurationCategory ? "seconds" : "")
            let flag = writableSet.contains(m.key) ? "read+write" : "read-only"
            lines.append("\(m.key) [\(unit)] \(flag)")
        }
        let text = String(localized: "health_types_header") + "\n" + lines.joined(separator: "\n")
        return ToolResult(success: true, text: text)
    }

    // MARK: action - summary

    /// 今日 + 近 7 天常用指标一次取回：把「今天走了多少步」这类高频问题
    /// 从多次往返压到一次调用。
    private func summaryAction() async -> ToolResult {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        guard let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) else {
            return failure(String(localized: "health_bad_date_range"))
        }
        await requestReadAccess(for: HealthMetrics.summaryKeys.compactMap { HealthMetrics.byKey[$0]?.objectType })

        var lines: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        lines.append(String(format: String(localized: "health_summary_header"), df.string(from: now)))

        for key in HealthMetrics.summaryKeys {
            guard let def = HealthMetrics.byKey[key] else { continue }
            if let line = await metricLine(def, start: todayStart, end: now, header: String(localized: "health_label_today")) {
                lines.append(line)
            }
        }
        lines.append("")
        for key in HealthMetrics.summaryKeys {
            guard let def = HealthMetrics.byKey[key] else { continue }
            if let line = await metricLine(def, start: weekStart, end: now, header: String(localized: "health_label_7d")) {
                lines.append(line)
            }
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    private func metricLine(_ def: HealthMetricDef, start: Date, end: Date, header: String) async -> String? {
        if def.isDurationCategory {
            guard let seconds = await categoryDuration(def, start: start, end: end) else { return nil }
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(header) \(def.key): \(h)h \(m)m"
        }
        guard let value = await statisticValue(def, start: start, end: end, options: def.options ?? .discreteAverage) else {
            return nil
        }
        return "\(header) \(def.key): \(formatValue(value, def: def))"
    }

    // MARK: action - query

    private func queryAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let key = parameters["metric"] as? String, let def = HealthMetrics.byKey[key] else {
            return failure(String(format: String(localized: "health_type_unsupported"),
                                  HealthMetrics.all.map(\.key).joined(separator: ", ")))
        }
        let (start, end, rangeError) = resolveRange(parameters)
        if let rangeError { return failure(rangeError) }

        let aggregate = (parameters["aggregate"] as? String)?.lowercased() ?? "auto"
        let limit = clampedLimit(parameters["limit"])

        await requestReadAccess(for: [def.objectType])

        if aggregate != "none", let options = resolveOptions(aggregate, def: def) {
            if let value = await statisticValue(def, start: start, end: end, options: options) {
                let label = String(localized: "health_label_aggregate")
                return ToolResult(success: true,
                                  text: "\(label) \(def.key) (\(shortISO(start)) ~ \(shortISO(end))): \(formatValue(value, def: def))")
            }
            // [B] 「区间无数据」是正常空结果而非工具故障：以 success=false 返回会进
        // 熔断计数（连续同签名失败 → 中断整个分析）。改为成功 + 明确提示，
        // 让模型跳过该天/该指标继续。
        return ToolResult(success: true,text: String(localized: "health_empty_result"))
        }

        let samples = await fetchSamples(def, start: start, end: end, limit: limit)
        guard !samples.isEmpty else { // [B] 「区间无数据」是正常空结果而非工具故障：以 success=false 返回会进
        // 熔断计数（连续同签名失败 → 中断整个分析）。改为成功 + 明确提示，
        // 让模型跳过该天/该指标继续。
        return ToolResult(success: true,text: String(localized: "health_empty_result")) }
        // 格式符纪律：%@ 只接受对象/String，Int 必须显式转字符串——
        // 实测 String(format: "%@", intValue) 编译通过但运行期 SIGSEGV（编译器不校验格式符）。
        var lines: [String] = [String(format: String(localized: "health_query_header"), def.key, String(samples.count))]
        for s in samples { lines.append(describeSample(s, def: def)) }
        if samples.count == limit {
            lines.append(String(localized: "health_result_truncated"))
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    // MARK: action - range_report

    /// 批量逐日报表：`metrics: [step_count, sleep, ...]` + 任意区间 →
    /// 一次调用返回「指标 × 天」矩阵。把「分析一周数据」从十几次逐日调用
    /// 压成一次（模型逐日手滑笔误、熔断中断的土壤即在此）。
    /// - quantity 类：HKStatisticsCollectionQuery 按天聚合（HealthKit 原生
    ///   逐日统计接口，单次查询拿整段）；
    /// - category 类（睡眠/正念）：按天统计与该日**重叠**的样本时长，归属
    ///   「醒来那天」（endDate 所在日），跨午夜不双计；
    /// - 无数据的日子显式输出 `-`，让模型知道「这天存在但没记录」，而不是
    ///   误判为调用失败。
    private func rangeReportAction(_ parameters: [String: Any]) async -> ToolResult {
        let keys = Self.metricKeys(from: parameters["metrics"])
        guard !keys.isEmpty else { return failure(String(localized: "health_metrics_required")) }
        let defs = keys.compactMap { HealthMetrics.byKey[$0] }
        guard !defs.isEmpty else {
            return failure(String(format: String(localized: "health_type_unsupported"),
                                  HealthMetrics.all.map(\.key).joined(separator: ", ")))
        }
        let (start,end,rangeError) = resolveRange(parameters)
        if let rangeError { return failure(rangeError) }

        let cal = Calendar.current
        let dayCount = (cal.dateComponents([.day],from: cal.startOfDay(for: start),to: cal.startOfDay(for: end)).day ?? 0)+1
        guard dayCount <= 90 else { return failure(String(localized: "health_range_too_long")) }

        await requestReadAccess(for: defs.map(\.objectType))

        var sections: [String] = []
        for def in defs {
            var dayLines: [String] = []
            if def.isDurationCategory {
                var day = cal.startOfDay(for: start)
                let lastDay = cal.startOfDay(for: end)
                while day <= lastDay {
                    let dayEnd = day.addingTimeInterval(86_399)
                    let seconds = await categoryDuration(def,start: day,end: dayEnd)
                    dayLines.append("\(Self.dayLabel(day)): \(Self.durationText(seconds))")
                    day = cal.date(byAdding: .day,value: 1,to: day)!
                }
            } else if let daily = await dailyStatistics(def,start: start,end: end) {
                for (day,value) in daily {
                    dayLines.append("\(Self.dayLabel(day)): \(value.map { formatValue($0,def: def) } ?? "-")")
                }
            }
            guard !dayLines.isEmpty else { continue }
            var section = "\(def.key) (\(shortISO(start)) ~ \(shortISO(end))):"
            section += "\n" + dayLines.joined(separator: "\n")
            sections.append(section)
        }
        guard !sections.isEmpty else {
            return ToolResult(success: true,text: String(localized: "health_empty_result"))
        }
        return ToolResult(success: true,text: sections.joined(separator: "\n\n"))
    }

    /// quantity 类指标的逐日聚合：单次 HKStatisticsCollectionQuery 覆盖整段区间。
    private func dailyStatistics(_ def: HealthMetricDef,
                                 start: Date,
                                 end: Date) async -> [(day: Date,value: Double?)]? {
        guard let quantityType = def.objectType as? HKQuantityType, let unit = def.unit else { return nil }
        let options = def.options ?? .discreteAverage
        let cal = Calendar.current
        return await withCheckedContinuation { (cont: CheckedContinuation<[(day: Date,value: Double?)]?,Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: start,end: end, options: [])
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: cal.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, results, _ in
                guard let results else { cont.resume(returning: nil); return }
                var out: [(Date,Double?)] = []
                results.enumerateStatistics(from: cal.startOfDay(for: start),to: end,with: { stats,_ in
                    let value: Double?
                    if options.contains(.cumulativeSum) {
                        value = stats.sumQuantity()?.doubleValue(for: unit)
                    } else if options.contains(.discreteAverage) {
                        value = stats.averageQuantity()?.doubleValue(for: unit)
                    } else if options.contains(.discreteMax) {
                        value = stats.maximumQuantity()?.doubleValue(for: unit)
                    } else if options.contains(.discreteMin) {
                        value = stats.minimumQuantity()?.doubleValue(for: unit)
                    } else {
                        value = nil
                    }
                    out.append((stats.startDate,value))
                })
                cont.resume(returning: out)
            }
            HKHealthStore().execute(query)
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM-dd"
        return df.string(from: day)
    }

    /// 时长文本：nil（无数据）→ "-"；否则 h/m。与卡片里逐日 `-` 标记同语义。
    private static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "-" }
        let h = Int(seconds)/3600
        let m = (Int(seconds)%3600)/60
        if h == 0 && m == 0 { return "<1m" }
        return "\(h)h \(m)m"
    }

    /// 解析 metrics 参数：JSON 数组或逗号分隔字符串。
    static func metricKeys(from raw: Any?) -> [String] {
        switch raw {
        case let list as [Any]:
            return list.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case let text as String:
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    // MARK: action - write

    private func writeAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let key = parameters["metric"] as? String, let def = HealthMetrics.byKey[key] else {
            return failure(String(format: String(localized: "health_type_unsupported"),
                                  HealthMetrics.writableKeys.joined(separator: ", ")))
        }
        guard def.writable else {
            return failure(String(format: String(localized: "health_type_not_writable"),
                                  HealthMetrics.writableKeys.joined(separator: ", ")))
        }
        guard let unit = def.unit else { return failure(String(localized: "health_type_not_writable_one")) }
        let number = Self.number(from: parameters["value"])
        guard let value = number else { return failure(String(localized: "health_value_required")) }

        let date = resolveDate(parameters["date"]) ?? Date()
        let quantity = HKQuantity(unit: unit, doubleValue: value)
        guard let sampleType = def.objectType as? HKSampleType else {
            return failure(String(localized: "health_type_not_writable_one"))
        }

        let store = HKHealthStore()
        if store.authorizationStatus(for: sampleType) != .sharingAuthorized {
            await HealthKitAuthGate.shared.request(read: [], share: [sampleType])
            if store.authorizationStatus(for: sampleType) != .sharingAuthorized {
                return failure(String(localized: "health_auth_denied"))
            }
        }

        let sample: HKSample
        if def.isDurationCategory {
            guard let categoryType = def.objectType as? HKCategoryType else {
                return failure(String(localized: "health_type_not_writable_one"))
            }
            let minutes = max(1, Int(value))
            let endDate = date.addingTimeInterval(Double(minutes) * 60)
            sample = HKCategorySample(type: categoryType, value: 0, start: date, end: endDate)
        } else {
            guard let quantityType = sampleType as? HKQuantityType else {
                return failure(String(localized: "health_type_not_writable_one"))
            }
            sample = HKQuantitySample(type: quantityType, quantity: quantity, start: date, end: date)
        }

        do {
            try await store.save(sample)
            return ToolResult(success: true,
                              text: String(format: String(localized: "health_write_done"),
                                           def.key,
                                           formatValue(value, def: def),
                                           sample.uuid.uuidString))
        } catch {
            return failure(String(format: String(localized: "health_write_failed"), error.localizedDescription))
        }
    }

    // MARK: action - delete

    /// 删除本 App 写入的样本。HealthKit 天然限制「App 只能删除自己创建的样本」，
    /// 因此该操作无法越权删除设备或其他 App 记录的数据。
    private func deleteAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let key = parameters["metric"] as? String, let def = HealthMetrics.byKey[key], def.writable else {
            return failure(String(format: String(localized: "health_type_unsupported"),
                                  HealthMetrics.writableKeys.joined(separator: ", ")))
        }
        let store = HKHealthStore()
        guard let sampleType = def.objectType as? HKSampleType else {
            return failure(String(localized: "health_type_not_writable_one"))
        }
        if store.authorizationStatus(for: sampleType) != .sharingAuthorized {
            await HealthKitAuthGate.shared.request(read: [], share: [sampleType])
            if store.authorizationStatus(for: sampleType) != .sharingAuthorized {
                return failure(String(localized: "health_auth_denied"))
            }
        }

        var predicate: NSPredicate
        if let id = parameters["sample_id"] as? String, let uuid = UUID(uuidString: id) {
            predicate = HKQuery.predicateForObject(with: uuid)
        } else {
            let (start, end, rangeError) = resolveRange(parameters)
            if let rangeError { return failure(rangeError) }
            predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        }

        let samples = await fetchRawSamples(def, start: nil, end: nil, limit: 200, predicate: predicate)
        guard !samples.isEmpty else { return failure(String(localized: "health_delete_nothing")) }
        do {
            try await store.delete(samples)
            return ToolResult(success: true,
                              text: String(format: String(localized: "health_delete_done"), String(samples.count), def.key))
        } catch {
            return failure(String(format: String(localized: "health_delete_failed"), error.localizedDescription))
        }
    }

    // MARK: action - workouts

    private func workoutsAction(_ parameters: [String: Any]) async -> ToolResult {
        let (start, end, rangeError) = resolveRange(parameters)
        if let rangeError { return failure(rangeError) }
        let limit = clampedLimit(parameters["limit"])
        let wanted = (parameters["workout_type"] as? String)?.lowercased()

        let workoutType = HKObjectType.workoutType()
        await HealthKitAuthGate.shared.request(read: [workoutType], share: [])

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let results = await withCheckedContinuation { (cont: CheckedContinuation<[HKWorkout], Never>) in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate,
                                      limit: limit, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            HKHealthStore().execute(query)
        }
        // 用可读名匹配，不能用 String(describing:)——HKWorkoutActivityType 是 ObjC 枚举，
        // 描述文本形如 "HKWorkoutActivityType(rawValue: 37)"，拿 "running" 去 contains 永远为假。
        let filtered = results.filter { w in
            guard let wanted, !wanted.isEmpty else { return true }
            return Self.workoutName(w.workoutActivityType).contains(wanted)
        }
        guard !filtered.isEmpty else { // [B] 「区间无数据」是正常空结果而非工具故障：以 success=false 返回会进
        // 熔断计数（连续同签名失败 → 中断整个分析）。改为成功 + 明确提示，
        // 让模型跳过该天/该指标继续。
        return ToolResult(success: true,text: String(localized: "health_empty_result")) }

        var lines: [String] = [String(format: String(localized: "health_workouts_header"), String(filtered.count))]
        for w in filtered {
            let minutes = Int(w.duration / 60)
            var parts = ["\(shortISO(w.startDate))", "\(Self.workoutName(w.workoutActivityType))", "\(minutes)min"]
            if let cal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                parts.append("\(Int(cal))kcal")
            }
            if let dist = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)) {
                parts.append(String(format: "%.2fkm", dist))
            }
            lines.append(parts.joined(separator: " | "))
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    // MARK: action - characteristic

    private func characteristicAction() async -> ToolResult {
        let store = HKHealthStore()
        let readTypes = Set(Self.characteristicTypes)
        await HealthKitAuthGate.shared.request(read: readTypes, share: [])
        do {
            var lines: [String] = []
            let sex = try store.biologicalSex()
            if sex.biologicalSex != .notSet {
                lines.append("biological_sex: \(Self.sexName(sex.biologicalSex))")
            }
            if let components = try? store.dateOfBirthComponents(), let year = components.year {
                lines.append("birth_year: \(String(year))")
            }
            let blood = try store.bloodType()
            if blood.bloodType != .notSet {
                lines.append("blood_type: \(Self.bloodName(blood.bloodType))")
            }
            guard !lines.isEmpty else { // [B] 「区间无数据」是正常空结果而非工具故障：以 success=false 返回会进
        // 熔断计数（连续同签名失败 → 中断整个分析）。改为成功 + 明确提示，
        // 让模型跳过该天/该指标继续。
        return ToolResult(success: true,text: String(localized: "health_empty_result")) }
            return ToolResult(success: true, text: lines.joined(separator: "\n"))
        } catch {
            // [B] 「区间无数据」是正常空结果而非工具故障：以 success=false 返回会进
        // 熔断计数（连续同签名失败 → 中断整个分析）。改为成功 + 明确提示，
        // 让模型跳过该天/该指标继续。
        return ToolResult(success: true,text: String(localized: "health_empty_result"))
        }
    }

    // MARK: 查询基建

    private func requestReadAccess(for types: [HKObjectType]) async {
        await HealthKitAuthGate.shared.request(read: Set(types), share: [])
    }

    private func statisticValue(_ def: HealthMetricDef,
                                start: Date,
                                end: Date,
                                options: HKStatisticsOptions) async -> Double? {
        guard let quantityType = def.objectType as? HKQuantityType, let unit = def.unit else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: quantityType,
                                          quantitySamplePredicate: predicate,
                                          options: options) { _, stats, _ in
                guard let stats else { cont.resume(returning: nil); return }
                let value: Double?
                if options.contains(.cumulativeSum) {
                    value = stats.sumQuantity()?.doubleValue(for: unit)
                } else if options.contains(.discreteAverage) {
                    value = stats.averageQuantity()?.doubleValue(for: unit)
                } else if options.contains(.discreteMax) {
                    value = stats.maximumQuantity()?.doubleValue(for: unit)
                } else if options.contains(.discreteMin) {
                    value = stats.minimumQuantity()?.doubleValue(for: unit)
                } else {
                    value = nil
                }
                cont.resume(returning: value)
            }
            HKHealthStore().execute(query)
        }
    }

    private func categoryDuration(_ def: HealthMetricDef, start: Date, end: Date) async -> Double? {
        guard let categoryType = def.objectType as? HKCategoryType else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(sampleType: categoryType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples, !samples.isEmpty else { cont.resume(returning: nil); return }
                let total = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                cont.resume(returning: total)
            }
            HKHealthStore().execute(query)
        }
    }

    private func fetchSamples(_ def: HealthMetricDef, start: Date, end: Date, limit: Int) async -> [HKSample] {
        await fetchRawSamples(def, start: start, end: end, limit: limit, predicate: nil)
    }

    private func fetchRawSamples(_ def: HealthMetricDef,
                                 start: Date?,
                                 end: Date?,
                                 limit: Int,
                                 predicate: NSPredicate?) async -> [HKSample] {
        guard let sampleType = def.objectType as? HKSampleType else { return [] }
        let finalPredicate = predicate ?? HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { (cont: CheckedContinuation<[HKSample], Never>) in
            let query = HKSampleQuery(sampleType: sampleType, predicate: finalPredicate,
                                      limit: limit, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: samples ?? [])
            }
            HKHealthStore().execute(query)
        }
    }

    private func describeSample(_ sample: HKSample, def: HealthMetricDef) -> String {
        if def.isDurationCategory {
            let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            return "\(shortISO(sample.startDate)) | \(minutes)min"
        }
        guard let quantitySample = sample as? HKQuantitySample, let unit = def.unit else {
            return shortISO(sample.startDate)
        }
        let value = quantitySample.quantity.doubleValue(for: unit)
        return "\(shortISO(sample.startDate)) | \(Self.trim(value)) \(unit.unitString)"
    }

    // MARK: 辅助

    private func failure(_ text: String) -> ToolResult {
        ToolResult(success: false, text: text)
    }

    private func resolveRange(_ parameters: [String: Any]) -> (start: Date, end: Date, error: String?) {
        let cal = Calendar.current
        let now = Date()
        var end = resolveDate(parameters["end_date"]) ?? now
        // [A] 纯日期（无时间部分）的 end_date 语义 = 「当天一整天」，必须顺延到
        // 当天最后一秒。否则 start/end 同传一个日期时区间塌缩成零宽度
        // （00:00 ~ 00:00），必然查空——「查某天的睡眠」失败即此因
        // （睡眠样本跨午夜，与零宽度区间无重叠）。delete 同走本函数，一并修复。
        if let rawEnd = parameters["end_date"] as? String,Self.isDateOnlyText(rawEnd) {
            end = cal.startOfDay(for: end).addingTimeInterval(86_399)
        }
        var start: Date
        if let explicit = resolveDate(parameters["start_date"]) {
            start = explicit
        } else if let days = Self.number(from: parameters["start_date"]) {
            start = cal.date(byAdding: .day, value: -Int(days), to: now) ?? cal.startOfDay(for: now)
        } else {
            start = cal.startOfDay(for: now)
        }
        guard start <= end else { return (start, end, String(localized: "health_bad_date_range")) }
        return (start, end, nil)
    }

    /// 是否为「纯日期」文本（无时间部分）：today / yesterday / yyyy-MM-dd。
    /// 用于 end 的整天语义判定；相对天数（7d）与带时间的格式不算。
    static func isDateOnlyText(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower == "today" || lower == "yesterday" { return true }
        guard !text.contains(":") else { return false }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: text) != nil
    }

    /// 解析日期参数：`today` / `yesterday` / `7d`（近 7 天）/ `yyyy-MM-dd` / `yyyy-MM-dd HH:mm`。
    private func resolveDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = Self.number(from: raw) { return nil }
        let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let cal = Calendar.current
        let lower = text.lowercased()
        if lower == "today" { return cal.startOfDay(for: Date()) }
        if lower == "yesterday" { return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) }
        if lower.hasSuffix("d"), let days = Double(lower.dropLast()), days > 0 {
            return cal.date(byAdding: .day, value: -Int(days), to: Date())
        }
        let formatters = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for pattern in formatters {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = pattern
            if let date = df.date(from: text) { return date }
        }
        return nil
    }

    private func clampedLimit(_ raw: Any?) -> Int {
        let value = Int(Self.number(from: raw) ?? 20)
        return min(max(value, 1), 200)
    }

    private func resolveOptions(_ aggregate: String, def: HealthMetricDef) -> HKStatisticsOptions? {
        switch aggregate {
        case "sum": return .cumulativeSum
        case "avg": return .discreteAverage
        case "min": return .discreteMin
        case "max": return .discreteMax
        case "none": return nil
        default: return def.options
        }
    }

    private func formatValue(_ value: Double, def: HealthMetricDef) -> String {
        guard let unit = def.unit else { return Self.trim(value) }
        return "\(Self.trim(value)) \(unit.unitString)"
    }

    /// 统一裁剪小数噪声（23.456700000000001 → 23.4567），同时保留体脂等需要 3-4 位小数的精度。
    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10000).rounded() / 10000
        return String(format: "%.4g", rounded)
    }

    private static func number(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private func shortISO(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }

    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "strength"
        case .highIntensityIntervalTraining: return "hiit"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .traditionalStrengthTraining: return "strength"
        default: return "other"
        }
    }

    private static func sexName(_ sex: HKBiologicalSex) -> String {
        switch sex {
        case .female: return "female"
        case .male: return "male"
        case .other: return "other"
        default: return "not_set"
        }
    }

    private static func bloodName(_ type: HKBloodType) -> String {
        switch type {
        case .aPositive: return "A+"
        case .aNegative: return "A-"
        case .bPositive: return "B+"
        case .bNegative: return "B-"
        case .abPositive: return "AB+"
        case .abNegative: return "AB-"
        case .oPositive: return "O+"
        case .oNegative: return "O-"
        default: return "not_set"
        }
    }
}

// MARK: - 供权限页一次性申请的类型集合

extension AppleHealthKitTool {
    /// 生理特征类型（性别 / 出生日期 / 血型）。
    /// 只读且**永不可作为写入类型**，故不进 `HealthMetrics`（那张表要求 objectType 可当 HKSampleType 用）。
    static var characteristicTypes: [HKObjectType] {
        [.biologicalSex, .dateOfBirth, .bloodType].compactMap {
            HKObjectType.characteristicType(forIdentifier: $0)
        }
    }

    /// 本工具会读取的全部 HealthKit 类型（指标 + 运动记录 + 生理特征）。
    ///
    /// 权限页据此**一次性**申请读授权：iOS 对未曾申请过的类型会再弹一次窗，
    /// 若每次只申请当前正查询的那一个类型，用户会被反复弹窗打断。
    static var readableTypes: Set<HKObjectType> {
        var types = Set(HealthMetrics.all.map(\.objectType))
        types.insert(HKObjectType.workoutType())
        types.formUnion(characteristicTypes)
        return types
    }
}
