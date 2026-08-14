import Foundation

// MARK: - 文件导入辅助

func decodeProviderFile(_ url: URL) -> LLMProvider? {
    guard url.startAccessingSecurityScopedResource() else { return nil }
    defer { url.stopAccessingSecurityScopedResource() }
    do {
        let data = try Data(contentsOf: url)
        var p = try JSONDecoder().decode(LLMProvider.self, from: data)
        p.id = UUID()
        return p
    } catch {
        return nil
    }
}
