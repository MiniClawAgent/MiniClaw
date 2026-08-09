import Foundation
import SwiftUI

/// App 支持的语言。rawValue 即 Locale 标识；`system` 用 `auto` 表示跟随系统。
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system = "auto"
    case chinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// Picker 中展示的母语名（语言列表惯例用语种母语，不随界面语言变化）。
    var nativeName: String {
        switch self {
        case .system:   return L10n.tr("跟随系统")
        case .chinese:  return "中文"
        case .english:  return "English"
        case .japanese: return "日本語"
        case .korean:   return "한국어"
        }
    }

    /// 实际生效的 Locale（system 时取系统首选语言）。
    var locale: Locale {
        if self == .system {
            return Locale(identifier: Locale.preferredLanguages.first ?? "en")
        }
        return Locale(identifier: rawValue)
    }

    /// 解析为查表用的语言码（system → 按系统语言映射到 en/ja/ko/zh-Hans）。
    var tableCode: String {
        if self == .system {
            let pref = Locale.preferredLanguages.first ?? "en"
            if pref.hasPrefix("ja") { return "ja" }
            if pref.hasPrefix("ko") { return "ko" }
            if pref.hasPrefix("zh") { return "zh-Hans" }
            return "en"
        }
        return rawValue
    }
}

/// 轻量本地化单例。以「中文文案」为 key：中文直接返回 key 本身，
/// 其他语言查 Localizable.json，未命中则回退 key（即中文原文）。
/// 切换语言时 `current` 变化触发根视图重建，所有 `L10n.tr` 重新求值刷新界面。
final class L10n: ObservableObject {
    /// 仅在主线程访问（SwiftUI 视图 body、AppState 初始化/didSet 均在主线程），
    /// 故对 Swift 6 严格并发检查使用 nonisolated(unsafe) 豁免，避免 @MainActor 级联到
    /// AppLanguage.nativeName / AppState 等非隔离调用点。
    nonisolated(unsafe) static let shared = L10n()

    @Published var current: AppLanguage = .system

    private var tables: [String: [String: String]] = [:]

    private init() {
        loadTables()
    }

    /// 从 Bundle 加载 Localizable.json（结构：{ "en": {key: value}, "ja": {...}, "ko": {...} }）。
    /// 容错解析：逐语言、逐 key 解析，单个 key 的 value 类型不对时跳过该 key（而非丢弃整个表）。
    /// 历史教训：之前用 `as? [String: [String: String]]` 整体强转，只要有任意一个 key 的 value 不是
    /// String（曾被误写成嵌套多语言 dict），整个表就会转换失败 → tables 为空 → 所有语言都回退中文 key，
    /// 表现为「切换语言没反应」。现改为逐项解析 + 诊断日志，避免静默失败。
    func loadTables() {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "json") else {
            AppLogger.shared.error("Localizable.json not found in Bundle.main", category: "L10n", subsystem: "L10n")
            tables = [:]
            return
        }
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.shared.error("Localizable.json parse failed (top-level not [String:Any])", category: "L10n", subsystem: "L10n")
            tables = [:]
            return
        }

        var result: [String: [String: String]] = [:]
        var totalSkipped = 0
        for (lang, tableAny) in raw {
            guard let tableAny = tableAny as? [String: Any] else {
                AppLogger.shared.error("Localizable.json: lang='\(lang)' table is not [String:Any], skipped", category: "L10n", subsystem: "L10n")
                continue
            }
            var dict: [String: String] = [:]
            var skipped = 0
            for (key, val) in tableAny {
                if let s = val as? String {
                    dict[key] = s
                } else {
                    // 容错：跳过类型不对的 key（避免整个表丢失），并记录便于排查。
                    skipped += 1
                }
            }
            totalSkipped += skipped
            result[lang] = dict
        }
        tables = result
        let totalEntries = result.values.reduce(0) { $0 + $1.count }
        AppLogger.shared.info("Localizable.json loaded: \(result.count) langs, \(totalEntries) entries, skipped \(totalSkipped) bad keys", category: "L10n", subsystem: "L10n")
    }

    func setLanguage(_ lang: AppLanguage) {
        current = lang
    }

    /// 翻译入口：以中文文案为 key。
    /// 读取 L10n.shared.current 查表；current 由 AppState.appLanguage 变更时通过
    /// ContentView.onChange / AppState.didSet 双路同步更新。
    static func tr(_ key: String) -> String { shared.tr(key) }

    /// 实例方法（保留给 nativeName 等需读取 current 的内部调用）。
    func tr(_ key: String) -> String {
        let code = current.tableCode
        if code == "zh-Hans" { return key }
        return tables[code]?[key] ?? key
    }
}
