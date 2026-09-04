import SwiftUI

/// 打开的 .md 文档内容查看器（独立 sheet）。
/// URL 可以是 `miniclaw://`、`/var/MiniClaw/...` 或远程 https URL。
struct MarkdownFileViewer: View {
    let sourceURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "loading"))
                } else if let errorMessage {
                    EmptyStateView(
                        label: String(localized: "cannot_load_document"),
                        systemImage: "doc.text.magnifyingglass",
                        description: errorMessage
                    )
                } else if let content {
                    ScrollView {
                        MarkdownContentView(content: content)
                            .padding()
                    }
                }
            }
            .navigationTitle(sourceURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "close")) { dismiss() }
                }
            }
        }
        .task { await loadContent() }
    }

    private func loadContent() async {
        isLoading = true
        defer { isLoading = false }

        // miniclaw:// 内部链接：先解析成本地文件 URL（防御性，正常情况下入口已解析）。
        let url: URL
        if sourceURL.scheme?.lowercased() == "miniclaw" {
            guard let resolved = FileSystemManager.shared.resolveMiniClawResourceURL(sourceURL.absoluteString) else {
                errorMessage = String(localized: "cannot_parse_link")
                return
            }
            url = resolved
        } else {
            url = sourceURL
        }

        // 本地文件（注意：必须用解析后的 url，不能用原始 sourceURL，
        // 否则 miniclaw:// 链接的解析结果会被丢弃、读取必然失败）
        if url.isFileURL {
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        // 远程文件
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            content = String(data: data, encoding: .utf8)
            if content == nil {
                errorMessage = String(localized: "unable_to_decode_file_content")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
