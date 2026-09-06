import Foundation

/// 一次「系统分享」的内容快照，写入 App Group 共享容器后由主 App 消费。
///
/// 为什么需要它：iOS 上 Share Extension **无法**用 `extensionContext.open`
/// 唤起宿主 App（官方文档：仅 Today / iMessage 扩展点支持该方法，Share
/// Extension 恒失败）。所以扩展只负责把内容落进共享容器，主 App 在深链 /
/// 冷启动 / 前台时读取并派发——分享链路不依赖任何唤起手段即可成立。
///
/// 本文件同时编入主 App 与 ShareExtension 两个 target（扩展不可链接主 App
/// 代码，共享逻辑必须以源码形式双编）。只依赖 Foundation。
struct PendingTaskShare: Codable, Equatable {
    let items: [Item]
    let timestamp: Date

    struct Item: Codable, Equatable {
        enum Kind: String,Codable {
            /// 正文文本或网页 URL，直接进 prompt。
            case text
            /// 共享文件目录里的文件名，主 App 读取后作为附件落会话目录。
            case attachment
        }
        let kind: Kind
        let value: String

        static func text(_ value: String) -> Item { Item(kind: .text,value: value) }
        static func attachment(_ fileName: String) -> Item { Item(kind: .attachment,value: fileName) }
    }

    /// 派发给智能体的正文（所有文本项按序拼接）。
    var combinedText: String {
        items.filter { $0.kind == .text }
            .map(\.value)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var attachmentNames: [String] {
        items.filter { $0.kind == .attachment }.map(\.value)
    }
}
