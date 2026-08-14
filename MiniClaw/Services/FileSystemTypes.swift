import Foundation

struct MountFileEntry: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    /// 挂载内的相对路径（用于钻取下级目录），例如 "Documents/2024"
    let relativePath: String
}

enum FileError: Error, LocalizedError {
    case notFound(String)
    case binaryFileNotSupported(String)
    case stringNotFound(String)
    case writeFailed(String)
    case absolutePathRequired(String)
    case pathEscapesRoot(String)
    case writeNotAllowed(String)
    case mountReadOnly(String)
    case invalidRange(String)
    case unsupportedImage(String)
    case sessionRequired(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): return String(format: L10n.l("fs_file_not_found"), path)
        case .binaryFileNotSupported(let path): return String(format: L10n.l("fs_binary_not_supported"), path)
        case .stringNotFound(let str): return String(format: L10n.l("fs_string_not_found"), str)
        case .writeFailed(let path): return String(format: L10n.l("fs_write_failed"), path)
        case .absolutePathRequired(let path): return String(format: L10n.l("fs_absolute_path_required"), path)
        case .pathEscapesRoot(let path): return String(format: L10n.l("fs_path_escapes_root"), path)
        case .writeNotAllowed(let path): return String(format: L10n.l("fs_write_not_allowed"), path)
        case .mountReadOnly(let name): return String(format: L10n.l("fs_mount_read_only"), name)
        case .invalidRange(let message): return message
        case .unsupportedImage(let path): return String(format: L10n.l("fs_unsupported_image"), path)
        case .sessionRequired(let path): return String(format: L10n.l("fs_session_required"), path)
        }
    }
}

// MARK: - Memory Manager

