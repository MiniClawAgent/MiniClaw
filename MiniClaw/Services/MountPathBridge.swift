import Foundation

// MARK: - C ↔ Swift 桥接（供 MiniClawiSH.m 在 iSH boot 末尾调用）
//
// 以下函数以 @_cdecl 暴露为 C 符号，由 iSH 内核侧（C）在 boot 末尾直接调用：
//   - miniclaw_mount_placeholder_reconcile：按当前挂载表对齐占位目录
//   - miniclaw_mount_mirror_initial_sync：触发双向镜像初始同步

/// 对应 C 侧 `extern void miniclaw_mount_placeholder_reconcile(void)`。
/// 在 iSH boot 末尾触发一次占位目录全量对账。
@_cdecl("miniclaw_mount_placeholder_reconcile")
public func miniclaw_mount_placeholder_reconcile() {
    MountPlaceholderSyncer.shared.reconcile()
}

/// 对应 C 侧 `extern void miniclaw_mount_mirror_initial_sync(void)`。
/// 在 iSH boot 末尾、占位对账之后触发一次双向镜像初始同步，
/// 确保 iSH 访问前沙盒内镜像已就绪（外部 → 镜像）。
@_cdecl("miniclaw_mount_mirror_initial_sync")
public func miniclaw_mount_mirror_initial_sync() {
    MountMirrorManager.shared.syncEnabledNow()
}
