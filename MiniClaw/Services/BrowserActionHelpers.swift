import Foundation
import UIKit
import MiniClawKit

/// 浏览器 UA 预设（提取自 BrowserController，供 UA 字符串解析使用）。
enum UAProfile: String, CaseIterable {
    case mobile
    case desktop
}

/// 浏览器控制器纯逻辑工具（2026-08 提取：UA 预设 / 动作参数解析 / URL 工具，可独立单测）。
enum BrowserActionHelpers {


    /// 桌面 Safari UA（提供给 智能体使用）
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 移动端（iOS）UA
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"


    /// 当前 UA 预设（持久化到 UserDefaults，默认 Mobile Safari）
    /// fileprivate：供同文件内的 BrowserTab.init 直接读取，避免触发 `BrowserController.shared` 递归初始化。
    static let uaProfileKey = "miniClaw.browserUAProfile"

    /// 当前 UA 字符串：**以浏览器 UA 预设（uaProfile）为单一事实来源**。
    /// 之前误读 settings.browser.uaMode（通用设置另一套存储），导致在浏览器设置里
    /// 切「Desktop Safari」后 applyUAProfileToAllTabs 仍应用移动 UA，页面不变。
    /// desktop → 桌面 UA；mobile → 移动 UA（通用设置配了 custom 且非空时用 custom）。
    static func defaultUAString() -> String {
        let profile = UAProfile(rawValue: UserDefaults.standard.string(forKey: uaProfileKey) ?? "") ?? .mobile
        switch profile {
        case .desktop:
            return Self.desktopUA
        case .mobile:
            let b = SettingsStore.shared.settings.browser
            if b.uaMode == "custom" {
                let custom = b.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty { return custom }
            }
            return Self.mobileUA
        }
    }


    /// 智能体工具入口：在指定会话上下文内执行，完全独立于全局 currentSessionID（首页/手动浏览）。
    /// 通过 scopedSessionID 临时覆盖 activeContext 的解析目标，调用结束后恢复。
    /// - Parameter tabID: 稳定标签 id（list_tabs 返回的 tab_id；标签增删后索引漂移但 id 稳定）。
    ///   优先于 tabIndex 解析，换算成当前索引后走原链路；nil 则仅用 tabIndex。
    /// preset(mobile|desktop) → MiniClawUAProfile;兼容 Kit rawValue 拼写(mobile_safari|desktop_safari)。
    /// 2026-08-12 修复:此前只读 `user_agent` 键且值域不匹配,preset=desktop 静默回退 mobile_safari。
    static func resolveUAProfile(_ params: [String: Any]) -> MiniClawKit.MiniClawUAProfile? {
        if let preset = params["preset"] as? String {
            switch preset.lowercased() {
            case "mobile", "mobile_safari": return .mobileSafari
            case "desktop", "desktop_safari": return .desktopSafari
            default: return nil
            }
        }
        return (params["user_agent"] as? String).flatMap(MiniClawKit.MiniClawUAProfile.init)
    }


    /// tab_id 兼容解析:Int 或数字字符串(引擎池 id,如 0/1)。2026-08-12 修复寻址断裂——
    /// 此前只读 Int,数字字符串或顶层丢失 → 引擎无显式目标静默回退激活标签。
    static func resolveTabId(_ params: [String: Any]) -> Int? {
        guard let raw = params["tab_id"] else { return nil }
        if let i = raw as? Int { return i }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }


    /// 2026-08-10:动作参数 → 引擎 MiniClawActionInput(引擎优先路径)
    static func engineInput(action: String, params: [String: Any]) -> MiniClawKit.MiniClawActionInput? {
        guard let browserAction = MiniClawKit.MiniClawBrowserAction(rawValue: action) else { return nil }
        return MiniClawKit.MiniClawActionInput(
            action: browserAction,
            url: params["url"] as? String,
            selector: params["selector"] as? String,
            text: params["text"] as? String,
            coordinateX: params["x"] as? Int,
            coordinateY: params["y"] as? Int,
            direction: (params["direction"] as? String).flatMap(MiniClawKit.MiniClawActionInput.ScrollDirection.init),
            amount: params["amount"] as? Int,
            script: params["script"] as? String,
            userAgent: Self.resolveUAProfile(params),
            maxDepth: params["max_depth"] as? Int,
            tabId: Self.resolveTabId(params),
            scrollCount: params["scroll_count"] as? Int,
            itemSelector: params["item_selector"] as? String,
            keywords: params["keywords"] as? [String],
            fuzzy: params["fuzzy"] as? Bool,
            timeout: params["timeout"] as? Int,
            viewportWidth: params["width"] as? Int,
            viewportHeight: params["height"] as? Int,
            viewportReset: params["reset"] as? Bool,
            fullPage: params["full_page"] as? Bool,
            cookies: params["cookies"] as? [[String: Any]]
        )
    }


    // MARK: - miniclaw:// 资源解析

    /// 将 miniclaw:// 资源安全解析为本地文件绝对路径；导航型 deep link 返回 nil。
    static func resolveMiniClawURL(_ raw: String) -> String? {
        FileSystemManager.shared.resolveMiniClawResourceURL(raw)?.path
    }


    /// 截图编码失败时的降采样辅助：按除数缩小图像（UIGraphicsImageRenderer 软缩放，
    /// 内存占用按 1/divisor² 下降，编码必成功）。
    /// nonisolated：后台线程调用（线程治理 2026-08-09）。
    nonisolated static func downscaled(_ image: UIImage, divisor: CGFloat) -> UIImage {
        let size = CGSize(width: image.size.width / divisor, height: image.size.height / divisor)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
