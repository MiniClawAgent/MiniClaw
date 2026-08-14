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

/// 地址栏搜索词使用的搜索引擎（浏览器设置可切换；仅影响搜索跳转，不影响默认首页）。
enum SearchEngine: String, CaseIterable, Identifiable {
    case bing, sogou, so360, baidu, google, duckduckgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bing: return "Bing"
        case .sogou: return L10n.l("search_sogou")
        case .so360: return L10n.l("search_360")
        case .baidu: return L10n.l("search_baidu")
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    /// 搜索 URL 模板（q= 已编码的搜索词）。
    func searchURL(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .bing: return "https://www.bing.com/search?q=" + encoded
        case .sogou: return "https://www.sogou.com/web?query=" + encoded
        case .so360: return "https://www.so.com/s?q=" + encoded
        case .baidu: return "https://www.baidu.com/s?wd=" + encoded
        case .google: return "https://www.google.com/search?q=" + encoded
        case .duckduckgo: return "https://duckduckgo.com/?q=" + encoded
        }
    }
}

