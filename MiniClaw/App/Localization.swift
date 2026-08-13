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
        case .system:   return L10n.l("system")
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

/// 本地化入口(标准 i18n):英文语义 key 经 String(localized:) 走 xcstrings,
/// 按 App 自定义语言选择 .lproj bundle。`L10n.tr(中文key)` 兼容层已删除(2026-08-12 治本完成)。
final class L10n: ObservableObject {
    /// 仅在主线程访问（SwiftUI 视图 body、AppState 初始化/didSet 均在主线程），
    /// 故对 Swift 6 严格并发检查使用 nonisolated(unsafe) 豁免，避免 @MainActor 级联到
    /// AppLanguage.nativeName / AppState 等非隔离调用点。
    nonisolated(unsafe) static let shared = L10n()

    @Published var current: AppLanguage = .system

    func setLanguage(_ lang: AppLanguage) {
        current = lang
    }

    /// 标准 i18n 路径(阶段1,2026-08-12)：英文语义 key,经 `String(localized:)` 走 xcstrings
    /// 查表(可被 Xcode 工具链管理),按自定义语言选择 bundle。所有用户可见/模型可见文本统一走此入口。
    static func l(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizedBundle(for: shared.current))
    }

    /// 按自定义语言选择 `.lproj` bundle(xcstrings 编译产物，含 en/zh-Hans/ja/ko)；
    /// 该语言资源缺失时回退 main(开发语言 en)。
    private static func localizedBundle(for lang: AppLanguage) -> Bundle {
        let code = lang.tableCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}
