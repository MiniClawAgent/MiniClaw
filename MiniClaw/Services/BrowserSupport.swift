import Foundation
import MiniClawKit
import WebKit
import UIKit
import SwiftUI
import Combine

// MARK: - Array 安全下标

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 搜索引擎

/// 搜索词跳转使用的搜索引擎（浏览器设置可切换；仅影响搜索跳转，不影响默认首页）。
///
/// [2026-09-14 新增 `.auto`] 「自动」= 不预设引擎，由 `SearchEnginePolicy` 按
/// **用户偏好 > 地区先验 > 可达性事实** 解析（用户显式选具体引擎时才有"偏好"）。
enum SearchEngine: String, CaseIterable, Identifiable {
    case auto, bing, sogou, so360, baidu, google, duckduckgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "search_auto")
        case .bing: return "Bing"
        case .sogou: return String(localized: "search_sogou")
        case .so360: return String(localized: "search_360")
        case .baidu: return String(localized: "search_baidu")
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// 搜索 URL 模板（q= 已编码的搜索词）。
    /// `.auto` 先解析成具体引擎再拼 —— `resolveAuto()` 只返回具体引擎（不会回到 `.auto`），故无递归风险。
    func searchURL(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .auto: return SearchEnginePolicy.resolveAuto().searchURL(query: query)
        case .bing: return "https://www.bing.com/search?q=" + encoded
        case .sogou: return "https://www.sogou.com/web?query=" + encoded
        case .so360: return "https://www.so.com/s?q=" + encoded
        case .baidu: return "https://www.baidu.com/s?wd=" + encoded
        case .google: return "https://www.google.com/search?q=" + encoded
        case .duckduckgo: return "https://duckduckgo.com/?q=" + encoded
        }
    }
}

/// 搜索引擎的决策策略。[2026-09-14 TopFlow定稿]
///
/// **优先级严格为「用户偏好 > 地区先验 > 可达性事实」**，并且**只做"排序"，永不做"过滤"**：
/// 任何情况下都返回完整候选表 —— 绝不因为"可能不通"就把某个引擎从表里删掉。
/// 理由：用户完全可能挂代理让 Google 通，「能不能通」只有实际结果说了算；
/// 一刀切禁用会误伤这类用户（见 `研究报告-搜索引擎选源方案`）。
enum SearchEnginePolicy {

    /// 从设置值解析出**本轮实际使用的引擎**。
    /// - 用户显式选了具体引擎 ⇒ 直接用（在候选表里置顶，见 `orderedCandidates`）；
    /// - `.auto` / 空 / 非法值 ⇒ 走 `resolveAuto()`。
    static func preferred(rawSetting: String?) -> SearchEngine {
        guard let raw = rawSetting,
              let engine = SearchEngine(rawValue: raw),
              engine != .auto else {
            return resolveAuto()
        }
        return engine
    }

    /// `.auto` 的解析：地区先验 + 可达性事实 → 取候选表首位。
    static func resolveAuto(
        languages: [String] = Locale.preferredLanguages,
        hasSystemProxy: Bool = !SystemProxyStore.proxyEnvironment.isEmpty,
        reachability: [SearchEngine: Bool] = [:]
    ) -> SearchEngine {
        orderedCandidates(languages: languages,
                          hasSystemProxy: hasSystemProxy,
                          reachability: reachability).first ?? .bing
    }

    /// 完整候选表。**任何分支都不会丢弃引擎**，只改变顺序。
    ///
    /// - **地区先验**：中文用户把中文引擎排在前面；其他语言把国际引擎排前面。
    ///   （注：`www.bing.com` 在中国大陆会自动跳 `cn.bing.com`，故无需为此维护两套模板。）
    /// - **可达性事实**：系统代理开启 ⇒ 这台设备**有能力**访问境外站点 ⇒ 把 `google` 提到最前。
    ///   这是"事实推翻先验排序"的落地；**注意这只是提前，不是放行/禁止**。
    /// - `reachability`（未来接探测结果）：`false` 的引擎**下沉到表尾**，但**仍留在表内**。
    static func orderedCandidates(
        languages: [String] = Locale.preferredLanguages,
        hasSystemProxy: Bool = !SystemProxyStore.proxyEnvironment.isEmpty,
        reachability: [SearchEngine: Bool] = [:]
    ) -> [SearchEngine] {
        let isChineseUser = (languages.first ?? "").hasPrefix("zh")
        var order: [SearchEngine] = isChineseUser
            ? [.bing, .baidu, .sogou, .so360, .google, .duckduckgo]
            : [.google, .bing, .duckduckgo, .baidu, .sogou, .so360]

        if hasSystemProxy, let i = order.firstIndex(of: .google), i != 0 {
            order.remove(at: i)
            order.insert(.google, at: 0)
        }

        // 已知不可达 ⇒ 只下沉，不剔除（`false` 之外的 nil/true 都视为可用，避免误伤）。
        let usable = order.filter { reachability[$0] != false }
        let knownUnreachable = order.filter { reachability[$0] == false }
        return usable + knownUnreachable
    }
}

