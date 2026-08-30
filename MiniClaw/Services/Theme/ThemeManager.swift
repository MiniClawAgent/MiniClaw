import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// theme.json 的宽松声明结构（外部 JSON 铁律：全字段 decodeIfPresent）。
/// 允许「单图模式」（image 字段，三页共用）或分槽位（home/chat/settings 各一张）。
struct ThemePackageDecl: Codable {
    var id: String = ""
    var name: String = ""
    /// 单图模式：三页共用这张图。
    var image: String? = nil
    /// 分槽位覆盖（优先于 image）。
    var home: String? = nil
    var chat: String? = nil
    var settings: String? = nil
    /// 暗色模式遮罩不透明度（0-1，缺省 0.35）。
    var dimDark: Double? = nil

    /// 指定槽位的图片文件名；分槽位优先，回落单图。
    func fileName(for slot: ThemeBackground.Slot) -> String? {
        switch slot {
        case .home: return home ?? image
        case .chat: return chat ?? image
        case .settings: return settings ?? image
        }
    }

    init() {}

    // 外部 JSON 容错解码（与 PluginManifest 同口径）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        image = try c.decodeIfPresent(String.self, forKey: .image)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        chat = try c.decodeIfPresent(String.self, forKey: .chat)
        settings = try c.decodeIfPresent(String.self, forKey: .settings)
        dimDark = try c.decodeIfPresent(Double.self, forKey: .dimDark)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, image, home, chat, settings, dimDark
    }
}

/// 背景主题包管理器：选用状态持久化 + 背景图加载（ImageIO downsampling + NSCache）。
/// 语义（唐唐 2026-08-30 定稿）：
/// - 插件提供背景预设，用户在外观页显式选用，排他生效（同一时刻一个主题）；
/// - **未选用任何主题时返回 nil，三页保持系统默认背景**（默认视觉零变化）；
/// - 包内零代码：仅图片 + 声明式 theme.json。
/// 线程安全：NSCache 本身线程安全；选用状态读写均在主线程（UI 调用点），
/// 与 SubAgentProfileStore 同款 @unchecked Sendable（共享单例）。
final class ThemeManager: ObservableObject, @unchecked Sendable {
    static let shared = ThemeManager()

    /// 对象级缓存：key = themeID/slot/解码尺寸。
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {}

    // MARK: - 选用状态（持久化在 AppearanceSettings）

    /// 当前生效的主题插件 id；nil = 系统默认背景。
    var activeThemeID: String? {
        get {
            let v = SettingsStore.shared.settings.appearance.backgroundThemeID
            AppLogger.shared.info("[Theme] activeThemeID 读取 = \(v ?? "nil(系统默认)")",
                                  category: "Theme", subsystem: "Theme")
            return v
        }
        set {
            objectWillChange.send()
            SettingsStore.shared.settings.appearance.backgroundThemeID = newValue
            SettingsStore.shared.save()
            imageCache.removeAllObjects()
            AppLogger.shared.info("[Theme] 选用主题写入 = \(newValue ?? "nil(清除)")，已保存",
                                  category: "Theme", subsystem: "Theme")
        }
    }

    /// 指定主题的声明；未选用或包缺失返回 nil。
    func activeDeclaration() -> ThemePackageDecl? {
        guard let id = activeThemeID else { return nil }
        let decl = declaration(pluginID: id)
        if decl == nil {
            AppLogger.shared.error("[Theme] theme.json 读取失败: plugins/theme/\(id)/theme.json",
                                   category: "Theme", subsystem: "Theme")
        }
        return decl
    }

    /// 读取某主题包的 theme.json（宽容解码）。
    func declaration(pluginID: String) -> ThemePackageDecl? {
        let url = FileSystemManager.shared.pluginTypeDir("theme")
            .appendingPathComponent(pluginID)
            .appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThemePackageDecl.self, from: data)
    }

    /// 已安装的主题包列表（插件页/外观页用）：[(pluginID, decl)]，按 pluginID 排序。
    func installedThemes() -> [(pluginID: String, decl: ThemePackageDecl)] {
        let dir = FileSystemManager.shared.pluginTypeDir("theme")
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let result = subs
            .filter { $0.hasDirectoryPath }
            .compactMap { url -> (String, ThemePackageDecl)? in
                guard let decl = declaration(pluginID: url.lastPathComponent) else { return nil }
                return (url.lastPathComponent, decl)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        AppLogger.shared.info("[Theme] 已装主题扫描: \(result.count) 个 ← \(result.map { $0.0 })",
                              category: "Theme", subsystem: "Theme")
        return result
    }

    /// 主题在包内的图片完整路径。
    func imageURL(pluginID: String, fileName: String) -> URL {
        FileSystemManager.shared.pluginTypeDir("theme")
            .appendingPathComponent(pluginID)
            .appendingPathComponent("assets")
            .appendingPathComponent(fileName)
    }

    // MARK: - 背景图加载（downsampling + 缓存）

    /// 当前生效主题在指定槽位的背景图；未选用/缺图返回 nil（视图层回退系统背景）。
    /// - Parameter maxPixel: 目标解码最大边（像素）。调用方传「容器尺寸 × 屏幕缩放」，
    ///   ImageIO 按该尺寸降采样解码——4K 源图也不会全分辨率解码（约 33MB/张的内存陷阱）。
    func backgroundImage(for slot: ThemeBackground.Slot, maxPixel: CGFloat) -> UIImage? {
        guard let decl = activeDeclaration(), let id = activeThemeID,
              let fileName = decl.fileName(for: slot) else {
            AppLogger.shared.info("[Theme] backgroundImage(\(slot.rawValue)) = nil（未选用主题/声明缺失/槽位缺图）",
                                  category: "Theme", subsystem: "Theme")
            return nil
        }
        let clamped = max(320, min(maxPixel, 8_000))
        let key = "\(id)/\(slot.rawValue)/\(Int(clamped))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }

        let url = imageURL(pluginID: id, fileName: fileName)
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let image = Self.downsampledImage(at: url, maxPixel: clamped) else {
            AppLogger.shared.error("[Theme] 背景图解码失败: \(url.path)（存在=\(exists)）",
                                   category: "Theme", subsystem: "Theme")
            return nil
        }
        AppLogger.shared.info("[Theme] 背景图就绪: \(slot.rawValue) ← \(fileName)（\(image.size.width)x\(image.size.height)@\(clamped)px）",
                              category: "Theme", subsystem: "Theme")
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// ImageIO 降采样解码：按目标最大边直接解码出"刚好够用"的位图，
    /// 避免 UIImage(contentsOfFile:) 全分辨率解码的内存放大（4K ≈ 33MB）。
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded())
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 读取图片声明尺寸（导入校验用；不解码位图）。
    static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// 导入校验：单张 ≤2MB、长边 ≤3840（4K）。返回 nil = 通过；否则返回错误文案 key 已在调用方组装。
    static func validateThemeAssets(in pluginDir: URL) -> String? {
        let assetsDir = pluginDir.appendingPathComponent("assets")
        guard FileManager.default.fileExists(atPath: assetsDir.path) else { return nil }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: assetsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in urls where url.pathExtension.lowercased() == "jpg"
            || url.pathExtension.lowercased() == "jpeg" || url.pathExtension.lowercased() == "png" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 2 * 1024 * 1024 {
                return String(format: L10n.l("theme_import_image_too_large"), url.lastPathComponent)
            }
            if let dim = imageDimensions(at: url), max(dim.width, dim.height) > 3840 {
                return String(format: L10n.l("theme_import_image_too_large"), url.lastPathComponent)
            }
        }
        return nil
    }
}
