import SwiftUI

//   - 挂载模式每行右侧显示分享按钮

enum FileBrowserMode: Hashable {
    case session
    case rootfs
    case mount(name: String)
}

/// 导航定位（可 Hashable，作为 NavigationStack path 的值类型）。
struct FileBrowserLocation: Hashable, Identifiable {
    let mode: FileBrowserMode
    let directoryURL: URL
    let displayGuestPath: String?
    let sessionID: UUID?

    var id: String {
        "\(mode)|\(directoryURL.path)|\(displayGuestPath ?? "")|\(sessionID?.uuidString ?? "")"
    }
}

/// 单个文件 / 目录条目。
struct FileBrowserItem: Identifiable, Hashable {
    let id: URL
    let readURL: URL
    let name: String
    let isDir: Bool
    let size: UInt64
}

