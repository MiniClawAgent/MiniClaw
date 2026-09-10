import Combine
import Foundation
import SwiftUI

@MainActor
final class FontSettings: ObservableObject {
    static let shared = FontSettings()

    @Published var chatInputScale: FontScaleLevel {
        didSet {
            guard chatInputScale != oldValue else { return }
            UserDefaults.standard.set(chatInputScale.rawValue,forKey: Keys.chatInput)
        }
    }
    @Published var messageBaseScale: FontScaleLevel {
        didSet {
            guard messageBaseScale != oldValue else { return }
            UserDefaults.standard.set(messageBaseScale.rawValue,forKey: Keys.messageBase)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontSettingsMessageBaseChanged,object: nil)
            }
        }
    }
    @Published var appBaseScale: FontScaleLevel {
        didSet {
            guard appBaseScale != oldValue else { return }
            UserDefaults.standard.set(appBaseScale.rawValue,forKey: Keys.appBase)
            DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        }
    }

    var isModified: Bool {
        chatInputScale != .default
            || messageBaseScale != .default
            || appBaseScale != .default
    }

    func scaledChatInput(_ size: CGFloat) -> CGFloat {
        size*chatInputScale.multiplier
    }

    func scaledMessage(_ size: CGFloat) -> CGFloat {
        size*messageBaseScale.multiplier
    }

    func scaledApp(_ size: CGFloat) -> CGFloat {
        size*appBaseScale.multiplier
    }

    private init() {
        let ud = UserDefaults.standard
        chatInputScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.chatInput)) ?? .default
        messageBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.messageBase)) ?? .default
        appBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.appBase)) ?? .default
        DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
    }

    func applyAppScaleToAllWindows() {
        guard #available(iOS 17.0,*) else { return }
        guard appBaseScale != .default else {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
                        window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                    }
                }
            }
            return
        }
        let category = appBaseScale.contentSizeCategory
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        }
    }

    func resetToDefaults() {
        chatInputScale = .default
        messageBaseScale = .default
        appBaseScale = .default
    }

    static let messageBaseChangedNotification = Notification.Name.fontSettingsMessageBaseChanged

    private enum Keys {
        static let chatInput = "fontSettings.chatInputScale"
        static let messageBase = "fontSettings.messageBaseScale"
        static let appBase = "fontSettings.appBaseScale"
    }
}

extension View {
    func appFontScale() -> some View {
        modifier(AppFontScaleModifier())
    }
}

private struct AppFontScaleModifier: ViewModifier {
    @ObservedObject private var fontSettings = FontSettings.shared

    func body(content: Content) -> some View {
        content.dynamicTypeSize(fontSettings.appBaseScale.dynamicTypeSize)
    }
}

enum FontScaleLevel: Int,CaseIterable,Identifiable,Comparable {
    case xSmall = -2
    case small = -1
    case `default` = 0
    case medium = 1
    case large = 2
    case extraLarge = 3

    var id: Int { rawValue }

    static var allCases: [FontScaleLevel] { [.xSmall,.small,.default,.medium,.large,.extraLarge] }

    var multiplier: CGFloat {
        switch self {
        case .xSmall: return 0.88 // ~15pt body
        case .small: return 0.94 // ~16pt body
        case .default: return 1.0 // 17pt body
        case .medium: return 1.06
        case .large: return 1.12
        case .extraLarge: return 1.21
        }
    }

    var label: String {
        switch self {
        case .xSmall: return "XS"
        case .small: return "Small"
        case .default: return "Default"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall: return .small
        case .small: return .medium
        case .default: return .large // system default
        case .medium: return .xLarge
        case .large: return .xxLarge
        case .extraLarge: return .xxxLarge
        }
    }

    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .small
        case .small: return .medium
        case .default: return .large
        case .medium: return .extraLarge
        case .large: return .extraExtraLarge
        case .extraLarge: return .extraExtraExtraLarge
        }
    }

    static func<(lhs: FontScaleLevel,rhs: FontScaleLevel) -> Bool {
        lhs.rawValue<rhs.rawValue
    }
}

///
///
extension Notification.Name {
    static let fontSettingsMessageBaseChanged = Notification.Name("fontSettingsMessageBaseChanged")
}
