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
                ContentUnavailableView {
                    Label(L10n.tr("Rootfs 未部署"), systemImage: "tray")
                } description: {
                    Text(L10n.tr("容器内文件系统尚未部署，请稍候或重启 App。"))
                }
                .navigationTitle(L10n.tr("Rootfs 管理"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.tr("完成")) { dismiss() }
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
                    .navigationTitle(L10n.tr("Rootfs 管理"))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FileBrowserLocation.self) { loc in
                        UnifiedFileBrowser(location: loc, path: $path)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.tr("完成")) { dismiss() }
                        }
                    }
            }
        }
    }
}

#endif
