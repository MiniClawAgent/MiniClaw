import Foundation

/// DeepSeek Files API 客户端（官方文档 2026-09 版）。
///
/// 官方推荐的图片传递三种方式：base64 内联（计入 48MiB 请求体限制）、
/// 外部 URL、**Files API `file_id` 引用**（不占请求体、单图最大 64MiB）。
/// 工具产出的截图以 `file_id` 引用是 HTTP 413（请求体过大）的官方解法。
///
/// - 上传：`POST {base}/files`，multipart/form-data，
///   `purpose=user_data`、`expires_after`（默认 30 天，防止配额堆积）。
/// - 引用：消息 content 块 `{"type":"file","file_id":"file-api-..."}`。
/// - 配额：单用户 25 GiB / 10000 文件；JPEG/PNG/GIF/WebP；单文件 ≤64MiB。
enum DeepSeekFilesClient {

    struct UploadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 上传 JPEG 图片，返回 `file_id`（形如 `file-api-...`）。
    /// - Parameters:
    ///   - baseURL: 端点 base（如 `https://api.deepseek.com`），仅取 scheme+host。
    ///   - apiKey: DeepSeek API Key。
    ///   - jpeg: JPEG 二进制数据。
    ///   - filename: 上传文件名（仅标识用途）。
    ///   - expiresInDays: 有效期天数（1~30）；到期自动清理，防止 25GiB 配额堆积。
    static func uploadJPEG(baseURL: String,
                           apiKey: String,
                           jpeg: Data,
                           filename: String = "miniclaw-screenshot.jpg",
                           expiresInDays: Int = 30) async throws -> String {
        let boundary = "miniclaw-\(UUID().uuidString)"
        let crlf = "\r\n"

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\(crlf)Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)\(value)\(crlf)".utf8))
        }
        // 官方表单字段：purpose 必须为 user_data；expires_after 可选（防配额堆积）
        appendField("purpose", "user_data")
        appendField("expires_after[anchor]", "created_at")
        appendField("expires_after[seconds]", String(min(max(expiresInDays, 1), 30) * 86_400))
        body.append(Data("--\(boundary)\(crlf)Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)Content-Type: image/jpeg\(crlf)\(crlf)".utf8))
        body.append(jpeg)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))

        // base 仅取 scheme+host：官方 Files 端点挂在裸域根路径（/files）
        guard let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host,
              let filesURL = URL(string: "\(scheme)://\(host)/files") else {
            throw UploadError(message: "invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: filesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError(message: "invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw UploadError(message: "HTTP \(http.statusCode) \(snippet)")
        }

        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any],
              let fileId = dict["id"] as? String, !fileId.isEmpty else {
            throw UploadError(message: "upload response missing id: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        return fileId
    }
}
