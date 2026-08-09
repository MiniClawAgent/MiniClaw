import Foundation

// MARK: - SyncedSession

/// 会话元数据同步格式。对齐 SyncedSession。
struct SyncedSession: Syncable {
    var sessionId: String
    var title: String?
    var modelName: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Int
    var icon: String?
    var iconColor: String?
    var thinkingLevel: String?
    var summary: String?
    var memoryEnabled: Int

    static let syncMetadata: SyncTypeMetadata<SyncedSession> = {
        typealias F = FieldDescriptor<SyncedSession>
        return SyncTypeMetadata<SyncedSession>(
            recordType: "SessionV2",
            idKeyPath: \SyncedSession.sessionId,
            scope: .perObject(\SyncedSession.sessionId),
            fields: [
                F.string("sessionId",      \SyncedSession.sessionId),
                F.optionalString("title",  \SyncedSession.title),
                F.string("modelName",      \SyncedSession.modelName),
                F.date("createdAt",        \SyncedSession.createdAt),
                F.date("updatedAt",        \SyncedSession.updatedAt),
                F.int("isPinned",          \SyncedSession.isPinned),
                F.optionalString("icon",   \SyncedSession.icon),
                F.optionalString("iconColor", \SyncedSession.iconColor),
                F.optionalString("thinkingLevel", \SyncedSession.thinkingLevel),
                F.optionalString("summary", \SyncedSession.summary),
                F.int("memoryEnabled",     \SyncedSession.memoryEnabled),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedSession.updatedAt),
            version: 1
        )
    }()

    static func from(_ session: ChatSession) -> SyncedSession {
        SyncedSession(
            sessionId: session.id.uuidString,
            title: session.title,
            modelName: session.modelName,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            isPinned: session.isPinned ? 1 : 0,
            icon: session.icon,
            iconColor: session.iconColor,
            thinkingLevel: session.thinkingLevel,
            summary: session.summary,
            memoryEnabled: 1
        )
    }
}

// MARK: - SyncedMessage

/// 聊天消息同步格式。对齐 SyncedMessage。
struct SyncedMessage: Syncable {
    var messageId: String
    var sessionId: String
    var role: String
    var content: String
    var toolCallsJson: String?
    var reasoning: String?
    var attachmentsJson: String?
    var createdAt: Date
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedMessage> = {
        typealias F = FieldDescriptor<SyncedMessage>
        return SyncTypeMetadata<SyncedMessage>(
            recordType: "MessageV2",
            idKeyPath: \SyncedMessage.messageId,
            scope: .perParent(parentType: "SessionV2", \SyncedMessage.sessionId),
            fields: [
                F.string("messageId",        \SyncedMessage.messageId),
                F.string("sessionId",        \SyncedMessage.sessionId),
                F.string("role",             \SyncedMessage.role),
                F.string("content",          \SyncedMessage.content),
                F.optionalString("toolCallsJson", \SyncedMessage.toolCallsJson),
                F.optionalString("reasoning", \SyncedMessage.reasoning),
                F.optionalString("attachmentsJson", \SyncedMessage.attachmentsJson),
                F.date("createdAt",          \SyncedMessage.createdAt),
                F.date("updatedAt",          \SyncedMessage.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedMessage.updatedAt),
            version: 1
        )
    }()

    static func from(_ message: ChatMessage) -> SyncedMessage {
        let toolCallsJson: String? = {
            let calls = message.toolCalls
            guard !calls.isEmpty else { return nil }
            return (try? JSONEncoder().encode(calls)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let attachmentsJson: String? = {
            let atts = message.attachments
            guard !atts.isEmpty else { return nil }
            return (try? JSONEncoder().encode(atts)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        return SyncedMessage(
            messageId: message.id.uuidString,
            sessionId: message.session?.id.uuidString ?? "",
            role: message.role.rawValue,
            content: message.content,
            toolCallsJson: toolCallsJson,
            reasoning: message.reasoning,
            attachmentsJson: attachmentsJson,
            createdAt: message.createdAt,
            updatedAt: message.createdAt
        )
    }
}

// MARK: - SyncedSkill

/// 技能同步格式。
struct SyncedSkill: Syncable {
    var skillId: String
    var name: String
    var skillDescription: String
    var version: String
    var directoryName: String
    var isEnabled: Int
    var installDate: Date
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedSkill> = {
        typealias F = FieldDescriptor<SyncedSkill>
        return SyncTypeMetadata<SyncedSkill>(
            recordType: "SkillV2",
            idKeyPath: \SyncedSkill.skillId,
            scope: .global,
            fields: [
                F.string("skillId",        \SyncedSkill.skillId),
                F.string("name",           \SyncedSkill.name),
                F.string("skillDescription", \SyncedSkill.skillDescription),
                F.string("version",        \SyncedSkill.version),
                F.string("directoryName",  \SyncedSkill.directoryName),
                F.int("isEnabled",         \SyncedSkill.isEnabled),
                F.date("installDate",      \SyncedSkill.installDate),
                F.date("updatedAt",        \SyncedSkill.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedSkill.updatedAt),
            version: 1
        )
    }()
}

// MARK: - SyncedEnvVar

/// 环境变量同步格式。值用 base64 编码传输。
struct SyncedEnvVar: Syncable {
    var entryId: String
    var key: String
    var valueB64: String
    var isSecret: Int
    var createdAt: Date
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedEnvVar> = {
        typealias F = FieldDescriptor<SyncedEnvVar>
        return SyncTypeMetadata<SyncedEnvVar>(
            recordType: "EnvVarItem",
            idKeyPath: \SyncedEnvVar.entryId,
            scope: .global,
            fields: [
                F.string("entryId",   \SyncedEnvVar.entryId),
                F.string("key",       \SyncedEnvVar.key),
                F.string("valueB64",  \SyncedEnvVar.valueB64),
                F.int("isSecret",     \SyncedEnvVar.isSecret),
                F.date("createdAt",   \SyncedEnvVar.createdAt),
                F.date("updatedAt",   \SyncedEnvVar.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedEnvVar.updatedAt),
            version: 1
        )
    }()

    /// 从 EnvVariable 构造（base64 编码值）
    static func from(_ env: EnvVariable) -> SyncedEnvVar {
        let valueData = Data(env.value.utf8)
        let valueB64 = valueData.base64EncodedString()
        return SyncedEnvVar(
            entryId: env.id.uuidString,
            key: env.key,
            valueB64: valueB64,
            isSecret: env.isSecret ? 1 : 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// 解码 base64 值
    func decodedValue() -> String? {
        guard let data = Data(base64Encoded: valueB64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - SyncedProviderConfig

/// 供应商配置同步格式（whole-file 模式，简化实现）。
struct SyncedProviderConfig: Syncable {
    var id: String = "provider-config"
    var configJson: String
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedProviderConfig> = {
        typealias F = FieldDescriptor<SyncedProviderConfig>
        return SyncTypeMetadata<SyncedProviderConfig>(
            recordType: "ProviderConfigV2",
            idKeyPath: \SyncedProviderConfig.id,
            scope: .global,
            fields: [
                F.string("configJson",  \SyncedProviderConfig.configJson),
                F.date("updatedAt",     \SyncedProviderConfig.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedProviderConfig.updatedAt),
            version: 1
        )
    }()

    /// 从 ProvidersContainer 构造
    static func from(_ container: ProvidersContainer) -> SyncedProviderConfig {
        let json = (try? JSONEncoder().encode(container)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return SyncedProviderConfig(configJson: json, updatedAt: Date())
    }
}

// MARK: - SyncedSoul

/// 灵魂（SOUL.md）同步格式。
struct SyncedSoul: Syncable {
    var id: String = "soul"
    var contentMarkdown: String
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedSoul> = {
        typealias F = FieldDescriptor<SyncedSoul>
        return SyncTypeMetadata<SyncedSoul>(
            recordType: "SoulV2",
            idKeyPath: \SyncedSoul.id,
            scope: .global,
            fields: [
                F.string("contentMarkdown", \SyncedSoul.contentMarkdown),
                F.date("updatedAt",         \SyncedSoul.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedSoul.updatedAt),
            version: 1
        )
    }()
}

// MARK: - SyncedMemoryGlobal

/// 全局记忆（GLOBAL.md）同步格式。
struct SyncedMemoryGlobal: Syncable {
    var id: String = "memory-global"
    var contentMarkdown: String
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedMemoryGlobal> = {
        typealias F = FieldDescriptor<SyncedMemoryGlobal>
        return SyncTypeMetadata<SyncedMemoryGlobal>(
            recordType: "MemoryGlobalV2",
            idKeyPath: \SyncedMemoryGlobal.id,
            scope: .global,
            fields: [
                F.string("contentMarkdown", \SyncedMemoryGlobal.contentMarkdown),
                F.date("updatedAt",         \SyncedMemoryGlobal.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedMemoryGlobal.updatedAt),
            version: 1
        )
    }()
}

// MARK: - SyncedMemoryDaily

/// 每日记忆日志同步格式。id = "YYYY-MM-DD"。
struct SyncedMemoryDaily: Syncable {
    var dateKey: String
    var entriesJson: String
    var updatedAt: Date

    static let syncMetadata: SyncTypeMetadata<SyncedMemoryDaily> = {
        typealias F = FieldDescriptor<SyncedMemoryDaily>
        return SyncTypeMetadata<SyncedMemoryDaily>(
            recordType: "MemoryDailyV2",
            idKeyPath: \SyncedMemoryDaily.dateKey,
            scope: .global,
            fields: [
                F.string("dateKey",     \SyncedMemoryDaily.dateKey),
                F.string("entriesJson", \SyncedMemoryDaily.entriesJson),
                F.date("updatedAt",     \SyncedMemoryDaily.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedMemoryDaily.updatedAt),
            version: 1
        )
    }()
}

// MARK: - SyncedSessionFile

/// 会话文件同步格式。
struct SyncedSessionFile: Syncable {
    var sessionId: String
    var relativePath: String
    var fileSize: Int
    var mimeType: String?
    var updatedAt: Date

    var compositeKey: String { "\(sessionId):\(relativePath)" }

    static let syncMetadata: SyncTypeMetadata<SyncedSessionFile> = {
        typealias F = FieldDescriptor<SyncedSessionFile>
        return SyncTypeMetadata<SyncedSessionFile>(
            recordType: "SessionFileV2",
            idKeyPath: \SyncedSessionFile.compositeKey,
            scope: .perParent(parentType: "SessionV2", \SyncedSessionFile.sessionId),
            fields: [
                F.string("sessionId",      \SyncedSessionFile.sessionId),
                F.string("relativePath",   \SyncedSessionFile.relativePath),
                F.int("fileSize",          \SyncedSessionFile.fileSize),
                F.optionalString("mimeType", \SyncedSessionFile.mimeType),
                F.date("updatedAt",        \SyncedSessionFile.updatedAt),
            ],
            conflictPolicy: .lastWriteWinsByField(\SyncedSessionFile.updatedAt),
            version: 1
        )
    }()
}

// MARK: - Bootstrap

/// 注册所有 Syncable 类型到全局注册表。
enum SyncedTypesBootstrap {
    @MainActor
    static func registerAll() {
        let r = SyncableTypeRegistry.shared
        r.register(SyncedSession.self)
        r.register(SyncedMessage.self)
        r.register(SyncedSkill.self)
        r.register(SyncedEnvVar.self)
        r.register(SyncedProviderConfig.self)
        r.register(SyncedSoul.self)
        r.register(SyncedMemoryGlobal.self)
        r.register(SyncedMemoryDaily.self)
        r.register(SyncedSessionFile.self)
    }
}
