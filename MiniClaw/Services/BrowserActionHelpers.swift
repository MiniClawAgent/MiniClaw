import Foundation
import UIKit
import MiniClawKit

/// 浏览器纯逻辑工具（2026-08 提取：UA 参数解析 / 动作参数解析 / URL 工具，可独立单测）。
///
/// [2026-09-15 体系统一] 原在这里的 `enum UAProfile`（mobile/desktop，key
/// "miniClaw.browserUAProfile"）与 `defaultUAString()` / `desktopUA` / `mobileUA` 已删除：
/// UA 的唯一事实来源是**引擎池**的 `MiniClawUAProfile`（key "BrowserUserAgentProfile"）。
/// 旧的这套只作用于从不上屏的旧标签（旧体系），留着就是第二套真相。
enum BrowserActionHelpers {

    /// 智能体工具入口：在指定会话上下文内执行，完全独立于全局 currentSessionID（首页/手动浏览）。
    /// 通过 scopedSessionID 临时覆盖 activeContext 的解析目标，调用结束后恢复。
    /// - Parameter tabID: 稳定标签 id（list_tabs 返回的 tab_id；标签增删后索引漂移但 id 稳定）。
    ///   优先于 tabIndex 解析，换算成当前索引后走原链路；nil 则仅用 tabIndex。
    /// preset(mobile|desktop) → MiniClawUAProfile;兼容 Kit rawValue 拼写(mobile_safari|desktop_safari)。
    /// 2026-08-12 修复:此前只读 `user_agent` 键且值域不匹配,preset=desktop 静默回退 mobile_safari。
    static func resolveUAProfile(_ params: [String: Any]) -> MiniClawUAProfile? {
        if let preset = params["preset"] as? String {
            switch preset.lowercased() {
            case "mobile", "mobile_safari": return .mobileSafari
            case "desktop", "desktop_safari": return .desktopSafari
            default: return nil
            }
        }
        return (params["user_agent"] as? String).flatMap(MiniClawUAProfile.init)
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
    static func engineInput(action: String, params: [String: Any]) -> MiniClawActionInput? {
        guard let browserAction = MiniClawBrowserAction(rawValue: action) else { return nil }
        return MiniClawActionInput(
            action: browserAction,
            url: params["url"] as? String,
            selector: params["selector"] as? String,
            text: params["text"] as? String,
            coordinateX: params["x"] as? Int,
            coordinateY: params["y"] as? Int,
            direction: (params["direction"] as? String).flatMap(MiniClawActionInput.ScrollDirection.init),
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
    /// - Parameter sessionID: 会话独享目录（attachments/workspace/browser/offloads）必须按会话
    ///   解析才能命中会话内产物；不传只会落到扁平目录，会话隔离后写入的文件永远找不到。
    ///   无会话上下文时传 nil（仅兼容隔离前落在扁平目录的旧文件）。
    static func resolveMiniClawURL(_ raw: String, sessionID: UUID? = nil) -> String? {
        FileSystemManager.shared.resolveMiniClawResourceURL(raw, sessionID: sessionID)?.path
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
