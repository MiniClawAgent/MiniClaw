import Foundation
import CoreLocation
import MapKit

// MARK: - 跨 actor 边界的数据

/// 统一结果。`MKMapItem` / `MKRoute` 都不是 Sendable，输出文本在回调内就地组装后回传。
private struct MapOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> MapOutcome { MapOutcome(success: true, text: text) }
    static func fail(_ text: String) -> MapOutcome { MapOutcome(success: false, text: text) }
}

/// 一个已解析的地点（Sendable）：坐标 + 展示名。
private struct MapPoint: Sendable {
    let coordinate: CLLocationCoordinate2D
    let name: String
}

// MARK: - apple-maps (MapKit)

/// 地图工具：POI 搜索、路线规划、预计到达时间。
///
/// ## 合规与依赖取舍
/// 直接用系统 MapKit，不引第三方地图 SDK：MapKit 在中国大陆由高德供数（持牌服务），
/// 无需 API key、不新增第三方隐私清单。若换腾讯/高德/百度 iOS SDK，反而要引入
/// 三方依赖 + key + 第三方 SDK 隐私声明，与「尽量少收集、审核面干净」的目标相反。
///
/// ## 为什么不用 CLGeocoder 做地址解析
/// `CLGeocoder.geocodeAddressString` 自 iOS 26 起被标记废弃（Apple 要求迁到
/// `MKGeocodingRequest`，而后者 iOS 26 才可用，本 App 部署目标是 iOS 16）。
/// 这里统一用 **MKLocalSearch 做地理编码**：一条非废弃的通路，16 起全版本可用，
/// 且搜索与解析共用同一套请求构造。
///
/// ## 主线程约束
/// MapKit 对象必须在主线程创建与释放（否则 dealloc 阶段可能在通知中心崩溃），
/// 因此所有地图操作都收在 `MapsBridge`（@MainActor）内。
struct AppleMapsTool: AgentTool {
    let name = "apple-maps"

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-maps",
            description: L10n.l("maps_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("op_map_actions"),
                        enum: ["search_poi", "route", "eta"]
                    ),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("poi_search_keyword")),
                    "near": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_map_center")),
                    "radius": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_search_radius")),
                    "from": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_origin")),
                    "to": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_destination")),
                    "transport_type": JSONSchema.JSONProperty(
                        type: "string",
                        description: L10n.l("param_transit_mode"),
                        enum: ["driving", "walking", "transit"]
                    ),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_result_limit")),
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
        case "search_poi":
            guard let query = Self.string(parameters["query"]), !query.isEmpty else {
                return ToolResult(success: false, text: L10n.l("maps_need_query"))
            }
            let outcome = await MapsBridge.searchPOI(query: query,
                                                    near: Self.string(parameters["near"]),
                                                    radius: Self.double(parameters["radius"]),
                                                    limit: Self.int(parameters["limit"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "route", "eta":
            guard let from = Self.string(parameters["from"]), !from.isEmpty,
                  let to = Self.string(parameters["to"]), !to.isEmpty else {
                return ToolResult(success: false, text: L10n.l("maps_need_from_to"))
            }
            let outcome = action == "route"
                ? await MapsBridge.route(from: from, to: to, mode: Self.string(parameters["transport_type"]))
                : await MapsBridge.eta(from: from, to: to, mode: Self.string(parameters["transport_type"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: L10n.l("maps_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleMapsTool {
    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - MainActor 桥接层

@MainActor
private enum MapsBridge {
    // MARK: 查询

    static func searchPOI(query: String, near: String?, radius: Double?, limit: Int?) async -> MapOutcome {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            guard let center = await resolve(near) else {
                return .fail(L10n.l("maps_resolve_failed") + near)
            }
            let meters = max(radius ?? 1000, 100)
            request.region = MKCoordinateRegion(center: center.coordinate,
                                                latitudinalMeters: meters * 2,
                                                longitudinalMeters: meters * 2)
        }
        let search = MKLocalSearch(request: request)
        return await withCheckedContinuation { cont in
            search.start { response, error in
                cont.resume(returning: Self.renderPOI(response, error: error, limit: limit))
            }
        }
    }

    static func route(from: String, to: String, mode: String?) async -> MapOutcome {
        guard let source = await resolve(from), let destination = await resolve(to) else {
            return .fail(L10n.l("maps_resolve_failed") + "\(from) / \(to)")
        }
        let request = MKDirections.Request()
        request.source = mapItem(for: source)
        request.destination = mapItem(for: destination)
        request.transportType = transportType(of: mode)
        let directions = MKDirections(request: request)
        return await withCheckedContinuation { cont in
            directions.calculate { response, error in
                cont.resume(returning: Self.renderRoute(response,
                                                        error: error,
                                                        sourceName: source.name,
                                                        destinationName: destination.name))
            }
        }
    }

    /// ETA 是路线计算的轻量版：只要时间与距离，不拉分段步骤。
    static func eta(from: String, to: String, mode: String?) async -> MapOutcome {
        guard let source = await resolve(from), let destination = await resolve(to) else {
            return .fail(L10n.l("maps_resolve_failed") + "\(from) / \(to)")
        }
        let request = MKDirections.Request()
        request.source = mapItem(for: source)
        request.destination = mapItem(for: destination)
        request.transportType = transportType(of: mode)
        let directions = MKDirections(request: request)
        return await withCheckedContinuation { cont in
            directions.calculateETA { response, error in
                cont.resume(returning: Self.renderETA(response,
                                                      error: error,
                                                      sourceName: source.name,
                                                      destinationName: destination.name))
            }
        }
    }

    // MARK: 地点解析

    /// 接受两种写法：`39.9,116.4` 直接解析；否则按地址做一次本地搜索取首个结果。
    static func resolve(_ raw: String) async -> MapPoint? {
        if let coordinate = Self.parseCoordinate(raw) {
            return MapPoint(coordinate: coordinate, name: raw)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = raw
        let search = MKLocalSearch(request: request)
        return await withCheckedContinuation { cont in
            search.start { response, _ in
                guard let item = response?.mapItems.first else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: MapPoint(coordinate: item.placemark.coordinate,
                                               name: item.name ?? raw))
            }
        }
    }

    nonisolated private static func parseCoordinate(_ raw: String) -> CLLocationCoordinate2D? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    nonisolated private static func mapItem(for point: MapPoint) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
    }

    nonisolated private static func transportType(of mode: String?) -> MKDirectionsTransportType {
        switch mode {
        case "walking": return .walking
        case "transit": return .transit
        default:        return .automobile
        }
    }

    // MARK: 输出组装（非隔离：地图对象在回调内就地消费，不带出闭包）

    nonisolated private static func renderPOI(_ response: MKLocalSearch.Response?,
                                              error: Error?,
                                              limit: Int?) -> MapOutcome {
        if let error { return .fail(L10n.l("maps_failed") + error.localizedDescription) }
        guard let items = response?.mapItems, !items.isEmpty else { return .ok(L10n.l("maps_no_results")) }
        let shown = Array(items.prefix(max(limit ?? 10, 1)))
        var lines: [String] = [L10n.l("maps_search_header") + "\(shown.count)/\(items.count)"]
        for item in shown {
            var parts = ["- " + (item.name ?? L10n.l("unknown"))]
            if let address = item.placemark.title, !address.isEmpty, address != item.name {
                parts.append(address)
            }
            if let phone = item.phoneNumber, !phone.isEmpty { parts.append(phone) }
            let coordinate = item.placemark.coordinate
            parts.append(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))
            lines.append(parts.joined(separator: " | "))
        }
        return .ok(lines.joined(separator: "\n"))
    }

    nonisolated private static func renderRoute(_ response: MKDirections.Response?,
                                                error: Error?,
                                                sourceName: String,
                                                destinationName: String) -> MapOutcome {
        if let error { return .fail(L10n.l("maps_failed") + error.localizedDescription) }
        guard let route = response?.routes.first else { return .ok(L10n.l("maps_no_results")) }
        var lines: [String] = [
            L10n.l("maps_route_header") + sourceName + " → " + destinationName,
            L10n.l("maps_distance_label") + distance(route.distance),
            L10n.l("maps_duration_label") + duration(route.expectedTravelTime),
        ]
        // 步骤可能上百条（长路线），只给前 10 段，够模型回答「怎么走」又不灌爆上下文
        let steps = Array(route.steps.prefix(10))
        if !steps.isEmpty {
            lines.append(L10n.l("maps_steps_header"))
            for step in steps {
                if step.instructions.isEmpty { continue }
                lines.append("- " + step.instructions + " (" + distance(step.distance) + ")")
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }

    nonisolated private static func renderETA(_ response: MKDirections.ETAResponse?,
                                              error: Error?,
                                              sourceName: String,
                                              destinationName: String) -> MapOutcome {
        if let error { return .fail(L10n.l("maps_failed") + error.localizedDescription) }
        guard let eta = response else { return .ok(L10n.l("maps_no_results")) }
        return .ok([
            L10n.l("maps_eta_header") + sourceName + " → " + destinationName,
            L10n.l("maps_duration_label") + duration(eta.expectedTravelTime),
            L10n.l("maps_distance_label") + distance(eta.distance),
        ].joined(separator: "\n"))
    }

    nonisolated private static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 { return String(format: "%.0f", meters) + L10n.l("unit_meters") }
        return String(format: "%.1f", meters / 1000) + L10n.l("unit_kilometers")
    }

    nonisolated private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds / 60)
        if total < 60 { return "\(max(total, 1))" + L10n.l("unit_minutes") }
        return "\(total / 60)" + L10n.l("unit_hours") + "\(total % 60)" + L10n.l("unit_minutes")
    }
}
