import SwiftUI

/// 通用文档展示页：从 App Bundle 的 `AboutDocs/` 目录读取指定 .md 文件，
/// 用自研 `MarkdownContentView` 渲染为可读文档。用于「关于 MiniClaw / 用户使用协议 / 用户隐私政策」等。
/// 注意：这些文档是开发者与用户的协议内容，不开放插件更改（不走 rule 插件体系）。
struct DocumentView: View {
    let filename: String
    let title: String

    @State private var content: String = ""
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError {
                ScrollView {
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ScrollView {
                    MarkdownContentView(content: content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(loadContent)
    }

    private func loadContent() {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("AboutDocs", isDirectory: true)
            .appendingPathComponent(filename),
              FileManager.default.fileExists(atPath: url.path) else {
            loadError = String(format: String(localized: "document_not_found"), filename)
            return
        }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            loadError = String(format: String(localized: "failed_to_read_document"), error.localizedDescription)
        }
    }
}
