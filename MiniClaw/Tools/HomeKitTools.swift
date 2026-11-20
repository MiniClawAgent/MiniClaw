import Foundation
import HomeKit

// MARK: - 跨 actor 边界的数据

/// 配件概览。
///
/// `HMAccessory` / `HMHome` 等都不是 Sendable，Swift 6 严格并发下无法带出 MainActor 隔离区，
/// 因此只把模型真正需要的字段摊平成值类型回传。
private struct HomeKitBrief: Sendable {
    let home: String
    let name: String
    let kind: String
    let room: String
    let reachable: Bool

    var line: String {
        let state = reachable ? String(localized: "homekit_online") : String(localized: "homekit_offline")
        return "- \(name) | \(kind) | \(room) | \(state)"
    }
}

/// HomeKit 侧的统一结果：成败 + 已本地化的文本。
private struct HomeKitOutcome: Sendable {
    let success: Bool
    let text: String
}

// MARK: - HomeKit 授权状态接入（供权限页展示与申请）

/// HomeKit 授权状态接入。
///
/// **事实纠正（2026-09-18）**：本文件与 `PermissionManager` 原注释都写「HomeKit 无系统查询 API」——**这是错的**。
/// `HMHomeManager.authorizationStatus` 是 iOS 13 起的公开只读查询属性，配 `didUpdateAuthorizationStatus:` 委托
/// （见 SDK `HomeKit.framework/Headers/HMHomeManager.h:53`）。正因那句错注释，`permissions.homeKit` 被永远
/// 钉在 `.notDetermined`，徽标与真实授权状态无关。
///
/// **但读取它必须先有 `HMHomeManager` 实例，而创建实例会让系统弹出 HomeKit 授权询问**。故这里严格分两种场景：
/// - **被动展示**（进入设置页）：只在实例**已存在**时读取，绝不为了查状态而创建 —— 「打开设置页」不是请求家庭数据的意图；
/// - **用户主动请求**（点「家庭配件」行）：才创建实例、触发真实的系统询问，再读真实状态。
@MainActor
enum HomeKitAuthorization {
    /// 已知的真实状态；从未创建过管理器时返回 nil，表示"尚未询问"（由视图自行决定如何呈现）。
    static var currentIfKnown: PermissionState? {
        guard HomeKitHub.hasBeenInstantiated else { return nil }
        return HomeKitHub.shared.authorizationState
    }

    /// 用户主动请求家庭数据：确保管理器存在 —— 这一步会**触发系统授权询问**。
    ///
    /// **不在此等待系统回答。** 实测（2026-09-18）用户点「不允许」时系统**不给任何回调**，
    /// 旧实现 `await waitUntilReady()` 会永久挂起，界面表现为一直转圈。
    /// 改为「触发询问后立即返回」，由调用方在 **App 回到 active** 时再读真实状态并结算
    /// （见 `PermissionManager.resolveHomeKitAskIfNeeded()`）。
    static func beginPrompt() {
        _ = HomeKitHub.shared   // 访问即创建实例（lazy），从而触发系统询问
    }
}

// MARK: - HMHomeManager 宿主

/// HomeKit 管理器宿主。
///
/// ## 为什么必须这样写
/// `HMHomeManager` 有两条硬约束：① 必须在主线程创建并全程驻留；② 初始化后**不会立即可用**，
/// 要等 `homeManagerDidUpdateHomes:` 首次回调才知道家庭数据已加载，直接读 `homes` 会拿到空数组。
///
/// 因此全局只持有一个实例，把「等到就绪」封装成可 await 的调用；所有 HomeKit 对象都留在本类
/// 内部（MainActor），对外只回传 `HomeKitBrief` / `HomeKitOutcome` / `String` 这类 Sendable 值。
///
/// 未授予 HomeKit 权限时该回调同样会触发（只是 homes 为空），所以这里不加超时——
/// 加超时反而会在慢设备上误判成失败。
@MainActor
private final class HomeKitHub: NSObject, HMHomeManagerDelegate {
    static let shared = HomeKitHub()

    /// 实例是否已创建。**读本标志不会创建实例**（`shared` 是 lazy 的）——
    /// 这是"只为查授权状态就绝不创建管理器"的前提：创建 `HMHomeManager` 会触发系统授权询问。
    private static var instantiated = false
    static var hasBeenInstantiated: Bool { instantiated }

    private let manager = HMHomeManager()
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        HomeKitHub.instantiated = true
        manager.delegate = self
    }

    /// 系统报告的 HomeKit 授权状态（`HMHomeManager.authorizationStatus`，iOS 13+）。
    /// 用 `contains` 而非 `==`：该类型是 `NS_OPTIONS`，组合值下等值判断会漏。
    var authorizationState: PermissionState {
        let s = manager.authorizationStatus
        if s.contains(.authorized) { return .authorized }
        if s.contains(.restricted) { return .restricted }
        return .notDetermined
    }

    /// 等到家庭数据首次加载完成；已就绪则立即返回。
    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }

    // delegate 是 ObjC 协议，回调可能来自任意线程；标记 nonisolated 后跳回主线程改状态。
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in HomeKitHub.shared.markReadyAndResumeWaiters() }
    }

    /// 授权状态变化同样是"已就绪"的定论。
    /// **实测纠正（2026-09-18，唐唐报告）**：上文原注释称「未授予 HomeKit 权限时 `didUpdateHomes`
    /// 同样会触发（只是 homes 为空）」——**不成立**。用户点「不允许」时该回调可能永不触发，
    /// 仅靠它会让所有等待者**永久挂起**（界面表现为一直转圈）。故这里一并唤醒。
    nonisolated func homeManager(_ manager: HMHomeManager,
                                 didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in HomeKitHub.shared.markReadyAndResumeWaiters() }
    }

    private func markReadyAndResumeWaiters() {
        isReady = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    // MARK: 对外能力（入参与返回均为 Sendable）

    func homeNames() async -> [String] {
        await waitUntilReady()
        return manager.homes.map(\.name)
    }

    func briefs(type: String?, room: String?) async -> [HomeKitBrief] {
        await waitUntilReady()
        return allAccessories
            .filter { HomeKitNames.matches($0.accessory, type: type, room: room) }
            .map { HomeKitNames.brief(accessory: $0.accessory, home: $0.home, room: $0.room) }
    }

    func search(query: String?, type: String?, room: String?) async -> [HomeKitBrief] {
        await waitUntilReady()
        return allAccessories
            .filter { item in
                if let type, !HomeKitNames.matches(item.accessory, type: type, room: nil) { return false }
                if let room, item.room.localizedCaseInsensitiveContains(room) == false { return false }
                if let query, item.accessory.name.localizedCaseInsensitiveContains(query) == false { return false }
                return true
            }
            .map { HomeKitNames.brief(accessory: $0.accessory, home: $0.home, room: $0.room) }
    }

    /// 单配件详情。先逐个 `readValue` 取实时值（缓存值可能已过期），再列出全部可读写特征。
    func detail(name: String) async -> HomeKitOutcome {
        await waitUntilReady()
        guard let item = findAccessory(name) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_not_found") + name)
        }
        var lines: [String] = [
            "\(String(localized: "homekit_accessory_label")) \(item.accessory.name)",
            "\(String(localized: "homekit_room_label")) \(item.room)",
            "\(String(localized: "homekit_reachable_label")) \(item.accessory.isReachable ? String(localized: "yes_label") : String(localized: "no_label"))",
        ]
        for service in item.accessory.services {
            // 配件信息服务只含厂商/型号/固件等元数据，对控制无用，跳过以免刷屏
            if service.serviceType == HMServiceTypeAccessoryInformation { continue }
            lines.append("")
            lines.append("[\(HomeKitNames.serviceName(service))]")
            for c in service.characteristics {
                if c.characteristicType == HMCharacteristicTypeIdentify { continue }
                // 实时读取可能失败（设备离线或不支持读），失败时退回缓存值，不整段报错
                if c.properties.contains(HMCharacteristicPropertyReadable) {
                    try? await c.readValue()
                }
                guard c.properties.contains(HMCharacteristicPropertyWritable)
                        || c.properties.contains(HMCharacteristicPropertyReadable) else { continue }
                var line = "  - \(HomeKitNames.characteristicName(c)) = \(HomeKitNames.valueText(c.value))"
                line += " [\(c.properties.contains(HMCharacteristicPropertyWritable) ? String(localized: "writable_yes") : String(localized: "writable_no"))]"
                if let meta = c.metadata {
                    var hints: [String] = []
                    if let min = meta.minimumValue, let max = meta.maximumValue {
                        hints.append("\(min)~\(max)")
                    }
                    if let step = meta.stepValue { hints.append("\(String(localized: "homekit_step_label")) \(step)") }
                    if let units = meta.units, !units.isEmpty { hints.append(units) }
                    if !hints.isEmpty { line += " (\(hints.joined(separator: ", ")))" }
                }
                lines.append(line)
            }
        }
        return HomeKitOutcome(success: true, text: lines.joined(separator: "\n"))
    }

    func write(accessory name: String, characteristic charName: String, value rawValue: String) async -> HomeKitOutcome {
        await waitUntilReady()
        guard let item = findAccessory(name) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_not_found") + name)
        }
        let all = item.accessory.services.flatMap(\.characteristics)
        // 先按规范类型匹配（稳定），再按可读名匹配（兜底厂商自定义特征）
        guard let characteristic = all.first(where: { c in
            if let wanted = HomeKitNames.characteristicType(named: charName), c.characteristicType == wanted { return true }
            return HomeKitNames.characteristicName(c).localizedCaseInsensitiveCompare(charName) == .orderedSame
        }) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_characteristic_not_found") + charName)
        }
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_readonly"))
        }
        guard let value = HomeKitNames.coerce(rawValue, format: characteristic.metadata?.format) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_bad_value") + rawValue)
        }
        do {
            try await characteristic.writeValue(value)
            let after = HomeKitNames.valueText(characteristic.value)
            return HomeKitOutcome(success: true, text: String(localized: "homekit_set_ok") + "\(HomeKitNames.characteristicName(characteristic)) = \(after)")
        } catch {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_set_failed") + error.localizedDescription)
        }
    }

    func sceneNames() async -> [String] {
        await waitUntilReady()
        guard let home = manager.primaryHome ?? manager.homes.first else { return [] }
        return runnableScenes(in: home).map(\.name)
    }

    func runScene(name: String) async -> HomeKitOutcome {
        await waitUntilReady()
        guard let home = manager.primaryHome ?? manager.homes.first else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_no_home"))
        }
        let sets = runnableScenes(in: home)
        guard let scene = sets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                ?? sets.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_scene_not_found") + name)
        }
        do {
            try await home.executeActionSet(scene)
            return HomeKitOutcome(success: true, text: String(localized: "homekit_scene_ok") + scene.name)
        } catch {
            return HomeKitOutcome(success: false, text: String(localized: "homekit_scene_failed") + error.localizedDescription)
        }
    }

    // MARK: 内部

    /// 全部配件（含所属家庭与房间）。
    /// 未分配房间的配件 `room` 为 nil，用占位名兜底——不能丢，否则用户再也找不到这些配件。
    private var allAccessories: [(home: String, room: String, accessory: HMAccessory)] {
        manager.homes.flatMap { home in
            var refs: [(String, String, HMAccessory)] = []
            for room in home.rooms {
                for accessory in room.accessories {
                    refs.append((home.name, room.name, accessory))
                }
            }
            let roomed = Set(refs.map { $0.2.uniqueIdentifier })
            for accessory in home.accessories where !roomed.contains(accessory.uniqueIdentifier) {
                refs.append((home.name, String(localized: "homekit_no_room"), accessory))
            }
            return refs
        }
    }

    private func findAccessory(_ name: String) -> (home: String, room: String, accessory: HMAccessory)? {
        let all = allAccessories
        return all.first { $0.accessory.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { $0.accessory.name.localizedCaseInsensitiveContains(name) }
    }

    /// 触发器自建的动作集（`HMActionSetTypeTriggerOwned`）由自动化在触发时自行执行，
    /// 手动执行既无意义也可能与自动化冲突，故排除。
    private func runnableScenes(in home: HMHome) -> [HMActionSet] {
        home.actionSets.filter { $0.actionSetType != HMActionSetTypeTriggerOwned }
    }
}

// MARK: - 名称映射与值转换

/// 纯函数集合：只做「类型 ↔ 名字」映射与值转换，不持有 HomeKit 对象状态，故不隔离到主线程。
private enum HomeKitNames {

    /// 本地化 key → 该短名覆盖的服务类型集合。
    /// 类型过滤与类型展示名共用这一张表，避免两处维护不一致。
    /// key 后缀即 schema 里的 `type` 取值（如 `light` ↔ `homekit_type_light`）。
    private static let typeTable: [(key: String, types: Set<String>)] = [
        ("homekit_type_light",      [HMServiceTypeLightbulb]),
        ("homekit_type_fan",        [HMServiceTypeFan]),
        ("homekit_type_thermostat", [HMServiceTypeThermostat]),
        ("homekit_type_lock",       [HMServiceTypeLockMechanism]),
        ("homekit_type_door",       [HMServiceTypeDoor, HMServiceTypeGarageDoorOpener]),
        ("homekit_type_switch",     [HMServiceTypeSwitch]),
        ("homekit_type_outlet",     [HMServiceTypeOutlet]),
        ("homekit_type_camera",     [HMServiceTypeCameraRTPStreamManagement, HMServiceTypeCameraControl]),
        ("homekit_type_speaker",    [HMServiceTypeSpeaker]),
        ("homekit_type_blind",      [HMServiceTypeWindow, HMServiceTypeWindowCovering]),
        ("homekit_type_irrigation", [HMServiceTypeIrrigationSystem]),
        ("homekit_type_sensor",     [HMServiceTypeTemperatureSensor, HMServiceTypeHumiditySensor,
                                     HMServiceTypeLightSensor, HMServiceTypeMotionSensor,
                                     HMServiceTypeOccupancySensor, HMServiceTypeContactSensor,
                                     HMServiceTypeAirQualitySensor, HMServiceTypeLeakSensor,
                                     HMServiceTypeSmokeSensor, HMServiceTypeCarbonDioxideSensor,
                                     HMServiceTypeCarbonMonoxideSensor]),
    ]

    static func matches(_ accessory: HMAccessory, type: String?, room: String?) -> Bool {
        if let type {
            let wanted = types(for: type)
            let hit = accessory.services.contains { service in
                // 厂商自定义服务类型的 serviceType 是反向域名字符串，按包含匹配兜底
                wanted.contains(service.serviceType) || service.serviceType.localizedCaseInsensitiveContains(type)
            }
            guard hit else { return false }
        }
        if let room {
            guard accessory.room?.name.localizedCaseInsensitiveContains(room) == true else { return false }
        }
        return true
    }

    private static func types(for type: String) -> Set<String> {
        typeTable.first { $0.key == "homekit_type_\(type)" }?.types ?? []
    }

    static func serviceName(_ service: HMService) -> String {
        if let hit = typeTable.first(where: { $0.types.contains(service.serviceType) }) {
            return String(localized: String.LocalizationValue(hit.key))
        }
        // 表外类型（厂商自定义等）退回系统本地化名
        return service.name
    }

    static func brief(accessory: HMAccessory, home: String, room: String) -> HomeKitBrief {
        let services = accessory.services.filter { $0.serviceType != HMServiceTypeAccessoryInformation }
        let kind = services.first.map { serviceName($0) } ?? String(localized: "homekit_type_other")
        return HomeKitBrief(home: home, name: accessory.name, kind: kind, room: room,
                            reachable: accessory.isReachable)
    }

    /// 可读短名 → 规范特征类型。模型侧用 `power` / `brightness` 比一长串 UUID 可靠得多。
    static func characteristicType(named name: String) -> String? {
        switch name.lowercased() {
        case "power", "power_state", "on":        return HMCharacteristicTypePowerState
        case "brightness":                        return HMCharacteristicTypeBrightness
        case "hue":                               return HMCharacteristicTypeHue
        case "saturation":                        return HMCharacteristicTypeSaturation
        case "color_temperature":                 return HMCharacteristicTypeColorTemperature
        case "target_temperature", "temperature": return HMCharacteristicTypeTargetTemperature
        case "current_temperature":               return HMCharacteristicTypeCurrentTemperature
        case "target_humidity":                   return HMCharacteristicTypeTargetRelativeHumidity
        case "current_humidity":                  return HMCharacteristicTypeCurrentRelativeHumidity
        case "target_position", "position":       return HMCharacteristicTypeTargetPosition
        case "current_position":                  return HMCharacteristicTypeCurrentPosition
        case "target_door_state":                 return HMCharacteristicTypeTargetDoorState
        case "current_door_state":                return HMCharacteristicTypeCurrentDoorState
        case "rotation_speed", "speed":           return HMCharacteristicTypeRotationSpeed
        case "target_lock", "lock":               return HMCharacteristicTypeTargetLockMechanismState
        case "current_lock":                      return HMCharacteristicTypeCurrentLockMechanismState
        case "heating_cooling", "mode":           return HMCharacteristicTypeTargetHeatingCooling
        case "current_heating_cooling":           return HMCharacteristicTypeCurrentHeatingCooling
        case "air_quality":                       return HMCharacteristicTypeAirQuality
        case "obstruction":                       return HMCharacteristicTypeObstructionDetected
        case "mute":                              return HMCharacteristicTypeMute
        case "volume":                            return HMCharacteristicTypeVolume
        default:                                  return nil
        }
    }

    /// 特征展示名：优先用规范类型的短名，其次系统本地化描述，最后退回类型 UUID。
    static func characteristicName(_ c: HMCharacteristic) -> String {
        switch c.characteristicType {
        case HMCharacteristicTypePowerState:              return "power"
        case HMCharacteristicTypeBrightness:              return "brightness"
        case HMCharacteristicTypeHue:                     return "hue"
        case HMCharacteristicTypeSaturation:              return "saturation"
        case HMCharacteristicTypeColorTemperature:        return "color_temperature"
        case HMCharacteristicTypeTargetTemperature:       return "target_temperature"
        case HMCharacteristicTypeCurrentTemperature:      return "current_temperature"
        case HMCharacteristicTypeTargetRelativeHumidity:  return "target_humidity"
        case HMCharacteristicTypeCurrentRelativeHumidity: return "current_humidity"
        case HMCharacteristicTypeTargetPosition:          return "target_position"
        case HMCharacteristicTypeCurrentPosition:         return "current_position"
        case HMCharacteristicTypeTargetDoorState:         return "target_door_state"
        case HMCharacteristicTypeCurrentDoorState:        return "current_door_state"
        case HMCharacteristicTypeRotationSpeed:           return "rotation_speed"
        case HMCharacteristicTypeTargetHeatingCooling:    return "heating_cooling"
        case HMCharacteristicTypeCurrentHeatingCooling:   return "current_heating_cooling"
        case HMCharacteristicTypeAirQuality:              return "air_quality"
        case HMCharacteristicTypeObstructionDetected:     return "obstruction"
        case HMCharacteristicTypeMute:                    return "mute"
        case HMCharacteristicTypeVolume:                  return "volume"
        case HMCharacteristicTypeTargetLockMechanismState:return "target_lock"
        case HMCharacteristicTypeCurrentLockMechanismState:return "current_lock"
        default:
            return c.localizedDescription.isEmpty ? c.characteristicType : c.localizedDescription
        }
    }

    /// 按特征的元数据格式把字符串转成正确类型。
    /// HomeKit 对写入类型极严格——给 Bool 型特征写 Int 会被直接拒绝，所以必须按 format 解析。
    static func coerce(_ raw: String, format: String?) -> Any? {
        switch format {
        case .some(HMCharacteristicMetadataFormatBool):
            switch raw.lowercased() {
            case "1", "true", "on", "yes", "open":   return true
            case "0", "false", "off", "no", "close": return false
            default: return nil
            }
        case .some(HMCharacteristicMetadataFormatFloat):
            return Double(raw)
        case .some(HMCharacteristicMetadataFormatInt),
             .some(HMCharacteristicMetadataFormatUInt8),
             .some(HMCharacteristicMetadataFormatUInt16),
             .some(HMCharacteristicMetadataFormatUInt32),
             .some(HMCharacteristicMetadataFormatUInt64):
            if let i = Int(raw) { return i }
            if let d = Double(raw) { return Int(d) }
            return nil
        case .some(HMCharacteristicMetadataFormatString):
            return raw
        default:
            // 元数据缺失时按内容猜：bool → int → double → string
            switch raw.lowercased() {
            case "true", "on", "yes":  return true
            case "false", "off", "no": return false
            default: break
            }
            if let i = Int(raw) { return i }
            if let d = Double(raw) { return d }
            return raw
        }
    }

    static func valueText(_ value: Any?) -> String {
        guard let value else { return "—" }
        if let b = value as? Bool { return b ? "1" : "0" }
        return "\(value)"
    }
}

// MARK: - apple-homekit

/// HomeKit 配件控制工具。
///
/// ## 渐进式披露（省 token）
/// `list` 只给精简概览（名称/类型/房间/在线），`get` 才拉某个配件的全部特征值。
/// 直接把所有配件的所有特征一次返回会瞬间吃掉几千 token，而绝大多数提问用不到。
///
/// ## 刻意不做
/// - **不新建/删除家庭、房间与配件**：配对与结构变更属于 Home App 的职责，误操作代价高。
/// - **不增删改自动化规则**：`trigger` 只执行已有场景，不碰 Home 的自动化配置。
struct AppleHomeKitTool: AgentTool {
    let name = "apple-homekit"
    /// 发起调用的会话：能力授权请求需按会话记账（见 `ToolConfirmationBridge.ensureCapability`）。
    let currentSessionID: UUID?

    init(currentSessionID: UUID? = nil) {
        self.currentSessionID = currentSessionID
    }

    /// 会真实改变家中设备状态，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-homekit",
            description: String(localized: "homekit_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "op_homekit_actions"),
                        enum: ["list", "search", "get", "set", "scenes", "trigger"]
                    ),
                    "name": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_accessory_or_scene")),
                    "query": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_homekit_query")),
                    "type": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "param_homekit_type"),
                        enum: ["light", "fan", "thermostat", "lock", "door", "sensor", "switch", "outlet", "camera", "speaker", "blind", "irrigation"]
                    ),
                    "room": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_room_name")),
                    "characteristic": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_characteristic_name")),
                    "value": JSONSchema.JSONProperty(type: "string", description: String(localized: "param_target_value")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_action"))
        }
        // ── 能力守卫（单一入口：`ToolConfirmationBridge.ensureCapability`）──
        // 读取类动作需 homeRead、控制类动作需 homeControl：设置里持久开启，或本会话内经授权弹窗同意。
        // 未授权时弹一次授权窗（仅真实用户会话会弹）；拒绝则回报失败给模型。
        switch action {
        case "list", "search", "get", "scenes":
            guard await ToolConfirmationBridge.shared.ensureCapability(.homeRead, sessionID: currentSessionID) else {
                return ToolResult(success: false, text: AICapability.homeRead.unauthorizedMessage)
            }
        case "set", "trigger":
            guard await ToolConfirmationBridge.shared.ensureCapability(.homeControl, sessionID: currentSessionID) else {
                return ToolResult(success: false, text: AICapability.homeControl.unauthorizedMessage)
            }
        default:
            break
        }
        switch action {
        case "list":    return await listAction(parameters)
        case "search":  return await searchAction(parameters)
        case "get":     return await getAction(parameters)
        case "set":     return await setAction(parameters)
        case "scenes":  return await scenesAction()
        case "trigger": return await triggerAction(parameters)
        default:
            return ToolResult(success: false, text: String(localized: "homekit_unknown_action") + action)
        }
    }
}

// MARK: - actions

extension AppleHomeKitTool {
    private func listAction(_ parameters: [String: Any]) async -> ToolResult {
        let type = Self.string(parameters["type"])
        let room = Self.string(parameters["room"])
        // 先确认有没有家庭，避免把「未授权/无配置」误报成「没有配件」
        guard await HomeKitHub.shared.homeNames().isEmpty == false else {
            return ToolResult(success: false, text: String(localized: "homekit_no_home"))
        }
        let briefs = await HomeKitHub.shared.briefs(type: type, room: room)
        guard !briefs.isEmpty else {
            return ToolResult(success: true, text: String(localized: "homekit_no_accessory"))
        }
        var lines: [String] = []
        var current = ""
        for item in briefs {
            if item.home != current {
                current = item.home
                lines.append("\(String(localized: "homekit_home_label")) \(item.home)")
            }
            lines.append("  " + item.line)
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    private func searchAction(_ parameters: [String: Any]) async -> ToolResult {
        let query = Self.string(parameters["query"])?.lowercased()
        let type = Self.string(parameters["type"])
        let room = Self.string(parameters["room"])
        guard query != nil || type != nil || room != nil else {
            return ToolResult(success: false, text: String(localized: "homekit_need_filter"))
        }
        let hits = await HomeKitHub.shared.search(query: query, type: type, room: room)
        guard !hits.isEmpty else { return ToolResult(success: true, text: String(localized: "homekit_no_match")) }
        var lines: [String] = [String(localized: "homekit_match_header") + "\(hits.count)"]
        lines.append(contentsOf: hits.map(\.line))
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    private func getAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let name = Self.string(parameters["name"]) else {
            return ToolResult(success: false, text: String(localized: "homekit_need_name"))
        }
        let outcome = await HomeKitHub.shared.detail(name: name)
        return ToolResult(success: outcome.success, text: outcome.text)
    }

    private func setAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let name = Self.string(parameters["name"]) else {
            return ToolResult(success: false, text: String(localized: "homekit_need_name"))
        }
        guard let characteristic = Self.string(parameters["characteristic"]) else {
            return ToolResult(success: false, text: String(localized: "homekit_need_characteristic"))
        }
        guard let value = Self.string(parameters["value"]) else {
            return ToolResult(success: false, text: String(localized: "homekit_need_value"))
        }
        let outcome = await HomeKitHub.shared.write(accessory: name, characteristic: characteristic, value: value)
        return ToolResult(success: outcome.success, text: outcome.text)
    }

    private func scenesAction() async -> ToolResult {
        guard await HomeKitHub.shared.homeNames().isEmpty == false else {
            return ToolResult(success: false, text: String(localized: "homekit_no_home"))
        }
        let names = await HomeKitHub.shared.sceneNames()
        guard !names.isEmpty else { return ToolResult(success: true, text: String(localized: "homekit_no_scene")) }
        var lines: [String] = [String(localized: "homekit_scene_header")]
        lines.append(contentsOf: names.map { "- \($0)" })
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    private func triggerAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let name = Self.string(parameters["name"]) else {
            return ToolResult(success: false, text: String(localized: "homekit_need_scene"))
        }
        let outcome = await HomeKitHub.shared.runScene(name: name)
        return ToolResult(success: outcome.success, text: outcome.text)
    }

    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
