import Foundation
import CFNetwork

// MARK: - 系统代理跟随（自研，P4）
//
// 背景：iSH 容器用 Darwin 原生 socket 直连，**不自动跟随 iOS 系统 HTTP 代理**——
// 用户开启代理软件（非 TUN 模式）时，App 其余网络（NSURLSession 自动跟随）正常，
// 唯独容器内 curl/apk 直连，被墙域名必挂。表象即「只有 智能体装工具出问题」。
//
// 方案（源头）：读取系统代理设置（CFNetworkCopySystemProxySettings），生成
// HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY 注入 iSH 执行器进程树，
// 使容器内命令与 App 其余网络行为一致。用户未开代理时返回空，无副作用。

enum SystemProxyStore {
    /// 当前系统代理环境变量（无代理 / 读取失败 / 代理未启用时返回空字典）。
    static var proxyEnvironment: [String: String] {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let settings = raw as? [String: Any] else {
            return [:]
        }

        let httpEnabled = (settings[kCFNetworkProxiesHTTPEnable as String] as? Bool) ?? false
        let httpHost = settings[kCFNetworkProxiesHTTPProxy as String] as? String
        let httpPort = settings[kCFNetworkProxiesHTTPPort as String] as? Int
        // iOS 只有全局 HTTP 代理（kCFNetworkProxiesHTTPS* 键在 iOS 不可用）：
        // 同一代理同时覆盖 HTTP 与 HTTPS 出站。
        let httpsEnabled = httpEnabled
        let httpsHost = httpHost
        let httpsPort = httpPort

        var env: [String: String] = [:]
        if httpEnabled, let host = httpHost, !host.isEmpty, let port = httpPort {
            let proxy = "http://\(host):\(port)"
            env["HTTP_PROXY"] = proxy
            env["http_proxy"] = proxy
        }
        if httpsEnabled, let host = httpsHost, !host.isEmpty, let port = httpsPort {
            let proxy = "http://\(host):\(port)"
            env["HTTPS_PROXY"] = proxy
            env["https_proxy"] = proxy
        }
        if !env.isEmpty {
            env["ALL_PROXY"] = env["HTTPS_PROXY"] ?? env["HTTP_PROXY"] ?? ""
            // 本地回环与内网不走代理
            env["NO_PROXY"] = "localhost,127.0.0.1,::1,.local"
            env["no_proxy"] = "localhost,127.0.0.1,::1,.local"
        }
        return env
    }
}
