import SwiftUI
import WebKit

/// 浏览器设置：UA 预设切换 + Cookie/数据管理（从浏览器底部「选项」菜单进入）。
struct BrowserSheetSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var uaProfile: BrowserController.UAProfile = BrowserController.shared.uaProfile
    @State private var cookieGroups: [CookieGroup] = []
    /// 搜索引擎本地状态（驱动 Picker 即时刷新；onChange 写回 SettingsStore 持久化）。
    @State private var searchEngine: SearchEngine =
        SearchEngine(rawValue: SettingsStore.shared.settings.browser.searchEngine) ?? .bing
    /// 缓存大小文本（WebKit 磁盘缓存 + URLCache，后台计算，不卡主线程）。
    @State private var cacheSizeText: String = L10n.tr("计算中…")

    /// 按域名聚合的 Cookie 数量
    struct CookieGroup: Identifiable {
        let id = UUID()
        let domain: String
        let count: Int
    }

    var body: some View {
        List {
            // MARK: UA 设置
            Section(L10n.tr("UA 设置")) {
                Picker(L10n.tr("UA 预设"), selection: $uaProfile) {
                    Text("Mobile Safari").tag(BrowserController.UAProfile.mobile)
                    Text("Desktop Safari").tag(BrowserController.UAProfile.desktop)
                }
                .pickerStyle(.segmented)

                Text(uaProfile == .mobile ? BrowserController.mobileUA : BrowserController.desktopUA)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // MARK: 搜索引擎
            // 仅切换「地址栏搜索词」跳转的引擎（默认 bing），与默认首页无关。
            Section(L10n.tr("搜索引擎")) {
                Picker(L10n.tr("搜索引擎"), selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                // 切换立即显示（本地状态驱动）；写回 SettingsStore 持久化并即时生效。
                .onChange(of: searchEngine) { _, newValue in
                    var b = SettingsStore.shared.settings.browser
                    b.searchEngine = newValue.rawValue
                    SettingsStore.shared.set(b, domain: .browser, summary: L10n.tr("修改搜索引擎"))
                }

                Text(L10n.tr("仅在地址栏输入搜索词时生效，不影响默认首页。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: 缓存
            Section(L10n.tr("缓存")) {
                HStack {
                    Text(L10n.tr("缓存大小"))
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task { await clearCache() }
                } label: {
                    Text(L10n.tr("清理缓存"))
                }
            }

            // MARK: Cookie 和数据
            Section(L10n.tr("Cookie 和数据")) {
                HStack {
                    Text(L10n.tr("Cookie 总数"))
                    Spacer()
                    Text("\(totalCount)")
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task {
                        let store = BrowserController.shared.activeContext.cookieStore
                        let all = await store.allCookies()
                        for cookie in all { await store.deleteCookie(cookie) }
                        await reloadCookies()
                    }
                } label: {
                    Text(L10n.tr("清除所有 Cookie"))
                }
            }

            if !cookieGroups.isEmpty {
                Section(L10n.tr("按域名分类")) {
                    ForEach(cookieGroups) { group in
                        HStack {
                            Text(group.domain)
                            Spacer()
                            Text("\(group.count) " + L10n.tr("个 Cookie"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("浏览器设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.tr("完成")) { dismiss() }
            }
        }
        .onAppear {
            Task { await reloadCookies() }
            reloadCacheSize()
            // 外部可能已修改（如设置页）：进入时同步一次。
            searchEngine = SearchEngine(rawValue: SettingsStore.shared.settings.browser.searchEngine) ?? .bing
        }
        .onChange(of: uaProfile) { _, newVal in
            BrowserController.shared.uaProfile = newVal
            BrowserController.shared.applyUAProfileToAllTabs()
            // UA 变更只影响后续 HTTP 请求：立即刷新当前页让新 UA 生效。
            BrowserController.shared.uiReload()
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
        await BrowserController.shared.clearBrowserCaches()
        await MainActor.run { reloadCacheSize() }
    }

    private func reloadCookies() async {
        let cookies = await BrowserController.shared.activeContext.cookieStore.allCookies()
        var dict: [String: Int] = [:]
        for cookie in cookies {
            dict[cookie.domain, default: 0] += 1
        }
        cookieGroups = dict
            .map { CookieGroup(domain: $0.key, count: $0.value) }
            .sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
    }
}
