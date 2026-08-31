import Foundation
import EventKit

// MARK: - 共享 EKEventStore

/// EventKit 不是线程安全的：`EKEventStore` 必须在固定的线程/队列上创建，并始终在同一处使用。
/// 这里统一放主线程单例，所有读写经 `MainActor` 串行化（与授权弹窗同一线程，避免跨线程回调丢失）。
@MainActor
enum EventKitStore {
    static let shared = EKEventStore()
}

// MARK: - 授权串行门

/// EventKit 授权串行门。
///
/// 与 HealthKit 同源的问题：iOS 同一时刻只接受一个系统授权弹窗，**并发调用
/// `requestAccess` 会静默失败或被系统直接拒绝**（多个工具调用 / 权限页与工具
/// 内部同时触发时极易命中）。用 actor 把每一次授权请求串行化。
///
/// 已授权时直接放行，不排队——只有真正要弹窗的请求才需要互斥。
actor EventKitAuthGate {
    static let shared = EventKitAuthGate()

    /// 请求授权。返回「当前可否继续读写」，**false 表示未授权**（调用方应给出引导文案）。
    func ensureAccess(to type: EKEntityType) async -> Bool {
        if Self.isAuthorized(type) { return true }
        return await requestAccess(type)
    }

    /// 只查询、不触发弹窗。供「先看状态再决定要不要写」的路径使用。
    nonisolated static func isAuthorized(_ type: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if #available(iOS 17.0, *) {
            if status == .fullAccess { return true }
        }
        return status == .authorized
    }

    /// 弹窗必须在主线程发起：`EKEventStore` 固定在主线程，授权回调也回到主线程。
    ///
    /// 这里**不能用 `await MainActor.run { ... }` 包住等待**——`MainActor.run` 只有同步闭包
    /// 重载，塞一个 async 挂起点进去编译不过。整个方法标记 `@MainActor` 才是正确写法：
    /// 从 actor 域切到主线程，参数与返回值都是 Sendable，跨隔离域没有问题。
    @MainActor
    private func requestAccess(_ type: EKEntityType) async -> Bool {
        let store = EventKitStore.shared
        return await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                switch type {
                case .event:
                    store.requestFullAccessToEvents { granted, _ in cont.resume(returning: granted) }
                case .reminder:
                    store.requestFullAccessToReminders { granted, _ in cont.resume(returning: granted) }
                @unknown default:
                    store.requestAccess(to: type) { granted, _ in cont.resume(returning: granted) }
                }
            } else {
                store.requestAccess(to: type) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }
}

// MARK: - 日期解析

/// 事件 / 提醒的日期解析。
///
/// 模型侧传来的时间形态很杂，统一收敛到三种输入：
/// 1. **ISO 8601**：`2026-09-01`、`2026-09-01T10:00`、`2026-09-01T10:00:00+08:00`（带秒/时区均可）
/// 2. **相对偏移**：`now`、`+7d`、`-2h`、`+30m`、`+1w`（相对当前时刻）
/// 3. **自然语言兜底**：以上都失败时交给 `NSDataDetector`（"明天下午三点" 之类），
///    失败则返回 nil 让调用方报参数错误——**绝不静默兜成「现在」**，否则会写错时间。
/// ISO 8601 格式化器容器。
///
/// `DateFormatter` 被 Apple 标注为 Sendable，但 `ISO8601DateFormatter` 没有（SDK 标注缺口），
/// 直接放静态属性会报「non-Sendable 类型可能有共享可变状态」。
///
/// 这两个实例在初始化时配好 `formatOptions` 之后**只读、不再变更**，且 ISO 8601 解析与
/// locale 无关，不存在「切语言后要重建」的问题，因此用显式 Sendable 盒子持有——
/// 既避免每次解析重建（formatter 创建不便宜），也不必为此加一把锁。
private final class ISOFormatters: @unchecked Sendable {
    static let shared = ISOFormatters()

    let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()

    let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum EventDateParser {
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let minutePrecision: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    /// 解析时间字符串。无法识别返回 nil。
    /// - Parameter endOfDay: 仅日期（无时分）时是否取当日 23:59:59，用于「结束时间」语义。
    static func parse(_ raw: String?, endOfDay: Bool = false) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }

        // 相对偏移：now / +7d / -2h / +30m / +1w
        if let d = parseRelative(s) { return d }

        // ISO 8601（含时区、含小数秒）
        if let d = ISOFormatters.shared.full.date(from: s) ?? ISOFormatters.shared.plain.date(from: s) { return d }

        // 仅日期：按当日起点（或终点）解析——未给定时区，按用户本地时区解释
        if let d = dateOnly.date(from: s) {
            return endOfDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) : d
        }
        // 精确到分（无时区，按本地时区）
        if let d = minutePrecision.date(from: s) { return d }

        // 自然语言兜底（中文/英文的"明天下午三点""next Friday"）
        return parseNaturalLanguage(s)
    }

    private static func parseRelative(_ s: String) -> Date? {
        let lower = s.lowercased()
        if lower == "now" || lower == "today" { return Date() }
        guard let first = lower.first, first == "+" || first == "-" else { return nil }
        let sign: TimeInterval = first == "+" ? 1 : -1
        let body = lower.dropFirst()
        guard !body.isEmpty else { return nil }
        guard let unitChar = body.last, let num = Double(body.dropLast()) else { return nil }
        // 只接受整数倍偏移，避免 "1.5d" 这类歧义输入被悄悄接受
        guard num == num.rounded() else { return nil }
        let multiplier: TimeInterval
        switch unitChar {
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        case "w": multiplier = 604800
        default: return nil
        }
        return Date().addingTimeInterval(sign * num * multiplier)
    }

    private static func parseNaturalLanguage(_ s: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(s.startIndex..., in: s)
        var hit: Date?
        detector?.enumerateMatches(in: s, range: range) { result, _, stop in
            if let d = result?.date {
                hit = d
                stop.pointee = true
            }
        }
        return hit
    }

    /// 统一输出为 ISO 8601 字符串（带秒、无小数），模型侧易解析。
    static func string(from date: Date?) -> String {
        guard let date else { return "" }
        return ISOFormatters.shared.plain.string(from: date)
    }

    /// 人类可读的短格式，用于列表输出（"9月1日 14:00" 这类由系统本地化）。
    static func shortString(from date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - 重复规则

/// 重复规则规格。模型侧用扁平参数表达，这里收敛成 `EKRecurrenceRule`。
///
/// 刻意不做的两件事：
/// - **不按月/按年的「第几个星期几」**（`setPositions`）：表达复杂、模型易填错，
///   且日常使用频率极低。需要时可用 `recur_count` + 多次创建覆盖。
/// - **不做子任务**（提醒的 `--parent-id`）：iOS 的 EventKit 无公开 API。
struct RecurrenceSpec {
    let frequency: EKRecurrenceFrequency
    let interval: Int
    let days: [EKRecurrenceDayOfWeek]?
    let end: EKRecurrenceEnd?

    /// 从扁平参数构造。任一字段非法返回 nil，由调用方报错（不静默忽略重复设置）。
    static func make(freq: String?,
                     interval: Int?,
                     days: [String]?,
                     until: String?,
                     count: Int?) -> RecurrenceSpec? {
        guard let rawFreq = freq?.lowercased(), !rawFreq.isEmpty else { return nil }
        let frequency: EKRecurrenceFrequency
        switch rawFreq {
        case "daily":   frequency = .daily
        case "weekly":  frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly":  frequency = .yearly
        default: return nil
        }

        let iv = max(1, interval ?? 1)

        // days 仅对 weekly/monthly/yearly 有意义；daily 传了直接视为非法，避免静默丢弃
        var recurrenceDays: [EKRecurrenceDayOfWeek]? = nil
        if let days, !days.isEmpty {
            guard frequency != .daily else { return nil }
            var parsed: [EKRecurrenceDayOfWeek] = []
            for d in days {
                guard let wd = weekday(from: d) else { return nil }
                parsed.append(EKRecurrenceDayOfWeek(wd))
            }
            recurrenceDays = parsed
        }

        // until 与 count 互斥：同时给出视为参数错误，不做「谁优先」的猜测
        if let untilRaw = until, !untilRaw.isEmpty, count != nil { return nil }

        var end: EKRecurrenceEnd? = nil
        if let untilRaw = until, !untilRaw.isEmpty {
            guard let d = EventDateParser.parse(untilRaw, endOfDay: true) else { return nil }
            end = EKRecurrenceEnd(end: d)
        } else if let count, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return RecurrenceSpec(frequency: frequency, interval: iv, days: recurrenceDays, end: end)
    }

    func rule() -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: frequency,
                         interval: interval,
                         daysOfTheWeek: days,
                         daysOfTheMonth: nil,
                         monthsOfTheYear: nil,
                         weeksOfTheYear: nil,
                         daysOfTheYear: nil,
                         setPositions: nil,
                         end: end)
    }

    /// 星期解析：接受 1-7（周日=1）、0-6（周日=0）与英文缩写（mon / monday）。
    private static func weekday(from raw: String) -> EKWeekday? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let byName: [String: EKWeekday] = [
            "sun": .sunday, "sunday": .sunday,
            "mon": .monday, "monday": .monday,
            "tue": .tuesday, "tuesday": .tuesday,
            "wed": .wednesday, "wednesday": .wednesday,
            "thu": .thursday, "thursday": .thursday,
            "fri": .friday, "friday": .friday,
            "sat": .saturday, "saturday": .saturday,
        ]
        if let wd = byName[s] { return wd }
        if let n = Int(s) {
            switch n {
            case 1...7: return EKWeekday(rawValue: n)
            case 0:     return .sunday
            default:    return nil
            }
        }
        return nil
    }
}

// MARK: - 重复规则解析结果

/// `recur*` 参数组的解析结果，日历与提醒共用。
///
/// 刻意不用 `Result`——它的 `Failure` 必须遵守 `Error`，而这里携带的只是一段
/// 已本地化的说明文案，为它单独造一个 `Error` 类型纯属多余。
///
/// 该枚举**不需要 Sendable**：`RecurrenceSpec` 不是 Sendable，解析与消费都发生在
/// 同一个 MainActor 隔离域内（`CalendarBridge` / `ReminderBridge`）。
enum RecurrenceResolve {
    /// 本次调用没有要求改动重复规则。
    case untouched
    case rule(RecurrenceSpec)
    /// 要求了但参数非法，携带可直接回给模型的说明。
    case invalid(String)
}
