import Foundation
import Contacts

// MARK: - 跨 actor 边界的数据

/// 统一结果。`CNContact` 不是 Sendable，输出文本在桥接层内就地组装后回传。
private struct ContactOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> ContactOutcome { ContactOutcome(success: true, text: text) }
    static func fail(_ text: String) -> ContactOutcome { ContactOutcome(success: false, text: text) }
}

/// 写入类操作的全部入参（Sendable，可安全跨 actor 边界）。
private struct ContactDraft: Sendable {
    var givenName: String?
    var familyName: String?
    var organization: String?
    var phone: String?
    var email: String?
}

// MARK: - apple-contacts (Contacts)

/// 通讯录工具。
///
/// ## 为什么需要它
/// 「给张总发条消息」「查一下李工电话」这类请求，模型拿不到通讯录就只能反问用户。
/// iOS 上发消息/打电话本身没有后台可用的公开 API（`MFMessageComposeViewController`
/// 必须前台弹窗），所以本工具只覆盖**通讯录数据的读与写**，触达动作交给
/// `apple-open`（`sms:` / `tel:` scheme）在前台完成——两者配合才能跑通整条链路。
///
/// ## 明确不做的
/// - **备注字段**：`CNContactNoteKey` 需要 `com.apple.developer.contacts.notes`
///   授权 entitlement，没有它读取会失败。v1 不申请该权限，故字段整体不出现。
/// - **分组 / 容器**：`CNGroup` / `CNContainer` 语义偏冷门，且跨账号行为不一致。
struct AppleContactsTool: AgentTool {
    let name = "apple-contacts"
    /// 会真实改动用户通讯录，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-contacts",
            description: L10n.l("contacts_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("op_contacts_actions"),
                        enum: ["search", "get", "create", "update", "delete"]
                    ),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_contact_query")),
                    "contact_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_contact_id")),
                    "given_name": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_given_name")),
                    "family_name": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_family_name")),
                    "organization": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_organization")),
                    "phone": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_phone_number")),
                    "email": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_email_address")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_result_limit")),
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
        case "search":
            let ok = await ContactsBridge.ensureAccess()
            guard ok else { return ToolResult(success: false, text: L10n.l("contacts_denied")) }
            guard let query = Self.string(parameters["query"]), !query.isEmpty else {
                return ToolResult(success: false, text: L10n.l("contacts_need_query"))
            }
            let outcome = await ContactsBridge.search(query: query,
                                                      limit: Self.int(parameters["limit"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "get":
            let ok = await ContactsBridge.ensureAccess()
            guard ok else { return ToolResult(success: false, text: L10n.l("contacts_denied")) }
            guard let id = Self.string(parameters["contact_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: L10n.l("contacts_need_id"))
            }
            let outcome = await ContactsBridge.get(id: id)
            return ToolResult(success: outcome.success, text: outcome.text)

        case "create":
            let ok = await ContactsBridge.ensureAccess()
            guard ok else { return ToolResult(success: false, text: L10n.l("contacts_denied")) }
            let draft = Self.draft(from: parameters)
            guard draft.hasIdentity else {
                return ToolResult(success: false, text: L10n.l("contacts_need_identity"))
            }
            let outcome = await ContactsBridge.create(draft)
            return ToolResult(success: outcome.success, text: outcome.text)

        case "update":
            let ok = await ContactsBridge.ensureAccess()
            guard ok else { return ToolResult(success: false, text: L10n.l("contacts_denied")) }
            guard let id = Self.string(parameters["contact_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: L10n.l("contacts_need_id"))
            }
            let outcome = await ContactsBridge.update(id: id, draft: Self.draft(from: parameters))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "delete":
            let ok = await ContactsBridge.ensureAccess()
            guard ok else { return ToolResult(success: false, text: L10n.l("contacts_denied")) }
            guard let id = Self.string(parameters["contact_id"]), !id.isEmpty else {
                return ToolResult(success: false, text: L10n.l("contacts_need_id"))
            }
            let outcome = await ContactsBridge.delete(id: id)
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: L10n.l("contacts_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleContactsTool {
    private static func draft(from parameters: [String: Any]) -> ContactDraft {
        ContactDraft(givenName: string(parameters["given_name"]),
                     familyName: string(parameters["family_name"]),
                     organization: string(parameters["organization"]),
                     phone: string(parameters["phone"]),
                     email: string(parameters["email"]))
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
}

extension ContactDraft {
    /// 至少要有一个能识别这个人的字段，否则会往通讯录里塞空联系人。
    var hasIdentity: Bool {
        [givenName, familyName, organization, phone, email].contains { ($0?.isEmpty == false) }
    }
}

// MARK: - MainActor 桥接层

/// 通讯录的读写全部隔离在 MainActor 内。
///
/// 与 EventKit 同源的两条约束：`CNContactStore` 必须在固定的线程上使用，
/// `CNContact` / `CNSaveRequest` 也都不是 Sendable。因此每个方法都在主线程
/// 一次做完「取数 + 组装输出」，只回传 Sendable 的文本。
@MainActor
private enum ContactsBridge {
    static let store = CNContactStore()

    /// 不含 `CNContactNoteKey`：该键需要专门的 entitlement，未申请时读取会失败。
    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    // MARK: 查询

    static func search(query: String, limit: Int?) async -> ContactOutcome {
        let request = CNContactFetchRequest(keysToFetch: fetchKeys)
        request.predicate = predicate(for: query)
        var found: [CNContact] = []
        let cap = max(limit ?? 20, 1)
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                found.append(contact)
                if found.count >= cap { stop.pointee = true }
            }
        } catch {
            return .fail(L10n.l("contacts_read_failed") + error.localizedDescription)
        }
        guard !found.isEmpty else { return .ok(L10n.l("contacts_no_match") + query) }
        var lines: [String] = [L10n.l("contacts_list_header") + "\(found.count)"]
        for c in found { lines.append(describe(c)) }
        return .ok(lines.joined(separator: "\n"))
    }

    static func get(id: String) async -> ContactOutcome {
        do {
            let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys)
            return .ok(describe(contact))
        } catch {
            return .fail(L10n.l("contacts_read_failed") + error.localizedDescription)
        }
    }

    // MARK: 写入

    static func create(_ draft: ContactDraft) async -> ContactOutcome {
        let contact = CNMutableContact()
        apply(draft, to: contact)
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return .ok(L10n.l("contacts_created") + "\n" + describe(contact))
        } catch {
            return .fail(L10n.l("contacts_save_failed") + error.localizedDescription)
        }
    }

    static func update(id: String, draft: ContactDraft) async -> ContactOutcome {
        let existing: CNContact
        do {
            existing = try store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys)
        } catch {
            return .fail(L10n.l("contacts_not_found") + id)
        }
        // 未统一的联系人对象不能用于保存，必须走 mutableCopy 转成可写副本
        guard let contact = existing.mutableCopy() as? CNMutableContact else {
            return .fail(L10n.l("contacts_read_failed") + id)
        }
        apply(draft, to: contact)
        let request = CNSaveRequest()
        request.update(contact)
        do {
            try store.execute(request)
            return .ok(L10n.l("contacts_updated") + "\n" + describe(contact))
        } catch {
            return .fail(L10n.l("contacts_save_failed") + error.localizedDescription)
        }
    }

    static func delete(id: String) async -> ContactOutcome {
        let existing: CNContact
        do {
            existing = try store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys)
        } catch {
            return .fail(L10n.l("contacts_not_found") + id)
        }
        guard let contact = existing.mutableCopy() as? CNMutableContact else {
            return .fail(L10n.l("contacts_read_failed") + id)
        }
        let name = displayName(of: existing)
        let request = CNSaveRequest()
        request.delete(contact)
        do {
            try store.execute(request)
            return .ok(L10n.l("contacts_deleted") + name)
        } catch {
            return .fail(L10n.l("contacts_delete_failed") + error.localizedDescription)
        }
    }

    // MARK: 授权

    /// 授权串行门：并发调用 `requestAccess` 时系统只会保留一个弹窗，其余静默失败。
    /// Contacts 与 EventKit 共用同一套 `actor` 门思路，这里只有一个工具会触发，
    /// 故直接串行化在本方法内（同一时刻至多一个请求在等弹窗结果）。
    static func ensureAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .notDetermined: break
        default: return false
        }
        return await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: 辅助

    /// 按关键词形态选谓词：带 `@` 走邮箱、三位以上数字走号码、其余按姓名。
    /// 比「全量拉取再内存过滤」快一个量级，大通讯录下差别明显。
    private static func predicate(for query: String) -> NSPredicate {
        if query.contains("@") {
            return CNContact.predicateForContacts(matchingEmailAddress: query)
        }
        let digits = query.filter { $0.isNumber }
        if digits.count >= 3 {
            return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        }
        return CNContact.predicateForContacts(matchingName: query)
    }

    private static func apply(_ draft: ContactDraft, to contact: CNMutableContact) {
        if let v = draft.givenName { contact.givenName = v }
        if let v = draft.familyName { contact.familyName = v }
        if let v = draft.organization { contact.organizationName = v }
        if let v = draft.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                   value: CNPhoneNumber(stringValue: v))]
        }
        if let v = draft.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: v as NSString)]
        }
    }

    private static func describe(_ contact: CNContact) -> String {
        var parts = ["- " + displayName(of: contact)]
        let phones = contact.phoneNumbers.map { $0.value.stringValue }
        if !phones.isEmpty { parts.append(L10n.l("phone_label") + phones.joined(separator: ", ")) }
        let emails = contact.emailAddresses.map { $0.value as String }
        if !emails.isEmpty { parts.append(L10n.l("email_label") + emails.joined(separator: ", ")) }
        if !contact.organizationName.isEmpty {
            parts.append(L10n.l("org_label") + contact.organizationName)
        }
        parts.append(L10n.l("id_label") + contact.identifier)
        return parts.joined(separator: " | ")
    }

    /// 中文习惯「姓+名」，英文习惯「名 姓」——按是否有 CJK 字符切换拼法。
    private static func displayName(of contact: CNContact) -> String {
        let family = contact.familyName
        let given = contact.givenName
        if family.isEmpty && given.isEmpty { return L10n.l("unnamed_contact") }
        let hasCJK = (family + given).unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        return hasCJK ? family + given : [given, family].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
