import Foundation
import EventKit

// MARK: - 跨 actor 边界的数据

/// 统一结果。EventKit 对象不是 Sendable，失败原因在桥接层内就地本地化后回传文本。
private struct CalendarOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> CalendarOutcome { CalendarOutcome(success: true, text: text) }
    static func fail(_ text: String) -> CalendarOutcome { CalendarOutcome(success: false, text: text) }
}

/// 重复规则的原始参数。
/// 刻意传原始值而非 `RecurrenceSpec`：`EKRecurrenceDayOfWeek` / `EKRecurrenceEnd` 都不是
/// Sendable，跨不过 actor 边界，所以规则在桥接层内部构造。
private struct RecurrenceDraft: Sendable {
    let freq: String?
    let interval: Int?
    let days: [String]?
    let until: String?
    let count: Int?
}

/// 写入类操作的全部入参（Sendable，可安全跨 actor 边界）。
private struct EventDraft: Sendable {
    var title: String?
    var start: String?
    var end: String?
    var notes: String?
    var location: String?
    var calendarName: String?
    var allDay = false
    var recur: RecurrenceDraft?
    var clearRecur = false
}

// MARK: - apple-calendar (EventKit 事件)

/// 日历事件工具。
///
/// ## 设计要点
/// - **渐进式披露**：`list` 只给精简字段（标题/时间/日历/地点），`calendars` 单列可选日历，
///   `freebusy` 直接回答「哪段有空」——三条都是便宜调用，避免为一次提问拉全量详情。
/// - **重复事件**：创建/更新支持 `recur*` 一组参数；更新重复事件时可用 `occurrence_date`
///   只改其中一次（EventKit 的经典坑：默认会改整个系列）。
/// - **授权**：与提醒共用 `EventKitAuthGate`，写入前才弹窗，未授权返回可执行的引导文案。
struct AppleCalendarTool: AgentTool {
    let name = "apple-calendar"
    /// 会真实改动用户数据，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-calendar",
            description: L10n.l("calendar_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("op_calendar_actions"),
                        enum: ["list", "calendars", "freebusy", "create", "update", "delete"]
                    ),
                    "title": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_event_title")),
                    "start_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_start_time")),
                    "end_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_end_time")),
                    "event_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_event_id")),
                    "calendar_name": JSONSchema.JSONProperty(type: "string", description: L10n.l("calendar_name")),
                    "notes": JSONSchema.JSONProperty(type: "string", description: L10n.l("note_label")),
                    "location": JSONSchema.JSONProperty(type: "string", description: L10n.l("place_param")),
                    "all_day": JSONSchema.JSONProperty(type: "boolean", description: L10n.l("param_all_day")),
                    "range_days": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_query_days")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_result_limit")),
                    "occurrence_date": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_occurrence_date")),
                    "recur": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_recur_freq"), enum: ["daily", "weekly", "monthly", "yearly"]),
                    "recur_interval": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_recur_interval")),
                    "recur_days": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_recur_days")),
                    "recur_until": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_recur_until")),
                    "recur_count": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_recur_count")),
                    "clear_recur": JSONSchema.JSONProperty(type: "boolean", description: L10n.l("param_clear_recur")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_action"))
        }

        switch action {
        case "list", "calendars", "freebusy":
            // 查询也走同一道门：未授权时读到的是空数据，会误导模型以为用户没有日程。
            let ok = await EventKitAuthGate.shared.ensureAccess(to: .event)
            guard ok else { return ToolResult(success: false, text: L10n.l("calendar_denied")) }
            let outcome: CalendarOutcome
            switch action {
            case "list":
                outcome = await CalendarBridge.list(
                    rangeDays: Self.int(parameters["range_days"]),
                    limit: Self.int(parameters["limit"]),
                    startDate: Self.string(parameters["start_date"]),
                    endDate: Self.string(parameters["end_date"]),
                    calendarName: Self.string(parameters["calendar_name"]))
            case "calendars":
                outcome = await CalendarBridge.calendars()
            default:
                outcome = await CalendarBridge.freebusy(
                    rangeDays: Self.int(parameters["range_days"]),
                    startDate: Self.string(parameters["start_date"]),
                    endDate: Self.string(parameters["end_date"]),
                    calendarName: Self.string(parameters["calendar_name"]))
            }
            return ToolResult(success: outcome.success, text: outcome.text)

        case "create", "update", "delete":
            // 写操作：先过授权门（只有这里才可能触发写权限弹窗）
            let ok = await EventKitAuthGate.shared.ensureAccess(to: .event)
            guard ok else { return ToolResult(success: false, text: L10n.l("calendar_denied")) }
            let outcome: CalendarOutcome
            switch action {
            case "create":
                guard let title = Self.string(parameters["title"]), !title.isEmpty else {
                    return ToolResult(success: false, text: L10n.l("calendar_need_title"))
                }
                var draft = Self.draft(from: parameters)
                draft.title = title
                outcome = await CalendarBridge.create(draft)
            case "update":
                guard let id = Self.string(parameters["event_id"]), !id.isEmpty else {
                    return ToolResult(success: false, text: L10n.l("calendar_need_event_id"))
                }
                outcome = await CalendarBridge.update(id: id,
                                                      draft: Self.draft(from: parameters),
                                                      occurrenceDate: Self.string(parameters["occurrence_date"]))
            default:
                guard let id = Self.string(parameters["event_id"]), !id.isEmpty else {
                    return ToolResult(success: false, text: L10n.l("calendar_need_event_id"))
                }
                outcome = await CalendarBridge.delete(id: id,
                                                      occurrenceDate: Self.string(parameters["occurrence_date"]))
            }
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: L10n.l("calendar_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleCalendarTool {
    /// 只要出现任一 recur_* 参数就认为「要改重复规则」——
    /// 只给 recur_days 却不给 recur 时，报错比静默忽略更符合预期。
    private static func draft(from parameters: [String: Any]) -> EventDraft {
        let keys = ["recur", "recur_interval", "recur_days", "recur_until", "recur_count"]
        let asked = keys.contains { parameters[$0] != nil }
        var draft = EventDraft()
        draft.title = Self.string(parameters["title"])
        draft.start = Self.string(parameters["start_date"])
        draft.end = Self.string(parameters["end_date"])
        draft.notes = Self.string(parameters["notes"])
        draft.location = Self.string(parameters["location"])
        draft.calendarName = Self.string(parameters["calendar_name"])
        draft.allDay = Self.bool(parameters["all_day"])
        draft.clearRecur = Self.bool(parameters["clear_recur"])
        if asked {
            draft.recur = RecurrenceDraft(freq: Self.string(parameters["recur"]),
                                          interval: Self.int(parameters["recur_interval"]),
                                          days: Self.days(from: parameters),
                                          until: Self.string(parameters["recur_until"]),
                                          count: Self.int(parameters["recur_count"]))
        }
        return draft
    }

    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }

    private static func days(from parameters: [String: Any]) -> [String]? {
        guard let raw = string(parameters["recur_days"]) else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.isEmpty ? nil : parts
    }
}

// MARK: - MainActor 桥接层

/// 日历的读写全部隔离在 MainActor 内。
///
/// 两条硬约束叠加的结果：
/// 1. `EKEventStore` 不是线程安全的，必须固定在创建它的线程上使用；
/// 2. `EKEvent` / `EKCalendar` / `NSPredicate` 都不是 Sendable，Swift 6 下不能带出隔离区。
///
/// 因此每个方法都在主线程一次做完「取数 + 组装输出」，只回传 Sendable 的文本。
@MainActor
private enum CalendarBridge {
    private static var store: EKEventStore { EventKitStore.shared }

    // MARK: 查询

    /// 列出时间范围内的事件（精简字段）。
    static func list(rangeDays: Int?,
                     limit: Int?,
                     startDate: String?,
                     endDate: String?,
                     calendarName: String?) async -> CalendarOutcome {
        let start = EventDateParser.parse(startDate) ?? Date()
        let end = EventDateParser.parse(endDate, endOfDay: true)
            ?? Calendar.current.date(byAdding: .day, value: max(rangeDays ?? 7, 1), to: start)
            ?? start.addingTimeInterval(86400)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: resolveCalendars(name: calendarName))
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        guard !events.isEmpty else { return .ok(L10n.l("calendar_no_events")) }
        let shown = Array(events.prefix(max(limit ?? 50, 1)))
        var lines: [String] = [L10n.l("calendar_list_header") + "\(shown.count)/\(events.count)"]
        for e in shown { lines.append(describe(e)) }
        return .ok(lines.joined(separator: "\n"))
    }

    /// 列出所有可用日历（含可写性），供 create / update 选目标。
    static func calendars() async -> CalendarOutcome {
        let all = store.calendars(for: .event)
        guard !all.isEmpty else { return .ok(L10n.l("calendar_no_calendars")) }
        var lines: [String] = [L10n.l("calendars_header")]
        for c in all {
            let writable = c.allowsContentModifications ? L10n.l("writable_yes") : L10n.l("writable_no")
            lines.append("- \(c.title) [\(c.source.title)] \(writable)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    /// 空闲/忙碌分析：合并重叠区间后给出忙碌段，并反推出其中的空闲段。
    static func freebusy(rangeDays: Int?,
                         startDate: String?,
                         endDate: String?,
                         calendarName: String?) async -> CalendarOutcome {
        let start = EventDateParser.parse(startDate) ?? Date()
        let end = EventDateParser.parse(endDate, endOfDay: true)
            ?? Calendar.current.date(byAdding: .day, value: max(rangeDays ?? 1, 1), to: start)
            ?? start.addingTimeInterval(86400)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: resolveCalendars(name: calendarName))
        let all = store.events(matching: predicate)
        // 全天事件横跨整天，会让「忙碌」铺满整个区间，对找空档没有意义——单独统计。
        let timed = all.filter { !$0.isAllDay }
        let allDay = all.filter(\.isAllDay)

        var lines: [String] = [L10n.l("freebusy_range") + EventDateParser.shortString(from: start)
                               + " → " + EventDateParser.shortString(from: end)]
        if !allDay.isEmpty {
            lines.append(L10n.l("freebusy_allday") + allDay.map(\.title).joined(separator: "、"))
        }

        let busy = merge(intervals: timed.compactMap { ev -> (Date, Date)? in
            guard let s = ev.startDate, let e = ev.endDate, e > s else { return nil }
            return (s, e)
        })
        guard !busy.isEmpty else {
            lines.append(L10n.l("freebusy_all_free"))
            return .ok(lines.joined(separator: "\n"))
        }

        lines.append(L10n.l("freebusy_busy_header"))
        for (s, e) in busy {
            lines.append("- " + EventDateParser.shortString(from: s) + " → " + EventDateParser.shortString(from: e))
        }

        let free = gaps(between: busy, from: start, to: end)
        if free.isEmpty {
            lines.append(L10n.l("freebusy_no_gap"))
        } else {
            lines.append(L10n.l("freebusy_free_header"))
            for (s, e) in free {
                let minutes = Int(e.timeIntervalSince(s) / 60)
                lines.append("- " + EventDateParser.shortString(from: s) + " → " + EventDateParser.shortString(from: e)
                             + " (" + "\(minutes)" + L10n.l("unit_minutes") + ")")
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: 写入

    static func create(_ draft: EventDraft) async -> CalendarOutcome {
        guard let title = draft.title, !title.isEmpty else { return .fail(L10n.l("calendar_need_title")) }
        guard let start = EventDateParser.parse(draft.start) else { return .fail(L10n.l("calendar_need_start")) }
        // 未给结束时间：普通事件默认 1 小时，全天事件默认当天结束
        let fallbackEnd = draft.allDay
            ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start)
            : start.addingTimeInterval(3600)
        // `?? fallbackEnd` 已经把 Optional 消掉了，这里不是可选绑定
        let end = EventDateParser.parse(draft.end, endOfDay: draft.allDay) ?? fallbackEnd
        guard end > start else { return .fail(L10n.l("calendar_bad_range")) }

        guard let target = writableCalendar(name: draft.calendarName) else {
            return .fail(L10n.l("calendar_no_calendars"))
        }
        let spec: RecurrenceSpec?
        switch recurrence(from: draft) {
        case .invalid(let text): return .fail(text)
        case .untouched:         spec = nil
        case .rule(let s):       spec = s
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = draft.allDay
        event.calendar = target
        if let notes = draft.notes { event.notes = notes }
        if let location = draft.location { event.location = location }
        if let spec { event.recurrenceRules = [spec.rule()] }
        do {
            try store.save(event, span: .thisEvent)
            return .ok(L10n.l("calendar_created") + "\n" + describe(event))
        } catch {
            return .fail(L10n.l("calendar_save_failed") + error.localizedDescription)
        }
    }

    static func update(id: String, draft: EventDraft, occurrenceDate: String?) async -> CalendarOutcome {
        let spec: RecurrenceSpec?
        switch recurrence(from: draft) {
        case .invalid(let text): return .fail(text)
        case .untouched:         spec = nil
        case .rule(let s):       spec = s
        }

        // 定位目标：给了 occurrence_date 就在展开的 occurrence 里精确匹配那一次，
        // 否则取系列主事件（改整个系列）。
        let event: EKEvent
        if let occurrenceRaw = occurrenceDate {
            guard let occurrenceStart = EventDateParser.parse(occurrenceRaw) else {
                return .fail(L10n.l("calendar_bad_occurrence"))
            }
            guard let master = store.event(withIdentifier: id) else {
                return .fail(L10n.l("calendar_event_not_found") + id)
            }
            // 查询返回的是展开后的 occurrence（同一个 eventIdentifier 会出现多次）
            let spanStart = Calendar.current.date(byAdding: .day, value: -1, to: master.startDate ?? occurrenceStart) ?? occurrenceStart
            let spanEnd = Calendar.current.date(byAdding: .year, value: 2, to: occurrenceStart) ?? occurrenceStart
            let predicate = store.predicateForEvents(withStart: spanStart, end: spanEnd, calendars: nil)
            guard let hit = store.events(matching: predicate).first(where: { ev in
                ev.eventIdentifier == id && ev.startDate == occurrenceStart
            }) else {
                return .fail(L10n.l("calendar_occurrence_not_found"))
            }
            event = hit
        } else {
            guard let master = store.event(withIdentifier: id) else {
                return .fail(L10n.l("calendar_event_not_found") + id)
            }
            event = master
        }

        if let title = draft.title, !title.isEmpty { event.title = title }
        if let startRaw = draft.start {
            guard let start = EventDateParser.parse(startRaw) else { return .fail(L10n.l("calendar_need_start")) }
            event.startDate = start
        }
        if let endRaw = draft.end {
            guard let end = EventDateParser.parse(endRaw, endOfDay: event.isAllDay) else {
                return .fail(L10n.l("calendar_bad_range"))
            }
            event.endDate = end
        }
        if let start = event.startDate, let end = event.endDate, end <= start {
            return .fail(L10n.l("calendar_bad_range"))
        }
        if let notes = draft.notes { event.notes = notes }
        if let location = draft.location { event.location = location }
        if let calName = draft.calendarName, let cal = calendar(named: calName) { event.calendar = cal }
        if let spec { event.recurrenceRules = [spec.rule()] }
        else if draft.clearRecur { event.recurrenceRules = nil }

        // 只改一次 vs 改此后所有：由是否给了 occurrence_date 决定，语义与 EKEventStore 一致
        let span: EKSpan = occurrenceDate == nil ? .futureEvents : .thisEvent
        do {
            try store.save(event, span: span)
            return .ok(L10n.l("calendar_updated") + "\n" + describe(event))
        } catch {
            return .fail(L10n.l("calendar_save_failed") + error.localizedDescription)
        }
    }

    static func delete(id: String, occurrenceDate: String?) async -> CalendarOutcome {
        guard let event = store.event(withIdentifier: id) else {
            return .fail(L10n.l("calendar_event_not_found") + id)
        }
        let title = event.title ?? ""
        let span: EKSpan = occurrenceDate == nil ? .futureEvents : .thisEvent
        do {
            try store.remove(event, span: span)
            return .ok(L10n.l("calendar_deleted") + title)
        } catch {
            return .fail(L10n.l("calendar_delete_failed") + error.localizedDescription)
        }
    }

    // MARK: 辅助

    /// 从草稿构造重复规则。未要求改规则 → .untouched；要求了但非法 → .invalid。
    private static func recurrence(from draft: EventDraft) -> RecurrenceResolve {
        guard let r = draft.recur else { return .untouched }
        guard let spec = RecurrenceSpec.make(freq: r.freq,
                                             interval: r.interval,
                                             days: r.days,
                                             until: r.until,
                                             count: r.count) else {
            return .invalid(L10n.l("calendar_bad_recur"))
        }
        // 同时又给规则又要求清除，是自相矛盾——直接报错而不是猜优先级
        if draft.clearRecur { return .invalid(L10n.l("calendar_recur_conflict")) }
        return .rule(spec)
    }

    /// 事件精简描述（list / create / update 共用同一形态，模型侧输出稳定）。
    private static func describe(_ e: EKEvent) -> String {
        let time = e.isAllDay
            ? String(EventDateParser.string(from: e.startDate).prefix(10)) + " " + L10n.l("all_day_label")
            : EventDateParser.shortString(from: e.startDate) + " → " + EventDateParser.shortString(from: e.endDate)
        var parts = ["- \(e.title ?? "") | \(time)"]
        if let loc = e.location, !loc.isEmpty { parts.append(L10n.l("place_label") + loc) }
        parts.append(L10n.l("calendar_label") + e.calendar.title)
        parts.append(L10n.l("id_label") + e.eventIdentifier)
        return parts.joined(separator: " | ")
    }

    /// 合并重叠区间（用于 freebusy）。
    private static func merge(intervals: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var out: [(Date, Date)] = []
        for iv in sorted {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1] = (last.0, max(last.1, iv.1))
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// 反推忙碌区间之间的空档。短于 5 分钟的空档没有安排价值，过滤掉以免输出噪声。
    private static func gaps(between busy: [(Date, Date)], from start: Date, to end: Date) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        var cursor = start
        for (s, e) in busy {
            if s > cursor { out.append((cursor, s)) }
            cursor = max(cursor, e)
        }
        if cursor < end { out.append((cursor, end)) }
        return out.filter { $0.1.timeIntervalSince($0.0) >= 300 }
    }

    private static func calendar(named name: String) -> EKCalendar? {
        store.calendars(for: .event).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// 按名字过滤日历；未指定时传 nil（表示不限制，覆盖用户全部日历）。
    private static func resolveCalendars(name: String?) -> [EKCalendar]? {
        guard let name else { return nil }
        guard let c = calendar(named: name) else { return [] }
        return [c]
    }

    /// 写入目标日历：未指定时取默认日历，默认日历不可写则回退到第一个可写日历。
    /// 用户可能一个日历都没有（未登录 iCloud 且删光本地日历），此时返回 nil 由调用方报错，
    /// **不做强制解包**——那会在最边缘的场景下直接崩进程。
    private static func writableCalendar(name: String?) -> EKCalendar? {
        if let name, let c = calendar(named: name) { return c }
        if let def = store.defaultCalendarForNewEvents, def.allowsContentModifications { return def }
        return store.calendars(for: .event).first { $0.allowsContentModifications }
            ?? store.defaultCalendarForNewEvents
    }
}
