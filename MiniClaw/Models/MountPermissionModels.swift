import Foundation

struct MountPoint: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    /// 虚拟路径，形如 `/var/MiniClaw/mounts/<name>`
    var path: String
    /// 外部文件夹真实路径（仅用于 UI 展示；bookmark 解析失败时的兜底显示）
    var externalPath: String? = nil
    /// security-scoped bookmark，持久化对外部文件夹的访问授权（跨重启有效）
    var bookmark: Data? = nil
    /// 是否允许 Agent 写入该挂载（默认 false = 只读，安全；需在设置中显式开启）。
    /// 旧字段名为 isReadOnly，改名是为了语义清晰且新默认值 false 对老数据同样安全（不写）。
    var isWritable: Bool = false
    var isMounted: Bool = false
}

/// 权限配置
struct PermissionConfig: Codable {
    /// 是否允许 miniclaw-config（Agent Tool / CLI）写入配置 — 对齐 spec 9.2.9 / 9.5
    var miniclawConfigWrite: Bool = false
    var location: PermissionState = .notDetermined
    var bluetooth: PermissionState = .notDetermined
    var microphone: PermissionState = .notDetermined
    var speechRecognition: PermissionState = .notDetermined
    var camera: PermissionState = .notDetermined
    var photoLibrary: PermissionState = .notDetermined
    var notifications: PermissionState = .notDetermined
    var calendar: PermissionState = .notDetermined
    var reminders: PermissionState = .notDetermined
    var healthKit: PermissionState = .notDetermined
    var homeKit: PermissionState = .notDetermined
    var nfc: PermissionState = .notDetermined
    var localNetwork: PermissionState = .notDetermined
    /// 蜂窝数据访问状态（读取自 CTCellularData；iOS 无公网联网授权弹窗，
    /// 此项反映用户在「设置 → 蜂窝网络」中对本 app 的开关）
    var cellularData: PermissionState = .notDetermined
}

enum PermissionState: String, Codable {
    case notDetermined = "未授权"
    case authorized = "已授权"
    case denied = "已拒绝"
    case restricted = "受限"

    /// 显示标签(英文 key,经 L10n.l 查表);rawValue 保持中文以兼容 Codable 持久化。
    var label: String {
        switch self {
        case .notDetermined: "permission_not_determined"
        case .authorized: "permission_authorized"
        case .denied: "permission_denied"
        case .restricted: "permission_restricted"
        }
    }
}

