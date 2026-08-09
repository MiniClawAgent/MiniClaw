import Foundation

// MARK: - SyncBootstrap

/// 同步系统启动注册。在 App 启动时调用一次，注册所有 hydrator 和 transport。
/// 对齐 SyncV2Bootstrap。
enum SyncBootstrap {
    /// 一次性注册所有同步组件。在 MiniClawApp.onAppear 或 scenePhase 变化时调用。
    @MainActor
    static func setup() {
        let core = SyncCore.shared

        // 1. 注册所有 Syncable 类型到全局注册表
        SyncedTypesBootstrap.registerAll()

        // 2. 注册 hydrator
        core.registerHydrator(ProviderConfigHydrator())
        core.registerHydrator(EnvVarHydrator())
        core.registerHydrator(SessionHydrator())
        core.registerHydrator(SoulHydrator())
        core.registerHydrator(MemoryHydrator())
        core.registerHydrator(SkillHydrator())

        // 3. CloudKit transport — 仅当 entitlements 声明了 CloudKit 时才注册。
        //    CKContainer(identifier:) 在无 CloudKit entitlement 时触发 fatal error（非可抛 Error，
    //    failable init 捕获不住），导致 App 启动即崩。2026-08-03 已从 entitlements 移除 CloudKit。
        //    后续重做 iCloud 同步时：① entitlements 加回 CloudKit；② 模型适配 CloudKit 规则；
    //    ③ 此处取消守卫恢复注册。
        AppLogger.shared.info("SyncBootstrap: CloudKit transport skipped (iCloud sync disabled)")

        AppLogger.shared.info("SyncBootstrap: setup complete")
    }

    /// 根据用户设置启动或停止同步。
    @MainActor
    static func startIfNeeded() {
        let config = SettingsStore.shared.settings.sync
        guard config.iCloudEnabled else {
            AppLogger.shared.info("SyncBootstrap: iCloud disabled by user")
            return
        }

        Task {
            // 确保 zone 存在
            if let transport = SyncCore.shared.transports.first as? CloudKitTransport {
                do {
                    try await transport.ensureZoneExists()
                } catch {
                    AppLogger.shared.error("Failed to ensure zone: \(error.localizedDescription)")
                }
            }
            await SyncCore.shared.start()
        }
    }
}
