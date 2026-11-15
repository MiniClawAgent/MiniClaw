import Foundation
import EventKit

// MARK: - 跨 actor 边界的数据

/// 统一结果。EventKit 对象不是 Sendable，失败原因在桥接层内就地本地化后回传文本。
private struct ReminderOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> ReminderOutcome { ReminderOutcome(success: true, text: text) }
    static func fail(_ text: String) -> ReminderOutcome { ReminderOutcome(success: false, text: text) }
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
private struct ReminderDraft: Sendable {
    var title: String?
    var due: String?
    var notes: String?
    var priority: Int?
    var listName: String?
    var recur: RecurrenceDraft?
    var clearRecur = false
}

// MARK: - apple-reminders (EventKit 提醒)

/// 提醒事项工具。
///
/// ## 设计要点
/// - **`complete` 独立成 action**：完成/取消完成是提醒最高频的操作，塞进 `update` 的
///   一个布尔字段会让模型多绕一层，也更容易漏传。
/// - **不做地理围栏提醒**（到某地点时提醒）：那需要 Always 定位授权才能可靠触发，
///   与本 App 刻意只申请 WhenInUse、并已移除 `location` 后台模式的方向冲突。
/// - **不做子任务**：iOS 的 EventKit 无公开 API 读写提醒的父子关系。
/// - 与日历共用 `EventKitAuthGate` 与 `RecurrenceSpec`，重复规则参数完全一致。
struct AppleRemindersTool: AgentTool {
    let name = "apple_reminders"
    /// 会真实改动用户数据，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple_reminders",
            description: String(localized: "reminders_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "op_reminder_actions_full"),
                        enum: ["list", "create", "update", "complete", "delete"]
                    ),
                    "title": JSONSchema.JSONProperty(type: "string", description: String(localized: "reminder_title")),
                    "due_date": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_due_time")),
                    "reminder_id": JSONSchema.JSONProperty(type: "string", description: String(localized: "reminder_id")),
                    "list_name": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_reminder_list")),
                    "notes": JSONSchema.JSONProperty(type: "string", description: String(localized: "note_label")),
                    "priority": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_priority")),
                    "completed": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_only_completed")),
                    "undo": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_undo_complete")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_result_limit")),
                    "recur": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_recur_freq"), enum: ["daily", "weekly", "monthly", "yearly"]),
                    "recur_interval": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_recur_interval")),
                    "recur_days": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_recur_days")),
                    "recur_until": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_recur_until")),
                    "recur_count": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_recur_count")),
                    "clear_recur": JSONSchema.JSONProperty(type: "boolean", description: String(localized: "param_clear_recur")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_action"))
        }

        let ok = await EventKitAuthGate.shared.ensureAccess(to: .reminder)
        guard ok else { return ToolResult(success: false, text: String(localized: "reminders_denied")) }

        // `parameters` 不是 Sendable，不能进 MainActor 闭包——先把入参摊平成 Sendable 值再过桥。
        switch action {
        case "list":
            let limit = Self.int(parameters["limit"]) ?? 50
            // completed 未传 = 全部；true = 只看已完成；false = 只看未完成
            let wantsCompleted = parameters["completed"] != nil ? Self.bool(parameters["completed"]) : nil
            let outcome = await ReminderBridge.list(limit: limit,
                                                    wantsCompleted: wantsCompleted,
                                                    listName: Self.string(parameters["list_name"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "create":
            guard let title = Self.string(parameters["title"]), !title.isEmpty else {
                return ToolResult(success: false, text: String(localized: "reminders_need_title"))
            }
            var draft = Self.draft(from: parameters)
            draft.title = title
            let outcome = await ReminderBridge.create(draft)
            return ToolResult(success: outcome.success, text: outcome.text)

        case "update":
            guard let id = Self.string(parameters["reminder_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: String(localized: "reminders_need_id"))
            }
            let outcome = await ReminderBridge.update(id: id, draft: Self.draft(from: parameters))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "complete":
            guard let id = Self.string(parameters["reminder_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: String(localized: "reminders_need_id"))
            }
            let outcome = await ReminderBridge.complete(id: id, undo: Self.bool(parameters["undo"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "delete":
            guard let id = Self.string(parameters["reminder_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: String(localized: "reminders_need_id"))
            }
            let outcome = await ReminderBridge.delete(id: id)
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: String(localized: "reminders_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleRemindersTool {
    /// 只要出现任一 recur_* 参数就认为「要改重复规则」——
    /// 只给 recur_days 却不给 recur 时，报错比静默忽略更符合预期。
    private static func draft(from parameters: [String: Any]) -> ReminderDraft {
        let keys = ["recur", "recur_interval", "recur_days", "recur_until", "recur_count"]
        let asked = keys.contains { parameters[$0] != nil }
        var draft = ReminderDraft()
        draft.title = Self.string(parameters["title"])
        draft.due = Self.string(parameters["due_date"])
        draft.notes = Self.string(parameters["notes"])
        draft.priority = Self.int(parameters["priority"])
        draft.listName = Self.string(parameters["list_name"])
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

/// 提醒的读写全部隔离在 MainActor 内。
///
/// 两条硬约束叠加的结果：
/// 1. `EKEventStore` 不是线程安全的，必须固定在创建它的线程上使用；
/// 2. `EKReminder` / `EKCalendar` / `NSPredicate` 都不是 Sendable，Swift 6 下不能带出隔离区。
///
/// 因此每个方法都在主线程一次做完「取数 + 组装输出」，只回传 Sendable 的文本。
@MainActor
private enum ReminderBridge {
    private static var store: EKEventStore { EventKitStore.shared }

    // MARK: 查询

    /// 列出提醒。
    ///
    /// 排序与组装**必须发生在回调内部**，不能 `await fetch(...)` 拿回数组再处理：
    /// `EKReminder` 不是 Sendable，把它带过 await 会被 Swift 6 判成「跨隔离域传递」而报错。
    /// 编译器对该回调的判定就是 main actor 隔离（诊断原话：main actor-isolated 'items'），
    /// 与 `EventKitStore` 固定在主线程的纪律一致，所以在回调里读对象是安全的。
    static func list(limit: Int, wantsCompleted: Bool?, listName: String?) async -> ReminderOutcome {
        let predicate = makePredicate(wantsCompleted: wantsCompleted, listName: listName)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { items in
                cont.resume(returning: Self.render(items, limit: limit))
            }
        }
    }

    /// 排序 + 组装输出。只在 `fetchReminders` 的回调里调用——那里才是对象所处的隔离域。
    private static func render(_ items: [EKReminder]?, limit: Int) -> ReminderOutcome {
        guard let items else { return .fail(String(localized: "reminders_fetch_failed")) }
        guard !items.isEmpty else { return .ok(String(localized: "reminders_empty")) }

        let sorted = items.sorted { lhs, rhs in
            // 已完成的排后面，其余按到期时间升序（无到期时间的排最后）
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            switch (dueDate(of: lhs), dueDate(of: rhs)) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            default:           return false
            }
        }
        let shown = Array(sorted.prefix(max(limit, 1)))
        var lines: [String] = [String(localized: "reminders_list_header") + "\(shown.count)/\(sorted.count)"]
        for r in shown { lines.append(describe(r)) }
        return .ok(lines.joined(separator: "\n"))
    }

    /// predicate 只能在 store 所在的线程上构造，因此不把 NSPredicate 传出本层。
    private static func makePredicate(wantsCompleted: Bool?, listName: String?) -> NSPredicate {
        let calendars = resolveLists(name: listName)
        switch wantsCompleted {
        case .some(true):  return store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
        case .some(false): return store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        case .none:        return store.predicateForReminders(in: calendars)
        }
    }

    // MARK: 写入

    static func create(_ draft: ReminderDraft) async -> ReminderOutcome {
        guard let target = writableList(name: draft.listName) else {
            return .fail(String(localized: "reminders_no_list"))
        }
        // 重复提醒必须有到期日，否则 EKRecurrenceRule 没有锚点
        if draft.recur != nil && draft.due == nil {
            return .fail(String(localized: "reminders_recur_need_due"))
        }
        let spec: RecurrenceSpec?
        switch recurrence(from: draft) {
        case .invalid(let text): return .fail(text)
        case .untouched:         spec = nil
        case .rule(let s):       spec = s
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar = target
        if let notes = draft.notes { reminder.notes = notes }
        if let p = draft.priority { reminder.priority = clampedPriority(p) }
        if let dueRaw = draft.due {
            guard let d = EventDateParser.parse(dueRaw) else { return .fail(String(localized: "reminders_bad_due")) }
            reminder.dueDateComponents = components(from: d)
        }
        if let spec { reminder.recurrenceRules = [spec.rule()] }
        do {
            try store.save(reminder, commit: true)
            return .ok(String(localized: "reminders_created") + "\n" + describe(reminder))
        } catch {
            return .fail(String(localized: "reminders_save_failed") + error.localizedDescription)
        }
    }

    static func update(id: String, draft: ReminderDraft) async -> ReminderOutcome {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return .fail(String(localized: "reminders_not_found") + id)
        }
        let spec: RecurrenceSpec?
        switch recurrence(from: draft) {
        case .invalid(let text): return .fail(text)
        case .untouched:         spec = nil
        case .rule(let s):       spec = s
        }

        if let title = draft.title, !title.isEmpty { reminder.title = title }
        if let notes = draft.notes { reminder.notes = notes }
        if let p = draft.priority { reminder.priority = clampedPriority(p) }
        if let dueRaw = draft.due {
            guard let d = EventDateParser.parse(dueRaw) else { return .fail(String(localized: "reminders_bad_due")) }
            reminder.dueDateComponents = components(from: d)
        }
        if let listName = draft.listName, let list = self.list(named: listName) {
            reminder.calendar = list
        }
        if let spec { reminder.recurrenceRules = [spec.rule()] }
        else if draft.clearRecur { reminder.recurrenceRules = nil }

        do {
            try store.save(reminder, commit: true)
            return .ok(String(localized: "reminders_updated") + "\n" + describe(reminder))
        } catch {
            return .fail(String(localized: "reminders_save_failed") + error.localizedDescription)
        }
    }

    static func complete(id: String, undo: Bool) async -> ReminderOutcome {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return .fail(String(localized: "reminders_not_found") + id)
        }
        reminder.isCompleted = !undo
        if undo { reminder.completionDate = nil }
        do {
            try store.save(reminder, commit: true)
            let prefix = undo ? String(localized: "reminders_uncompleted") : String(localized: "reminders_completed")
            return .ok(prefix + (reminder.title ?? ""))
        } catch {
            return .fail(String(localized: "reminders_save_failed") + error.localizedDescription)
        }
    }

    static func delete(id: String) async -> ReminderOutcome {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return .fail(String(localized: "reminders_not_found") + id)
        }
        let title = reminder.title ?? ""
        do {
            try store.remove(reminder, commit: true)
            return .ok(String(localized: "reminders_deleted") + title)
        } catch {
            return .fail(String(localized: "reminders_delete_failed") + error.localizedDescription)
        }
    }

    // MARK: 辅助

    /// 从草稿构造重复规则。未要求改规则 → .untouched；要求了但非法 → .invalid。
    private static func recurrence(from draft: ReminderDraft) -> RecurrenceResolve {
        guard let r = draft.recur else { return .untouched }
        guard let spec = RecurrenceSpec.make(freq: r.freq,
                                             interval: r.interval,
                                             days: r.days,
                                             until: r.until,
                                             count: r.count) else {
            return .invalid(String(localized: "reminders_bad_recur"))
        }
        // 同时又给规则又要求清除，是自相矛盾——直接报错而不是猜优先级
        if draft.clearRecur { return .invalid(String(localized: "reminders_recur_conflict")) }
        return .rule(spec)
    }

    private static func describe(_ r: EKReminder) -> String {
        let mark = r.isCompleted ? "[x]" : "[ ]"
        var parts = ["- \(mark) \(r.title ?? "")"]
        if let d = dueDate(of: r) { parts.append(String(localized: "due_label") + EventDateParser.shortString(from: d)) }
        if r.priority > 0 { parts.append(String(localized: "priority_label") + "\(r.priority)") }
        parts.append(String(localized: "reminders_list_label") + r.calendar.title)
        parts.append(String(localized: "id_label") + r.calendarItemIdentifier)
        return parts.joined(separator: " | ")
    }

    /// 提醒的到期时间是 `DateComponents`（可只含日期、不含时分），转成 Date 便于排序与展示。
    private static func dueDate(of r: EKReminder) -> Date? {
        guard let dc = r.dueDateComponents else { return nil }
        return Calendar.current.date(from: dc)
    }

    /// 优先级收敛到 0-9（EventKit 的有效区间），越界一律夹取而非报错。
    private static func clampedPriority(_ raw: Int) -> Int {
        min(max(raw, 0), 9)
    }

    private static func components(from date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private static func list(named name: String) -> EKCalendar? {
        store.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// 按名字过滤列表；未指定时传 nil（表示不限制，覆盖用户全部列表）。
    private static func resolveLists(name: String?) -> [EKCalendar]? {
        guard let name else { return nil }
        guard let c = list(named: name) else { return [] }
        return [c]
    }

    /// 写入目标列表：未指定时取默认列表，默认列表不可写则回退到第一个可写列表。
    /// 一个列表都没有时返回 nil 由调用方报错——**不做强制解包**，那会直接崩进程。
    private static func writableList(name: String?) -> EKCalendar? {
        if let name, let c = list(named: name) { return c }
        if let def = store.defaultCalendarForNewReminders(), def.allowsContentModifications { return def }
        return store.calendars(for: .reminder).first { $0.allowsContentModifications }
            ?? store.defaultCalendarForNewReminders()
    }
}
