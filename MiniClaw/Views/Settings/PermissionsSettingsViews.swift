import SwiftUI
import UIKit

// MARK: - 权限与后台（后台行为迁移自通用设置 + 权限授权列表）

struct PermissionsSettingsView: View {
    /// 观察统一配置，权限状态回写后徽标实时刷新。
    @ObservedObject private var store = SettingsStore.shared
    /// 提示弹窗（如剪贴板无需授权说明）。
    @State private var showInfo = false
    @State private var infoText = ""
    /// 正在申请中的权限键，避免重复点击。
    @State private var busyKey: String?
    /// 用于强制视图在权限状态回写后重绘（SettingsStore 未主动发 willChange，靠此触发刷新）。
    @State private var tick: Bool = false
    /// 通知是否已授权（决定「通知」行显示开关还是「未授权」，2026-08-07 自后台页移入）。
    @State private var notifAuthorized: Bool = false
    /// 定位授权状态（2026-08-07 自后台页移入；供 apple-location 取当前位置使用）。
    @State private var locationState: PermissionState = .notDetermined

    /// 权限清单（仅展示用户指定的项；健康仅保留「健康数据」，位置已移至「后台」页定位行）。
    /// 2026-08-31：健康数据已恢复展示——AppleHealthKitTool 真实现已接入（读 24 项 / 写 8 项白名单），
    /// 此处点击即一次性申请全量读类型授权（写入授权由「设置 → 通用 → 允许 AI 写入健康数据」按需申请）。
    /// 家庭配件（AppleHomeKitTool）仍是占位空壳，入口继续保持隐藏。
    private let permissionItems: [(key: String, label: String)] = [
        ("healthData", String(localized: "health_data")),
        ("calendar",  String(localized: "calendar")),
        ("photos",    String(localized: "images")),
        // ("homeKit",   String(localized: "home_accessories")),   // 待 HomeKit 工具接入后恢复
        ("pasteboard",String(localized: "clipboard")),
        ("reminders", String(localized: "reminders")),
        ("microphone",String(localized: "microphone")),
        ("speech",    String(localized: "speech_recognition")),
        ("localNetwork", String(localized: "local_network")),   // iSH 内网 DNS/局域网设备访问依赖（NWBrowser 触发系统弹窗）
    ]

    /// 权限状态实时从统一配置读取。
    private var permissions: PermissionConfig { store.settings.permissions }

    var body: some View {
        Form {
            Section {
                NavigationLink(String(localized: "background")) {
                    BackgroundSettingsView()
                }
            } header: {
                Text(String(localized: "background"))
            } footer: {
                Text(String(localized: "permissions_background_section_footer"))
            }

            Section {
                notificationRow
                locationRow
                ForEach(permissionItems, id: \.key) { item in
                    permissionRow(item)
                }
            } header: {
                Text(String(localized: "permissions"))
            } footer: {
                Text(String(localized: "lists_the_permissions_this_app_may_request_and_their_current_authorization_status_tap_an_unauthorized_item_to_request_it_in_app_or_jump_to_system_settings_to_enable_it"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "permissions_background"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await MainActor.run { PermissionManager.shared.refreshStatuses() }
            let notif = await PermissionManager.shared.notificationAuthorized
            await MainActor.run {
                notifAuthorized = notif
                locationState = PermissionManager.shared.locationState()
            }
            tick.toggle()
        }
        // 从系统设置授权返回时刷新通知/定位状态（.task 不会重跑）。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                let notif = await PermissionManager.shared.notificationAuthorized
                await MainActor.run {
                    notifAuthorized = notif
                    locationState = PermissionManager.shared.locationState()
                }
            }
        }
        .alert(String(localized: "tip"), isPresented: $showInfo) {
            Button(String(localized: "got_it"), role: .cancel) {}
        } message: { Text(infoText) }
    }

    // 通知行（2026-08-07 自后台页移入）：已授权显示开关（后台通知开关），未授权显示「未授权」引导申请。
    @ViewBuilder
    private var notificationRow: some View {
        if notifAuthorized {
            Toggle(String(localized: "notifications"), isOn: Binding(
                get: { store.settings.background.notifications },
                set: { newValue in
                    var b = store.settings.background
                    b.notifications = newValue
                    store.set(b, domain: .background, summary: String(localized: "modify_notification_settings"))
                }
            ))
        } else {
            HStack {
                Text(String(localized: "notifications"))
                Spacer()
                // 与其它权限行的授权徽标同款（PermissionBadgeView 单一来源）：红字红底胶囊，
                // 但保持可点击（点击申请通知授权）。
                Button(String(localized: "not_authorized")) { requestNotification() }
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PermissionBadgeView.badgeColor(.denied).opacity(0.15))
                    .foregroundStyle(PermissionBadgeView.badgeColor(.denied))
                    .clipShape(Capsule())
            }
        }
    }

    // 定位权限行（2026-08-07 自后台页移入）：与其它权限行完全一致——
    // 整行可点击、申请中显示菊花、右侧授权胶囊徽标、申请后实时刷新状态。
    @ViewBuilder
    private var locationRow: some View {
        Button {
            Task { await requestLocation() }
        } label: {
            HStack {
                Text(String(localized: "locate_action"))
                Spacer()
                // 申请中显示菊花（与其它权限行同款）
                if busyKey == "location" {
                    ProgressView().scaleEffect(0.7)
                }
                PermissionBadgeView(state: locationState)
            }
        }
        .buttonStyle(.plain)
        .disabled(busyKey != nil && busyKey != "location")
    }

    private func requestLocation() async {
        guard busyKey == nil else { return }
        busyKey = "location"
        let result = await PermissionManager.shared.requestPermission("location")
        // 与其它权限一致：申请后仍非授权（拒绝/受限/未决定）则跳转系统设置引导开启。
        if result != .authorized {
            openSettings()
        }
        await MainActor.run {
            busyKey = nil
            locationState = PermissionManager.shared.locationState()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestNotification() {
        Task {
            let granted = await PermissionManager.shared.requestNotification()
            let notif = await PermissionManager.shared.notificationAuthorized
            await MainActor.run {
                notifAuthorized = notif
                // 授权成功且通知开关从未打开过 → 默认打开（授权即希望收到任务通知）；
                // 用户之后手动关闭不会被覆盖（只有授权这一刻才置默认开）。
                if granted, !store.settings.background.notifications {
                    var b = store.settings.background
                    b.notifications = true
                    store.set(b, domain: .background, summary: String(localized: "modify_notification_settings"))
                }
            }
        }
    }

    // 单行：可点击申请/跳转；右侧显示授权徽标；申请中显示菊花。
    @ViewBuilder
    private func permissionRow(_ item: (key: String, label: String)) -> some View {
        Button {
            handleTap(item)
        } label: {
            HStack {
                Text(item.label)
                Spacer()
                // 申请中显示菊花（名称后、徽标前），返回后恢复徽标
                if busyKey == item.key {
                    ProgressView().scaleEffect(0.7)
                }
                permissionBadge(state: state(for: item.key))
            }
        }
        .buttonStyle(.plain)
        .disabled(busyKey != nil && busyKey != item.key)
    }

    /// 点击处理：剪贴板无需授权直接提示；其余先尝试 App 内申请，若仍非授权则跳转系统设置。
    private func handleTap(_ item: (key: String, label: String)) {
        let key = item.key
        if key == "pasteboard" {
            infoText = String(localized: "the_clipboard_requires_no_authorization_the_app_can_always_read_and_write_it_and_no_system_setting_needs_to_be_enabled")
            showInfo = true
            return
        }
        // 本地网络：无公开的状态查询 API，只能靠 NWBrowser 探测（首次会触发系统弹窗）。
        // 2026-09-07 行为调整：不论当前状态一律重新探测——
        //   未授权 → 触发系统弹窗，用户允许即写回「已授权」；
        //   已拒绝 → 快速失败，引导去系统设置开启（用户在设置里打开后回到本页再点
        //            一次即可刷新为已授权，此前点都不让点是错的）；
        //   未能确认（无网络 / 用户未做选择）→ 不写状态，提示重试而非误标已拒绝。
        if key == "localNetwork" {
            guard busyKey == nil else { return }
            busyKey = key
            PermissionManager.shared.requestLocalNetwork()
            Task { @MainActor in
                // 系统弹窗没有超时，用户可能十几秒后才回答——等待窗口必须给足（30s），
                // 否则用户点了「允许」而 UI 早已放弃等待，状态永远停在未授权。
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if store.settings.permissions.localNetwork != .notDetermined { break }
                }
                busyKey = nil
                tick.toggle()
                switch store.settings.permissions.localNetwork {
                case .denied:
                    // 本地网络开关在「设置 → 隐私与安全性 → 本地网络」，
                    // openSettingsURLString 到不了该层，只能给文字引导。
                    infoText = String(localized: "local_network_permission_was_denied_go_to_settings_privacy_security_local_network_and_enable_miniclaw_once_enabled_internal_dns_names_and_lan_devices_will_work_automatically")
                    showInfo = true
                case .notDetermined:
                    infoText = String(localized: "local_network_probe_inconclusive")
                    showInfo = true
                default:
                    break   // 已授权：徽标已刷新，无需提示
                }
            }
            return
        }
        guard busyKey == nil else { return }
        busyKey = key
        Task { @MainActor in
            let result = await PermissionManager.shared.requestPermission(key)
            busyKey = nil
            if result != .authorized {
                // 未授权（拒绝/受限/未确定）：跳转系统设置引导开启
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            }
        }
    }

    private func state(for key: String) -> PermissionState {
        switch key {
        case "health", "healthData": return permissions.healthKit
        case "calendar":            return permissions.calendar
        case "photos":              return permissions.photoLibrary
        case "homeKit":             return permissions.homeKit
        case "pasteboard":          return .authorized  // 始终可用
        case "reminders":           return permissions.reminders
        case "microphone":          return permissions.microphone
        case "speech":              return permissions.speechRecognition
        case "localNetwork":        return permissions.localNetwork
        default:                    return .notDetermined
        }
    }

    @ViewBuilder
    private func permissionBadge(state: PermissionState) -> some View {
        PermissionBadgeView(state: state)
    }

    private func badgeColor(_ state: PermissionState) -> Color {
        PermissionBadgeView.badgeColor(state)
    }
}

// MARK: - 授权徽标（权限页 / 后台页共用，样式单一来源）

/// 授权状态胶囊徽标：状态文字 + 彩色圆角底（绿=已授权 / 红=拒绝 / 橙=受限 / 灰=未决定）。
struct PermissionBadgeView: View {
    let state: PermissionState

    var body: some View {
        Text(String(localized: String.LocalizationValue(state.label)))
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.badgeColor(state).opacity(0.15))
            .foregroundStyle(Self.badgeColor(state))
            .clipShape(Capsule())
    }

    static func badgeColor(_ state: PermissionState) -> Color {
        switch state {
        case .authorized:    return .green
        case .denied:        return .red
        case .restricted:    return .orange
        case .notDetermined: return .gray
        }
    }
}
