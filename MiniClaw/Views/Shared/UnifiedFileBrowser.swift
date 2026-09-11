import SwiftUI
import UIKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 统一文件浏览器
//
// 会话文件、Rootfs 文件、挂载文件统一为一个组件，交互参考 iOS 文件 app：
//   - 点击目录 → 进入子目录（NavigationStack push）
//   - 点击文件 → 预览（FilePreviewView）
//   - 长按任意条目 → 弹出上下文菜单（复制路径 / 复制文件 / 删除）
//   - 不使用 swipe 操作（避免与系统滑动返回冲突误触）
//   - 统一行样式：彩色图标 + 文件名 + 文件大小副标题（`.insetGrouped` 列表）

struct UnifiedFileBrowser: View {
    let location: FileBrowserLocation
    @Binding var path: [FileBrowserLocation]

    @State private var entries: [FileBrowserItem] = []
    @State private var fileToView: FileBrowserItem?
    @State private var deleteTarget: FileBrowserItem?
    @State private var errorMessage: String?
    @State private var loadError: String?
    @State private var toast: String?

    private var mode: FileBrowserMode { location.mode }
    private var directoryURL: URL { location.directoryURL }
    private var sessionID: UUID? { location.sessionID }

    // MARK: - rootfs 会话子树重定向

    /// 文件管理器统一隐藏的内部条目：
    /// - 点开头文件（.bundled-rules-manifest.json 等隐藏文件）；
    /// - `rules` 目录：项目托管规则，由 App 升级自动管理，用户误改会影响 智能体行为，
    ///   不在任何文件管理器入口显示（智能体仍可访问，规则仍随 App 升级更新）。
    private static func isHiddenEntry(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return name == "rules"
    }

    private static var rootfsRootBase: URL? {
        guard let deployed = try? LinuxShellRuntime.deployedRootfsURL() else { return nil }
        return deployed.appendingPathComponent("data")
    }

    static var isRootfsAvailable: Bool { rootfsRootBase != nil }

    /// 把「逻辑 rootfs 路径」翻译为「真实读取 URL」。
    /// 仅对 sessions 子树重定向到宿主会话根（rootfs 里只是占位节点）。
    private func resolveReadURL(_ url: URL) -> URL {
        switch mode {
        case .rootfs:
            guard let base = Self.rootfsRootBase else { return url }
            let sessionsRootfs = base.appendingPathComponent("var/MiniClaw/sessions")
            let p = url.standardizedFileURL.path
            let r = sessionsRootfs.standardizedFileURL.path
            if p == r || p.hasPrefix(r + "/") {
                let rest = String(p.dropFirst(r.count))
                let trimmed = rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
                return SessionFileRouter.sessionsHostBase.appendingPathComponent(trimmed)
            }
            return url
        default:
            return url
        }
    }

    // MARK: - guest 路径

    private var currentGuestPath: String {
        location.displayGuestPath ?? aiAccessibleGuestPath(for: directoryURL)
    }

    private func childGuestPath(for name: String) -> String? {
        if let g = location.displayGuestPath {
            return g == "/" ? "/\(name)" : "\(g)/\(name)"
        }
        return aiAccessibleGuestPath(for: directoryURL.appendingPathComponent(name))
    }

    private var showSessionsBanner: Bool {
        location.displayGuestPath?.contains("/sessions") == true
    }

    // MARK: - body

    var body: some View {
        List {
            Section {
                pathBar
            } header: {
                Text(String(localized: "current_path_agent_accessible"))
            }
            if showSessionsBanner {
                Section {
                    Label(String(localized: "the_following_are_isolated_files_for_each_session_physically_stored_in_the_host_documents_miniclaw_sessions"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entries.isEmpty {
                Section {
                    Text(loadError ?? String(localized: "empty_folder"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(directoryURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .refreshable { load() }
        .fullScreenCover(item: $fileToView) { item in
            FilePreviewView(fileURL: item.readURL)
        }
        .alert(Text(String(localized: "confirm_deletion")), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(String(localized: "delete_action"), role: .destructive) { confirmDelete() }
            Button(String(localized: "cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            if let t = deleteTarget {
                let type = t.isDir ? String(localized: "directory") : String(localized: "files")
                Text(String(localized: "will_delete") + type + "「\(t.name)」" + String(localized: "and_all_its_contents_this_action_cannot_be_undone"))
            }
        }
        .alert(Text(String(localized: "cannot_preview")), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "got_it"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: - 行渲染（iOS 文件 app 风格）

    @ViewBuilder
    private func row(for entry: FileBrowserItem) -> some View {
        HStack(spacing: 12) {
            // 左侧图标
            Image(systemName: entry.isDir ? "folder.fill" : fileIconName(for: entry.name))
                .font(.system(size: 22))
                .foregroundStyle(entry.isDir ? Color.yellow : Color.blue)
                .frame(width: 28, height: 28)

            // 文件名 + 大小
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.isDir {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 挂载模式：分享按钮
            if !entry.isDir, case .mount = mode {
                ShareLink(item: entry.readURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDir {
                path.append(childLocation(for: entry))
            } else {
                openFile(entry)
            }
        }
        .contextMenu {
            // 长按菜单：复制路径
            Button {
                copyPath(entry)
            } label: {
                Label(String(localized: "copy_path"), systemImage: "doc.on.clipboard")
            }
            // 长按菜单：复制文件（仅文件）
            if !entry.isDir {
                Button {
                    copyFile(entry)
                } label: {
                    Label(String(localized: "copy_file"), systemImage: "doc.on.doc")
                }
            }
            // 长按菜单：删除
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label(String(localized: "delete_action"), systemImage: "trash")
            }
        }
    }

    private func childLocation(for entry: FileBrowserItem) -> FileBrowserLocation {
        FileBrowserLocation(
            mode: mode,
            directoryURL: directoryURL.appendingPathComponent(entry.name),
            displayGuestPath: childGuestPath(for: entry.name),
            sessionID: sessionID
        )
    }

    // MARK: - 加载目录

    private func load() {
        loadError = nil
        let readDir = resolveReadURL(directoryURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: readDir.path) else {
            entries = []
            return
        }
        do {
            let names = try fm.contentsOfDirectory(atPath: readDir.path)
                .filter { $0 != ".DS_Store" && !Self.isHiddenEntry($0) }
            var result: [FileBrowserItem] = []
            for name in names {
                let logical = directoryURL.appendingPathComponent(name)
                let readURL = resolveReadURL(logical)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: readURL.path, isDirectory: &isDir)
                let size: UInt64 = isDir.boolValue
                    ? 0
                    : (try? fm.attributesOfItem(atPath: readURL.path)[.size] as? UInt64) ?? 0
                result.append(FileBrowserItem(id: logical,
                                             readURL: readURL,
                                             name: name,
                                             isDir: isDir.boolValue,
                                             size: size))
            }
            result.sort {
                if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            entries = result
        } catch {
            entries = []
            loadError = String(format: String(localized: "failed_to_read_directory"), error.localizedDescription)
        }
    }

    // MARK: - 操作

    private func openFile(_ entry: FileBrowserItem) {
        if case .rootfs = mode, entry.size >= 2_000_000 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
            errorMessage = String(format: String(localized: "file_too_large_to_preview"), sizeStr)
            return
        }
        fileToView = entry
    }

    private func copyPath(_ entry: FileBrowserItem) {
        let p = guestPath(for: entry.name)
        UIPasteboard.general.string = p
        showToast(String(format: String(localized: "path_copied"), p))
    }

    private func copyFile(_ entry: FileBrowserItem) {
        // iOS 文件 app 的「拷贝」行为：把文件数据按 UTI 写入剪贴板，可粘贴到其他 App。
        guard entry.size < 50_000_000 else {
            errorMessage = String(format: String(localized: "file_too_large_to_copy_to_the_clipboard"),
                                 ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
            return
        }
        // [2026-09-11 审计修复] 大文件读取移出主线程（Data(contentsOf:) 50MB 可冻结主线程数百 ms~秒级）。
        let readURL = entry.readURL
        let name = entry.name
        let uti = (try? readURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            ?? "public.data"
        Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: readURL)
            await MainActor.run {
                guard let data else {
                    showToast(String(format: String(localized: "copy_failed_format"), "read failed"))
                    return
                }
                UIPasteboard.general.setData(data, forPasteboardType: uti)
                showToast(String(format: String(localized: "copied_file"), name))
            }
        }
    }

    private func guestPath(for name: String) -> String {
        if let g = location.displayGuestPath {
            return g == "/" ? "/\(name)" : "\(g)/\(name)"
        }
        return aiAccessibleGuestPath(for: directoryURL.appendingPathComponent(name))
    }

    private func confirmDelete() {
        guard let t = deleteTarget else { return }
        do {
            try FileManager.default.removeItem(at: t.readURL)
            deleteTarget = nil
            load()
        } catch {
            deleteTarget = nil
            showToast(String(format: String(localized: "delete_failed"), error.localizedDescription))
        }
    }

    // MARK: - 路径栏 + toast

    private var pathBar: some View {
        let p = currentGuestPath
        return Text(p)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(nil)
            .onLongPressGesture {
                UIPasteboard.general.string = p
                showToast(String(format: String(localized: "path_copied"), p))
            }
    }

    private func showToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 48)
                .transition(.opacity)
        }
    }

    // MARK: - 文件图标

    private func fileIconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "mp3", "wav", "m4a", "aac":
            return "waveform"
        case "mp4", "mov", "m4v":
            return "film"
        case "md", "txt", "json", "log", "yaml", "yml", "toml", "xml",
             "csv", "sh", "py", "swift", "js", "ts", "css", "html", "h":
            return "doc.plaintext"
        case "zip", "tar", "gz", "tgz", "7z":
            return "doc.zipper"
        default:
            return "doc"
        }
    }
}

// MARK: - 路径 / 拷贝辅助（三种文件管理共用）

func aiAccessibleGuestPath(for url: URL) -> String {
    let p = url.standardizedFileURL.path
    if let g = SessionFileRouter.shared.reverseResolve(hostPath: p) { return g }
    let root = FileSystemManager.shared.miniClawRoot.standardizedFileURL.path
    if p == root { return "/var/MiniClaw" }
    if p.hasPrefix(root + "/") {
        let rel = String(p.dropFirst(root.count + 1))
        return "/var/MiniClaw/" + rel
    }
    return p
}

func uniqueCopyName(for name: String, in dir: URL) -> String {
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var i = 2
    while true {
        let cand = ext.isEmpty
            ? String(format: String(localized: "copy_of_format"), base, String(i))
            : String(format: String(localized: "copy_ext_format"), base, String(i), ext)
        if !fm.fileExists(atPath: dir.appendingPathComponent(cand).path) { return cand }
        i += 1
    }
}

