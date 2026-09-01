import Foundation
import Photos
import UIKit

// MARK: - 跨 actor 边界的数据

/// 统一结果。`PHAsset` 不是 Sendable，失败原因在桥接层内就地本地化后回传文本。
private struct PhotoOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> PhotoOutcome { PhotoOutcome(success: true, text: text) }
    static func fail(_ text: String) -> PhotoOutcome { PhotoOutcome(success: false, text: text) }
}

/// 导出请求的结果。
///
/// `PHAsset` 带不出主线程，所以「是否存在 / 是否图片 / 原始字节」必须在桥接层里就地判定，
/// 只把 Sendable 的字节包回传。转码与落盘放在隔离区外——大图 JPEG 编码不该占住主线程。
private enum PhotoPayload: Sendable {
    case data(Data)
    case notFound
    case notImage
    case failed
}

// MARK: - apple-photos (PhotoKit)

/// 相册工具。
///
/// ## 与「聊天里发图片」的关系
/// 聊天输入框选图（UIImagePickerController）是 **UI 层**把图片交给 AI 的通道，不走本工具。
/// 本工具补的是反方向：**让 AI 主动查相册并取出某张图**——用户说「找找我上个月在海边拍的
/// 照片」时，AI 需要有能力自己翻。
///
/// ## 关键设计：`get` 导出为沙盒内 JPEG
/// PhotoKit 的 `PHAsset` 只是一个句柄，AI（以及 `apple-vision` / `apple-image` 等工具）
/// 读不了。`get` 把目标照片落盘到 `attachmentsDir/photos/`，返回路径，后续交给既有工具处理。
/// HEIC/HEIF 会转成 JPEG——多数图像管线对 JPEG 的支持最稳。
///
/// ## 明确不支持
/// - **视频导出**：需要 `AVAssetExportSession` 异步转码，价值/复杂度比不高。`get` 遇到
///   视频会明确告知，而不是静默返回一张封面图冒充。
/// - **删除照片**：破坏性且不可撤销，与「敏感操作需用户确认」的取向冲突。
struct ApplePhotosTool: AgentTool {
    let name = "apple-photos"
    /// `save` 会写入用户相册，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-photos",
            description: L10n.l("photos_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("op_photo_actions"),
                        enum: ["list", "get", "save"]
                    ),
                    "asset_id": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_asset_id")),
                    "path": JSONSchema.JSONProperty(type: "string", description: L10n.l("image_path_save_param")),
                    "album": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_album_name")),
                    "media_type": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("param_media_type"),
                        enum: ["all", "image", "video"]
                    ),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_return_limit")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_action"))
        }
        switch action {
        case "list": return await listAssets(parameters)
        case "get":  return await exportAsset(parameters)
        case "save": return await saveAsset(parameters)
        default:
            return ToolResult(success: false, text: L10n.l("photos_unknown_action") + action)
        }
    }
}

// MARK: - 实现

extension ApplePhotosTool {
    private func listAssets(_ parameters: [String: Any]) async -> ToolResult {
        guard await Self.ensureReadAccess() else { return Self.denied() }
        // 入参就地摊平成 Sendable 值再过桥——`parameters` 本身不是 Sendable，进不了隔离区。
        let outcome = await PhotosBridge.list(limit: Self.int(parameters["limit"]) ?? 20,
                                              mediaType: Self.string(parameters["media_type"]) ?? "all",
                                              albumName: Self.string(parameters["album"]))
        return ToolResult(success: outcome.success, text: outcome.text)
    }

    /// 导出单张图片到沙盒，返回可直接交给图像工具的路径。
    private func exportAsset(_ parameters: [String: Any]) async -> ToolResult {
        guard await Self.ensureReadAccess() else { return Self.denied() }
        guard let id = Self.string(parameters["asset_id"]) else {
            return ToolResult(success: false, text: L10n.l("photos_need_asset_id"))
        }

        let raw: Data
        switch await PhotosBridge.payload(id: id) {
        case .notFound: return ToolResult(success: false, text: L10n.l("photos_not_found"))
        case .notImage: return ToolResult(success: false, text: L10n.l("photos_video_unsupported"))
        case .failed:   return ToolResult(success: false, text: L10n.l("photos_export_failed"))
        case .data(let data): raw = data
        }

        // HEIC/HEIF 转 JPEG：下游图像工具对 JPEG 的支持最稳
        let payload: Data
        let ext: String
        if Self.needsTranscode(raw), let image = UIImage(data: raw), let jpeg = image.jpegData(compressionQuality: 0.92) {
            payload = jpeg
            ext = "jpg"
        } else {
            payload = raw
            ext = Self.extension(for: raw)
        }

        do {
            let dir = FileSystemManager.shared.attachmentsDir.appendingPathComponent("photos", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try payload.write(to: file)
            let kb = payload.count / 1024
            return ToolResult(success: true,
                              text: L10n.l("photos_exported") + file.path + "\n"
                                  + L10n.l("size_label") + "\(kb)" + L10n.l("unit_kb") + "\n"
                                  + L10n.l("photos_next_hint"))
        } catch {
            return ToolResult(success: false, text: L10n.l("photos_export_failed") + error.localizedDescription)
        }
    }

    private func saveAsset(_ parameters: [String: Any]) async -> ToolResult {
        guard await Self.ensureWriteAccess() else { return Self.denied() }
        guard let rawPath = Self.string(parameters["path"]) else {
            return ToolResult(success: false, text: L10n.l("photos_need_path"))
        }
        let url = Self.resolve(rawPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ToolResult(success: false, text: L10n.l("photos_file_missing") + rawPath)
        }
        let isVideo = Self.videoExtensions.contains(url.pathExtension.lowercased())

        do {
            // `performChanges` 与主线程无关，无需过桥；但闭包要只捕获 Sendable 值。
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            return ToolResult(success: true, text: L10n.l("photos_saved"))
        } catch {
            return ToolResult(success: false, text: L10n.l("photos_save_failed") + error.localizedDescription)
        }
    }

    private static func denied() -> ToolResult {
        ToolResult(success: false, text: L10n.l("photos_denied"))
    }
}

// MARK: - MainActor 桥接层

/// 相册的读取全部隔离在 MainActor 内。
///
/// `PHAsset` / `PHFetchResult` / `PHAssetCollection` 都不是 Sendable，Swift 6 下不能带出隔离区。
/// 因此每个方法都在主线程一次做完「取数 + 组装输出」，只回传 Sendable 的值。
@MainActor
private enum PhotosBridge {
    /// 参数名刻意叫 `albumName` 而非 `album`：`if let album` 的局部绑定会把下面的
    /// `album(named:)` 方法名遮蔽掉，Swift 会把它当成「对 String 取值调用」。
    static func list(limit: Int, mediaType: String, albumName: String?) async -> PhotoOutcome {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = max(min(limit, 200), 1)

        let result: PHFetchResult<PHAsset>
        if let albumName {
            guard let collection = album(named: albumName) else {
                return .fail(L10n.l("photos_album_not_found") + albumName)
            }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            switch mediaType {
            case "image": result = PHAsset.fetchAssets(with: .image, options: options)
            case "video": result = PHAsset.fetchAssets(with: .video, options: options)
            default:      result = PHAsset.fetchAssets(with: options)
            }
        }

        guard result.count > 0 else { return .ok(L10n.l("photos_empty")) }
        var lines: [String] = [L10n.l("photos_list_header") + "\(result.count)"]
        // 用下标遍历而非 enumerateObjects：后者的闭包会捕获可变局部变量，
        // 在严格并发下会触发「跨隔离域可变捕获」的诊断。
        for i in 0..<result.count { lines.append(describe(result.object(at: i))) }
        return .ok(lines.joined(separator: "\n"))
    }

    /// 取单张图片的原始字节。存在性与类型判定都在这里做完，只回传 Sendable 的字节。
    static func payload(id: String) async -> PhotoPayload {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return .notFound
        }
        // 视频导出要走 AVAssetExportSession，本工具不做；明确告知而不是返回封面图
        guard asset.mediaType == .image else { return .notImage }
        guard let data = await imageData(for: asset) else { return .failed }
        return .data(data)
    }

    // MARK: 辅助

    private static func album(named name: String) -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject
    }

    /// 取图片原始数据。
    ///
    /// `requestImageDataAndOrientation` 的回调**可能被调用多次**（先缩略后原图），
    /// 用一次性盒子包住 continuation，避免重复 resume 触发崩溃。
    private static func imageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true // iCloud 图库需要下载，否则拿到 nil
        options.isSynchronous = false
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let box = OnceBox(cont)
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                box.resume(data)
            }
        }
    }

    private static func describe(_ asset: PHAsset) -> String {
        let kind = asset.mediaType == .video ? L10n.l("media_video") : L10n.l("media_image")
        var parts = ["- \(kind) | \(asset.pixelWidth)x\(asset.pixelHeight)"]
        if let d = asset.creationDate { parts.append(EventDateParser.shortString(from: d)) }
        if let loc = asset.location {
            let lat = String(format: "%.4f", loc.coordinate.latitude)
            let lng = String(format: "%.4f", loc.coordinate.longitude)
            parts.append(L10n.l("place_label") + "\(lat),\(lng)")
        }
        if asset.isFavorite { parts.append(L10n.l("photos_favorite")) }
        parts.append(L10n.l("id_label") + asset.localIdentifier)
        return parts.joined(separator: " | ")
    }
}

// MARK: - 纯函数（无隔离要求）

extension ApplePhotosTool {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]

    /// 是否是需要转码的高效格式（HEIC/HEIF）。JPEG/PNG 原样保留。
    private static func needsTranscode(_ data: Data) -> Bool {
        // HEIC/HEIF 的第 4-8 字节是 "ftyp" 品牌标记，品牌为 heic/heix/hevc/mif1 等
        guard data.count > 12 else { return false }
        let brand = data.subdata(in: 4..<12)
        guard let s = String(data: brand, encoding: .ascii), s.hasSuffix("ftyp") else { return false }
        let next = data.subdata(in: 8..<12)
        guard let b = String(data: next, encoding: .ascii) else { return false }
        return ["heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains(b)
    }

    private static func `extension`(for data: Data) -> String {
        // JPEG: FF D8 FF / PNG: 89 50 4E 47 / GIF: 47 49 46
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "jpg" }
        if data.count >= 4, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "png" }
        if data.count >= 3, data[0] == 0x47, data[1] == 0x49, data[2] == 0x46 { return "gif" }
        return "jpg"
    }

    /// 路径解析：相对路径按沙盒根解析，绝对路径直接用。
    private static func resolve(_ raw: String) -> URL {
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return FileSystemManager.shared.miniClawRoot.appendingPathComponent(raw)
    }

    // MARK: 授权

    /// 读相册需要 readWrite 级授权（addOnly 读不到内容）。
    private static func ensureReadAccess() async -> Bool {
        await requestAccess(level: .readWrite)
    }

    /// 只写入相册时 addOnly 即可，避免向用户索取超出需要的权限。
    private static func ensureWriteAccess() async -> Bool {
        await requestAccess(level: .addOnly)
    }

    /// 部署目标是 iOS 16，`PHAccessLevel` 与 `requestAuthorization(for:)` 都可用（iOS 14+），
    /// 故不再做 `#available` 分支——旧分支里的 `authorizationStatus()` 已被 Apple 标记待废弃。
    private static func requestAccess(level: PHAccessLevel) async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: level) {
        case .authorized, .limited: return true
        case .denied, .restricted:  return false
        case .notDetermined:        break
        @unknown default:           return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: level)
        return status == .authorized || status == .limited
    }

    // MARK: 入参摊平

    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

// MARK: - 一次性 continuation 盒子

/// 保证 `CheckedContinuation` 只被 resume 一次。
/// PhotoKit 的部分回调（如图片数据请求）会分多次派发，重复 resume 会直接触发运行时错误。
///
/// `T` 必须 Sendable：`resume(returning:)` 的入参是 `sending T`，无约束的泛型满足不了。
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
