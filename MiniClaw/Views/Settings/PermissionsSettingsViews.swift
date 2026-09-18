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

    /// 权限清单：系统授权状态类项目。健康数据与家庭配件**不在此列** ——
    /// 二者连同各自的功能说明与写入总闸集中在「控制」区（见 body），
    /// 避免同一能力的入口散落在多处设置页。
    private let permissionItems: [(key: String, label: String)] = [
        ("calendar",  String(localized: "calendar")),
        ("photos",    String(localized: "images")),
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
            // 「控制」区：**只放二级入口**，所有开关都收进各自的二级页
            // （2026-09-18 唐唐要求：控制项严格进二级菜单，不在本页散落开关）。
            Section {
                NavigationLink(String(localized: "background")) {
                    BackgroundSettingsView()
                }
                NavigationLink(String(localized: "health_capability_title")) {
                    HealthCapabilitySettingsView()
                }
                NavigationLink(String(localized: "home_capability_title")) {
                    HomeCapabilitySettingsView()
                }
            } header: {
                Text(String(localized: "control"))
            } footer: {
                Text(String(localized: "control_section_footer"))
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
        case "calendar":            return permissions.calendar
        case "photos":              return permissions.photoLibrary
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

    // `.unknown`（系统不公开结论 —— 目前只有 HealthKit 读授权）**不渲染任何徽标**：
    // 既不虚报"已授权"，也不误报"未授权"（2026-09-18 唐唐要求）。
    @ViewBuilder
    var body: some View {
        if state != .unknown {
            Text(String(localized: String.LocalizationValue(state.label)))
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Self.badgeColor(state).opacity(0.15))
                .foregroundStyle(Self.badgeColor(state))
                .clipShape(Capsule())
        }
    }

    static func badgeColor(_ state: PermissionState) -> Color {
        switch state {
        case .authorized:    return .green
        case .denied:        return .red
        case .restricted:    return .orange
        case .notDetermined: return .gray
        case .unknown:       return .clear   // 不显示徽标；仅为 switch 穷尽
        }
    }
}

// MARK: - 控制 · 能力开关与系统授权行（健康/家庭二级页共用，单一来源）

/// 能力总闸开关：绑定 `defaults` 域的某个 Bool。
/// 四个能力开关共用同一读写口径 —— 避免同一套 get/set 写四遍后各自漂移。
struct CapabilityToggleRow: View {
    let title: String
    let keyPath: WritableKeyPath<DefaultSettings, Bool>
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { store.settings.defaults[keyPath: keyPath] },
            set: { newValue in
                var d = store.settings.defaults
                d[keyPath: keyPath] = newValue
                store.set(d, domain: .defaults, summary: title)
            }
        ))
    }
}

/// 能力的系统授权状态行：整行可点申请系统授权，右侧显示授权徽标。
/// 与权限页用同一枚 `PermissionBadgeView`，样式一致。
struct CapabilityAuthorizationRow: View {
    let permissionKey: String
    let title: String
    @ObservedObject private var store = SettingsStore.shared
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            // 已拒绝 / 受限：系统**不会再弹授权窗** → 直接跳 App 的系统设置，让用户自行重新授权。
            // `.unknown`（已询问过、但系统不公开结论，如 HealthKit 读授权）再请求同样没用 → 一并跳设置。
            if state == .denied || state == .restricted || state == .unknown {
                openAppSettings()
                return
            }
            busy = true
            Task { @MainActor in
                let result = await PermissionManager.shared.requestPermission(permissionKey)
                busy = false
                // 只有「已拒绝 / 受限」才跳系统设置 —— 这两类系统不会再弹窗，必须让用户自己去开。
                // 不能因为"非授权"就跳：首次点击（尚未询问）会被立刻弹出到系统设置；
                // HomeKit 更把答案交给 App 回到 active 后结算（见 resolveHomeKitAskIfNeeded）。
                if result == .denied || result == .restricted {
                    openAppSettings()
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if busy { ProgressView().scaleEffect(0.7) }
                PermissionBadgeView(state: state)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private var state: PermissionState {
        switch permissionKey {
        case "health", "healthData": return store.settings.permissions.healthKit
        case "homeKit":              return store.settings.permissions.homeKit
        default:                     return .notDetermined
        }
    }
}

// MARK: - 控制 · 健康（HealthKit）二级页

/// 健康能力二级页：系统授权状态 + 「允许 AI 读取」/「允许 AI 写入」两个总闸。
/// 控制页只放入口，开关一律收在本页（2026-09-18 结构要求：控制项严格进二级菜单）。
struct HealthCapabilitySettingsView: View {
    var body: some View {
        Form {
            Section {
                CapabilityAuthorizationRow(permissionKey: "healthData",
                                          title: String(localized: "health_data_section"))
            } footer: {
                Text(String(localized: "health_data_capability_detail"))
            }

            Section {
                CapabilityToggleRow(title: String(localized: "allow_health_read"),
                                    keyPath: \DefaultSettings.healthReadEnabled)
            } footer: {
                Text(String(localized: "allow_health_read_footer"))
            }

            Section {
                CapabilityToggleRow(title: String(localized: "allow_health_write"),
                                    keyPath: \DefaultSettings.healthWriteEnabled)
            } footer: {
                Text(String(localized: "allow_health_write_footer"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "health_capability_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await MainActor.run { PermissionManager.shared.refreshStatuses() } }
        // 用 didBecomeActive（而非 willEnterForeground）：从系统授权弹窗或系统设置返回时**只触发前者**，
        // 否则用户在设置里改完回来，徽标不会刷新。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            PermissionManager.shared.refreshStatuses()
        }
    }
}

// MARK: - 控制 · 家庭（HomeKit）二级页

/// 家庭能力二级页：系统授权状态 + 「允许 AI 读取」/「允许 AI 控制」两个总闸。
struct HomeCapabilitySettingsView: View {
    var body: some View {
        Form {
            Section {
                CapabilityAuthorizationRow(permissionKey: "homeKit",
                                          title: String(localized: "home_accessories"))
            } footer: {
                Text(String(localized: "home_accessories_capability_detail"))
            }

            Section {
                CapabilityToggleRow(title: String(localized: "allow_home_read"),
                                    keyPath: \DefaultSettings.homeReadEnabled)
            } footer: {
                Text(String(localized: "allow_home_read_footer"))
            }

            Section {
                CapabilityToggleRow(title: String(localized: "allow_home_control"),
                                    keyPath: \DefaultSettings.homeControlEnabled)
            } footer: {
                Text(String(localized: "allow_home_control_footer"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(slot: .settings))
        .navigationTitle(String(localized: "home_capability_title"))
        .navigationBarTitleDisplayMode(.inline)
        // 只读**已缓存**的授权状态，**绝不在此创建 HMHomeManager** ——
        // 创建它会触发系统授权询问，而"打开页面"不是用户请求家庭数据的意图。
        // 真正的授权请求只发生在用户**点击「家庭配件」行**时。
        .task { await MainActor.run { PermissionManager.shared.refreshStatuses() } }
        // 用 didBecomeActive（而非 willEnterForeground）：从系统授权弹窗或系统设置返回时**只触发前者**。
        // 这里还要结算"刚发起过 HomeKit 询问但尚未落状态"的那一笔 ——
        // 系统对"用户拒绝"不给任何回调，只能在此推断（见 resolveHomeKitAskIfNeeded）。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            PermissionManager.shared.resolveHomeKitAskIfNeeded()
            PermissionManager.shared.refreshStatuses()
        }
    }
}
