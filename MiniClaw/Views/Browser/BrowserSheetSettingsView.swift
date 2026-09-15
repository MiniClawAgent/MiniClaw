import SwiftUI
import WebKit

/// 浏览器设置：UA 预设切换 + Cookie/数据管理（从浏览器底部「选项」菜单进入）。
struct BrowserSheetSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// UA 预设：[2026-09-15 体系统一] 类型改为引擎池的 `MiniClawUAProfile`——
    /// 旧的 `UAProfile` 只作用于从不上屏的旧标签，改了等于没改。
    @State private var uaProfile: MiniClawUAProfile = BrowserEngineAdapter.shared.uaProfile
    @State private var cookieGroups: [CookieGroup] = []
    /// 搜索引擎本地状态（驱动 Picker 即时刷新；onChange 写回 SettingsStore 持久化）。
    @State private var searchEngine: SearchEngine =
        SearchEngine(rawValue: SettingsStore.shared.settings.browser.searchEngine) ?? .auto
    /// 缓存大小文本（WebKit 磁盘缓存 + URLCache，后台计算，不卡主线程）。
    @State private var cacheSizeText: String = String(localized: "calculating")

    /// 按域名聚合的 Cookie 数量
    struct CookieGroup: Identifiable {
        let id = UUID()
        let domain: String
        let count: Int
    }

    var body: some View {
        List {
            // MARK: UA 设置
            Section(String(localized: "user_agent")) {
                Picker(String(localized: "ua_preset"), selection: $uaProfile) {
                    Text("Mobile Safari").tag(MiniClawUAProfile.mobileSafari)
                    Text("Desktop Safari").tag(MiniClawUAProfile.desktopSafari)
                }
                .pickerStyle(.segmented)

                // 预览：直接取引擎池解析出的 UA 字符串（与实际生效的 UA 同源，不是另一套常量）。
                Text(uaProfile.userAgentString ?? BrowserEngineAdapter.shared.currentUAString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // MARK: 搜索引擎
            // 仅切换「地址栏搜索词」跳转的引擎（默认 auto=按地区先验+可达性解析，见 SearchEnginePolicy），与默认首页无关。
            Section(String(localized: "search_engine")) {
                Picker(String(localized: "search_engine"), selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                // 切换立即显示（本地状态驱动）；写回 SettingsStore 持久化并即时生效。
                .onChange(of: searchEngine) { newValue in
                    var b = SettingsStore.shared.settings.browser
                    b.searchEngine = newValue.rawValue
                    SettingsStore.shared.set(b, domain: .browser, summary: String(localized: "change_search_engine"))
                }

                Text(String(localized: "only_takes_effect_when_a_search_term_is_typed_in_the_address_bar_the_default_homepage_is_unaffected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: 缓存
            Section(String(localized: "cache")) {
                HStack {
                    Text(String(localized: "cache_size"))
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task { await clearCache() }
                } label: {
                    Text(String(localized: "clear_cache"))
                }
            }

            // MARK: Cookie 和数据
            Section(String(localized: "cookies_and_data")) {
                HStack {
                    Text(String(localized: "total_cookies"))
                    Spacer()
                    Text("\(totalCount)")
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task {
                        let store = BrowserEngineAdapter.shared.cookieStore
                        let all = await store.allCookies()
                        for cookie in all { await store.deleteCookie(cookie) }
                        await reloadCookies()
                    }
                } label: {
                    Text(String(localized: "clear_all_cookies"))
                }
            }

            if !cookieGroups.isEmpty {
                Section(String(localized: "group_by_domain")) {
                    ForEach(cookieGroups) { group in
                        HStack {
                            Text(group.domain)
                            Spacer()
                            Text("\(group.count) " + String(localized: "cookie_count_suffix"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "browser_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
        .onAppear {
            Task { await reloadCookies() }
            reloadCacheSize()
            // 外部可能已修改（如设置页）：进入时同步一次。
            searchEngine = SearchEngine(rawValue: SettingsStore.shared.settings.browser.searchEngine) ?? .auto
        }
        .onChange(of: uaProfile) { newVal in
            BrowserEngineAdapter.shared.uaProfile = newVal
            BrowserEngineAdapter.shared.applyUAProfileToAllTabs()
            // UA 变更只影响后续 HTTP 请求：立即刷新当前页让新 UA 生效。
            // [2026-09-15 体系统一] 旧 UAProfile 体系（key "miniClaw.browserUAProfile"）已删，
            // UA 唯一事实来源 = 引擎池 MiniClawUAProfile；刷新也走适配器（即用户看到的页面）。
            BrowserEngineAdapter.shared.uiReload()
        }
    }

    private var totalCount: Int {
        cookieGroups.reduce(0) { $0 + $1.count }
    }

    // MARK: - 缓存大小与清理

    /// 缓存大小：WebKit 磁盘缓存目录（Library/WebKit）+ URLCache 磁盘用量。
    /// WKWebsiteDataStore 无大小 API，目录扫描是稳定口径（随系统缓存机制演进不变）。
    private func reloadCacheSize() {
        let webkitDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WebKit")
        // 目录扫描用全局队列（FileManager.enumerator 在 Swift 并发异步上下文不可用，
        // 且扫描应远离主线程）。
        DispatchQueue.global(qos: .utility).async {
            var total = Int64(URLCache.shared.currentDiskUsage)
            if let enumerator = FileManager.default.enumerator(
                at: webkitDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    if let v = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(v)
                    }
                }
            }
            let text = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            DispatchQueue.main.async { cacheSizeText = text }
        }
    }

    /// 清理缓存：统一走 BrowserController.clearBrowserCaches()
    /// （WebKit 磁盘/内存/离线缓存 + URLCache + 共享区 browser/ + Caches/MiniClaw/）。
    private func clearCache() async {
        await BrowserEngineAdapter.shared.clearBrowserCaches()
        await MainActor.run { reloadCacheSize() }
    }

    private func reloadCookies() async {
        let cookies = await BrowserEngineAdapter.shared.cookieStore.allCookies()
        var dict: [String: Int] = [:]
        for cookie in cookies {
            dict[cookie.domain, default: 0] += 1
        }
        cookieGroups = dict
            .map { CookieGroup(domain: $0.key, count: $0.value) }
            .sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
    }
}
