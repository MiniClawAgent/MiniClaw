import Foundation

// MARK: - Browser Action Enum

public struct MiniClawActionInput {
    public let action: MiniClawBrowserAction
    public let url: String?
    public let selector: String?
    public let text: String?
    public let coordinateX: Int?
    public let coordinateY: Int?
    public let direction: ScrollDirection?
    public let amount: Int?
    public let script: String?
    public let userAgent: MiniClawUAProfile?
    public let maxDepth: Int?
    public let tabId: Int?
    public var scrollCount: Int? = nil
    public var itemSelector: String? = nil
    public var keywords: [String]? = nil
    public var fuzzy: Bool? = nil
    public var timeout: Int? = nil
    /// Custom viewport width in CSS pixels for `set_viewport`.
    public var viewportWidth: Int? = nil
    /// Custom viewport height in CSS pixels for `set_viewport`.
    public var viewportHeight: Int? = nil
    /// When true with `set_viewport`, clear the session-level viewport
    /// override and fall back to the global setting.
    public var viewportReset: Bool? = nil
    /// When true with `screenshot`, capture the entire scrollable page by
    /// temporarily resizing the WebView to `document.documentElement.scrollHeight`.
    /// Default false captures only the current viewport.
    public var fullPage: Bool? = nil
    /// Cookies to write (set_cookies). Each entry is a loosely-typed dict with
    /// keys: name, value (required), and optional domain, path, secure,
    /// http_only, expires (Unix seconds).
    public var cookies: [[String: Any]]? = nil

    public init(action: MiniClawBrowserAction,url: String? = nil,selector: String? = nil,
                text: String? = nil,coordinateX: Int? = nil,coordinateY: Int? = nil,
                direction: ScrollDirection? = nil,amount: Int? = nil,script: String? = nil,
                userAgent: MiniClawUAProfile? = nil,maxDepth: Int? = nil,tabId: Int? = nil,
                scrollCount: Int? = nil,itemSelector: String? = nil,keywords: [String]? = nil,
                fuzzy: Bool? = nil,timeout: Int? = nil,viewportWidth: Int? = nil,
                viewportHeight: Int? = nil,viewportReset: Bool? = nil,fullPage: Bool? = nil,
                cookies: [[String: Any]]? = nil) {
        self.action = action
        self.url = url
        self.selector = selector
        self.text = text
        self.coordinateX = coordinateX
        self.coordinateY = coordinateY
        self.direction = direction
        self.amount = amount
        self.script = script
        self.userAgent = userAgent
        self.maxDepth = maxDepth
        self.tabId = tabId
        self.scrollCount = scrollCount
        self.itemSelector = itemSelector
        self.keywords = keywords
        self.fuzzy = fuzzy
        self.timeout = timeout
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.viewportReset = viewportReset
        self.fullPage = fullPage
        self.cookies = cookies
    }

    public enum ScrollDirection: String {
        case up,down
    }

    public static func parse(from json: String) -> MiniClawActionInput? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionStr = dict["action"] as? String,
              let action = MiniClawBrowserAction(rawValue: actionStr) else {
            return nil
        }

        return MiniClawActionInput(
            action: action,
            url: dict["url"] as? String,
            selector: dict["selector"] as? String,
            text: dict["text"] as? String,
            coordinateX: dict["coordinate_x"] as? Int,
            coordinateY: dict["coordinate_y"] as? Int,
            direction: (dict["direction"] as? String).flatMap(ScrollDirection.init),
            amount: dict["amount"] as? Int,
            script: dict["script"] as? String,
            userAgent: (dict["user_agent"] as? String).flatMap(MiniClawUAProfile.init),
            maxDepth: dict["max_depth"] as? Int,
            tabId: dict["tab_id"] as? Int,
            scrollCount: dict["scroll_count"] as? Int,
            itemSelector: dict["item_selector"] as? String,
            keywords: {
                if let arr = dict["keywords"] as? [String] {
                    let tokens = arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    return tokens.isEmpty ? nil : tokens
                } else if let str = dict["keywords"] as? String {
                    let tokens = str.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    return tokens.isEmpty ? nil : tokens
                }
                return nil
            }(),
            fuzzy: dict["fuzzy"] as? Bool,
            timeout: dict["timeout"] as? Int,
            viewportWidth: dict["viewport_width"] as? Int,
            viewportHeight: dict["viewport_height"] as? Int,
            viewportReset: dict["reset"] as? Bool,
            fullPage: dict["full_page"] as? Bool,
            cookies: Self.parseCookies(dict["cookies"])
        )
    }

    /// `cookies` may arrive either as a real JSON array (`[[String: Any]]`) or —
    /// because the tool schema can only type it as a string — as a JSON-encoded
    /// STRING like `"[{\"name\":...}]"`. Accept both so a schema-faithful model
    /// (which emits the string form) isn't silently dropped to empty.
    private static func parseCookies(_ raw: Any?) -> [[String: Any]]? {
        if let arr = raw as? [[String: Any]] { return arr }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,let data = trimmed.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            return arr
        }
        return nil
    }
}

// MARK: - User Agent Profile

public struct MiniClawActionResult {
    public var text: String
    public let success: Bool
    /// Base64-encoded image data for the API (vision).
    public let base64Image: String?
    /// Local file path where the screenshot/image was saved to disk.
    public let imageFilePath: String?
    /// Raw downloaded file data (for fetch action).
    public let fetchedFileData: Data?
    /// Determined filename for the fetched file (for fetch action).
    public let fetchedFileName: String?
    /// The page URL at the time this action was executed.
    public var pageURL: String?
    /// The tab id this action actually ran on. Stamped by `MiniClawTabPool.execute`
    /// at the point of dispatch using the verified `targetId`, NOT the global
    /// `selectedTabId` — which is overwritten when the fan-out branch spawns
    /// a fresh tab for a concurrent navigate. Without this, the agent had to
    /// guess tab_id for its follow-up reads/scrolls and routinely picked the
    /// wrong one, sometimes surfacing as empty get_text results.
    /// [T-ios-browser-result-tab-id]
    public var tabId: Int?

    init(text: String,success: Bool = true,base64Image: String? = nil,imageFilePath: String? = nil,
         fetchedFileData: Data? = nil,fetchedFileName: String? = nil,pageURL: String? = nil,
         tabId: Int? = nil) {
        self.text = text
        self.success = success
        self.base64Image = base64Image
        self.imageFilePath = imageFilePath
        self.fetchedFileData = fetchedFileData
        self.fetchedFileName = fetchedFileName
        self.pageURL = pageURL
        self.tabId = tabId
    }

    public static func error(_ message: String) -> MiniClawActionResult {
        MiniClawActionResult(text: "Error: \(message)", success: false)
    }
}

public enum MiniClawBrowserAction: String,CaseIterable {
    case navigate
    case screenshot
    case click
    case type
    case getText = "get_text"
    case scroll
    case getPageInfo = "get_page_info"
    case executeJS = "execute_js"
    case findElements = "find_elements"
    case hover
    case getReadable = "get_readable"
    case setUserAgent = "set_user_agent"
    case setViewport = "set_viewport"
    case getBackbone = "get_backbone"
    case fetch
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case listTabs = "list_tabs"
    case getCookies = "get_cookies"
    case setCookies = "set_cookies"
    case scrollAndCollect = "scroll_and_collect"
    case waitForDomStable = "wait_for_dom_stable"
}

// MARK: - Browser Action Input

public enum MiniClawUAProfile: String {
    case mobileSafari = "mobile_safari"
    case desktopSafari = "desktop_safari"
    case custom = "custom"

    /// Returns a UA string, or `nil` for `.custom` (caller uses the custom string stored externally).
    public var userAgentString: String? {
        switch self {
        case .custom:
            return nil
        case .desktopSafari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .mobileSafari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
    }

    public var displayName: String {
        switch self {
        case .desktopSafari: return "Desktop Safari"
        case .mobileSafari: return "Mobile Safari"
        case .custom: return "Custom"
        }
    }

    public var icon: String {
        switch self {
        case .desktopSafari: return "desktopcomputer"
        case .mobileSafari: return "iphone"
        case .custom: return "pencil.line"
        }
    }

    /// Logical viewport size for the profile. Only takes effect for headless
    /// agent usage — once the WKWebView is embedded in SwiftUI its bounds are
    /// driven by the container. Desktop rendering in the visible browser is
    /// forced separately via a viewport-meta override script.
    public var viewportSize: (width: Int,height: Int) {
        switch self {
        case .desktopSafari: return (1280,800)
        case .mobileSafari,.custom: return (390,844)
        }
    }
}

// MARK: - Browser Action Result
