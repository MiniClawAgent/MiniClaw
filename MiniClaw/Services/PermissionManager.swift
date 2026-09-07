import Foundation
import Network
import CoreTelephony
import Combine
import HealthKit
import EventKit
import Photos
import CoreLocation
import Speech
import UserNotifications

// MARK: - 权限管理

/// 统一管理 iOS 网络类权限的申请与状态回写。
///
/// 关于 iOS 网络权限的重要事实（避免误解）：
/// 1. **公网联网（蜂窝 / Wi-Fi）没有授权弹窗**。App 默认即可联网，系统不会像
///    通知/相机那样弹窗。但「设置 → 蜂窝网络」里该 app 的开关，是在它
///    **第一次真正发起网络请求之后**才被系统登记出来的。因此想让 app 提前
///    进入系统联网登记表（而不是等首次调模型才登记），唯一可行的做法是
///    **主动发起一次真实的轻量网络请求做预热**（见 `requestNetworkAccess`）。
/// 2. **本地网络（Local Network）有授权弹窗**，且必须由 Bonjour 浏览（NWBrowser）
///    或广播触发 —— 直接访问 127.0.0.1、局域网 IP 或公网 HTTPS 都不会弹窗
///    （见 `requestLocalNetwork`）。
final class PermissionManager: @unchecked Sendable {
    static let shared = PermissionManager()

    /// 本地网络浏览器状态收敛到该串行队列，保证对 _browser 的访问无数据竞争。
    private let queue = DispatchQueue(label: "com.neartop.miniclaw.permission")
    /// 当前活跃的本地网络浏览器（仅在该队列内访问）。
    private var _browser: NWBrowser?
    /// 蜂窝数据状态观察者（必须强持有，否则回调不触发）。仅在主线程访问。
    private var cellularData: CTCellularData?

    private init() {}

    // MARK: - 公网联网权限（点击「添加密钥」按钮时调用）

    /// 申请公网联网访问：主动触发一次真实网络请求，让系统立刻登记本 app 的联网状态，
    /// 并读取蜂窝数据授权状态写回设置。
    ///
    /// 为什么这样做：iOS 对公网联网**没有授权弹窗**；app 只有在第一次真正联网后，
    /// 才会出现在「设置 → 蜂窝网络」的 app 列表里、被系统纳入联网管理。用户观察到的
    /// 「点获取模型才申请蜂窝」正是这个机制。因此在用户点「添加密钥」按钮时就主动预热
    /// 一次连接，等于把「首次联网登记」提前到此刻，用户随后即可在设置里管理该 app 的
    /// 蜂窝/Wi-Fi 开关，而不必等到真正调模型。
    ///
    /// 需在主线程调用（通常由按钮 action 触发）。
    func requestNetworkAccess() {
        warmUpPublicConnection()
        observeCellularState()
    }

    /// 发起一次轻量公网请求（HEAD），触发系统登记 app 联网。不弹窗、不阻塞 UI。
    /// 使用 Apple 的 captive 检测端点，全球（含中国大陆）可达且轻量。
    private func warmUpPublicConnection() {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = "HEAD"
        // 结果本身无需处理：动作(发起连接)即已让系统登记 app 联网。
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// 读取蜂窝数据限制状态并写回 PermissionConfig.cellularData。
    /// CTCellularData 首次查询可能返回 unknown，之后通过 notifier 异步更新为确定值。
    private func observeCellularState() {
        let cd = CTCellularData()
        cd.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            self?.persistCellular(from: state)
        }
        cellularData = cd
        persistCellular(from: cd.restrictedState)
    }

    private func persistCellular(from state: CTCellularDataRestrictedState) {
        let mapped: PermissionState
        switch state {
        case .notRestricted:  mapped = .authorized   // 允许联网
        case .restricted:     mapped = .denied       // 用户在设置里关闭了本 app 蜂窝
        default:              mapped = .notDetermined // unknown：尚未确定，等 notifier 更新
        }
        // unknown 不覆盖已确定的历史状态，避免刚查询时把 authorized/denied 打回未知。
        DispatchQueue.main.async {
            if mapped == .notDetermined,
               SettingsStore.shared.settings.permissions.cellularData != .notDetermined {
                return
            }
            SettingsStore.shared.update(domain: .permissions, summary: String(format: String(localized: "audit_cellular"), mapped.rawValue)) { (s: inout PermissionConfig) in
                s.cellularData = mapped
            }
        }
    }

    // MARK: - 本地网络权限

    /// 触发本地网络授权对话框，并把用户选择写回 PermissionConfig.localNetwork。
    ///
    /// 行为说明（2026-09-07 修正）：
    /// - 首次调用：系统弹出「允许 MiniClaw 发现本地网络上的设备」对话框。用户回答前
    ///   浏览器停在 `.waiting`（系统挂起该操作），**弹窗本身没有超时**——因此探测必须
    ///   等至终态，不能几秒就 cancel：否则用户在第 10 秒点了「允许」，权限其实拿到了，
    ///   UI 却早已放弃等待，状态永远停在未授权。
    /// - 用户允许 → `.ready` → `authorized`；用户拒绝 → `.failed(权限类错误)` → `denied`。
    /// - 已授权/已拒绝时再次调用不会重复弹窗，仅快速回读当前状态（探测兼读状态：用户在
    ///   系统设置里开启后回到本页再点一次，即可刷新为已授权）。
    /// - **只有权限类错误才记为 denied**：无网络/飞行模式等同样会 `.failed`。此前一律
    ///   记 denied，会让「没网时点一下」被永久标成已拒绝，之后点击只显示去设置的引导，
    ///   而系统其实从未弹过窗、设置列表里也没有本 app → 用户彻底卡死。
    ///
    /// 实现细节：通过 NWBrowser 浏览自定义 Bonjour 类型 `_miniclaw._tcp`（已在
    /// Info.plist 的 `NSBonjourServices` 中声明）。即使局域网内不存在该服务，浏览动作
    /// 本身即构成「本地网络使用」，足以触发系统弹窗。
    func requestLocalNetwork() {
        queue.async { [weak self] in
            guard let self else { return }
            // 残留浏览器先清理（2026-08-08 修复：上轮请求停在 .waiting 等非终态时，
            // 后续点击被 `_browser == nil` 的 guard 挡掉，表现为「点了没任何反应」）。
            if let old = self._browser {
                old.cancel()
                self._browser = nil
            }

            let parameters = NWParameters()
            parameters.includePeerToPeer = false

            let browser = NWBrowser(
                for: .bonjour(type: "_miniclaw._tcp", domain: nil),
                using: parameters
            )

            browser.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state, browser: browser)
            }

            self._browser = browser
            browser.start(queue: self.queue)
            // 终态前不 cancel：系统弹窗没有超时，用户可能十几秒后才回答（见上面说明）。
            // 60s 仅为兜底（用户始终不理会弹窗 / 系统节流停在 .waiting）；超时不写状态，
            // 用户可再次点击重试。
            self.queue.asyncAfter(deadline: .now() + Self.localNetworkProbeTimeout) { [weak self] in
                guard let self, self._browser === browser else { return }
                self.stop(browser)
            }
        }
    }

    /// 本地网络探测超时兜底（秒）。需远大于用户阅读并回答系统弹窗的时间。
    private static let localNetworkProbeTimeout: TimeInterval = 60

    // MARK: - 内部处理

    private func handle(state: NWBrowser.State, browser: NWBrowser) {
        switch state {
        case .ready:
            // 授权成功：浏览器进入就绪态。
            persistLocalNetwork(.authorized)
            stop(browser)
        case .failed(let error):
            // 仅权限类错误（EPERM/EACCES）才判定为「用户拒绝」并持久化。其余（无网络、
            // 飞行模式、DNS 不可达等）不写状态：误标成 denied 后用户再点只会被引导去
            // 系统设置，而那里根本没有本 app 的开关，等于把人卡死。
            if Self.isPermissionDenied(error) {
                persistLocalNetwork(.denied)
            }
            stop(browser)
        default:
            // .setup / .waiting / .cancelled 均不写状态，等待终态。
            break
        }
    }

    /// 是否为「本地网络权限被拒」的错误。系统未授予权限时 NWBrowser 以
    /// POSIX EPERM/EACCES 失败；无网络等情况则是其他错误码。
    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EPERM || code == .EACCES
        }
        return false
    }

    private func stop(_ browser: NWBrowser) {
        browser.cancel()
        if self._browser === browser {
            self._browser = nil
        }
    }

    /// 将本地网络权限状态持久化到设置（主线程写入）。
    private func persistLocalNetwork(_ state: PermissionState) {
        DispatchQueue.main.async {
            SettingsStore.shared.update(domain: .permissions, summary: String(format: String(localized: "audit_local_network"), state.rawValue)) { (s: inout PermissionConfig) in
                s.localNetwork = state
            }
        }
    }

    // MARK: - 系统权限：状态查询（不弹窗）

    /// 进入「权限与后台」页时调用：在不弹窗的前提下，读取各权限当前系统授权状态并回写配置，
    /// 使右侧徽标显示真实授权情况（而非永远停留在「未授权」）。
    @MainActor
    func refreshStatuses() {
        writePermission { p in
            p.location          = Self.locationStatus()
            p.calendar          = Self.ekStatus(.event)
            p.reminders         = Self.ekStatus(.reminder)
            p.photoLibrary      = Self.photosStatus()
            p.microphone        = Self.micStatus()
            p.speechRecognition = Self.speechStatus()
            p.healthKit         = Self.healthStatus()
            // homeKit 无系统查询 API；pasteboard 视为始终可用（由视图单独处理），两者保持原值。
        }
    }

    private static func locationStatus() -> PermissionState {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        case .denied, .restricted:                    return .denied
        default:                                      return .notDetermined
        }
    }

    private static func ekStatus(_ type: EKEntityType) -> PermissionState {
        switch EKEventStore.authorizationStatus(for: type) {
        case .authorized, .fullAccess: return .authorized
        case .denied, .restricted:     return .denied
        default:                       return .notDetermined
        }
    }

    private static func photosStatus() -> PermissionState {
        let s: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch s {
        case .authorized, .limited: return .authorized
        case .denied, .restricted:  return .denied
        default:                    return .notDetermined
        }
    }

    private static func micStatus() -> PermissionState {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .authorized
        case .denied:  return .denied
        default:       return .notDetermined
        }
    }

    private static func speechStatus() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:         return .authorized
        case .denied, .restricted: return .denied
        default:                  return .notDetermined
        }
    }

    /// 健康数据授权状态。
    ///
    /// **iOS 不提供读授权的查询能力**：为防止「用授权状态反推用户健康状况」的侧信道，
    /// 系统对**只读类型**的 `authorizationStatus(for:)` 永远返回 `.sharingDenied`，
    /// 哪怕用户刚刚点了允许——旧实现据此判断会永远显示「未授权」，属假阴性。
    /// 故此处不再查询系统，只返回本 App 记录的「是否已请求过」：
    /// `.authorized` = 已向用户弹过授权页（不代表用户同意读取），
    /// `.notDetermined` = 从未请求。实际能否读到数据由查询时的返回结果决定。
    private static func healthStatus() -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        return SettingsStore.shared.settings.permissions.healthKit
    }

    // MARK: - 系统权限：申请（弹系统对话框）

    /// 申请某项权限（在 App 内弹系统对话框）。返回最终状态，调用方据返回值决定是否跳转系统设置。
    /// - Parameter key: 权限键（health / healthData / calendar / photos / location / homeKit / microphone / speech）。
    @MainActor
    func requestPermission(_ key: String) async -> PermissionState {
        let state: PermissionState
        switch key {
        case "health", "healthData": state = await requestHealth()
        case "calendar":             state = await requestEK(.event)
        case "reminders":            state = await requestEK(.reminder)
        case "photos":               state = await requestPhotos()
        case "location":             state = await requestLocation()
        case "microphone":           state = await requestMic()
        case "speech":               state = await requestSpeech()
        case "localNetwork":         state = SettingsStore.shared.settings.permissions.localNetwork // 无系统查询 API，返回配置域持久化状态
        case "homeKit":              state = .notDetermined // HomeKit 无独立授权弹窗，由调用方跳设置
        default:                     state = .notDetermined
        }
        writePermission { p in
            switch key {
            case "health", "healthData": p.healthKit = state
            case "calendar":            p.calendar = state
            case "reminders":           p.reminders = state
            case "photos":              p.photoLibrary = state
            case "location":            p.location = state
            case "microphone":          p.microphone = state
            case "speech":              p.speechRecognition = state
            case "localNetwork":        p.localNetwork = state
            case "homeKit":             p.homeKit = state
            default: break
            }
        }
        return state
    }

    /// 申请健康数据授权。**只申请读，不申请写** —— 写授权在用户开启
    /// 「设置 → 通用 → 允许 AI 写入健康数据」后，由 apple-healthkit 的 write / delete
    /// 按需申请：写入弹窗对用户更敏感，不应在权限页首次授权时就一并索要。
    private func requestHealth() async -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        // 与工具内部共用 HealthKitAuthGate：iOS 同一时刻只接受一个授权请求。
        let completed = await HealthKitAuthGate.shared.request(read: AppleHealthKitTool.readableTypes, share: [])
        // completed 仅表示授权流程正常结束，不代表用户已授权（读授权不可探测）。
        return completed ? .authorized : .denied
    }

    private func requestEK(_ type: EKEntityType) async -> PermissionState {
        let store = EKEventStore()
        return await withCheckedContinuation { cont in
            if #available(iOS 17.0, *), type == .event {
                store.requestFullAccessToEvents { granted, _ in cont.resume(returning: granted ? .authorized : .denied) }
            } else if #available(iOS 17.0, *), type == .reminder {
                store.requestFullAccessToReminders { granted, _ in cont.resume(returning: granted ? .authorized : .denied) }
            } else {
                store.requestAccess(to: type) { granted, _ in cont.resume(returning: granted ? .authorized : .denied) }
            }
        }
    }

    private func requestPhotos() async -> PermissionState {
        await withCheckedContinuation { cont in
            if #available(iOS 14, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                    cont.resume(returning: (st == .authorized || st == .limited) ? .authorized : .denied)
                }
            } else {
                PHPhotoLibrary.requestAuthorization { st in
                    cont.resume(returning: st == .authorized ? .authorized : .denied)
                }
            }
        }
    }

    private func requestLocation() async -> PermissionState {
        // 轮询兜底（2026-08-08）：CLLocationManager 的 delegate 回调在部分 iOS 版本/场景下
        // 弹窗响应后延迟或丢失（用户点「允许」后 UI 菊花卡死、只有重进页面才恢复）。
        // 每秒轮询一次系统授权状态，非 notDetermined 即完成；10s 未响应返回当前状态，
        // 保证调用方 busyKey 一定被清理。delegate 回调保留（更快，正常路径毫秒级完成）。
        let mapStatus: @Sendable (CLAuthorizationStatus) -> PermissionState = { s in
            switch s {
            case .authorizedWhenInUse, .authorizedAlways: return .authorized
            case .denied, .restricted:                    return .denied
            default:                                      return .notDetermined
            }
        }
        return await withCheckedContinuation { cont in
            let box = LocationResumeBox(cont: cont)
            let requester = LocationAuthRequester()
            requester.completion = { s in box.finish(mapStatus(s)) }
            locationRequesters.append(requester)
            requester.start()
            let pollTask = Task { @MainActor in
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let s = CLLocationManager().authorizationStatus
                    if s != .notDetermined { box.finish(mapStatus(s)); return }
                }
                // 10s 用户仍未响应弹窗：返回当前状态，避免调用方菊花永久卡死。
                box.finish(mapStatus(CLLocationManager().authorizationStatus))
            }
            _ = pollTask // 任务自持运行，无需保留
        }
    }

    /// 一次性 resume 容器：delegate 回调与轮询兜底都可能触发完成，保证只 resume 一次（线程安全）。
    private final class LocationResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let cont: CheckedContinuation<PermissionState, Never>
        init(cont: CheckedContinuation<PermissionState, Never>) { self.cont = cont }
        func finish(_ state: PermissionState) {
            lock.lock()
            if didResume { lock.unlock(); return }
            didResume = true
            lock.unlock()
            cont.resume(returning: state)
        }
    }

    private func requestMic() async -> PermissionState {
        await withCheckedContinuation { cont in
            // 统一使用 AVAudioSession.requestRecordPermission（completion handler 版本），
            // 避免 AVAudioApplication.requestRecordPermission（async/await）的恢复点
            // 不在 GCD 主队列上导致 _dispatch_assert_queue_fail 崩溃。
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted ? .authorized : .denied)
            }
        }
    }

    private func requestSpeech() async -> PermissionState {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized ? .authorized : .denied)
            }
        }
    }

    // MARK: - 通知权限

    /// 同步读取当前通知授权状态（用于后台页 UI 展示：已授权→显示开关；否则显示「未授权」）。
    var notificationAuthorized: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// 申请通知授权，返回是否授权成功。
    @discardableResult
    func requestNotification() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - 定位状态（供后台页复用，与权限列表一致）

    /// 同步读取定位授权状态（后台页「定位权限」行复用）。
    func locationState() -> PermissionState {
        Self.locationStatus()
    }

    // MARK: - 内部辅助

    /// 把权限状态写回配置域（主线程写入）。
    private func writePermission(_ mutate: (inout PermissionConfig) -> Void) {
        SettingsStore.shared.update(domain: .permissions, summary: String(localized: "audit_refresh_permissions")) { (s: inout PermissionConfig) in
            mutate(&s)
        }
    }

    /// 保持 CLLocationManager 存活直到授权回调，避免被释放导致回调丢失。
    private var locationRequesters: [LocationAuthRequester] = []

    /// 包装 CLLocationManager 授权请求：通过代理异步拿到最终授权状态。
    private class LocationAuthRequester: NSObject, CLLocationManagerDelegate {
        var completion: ((CLAuthorizationStatus) -> Void)?
        private var manager: CLLocationManager?

        func start() {
            let m = CLLocationManager()
            m.delegate = self
            manager = m
            m.requestWhenInUseAuthorization()
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let s = manager.authorizationStatus
            guard s != .notDetermined else { return }
            completion?(s)
            self.manager = nil
        }
    }
}
