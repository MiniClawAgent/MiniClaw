import SwiftUI

/// 通用文档展示页：从 App Bundle 的 `BundledRules/` 目录读取指定 .md 文件，
/// 用自研 `MarkdownContentView` 渲染为可读文档。用于「关于 MiniClaw / 用户使用协议 / 用户隐私政策」等。
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
            .appendingPathComponent("BundledRules", isDirectory: true)
            .appendingPathComponent(filename),
              FileManager.default.fileExists(atPath: url.path) else {
            loadError = String(format: L10n.tr("无法定位文档：%@"), filename)
            return
        }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            loadError = String(format: L10n.tr("文档读取失败：%@"), error.localizedDescription)
        }
    }
}
