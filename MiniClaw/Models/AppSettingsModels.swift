import Foundation

struct AppearanceSettings: Codable {
    var useLargeText: Bool = false
    var accentColorRaw: String = "blue"
    /// 当前生效的背景主题插件 id（plugins/theme/<id>）；nil = 系统默认背景。
    /// 显式选用 + 排他生效（同一时刻一个主题）；删除主题插件时由 deleteSkill 清空。
    var backgroundThemeID: String? = nil
}

/// 后台设置（background）
struct BackgroundSettings: Codable, Equatable {
    /// 后台运行：开启后运用灵动岛 / Live Activity 显示任务进度、任务完成通知与画中画。
    /// （模糊定位保活已于 2026-09-07 移除：缺 UIBackgroundModes=location 时它在后台唤不醒 App。）
    var backgroundRun: Bool = true
    /// 实时活动：开启后对接 Live Activity（灵动岛 / 锁屏）渲染。
    var liveActivity: Bool = true
    /// 画中画：开启后退出会话页即以画中画常驻显示运行中的任务（图标 / 会话标题 / 执行进度）。
    var pictureInPicture: Bool = false
    /// 通知：仅当系统已授权通知时作为开关生效；未授权时 UI 显示「未授权」并引导授权。
    var notifications: Bool = false
}

/// 文件设置（files）
struct FileSettings: Codable, Equatable {
    var defaultWorkspace: String = "workspace"
    var autoOffloadThresholdKB: Int = 8
    var cleanupAttachmentsDays: Int = 30
}

/// 默认值设置（defaults）
struct DefaultSettings: Codable, Equatable {
    var defaultAgentName: String = "MiniClaw"
    var defaultLanguage: String = "auto"
    var confirmBeforeToolCall: Bool = false
    /// 允许 AI 读取健康数据（apple-healthkit 的 summary / query / range_report / workouts / characteristic）。
    /// 默认关闭：健康数据属敏感个人数据，需用户显式开启，或由 AI 在会话内经授权弹窗征得同意（仅本会话有效）。
    var healthReadEnabled: Bool = false
    /// 允许 AI 写入 / 删除健康数据（apple-healthkit 的 write 与 delete）。
    /// 默认关闭：写入会直接改动用户的健康记录，属高副作用，需要用户显式表达意图。
    /// 删除虽受 HealthKit 限制「只能删本 App 写入的样本」，仍由同一开关守卫。
    var healthWriteEnabled: Bool = false
    /// 允许 AI 读取家庭配件与场景（apple-homekit 的 list / search / get / scenes）。
    /// 默认关闭：家庭构成属私人信息（谁住在哪、有什么设备），同属敏感数据。
    var homeReadEnabled: Bool = false
    /// 允许 AI 控制家庭配件（apple-homekit 的 set / trigger）。
    /// 默认关闭：会真实改变家中设备状态（开锁、开灯、调温），副作用直接作用于物理世界。
    var homeControlEnabled: Bool = false
    /// AI 安装插件（miniclaw-plugin 的 install）前是否需要用户确认。
    /// 默认开启：AI 安装插件 = 改变自身能力集，弹窗过一道人审；关闭则直接安装。
    var aiPluginInstallRequiresConfirmation: Bool = true

    /// 全默认构造：自定义 `init(from:)` 会挤掉自动生成的无参 init，必须显式补回
    /// （与 `AppSettings.init()` 同一处坑）。
    init() {}

    /// 容错解码（2026-08-31）：本域由 `AppSettings.init(from:)` 以
    /// `decodeIfPresent(DefaultSettings.self) ?? DefaultSettings()` 兜底。若此处沿用
    /// 合成解码，旧 settings.json 缺任意一个键就会让**整个 defaults 域**解码失败、
    /// 回退全默认（表现为 confirmBeforeToolCall 等既有设置被静默重置）。
    /// 故逐键 decodeIfPresent；新增字段必须同步进此 init。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultAgentName = try c.decodeIfPresent(String.self, forKey: .defaultAgentName) ?? "MiniClaw"
        defaultLanguage = try c.decodeIfPresent(String.self, forKey: .defaultLanguage) ?? "auto"
        confirmBeforeToolCall = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeToolCall) ?? false
        healthReadEnabled = try c.decodeIfPresent(Bool.self, forKey: .healthReadEnabled) ?? false
        healthWriteEnabled = try c.decodeIfPresent(Bool.self, forKey: .healthWriteEnabled) ?? false
        homeReadEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeReadEnabled) ?? false
        homeControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeControlEnabled) ?? false
        aiPluginInstallRequiresConfirmation = try c.decodeIfPresent(Bool.self, forKey: .aiPluginInstallRequiresConfirmation) ?? true
    }
}

/// 统一配置聚合：除 providers 外的 13 个配置域。
/// providers 由 ProviderFileStore 独立持久化（同属「Swift 原生配置存储」框），暂不并入以避免回归。
struct AppSettings: Codable {
    /// 全默认构造（自定义 init(from:) 会挤掉自动生成的无参 init，此处显式补回）。
    init() {}

    var groups: [ModelGroup] = []
    var envvars: [EnvVariable] = []
    /// 环境变量隐私模式：开启后 shell/记忆输出中的变量值自动掩码 — 对齐 spec 9.2.4
    var envvarsPrivacyMode: Bool = false
    var soul: SoulConfig = SoulConfig()
    var session: SessionSettings = SessionSettings()
    var chat: ChatSettings = ChatSettings()
    var speech: SpeechSettings = SpeechSettings()
    var memory: MemorySettings = MemorySettings()
    var browser: BrowserSettings = BrowserSettings()
    var appearance: AppearanceSettings = AppearanceSettings()
    var background: BackgroundSettings = BackgroundSettings()
    var files: FileSettings = FileSettings()
    var permissions: PermissionConfig = PermissionConfig()
    var defaults: DefaultSettings = DefaultSettings()
    var sync: SyncConfig = SyncConfig()
    /// 子代理用户控制（设置 → 智能体 → 子代理）。
    var subagent: SubAgentSettings = SubAgentSettings()
    /// 联网搜索（web-search 插件）配置；API Key 走 Keychain，不落盘在此。
    var webSearch: WebSearchSettings = WebSearchSettings()
    /// 技能启用状态：`true`=启用（注入 system prompt），`false`=禁用。
    /// 键为技能 frontmatter 的 name；缺失视为启用（技能格式无启用概念，默认全启用）。
    var skillEnabledStates: [String: Bool] = [:]
    /// 技能安装时间（首次被记录的时间戳），键为技能 name。内置技能在首次加载时记录。
    var skillInstallDates: [String: Date] = [:]
    /// 技能调用次数（键为技能 frontmatter 的 name），用于斜杠命令菜单按调用热度排序。
    var skillUseCounts: [String: Int] = [:]
    /// 词元 用量统计（跨会话全局累计，可选以兼容旧 settings.json）。
    var tokenUsage: TokenUsageStats?
    /// 按会话累计的 词元 用量（键为 sessionID 的 uuidString），可选以兼容旧 settings.json。
    var sessionTokenUsage: [String: SessionTokenUsageData]? = nil

    /// 容错解码（源头修复，2026-08-05）：合成解码对**缺键的非 Optional 字段**直接抛
    /// keyNotFound → 旧版 settings.json（无 subagent 等后加字段）整体解码失败 →
    /// SettingsStore 静默回退全默认 → 用户全部已有设置被重置且被默认值覆盖落盘。
    /// 全部字段 decodeIfPresent + 默认值兜底；未来新增字段必须同步进此 init
    /// （编译器会因未覆盖的存储属性而报错，天然防漏）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([ModelGroup].self, forKey: .groups) ?? []
        envvars = try c.decodeIfPresent([EnvVariable].self, forKey: .envvars) ?? []
        envvarsPrivacyMode = try c.decodeIfPresent(Bool.self, forKey: .envvarsPrivacyMode) ?? false
        soul = try c.decodeIfPresent(SoulConfig.self, forKey: .soul) ?? SoulConfig()
        session = try c.decodeIfPresent(SessionSettings.self, forKey: .session) ?? SessionSettings()
        chat = try c.decodeIfPresent(ChatSettings.self, forKey: .chat) ?? ChatSettings()
        speech = try c.decodeIfPresent(SpeechSettings.self, forKey: .speech) ?? SpeechSettings()
        memory = try c.decodeIfPresent(MemorySettings.self, forKey: .memory) ?? MemorySettings()
        browser = try c.decodeIfPresent(BrowserSettings.self, forKey: .browser) ?? BrowserSettings()
        appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background) ?? BackgroundSettings()
        files = try c.decodeIfPresent(FileSettings.self, forKey: .files) ?? FileSettings()
        permissions = try c.decodeIfPresent(PermissionConfig.self, forKey: .permissions) ?? PermissionConfig()
        defaults = try c.decodeIfPresent(DefaultSettings.self, forKey: .defaults) ?? DefaultSettings()
        sync = try c.decodeIfPresent(SyncConfig.self, forKey: .sync) ?? SyncConfig()
        subagent = try c.decodeIfPresent(SubAgentSettings.self, forKey: .subagent) ?? SubAgentSettings()
        webSearch = try c.decodeIfPresent(WebSearchSettings.self, forKey: .webSearch) ?? WebSearchSettings()
        skillEnabledStates = try c.decodeIfPresent([String: Bool].self, forKey: .skillEnabledStates) ?? [:]
        skillInstallDates = try c.decodeIfPresent([String: Date].self, forKey: .skillInstallDates) ?? [:]
        skillUseCounts = try c.decodeIfPresent([String: Int].self, forKey: .skillUseCounts) ?? [:]
        tokenUsage = try c.decodeIfPresent(TokenUsageStats.self, forKey: .tokenUsage)
        sessionTokenUsage = try c.decodeIfPresent([String: SessionTokenUsageData].self, forKey: .sessionTokenUsage)
    }
}

/// 子代理（subagent）用户控制配置。
/// 子代理恒可用（未设总开关）：是否派发由智能体依据 SubAgentGuide 引导自行判断；
/// 用户只控制运行限制与思考档位。
struct SubAgentSettings: Codable {
    /// 最大并发子代理（1-4，默认 4；与引擎全局上限一致）。
    var maxConcurrent: Int = 4
    /// 子代理思考档位（参考 reasonix subagent_effort 思路）：
    /// `follow`=跟随模型默认（不强制） / `off`=关闭思考 / `low`=低 / `high`=高。
    var thinking: String = "follow"
}

/// 联网搜索（web-search 插件）用户配置。
/// API Key 不在此结构内——单独存 Keychain（`APIKeyStore` 的 webSearch 槽位），避免明文落盘。
struct WebSearchSettings: Codable, Equatable {
    /// 自定义 Base URL；留空时依次回退「DeepSeek 服务商配置」「DeepSeek 官方地址」。
    var baseURL: String = ""
    /// 模型未显式给 count 时的默认条数（1–50）。
    var defaultCount: Int = 10
    /// 模型未显式给 need_content 时的默认值（默认不返回正文，控制 token）。
    var defaultNeedContent: Bool = false
    /// 单次请求超时（秒）。
    var timeoutSeconds: Int = 20
    /// need_content 时单条正文上限（字符）。
    var contentCapChars: Int = 4_000
    /// need_content 时全部结果正文总预算（字符）。
    var contentBudgetChars: Int = 24_000
}

/// 配置域标识，用于审计日志定位与回滚
enum SettingsDomain: String, CaseIterable, Codable {
    case groups, envvars, soul, session, chat, speech, memory, browser, appearance, background, files, permissions, defaults, sync, subagent, webSearch
}
