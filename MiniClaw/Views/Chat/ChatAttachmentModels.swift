import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatInputInjection: Equatable {
    var id: Int
    var text: String
}

// MARK: - 待发送附件（输入栏内选中、发送前展示）

/// 输入框里已选中的附件：复制进 attachments/ 目录后的本地副本 + 展示信息。
struct InputAttachment: Identifiable, Equatable {
    let id: UUID
    /// 已复制到 FileSystemManager.attachmentsDir 内的本地 URL（发送后由消息引用，删除 chip 时一并清除副本）。
    let url: URL
    let fileName: String
    let kind: AttachmentKind
}

/// 附件类型，用于选择展示用的 SF 图标。
enum AttachmentKind: Equatable {
    case image, video, audio, document

    var icon: String {
        switch self {
        case .image:    return "photo"
        case .video:    return "film"
        case .audio:    return "music.note"
        case .document: return "doc"
        }
    }

    /// 由文件扩展名推断类型（图片/音频/视频见 FileSystemManager.attachmentExtensions）。
    static func from(ext: String) -> AttachmentKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp":           return .image
        case "mp4", "mov", "m4v":                            return .video
        case "mp3", "m4a", "wav":                            return .audio
        default:                                            return .document
        }
    }
}

/// 三选项弹窗中实际拉起的系统选择器。
