import SwiftUI
import UIKit

// MARK: - Rootfs 文件管理
//
// 浏览已部署 rootfs 容器内文件系统（沙盒内 <ish-rootfs>/data，对应容器内 "/"）。
// 仅当 iSH 已集成（ISH_ENABLED）时编译——首页菜单的「Rootfs 管理」项也仅在同条件下显示。
// 内部目录浏览统一交给 UnifiedFileBrowser（含会话子树真实读取重定向、信息丰富型行样式）。

#if ISH_ENABLED

struct RootfsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FileBrowserLocation] = []

    /// rootfs 容器内根：<ish-rootfs>/data
    private static var rootBase: URL? {
        guard let deployed = try? LinuxShellRuntime.deployedRootfsURL() else { return nil }
        return deployed.appendingPathComponent("data")
    }

    var body: some View {
        NavigationStack(path: $path) {
            if RootfsManagerView.rootBase == nil {
                EmptyStateView(label: String(localized: "rootfs_not_deployed"), systemImage: "tray",
                                 description: String(localized: "the_in_container_filesystem_is_not_deployed_yet_please_wait_or_restart_the_app"))
                .navigationTitle(String(localized: "rootfs_management"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "done")) { dismiss() }
                    }
                }
            } else {
                let rootLoc = FileBrowserLocation(
                    mode: .rootfs,
                    directoryURL: RootfsManagerView.rootBase!,
                    displayGuestPath: "/",
                    sessionID: nil
                )
                UnifiedFileBrowser(location: rootLoc, path: $path)
                    .navigationTitle(String(localized: "rootfs_management"))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FileBrowserLocation.self) { loc in
                        UnifiedFileBrowser(location: loc, path: $path)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "done")) { dismiss() }
                        }
                    }
            }
        }
    }
}

#endif
