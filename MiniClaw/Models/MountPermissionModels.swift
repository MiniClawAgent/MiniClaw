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
///
/// 注：bluetooth / nfc / camera / notifications 四个字段已删除——它们都曾是
/// 「只有声明、从不写回」的假状态，AI 通过 `miniclaw-config` 读到的是恒为
/// `.notDetermined` 的脏数据，开启写入后还会把假值持久化。其中通知的真实
/// 状态走 `PermissionManager.notificationAuthorized` 独立通道（设置-权限页使用），
/// 相机则无任何授权查询代码（拍照由 UIImagePickerController 系统侧处理）。
struct PermissionConfig: Codable {
    /// 是否允许 miniclaw-config（Agent Tool / CLI）写入配置 — 对齐 spec 9.2.9 / 9.5
    var miniclawConfigWrite: Bool = false
    var location: PermissionState = .notDetermined
    var microphone: PermissionState = .notDetermined
    var speechRecognition: PermissionState = .notDetermined
    var photoLibrary: PermissionState = .notDetermined
    var calendar: PermissionState = .notDetermined
    var reminders: PermissionState = .notDetermined
    var healthKit: PermissionState = .notDetermined
    var homeKit: PermissionState = .notDetermined
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
    /// 系统**不公开**该权限的结论 —— 目前只有 HealthKit **读**授权属此：
    /// iOS 对只读类型的 `authorizationStatus(for:)` 在询问过之后**恒返回 `.sharingDenied`**
    /// （无论用户允许还是拒绝），以阻止"用授权状态反推用户健康状况"的侧信道。
    ///
    /// 语义 =「**已询问，但给没给系统不告诉我们**」。
    /// 因此本状态**不显示任何状态徽标**：既不虚报"已授权"，也不误报"未授权"。
    case unknown = "未知"

    /// 显示标签(英文 key,经 String(localized:) 查表);rawValue 保持中文以兼容 Codable 持久化。
    var label: String {
        switch self {
        case .notDetermined: "permission_not_determined"
        case .authorized: "permission_authorized"
        case .denied: "permission_denied"
        case .restricted: "permission_restricted"
        case .unknown: "permission_unknown"
        }
    }
}

