import Foundation
import CoreLocation

// MARK: - 一次性定位取数器

/// 取数器保活表。
///
/// Swift 6 严格并发下，`static var` 持有非 Sendable 的可变数组属非法的全局可变状态；
/// 因此改用 `static let` 持有本引用类型，内部增删统一走自带锁。
private final class FetcherRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OneShotLocationFetcher] = []

    func add(_ fetcher: OneShotLocationFetcher) {
        lock.lock(); items.append(fetcher); lock.unlock()
    }

    func remove(_ fetcher: OneShotLocationFetcher) {
        lock.lock(); items.removeAll { $0 === fetcher }; lock.unlock()
    }
}

/// 一次性定位的 delegate 宿主。
///
/// 存在意义：`CLLocationManager` 必须在回调到达前**保持存活**，否则会被提前释放、
/// 回调永久丢失（表现为工具一直挂到超时）。因此由 `FetcherRegistry` 持有，
/// 自身在 `finish` 里撤销保活（而不是在 completion 闭包里做——那会捕获尚未声明的实例）。
///
/// **必须跑在主线程**：`CLLocationManager` 的 delegate 回调依赖创建它的那条线程上的
/// RunLoop。Swift 并发的通用执行器线程没有 RunLoop，在那里创建会导致回调永不送达
/// （表现同样是必超时，且极难与「信号差」区分）。故整类隔离到 MainActor，
/// 既然全部访问都在主线程，`finished` 无需加锁。
@MainActor
private final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let registry: FetcherRegistry
    private var finished = false
    private let completion: (CLLocation?) -> Void

    init(accuracy: CLLocationAccuracy,
         registry: FetcherRegistry,
         completion: @escaping (CLLocation?) -> Void) {
        self.registry = registry
        self.completion = completion
        self.manager = CLLocationManager()
        super.init()
        self.manager.desiredAccuracy = accuracy
        self.manager.delegate = self
    }

    func start() {
        manager.requestLocation()
    }

    // delegate 由系统在任意线程回调，声明为 nonisolated 并跳回主线程改状态——
    // 直接写 @MainActor 方法会触发「跨 actor 边界的协议一致性」数据竞争告警。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    /// 回调与超时可能同时到达，用 `finished` 保证 completion 只触发一次。
    /// 全程在主线程，无需加锁。
    func finish(_ location: CLLocation?) {
        guard !finished else { return }
        finished = true
        registry.remove(self)
        completion(location)
    }
}

// MARK: - apple-location

/// 设备定位与地址互转工具。
///
/// 只负责「怎么用」，不负责「何时授权」——定位授权沿用「设置 → 权限 → 定位」，
/// 未授权时本工具返回结构化错误码并引导用户去开启，不在 AI 链路中弹系统弹窗。
struct AppleLocationTool: AgentTool {
    let name = "apple-location"

    /// 超时阈值：室内 / GPS 冷启动下定位可能数十秒无结果，
    /// 与其让整轮对话卡住，不如 10 秒后降级返回（或明确报错让模型换个问法）。
    private static let timeout: TimeInterval = 10

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-location",
            description: L10n.l("location_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("location_param_action"),
                        enum: ["current", "geocode", "reverse_geocode"]
                    ),
                    "accuracy": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("location_param_accuracy"),
                        enum: ["reduced", "hundred", "best"]
                    ),
                    "include_address": JSONSchema.JSONProperty(
                        type: "boolean",
                        description: L10n.l("location_param_include_address")
                    ),
                    "address": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("location_param_address")
                    ),
                    "latitude": JSONSchema.JSONProperty(
                        type: "number",
                        description: L10n.l("location_param_latitude")
                    ),
                    "longitude": JSONSchema.JSONProperty(
                        type: "number",
                        description: L10n.l("location_param_longitude")
                    ),
                ],
                required: ["action"]
            )
        )
    )

    /// 保活尚未回调的取数器（见 `OneShotLocationFetcher` 头注释）。
    private static let registry = FetcherRegistry()

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        let action = (parameters["action"] as? String)?.lowercased() ?? ""
        switch action {
        case "current":         return await currentAction(parameters)
        case "geocode":         return await geocodeAction(parameters)
        case "reverse_geocode": return await reverseGeocodeAction(parameters)
        default:
            return ToolResult(success: false,
                              text: String(format: L10n.l("location_unknown_action"), action))
        }
    }

    // MARK: action - current

    private func currentAction(_ parameters: [String: Any]) async -> ToolResult {
        guard CLLocationManager.locationServicesEnabled() else {
            return ToolResult(success: false, text: L10n.l("location_unavailable"))
        }
        guard authorizationGranted() else {
            return ToolResult(success: false, text: L10n.l("location_denied"))
        }

        let accuracy = resolvedAccuracy(parameters["accuracy"])
        let includeAddress = Self.bool(from: parameters["include_address"]) ?? true

        guard let location = await fetchOnce(accuracy: accuracy) else {
            return ToolResult(success: false, text: L10n.l("location_timeout"))
        }

        var lines = [
            "latitude: \(Self.trim(location.coordinate.latitude))",
            "longitude: \(Self.trim(location.coordinate.longitude))",
            "horizontal_accuracy: ±\(Int(location.horizontalAccuracy)) m",
            "altitude: \(Int(location.altitude)) m",
            "timestamp: \(Self.stamp(location.timestamp))",
        ]
        if includeAddress, let address = await reverseGeocode(location) {
            lines.append("address: \(address)")
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    // MARK: action - geocode

    private func geocodeAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let address = parameters["address"] as? String, !address.isEmpty else {
            return ToolResult(success: false, text: L10n.l("location_arg_missing"))
        }
        let placemarks = await withCheckedContinuation { (cont: CheckedContinuation<[CLPlacemark], Never>) in
            CLGeocoder().geocodeAddressString(address) { marks, _ in
                cont.resume(returning: marks ?? [])
            }
        }
        guard !placemarks.isEmpty else {
            return ToolResult(success: false, text: L10n.l("location_geocode_no_result"))
        }
        var lines: [String] = [String(format: L10n.l("location_geocode_header"), String(placemarks.count))]
        for (index, mark) in placemarks.enumerated() where index < 5 {
            guard let coordinate = mark.location?.coordinate else { continue }
            lines.append("\(index + 1). \(Self.readableAddress(mark)) | \(Self.trim(coordinate.latitude)), \(Self.trim(coordinate.longitude))")
        }
        return ToolResult(success: true, text: lines.joined(separator: "\n"))
    }

    // MARK: action - reverse_geocode

    private func reverseGeocodeAction(_ parameters: [String: Any]) async -> ToolResult {
        guard let latitude = Self.number(from: parameters["latitude"]),
              let longitude = Self.number(from: parameters["longitude"]) else {
            return ToolResult(success: false, text: L10n.l("location_arg_missing"))
        }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let address = await reverseGeocode(location) else {
            return ToolResult(success: false, text: L10n.l("location_geocode_no_result"))
        }
        return ToolResult(success: true, text: "address: \(address)")
    }

    // MARK: 定位基建

    private func fetchOnce(accuracy: CLLocationAccuracy) async -> CLLocation? {
        await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            // 取数器的创建、启动与超时全部跳主线程：见 OneShotLocationFetcher 的 RunLoop 说明。
            Task { @MainActor in
                let fetcher = OneShotLocationFetcher(accuracy: accuracy, registry: Self.registry) { location in
                    cont.resume(returning: location)
                }
                Self.registry.add(fetcher)
                fetcher.start()

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                    fetcher.finish(nil)   // 超时：finish 内部保证不会重复触发
                }
            }
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            CLGeocoder().reverseGeocodeLocation(location) { marks, _ in
                cont.resume(returning: marks?.first.map { Self.readableAddress($0) })
            }
        }
    }

    private func authorizationGranted() -> Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    private func resolvedAccuracy(_ raw: Any?) -> CLLocationAccuracy {
        switch (raw as? String)?.lowercased() {
        case "best":    return kCLLocationAccuracyBest
        case "reduced": return kCLLocationAccuracyReduced
        default:        return kCLLocationAccuracyHundredMeters
        }
    }

    // MARK: 辅助

    private static func readableAddress(_ mark: CLPlacemark) -> String {
        let parts = [mark.name, mark.locality, mark.administrativeArea, mark.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? L10n.l("unknown") : parts.joined(separator: ", ")
    }

    private static func trim(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func stamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss Z"
        return df.string(from: date)
    }

    private static func number(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func bool(from raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return Bool(value.lowercased())
        default: return nil
        }
    }
}
