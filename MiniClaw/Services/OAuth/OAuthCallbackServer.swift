import Foundation
import os.log

private let logger = Logger(subsystem: "com.neartop.miniclaw", category: "OAuthCallback")

/// Result from an OAuth callback containing the authorization code and state.
struct OAuthCallbackResult: Sendable {
    let code: String
    let state: String?
}

/// Minimal local HTTP server that listens for OAuth redirect callbacks.
/// Runs on localhost, parses the authorization code from the callback URL,
/// and resumes the waiting continuation.
final class OAuthCallbackServer: @unchecked Sendable {

    private let port: UInt16
    private let callbackPath: String
    private var listenSocket: Int32 = -1
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private let queue = DispatchQueue(label: "oauth.callback.server")
    private var stopped = false

    init(port: UInt16, callbackPath: String = "/callback") {
        self.port = port
        self.callbackPath = callbackPath
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthError.serverError("Failed to create socket")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw OAuthError.serverError("Failed to bind port \(port): errno \(errno)")
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw OAuthError.serverError("Failed to listen on port \(port)")
        }

        self.listenSocket = fd
        logger.info("Listening on port \(self.port)")

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.stopped else { return }
                self.stopped = true
                logger.error("Callback timeout after \(timeout)s")
                // 先清 continuation 再 resume：防回调晚到导致双重 resume（fatalError）。
                self.continuation = nil
                cont.resume(throwing: OAuthError.callbackTimeout)
            }
        }
    }

    func stop() {
        let fdToClose = listenSocket
        listenSocket = -1
        if fdToClose >= 0 {
            close(fdToClose)
            logger.info("Stopped (listen socket closed)")
        }

        queue.sync {
            let wasStopped = stopped
            stopped = true
            if !wasStopped, let cont = continuation {
                continuation = nil
                cont.resume(throwing: OAuthError.invalidCallback("OAuth callback cancelled"))
            }
        }
    }

    // MARK: - Private

    private func acceptLoop() {
        while !stopped && listenSocket >= 0 {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenSocket, sockPtr, &addrLen)
                }
            }

            guard clientFd >= 0 else { break }
            handleConnection(clientFd)
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        let lines = requestString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return }
        logger.info("Request: \(String(firstLine))")

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1])

        if path.hasPrefix(callbackPath) {
            handleCallback(fd: fd, path: path)
        } else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = response.withCString { write(fd, $0, strlen($0)) }
        }
    }

    private func handleCallback(fd: Int32, path: String) {
        guard let components = URLComponents(string: "http://localhost\(path)") else {
            sendErrorPage(fd: fd, message: "Invalid callback URL")
            return
        }

        let queryItems = components.queryItems ?? []
        let code = queryItems.first(where: { $0.name == "code" })?.value
        let state = queryItems.first(where: { $0.name == "state" })?.value

        logger.info("Callback — code present: \(code != nil), state present: \(state != nil)")

        guard let code, !code.isEmpty else {
            let errorMsg = queryItems.first(where: { $0.name == "error" })?.value ?? "No code"
            logger.error("Callback error: \(errorMsg)")
            sendErrorPage(fd: fd, message: errorMsg)
            continuation?.resume(throwing: OAuthError.invalidCallback(errorMsg))
            continuation = nil
            return
        }

        sendSuccessPage(fd: fd)

        stopped = true
        continuation?.resume(returning: OAuthCallbackResult(code: code, state: state))
        continuation = nil
    }

    private func sendSuccessPage(fd: Int32) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><title>Authorization Successful</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body { font-family: -apple-system, sans-serif; display: flex;
                   justify-content: center; align-items: center; height: 100vh;
                   margin: 0; background: #f5f5f7; }
            .card { text-align: center; padding: 40px; background: white;
                    border-radius: 16px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            h1 { color: #1a1a1a; font-size: 24px; }
            p { color: #666; margin-top: 8px; }
        </style>
        </head>
        <body>
        <div class="card">
            <h1>Authorization Successful</h1>
            <p>You can close this tab and return to the app.</p>
        </div>
        </body>
        </html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { write(fd, $0, strlen($0)) }
    }

    private func sendErrorPage(fd: Int32, message: String) {
        // 转义 HTML 特殊字符：error 来自回调 URL 查询参数（外部输入），防注入。
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        let html = "<html><body><h1>Authorization Failed</h1><p>\(escaped)</p></body></html>"
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { write(fd, $0, strlen($0)) }
    }
}
