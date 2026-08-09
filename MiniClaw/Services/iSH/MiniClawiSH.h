//
//  MiniClawiSH.h
//  MiniClaw
//
//  Minimal bridge that boots the iSH (AArch64 / asbestos) runtime inside
//  MiniClaw and exposes it to Swift. The heavy lifting (kernel, emulator,
//  filesystem) lives in the prebuilt static libraries under
//  `第三方源码/ish-arm64`; this file only wires boot order and the
//  process-exit notification that ISHShellExecutor relies on.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (on the main queue) when a guest process exits.
/// `userInfo` carries `@"pid"` (NSNumber) and `@"code"` (NSNumber).
extern NSString *const ProcessExitedNotification;

/// Boot the iSH runtime exactly once.
/// @param rootfsPath Filesystem path to the deployed rootfs directory,
///                   i.e. the directory that contains `data/` and `meta.db`.
/// @return 0 on success, or a negative errno code on failure.
int MiniClawiSHEnsureBooted(const char *rootfsPath);

/// Asynchronously prewarm the iSH runtime at App launch (non-blocking).
/// Safe to call once from the App init path. Failures are logged and will
/// be retried by the next MiniClawiSHEnsureBooted() call (resettable guard).
void MiniClawiSHPrewarmBoot(const char *rootfsPath);

/// Whether the runtime has been successfully booted.
BOOL MiniClawiSHIsBooted(void);

/// Lifecycle phase of the iSH boot, used by the Settings "Runtime Status"
/// screen to show what the runtime is actually doing under the new model
/// (rootfs deployed + kernel prewarmed at App launch, not on first command).
typedef NS_ENUM(NSInteger, MiniClawiSHBootState) {
    MiniClawiSHBootStateIdle       = 0, ///< 尚未开始（App 打开即预热，仅极短暂窗口）
    MiniClawiSHBootStatePrewarming = 1, ///< 后台预热中（App 打开后自动启动内核）
    MiniClawiSHBootStateBooted     = 2, ///< 已成功启动（init / pid 1 运行中）
    MiniClawiSHBootStateFailed     = 3, ///< 启动失败（下次执行 Shell 时会自动重试）
};

/// Query the current boot phase. Cheap, returns the last known state.
MiniClawiSHBootState MiniClawiSHGetBootState(void);

NS_ASSUME_NONNULL_END
