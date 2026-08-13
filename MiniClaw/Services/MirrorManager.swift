import Foundation

// MARK: - 包管理器镜像源管理（自研，P3 扩展：Alpine APK / Python Pip / Node.js npm）
//
// 背景：容器内包管理器默认走国外源（Alpine 官方 CDN / pypi.org / registry.npmjs.org），
// 国内移动网络直连慢/不稳，智能体装工具易超时失败。三类包管理器各有独立配置文件，
// 统一由本管理器：候选源列表 + 连通性探测（HEAD，按延迟排序）+ 一键应用 + 持久化。

/// 单个候选镜像源。
struct MirrorEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// 基础 URL：apk 为镜像根（拼 /alpine/{v}/main）；pip/npm 为完整可用 URL。
    let url: String
}

/// 探测结果（含延迟毫秒，供 UI 展示）。
struct MirrorProbeResult: Equatable {
    let entry: MirrorEntry
    let latencyMs: Int
}

/// 镜像源类型：三类包管理器各自的配置机制、候选源、探测目标。
enum MirrorKind: String, CaseIterable, Identifiable {
    case apk
    case pip
    case npm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apk: return "Alpine APK"
        case .pip: return "Python Pip"
        case .npm: return "Node.js npm"
        }
    }

    var icon: String {
        switch self {
        case .apk: return "shippingbox"
        case .pip: return "wind"
        case .npm: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var footer: String {
        switch self {
        case .apk: return L10n.l("mirror_apk_desc")
        case .pip: return L10n.l("mirror_pip_desc")
        case .npm: return L10n.l("mirror_npm_desc")
        }
    }

    /// 候选源（顺序即 UI 展示顺序；探测后按实测延迟重排展示标注）。
    var mirrors: [MirrorEntry] {
        switch self {
        case .apk:
            return [
                MirrorEntry(id: "aliyun", name: "阿里云（中国）", url: "https://mirrors.aliyun.com"),
                MirrorEntry(id: "tuna", name: "清华 TUNA（中国）", url: "https://mirrors.tuna.tsinghua.edu.cn"),
                MirrorEntry(id: "ustc", name: "中科大（中国）", url: "https://mirrors.ustc.edu.cn"),
                MirrorEntry(id: "tencent", name: "腾讯云（中国）", url: "https://mirrors.cloud.tencent.com"),
                MirrorEntry(id: "huawei", name: "华为云（中国）", url: "https://repo.huaweicloud.com"),
                MirrorEntry(id: "official", name: "官方 CDN（全球）", url: "https://dl-cdn.alpinelinux.org"),
                MirrorEntry(id: "rwth", name: "RWTH（德国·欧洲）", url: "https://ftp.halifax.rwth-aachen.de"),
                MirrorEntry(id: "leaseweb", name: "LEASEWEB（英国·欧洲）", url: "https://mirror.leaseweb.com"),
                MirrorEntry(id: "jaist", name: "JAIST（日本·亚洲）", url: "https://ftp.jaist.ac.jp/pub/Linux"),
                MirrorEntry(id: "kakao", name: "Kakao（韩国·亚洲）", url: "https://mirror.kakao.com"),
            ]
        case .pip:
            return [
                MirrorEntry(id: "aliyun", name: "阿里云（中国）", url: "https://mirrors.aliyun.com/pypi/simple/"),
                MirrorEntry(id: "tuna", name: "清华 TUNA（中国）", url: "https://pypi.tuna.tsinghua.edu.cn/simple/"),
                MirrorEntry(id: "ustc", name: "中科大（中国）", url: "https://mirrors.ustc.edu.cn/pypi/web/simple"),
                MirrorEntry(id: "tencent", name: "腾讯云（中国）", url: "https://mirrors.cloud.tencent.com/pypi/simple/"),
                MirrorEntry(id: "huawei", name: "华为云（中国）", url: "https://repo.huaweicloud.com/repository/pypi/simple/"),
                MirrorEntry(id: "official", name: "官方 PyPI（全球）", url: "https://pypi.org/simple/"),
            ]
        case .npm:
            return [
                MirrorEntry(id: "npmmirror", name: "npmmirror（中国）", url: "https://registry.npmmirror.com/"),
                MirrorEntry(id: "huawei", name: "华为云（中国）", url: "https://repo.huaweicloud.com/repository/npm/"),
                MirrorEntry(id: "tencent", name: "腾讯云（中国）", url: "https://mirrors.cloud.tencent.com/npm/"),
                MirrorEntry(id: "official", name: "官方 npm（全球）", url: "https://registry.npmjs.org/"),
            ]
        }
    }

    /// 列表/当前源展示用的完整地址（apk 是镜像根，拼上 /alpine/ 与图片口径一致）。
    func displayURL(for entry: MirrorEntry) -> String {
        switch self {
        case .apk:
            return entry.url + "/alpine/"
        case .pip, .npm:
            return entry.url
        }
    }

    /// 默认源 id（未选择过时的兜底）。
    fileprivate var defaultID: String {
        switch self {
        case .apk: return "official"
        case .pip: return "official"
        case .npm: return "official"
        }
    }

    // MARK: 持久化 key

    fileprivate var selectionKey: String { "miniclaw.mirror.\(rawValue).selected" }
    fileprivate var probeKey: String { "miniclaw.mirror.\(rawValue).probe" }

    // MARK: 探测 / 写入

    /// 探测目标 URL（**真实使用路径**，与包管理器实际请求一致）：
    /// - apk：APKINDEX.tar.gz 真实索引文件（目录根 HEAD/GET 常被 429/405 拒绝）；
    /// - pip：真实包目录（华为云等对 simple 根 429、对包路径 200）；
    /// - npm：registry 标准探测端点 /-/ping。
    func probeURL(for entry: MirrorEntry, version: String?) -> URL? {
        switch self {
        case .apk:
            return URL(string: "\(entry.url)/alpine/\(version ?? "v3.21")/main/aarch64/APKINDEX.tar.gz")
        case .pip:
            let base = entry.url.hasSuffix("/") ? entry.url : entry.url + "/"
            return URL(string: base + "pip/")
        case .npm:
            let base = entry.url.hasSuffix("/") ? entry.url : entry.url + "/"
            return URL(string: base + "-/ping")
        }
    }

    /// 生成的配置文件内容（写入 guest 路径）。
    func configContent(entry: MirrorEntry, version: String?) -> String {
        switch self {
        case .apk:
            let v = version ?? "v3.21"
            return """
            \(entry.url)/alpine/\(v)/main
            \(entry.url)/alpine/\(v)/community
            """
        case .pip:
            let host = (URL(string: entry.url)?.host) ?? entry.url
            return """
            [global]
            index-url = \(entry.url)
            trusted-host = \(host)
            """
        case .npm:
            return "registry=\(entry.url)"
        }
    }

    /// guest 侧配置文件的宿主路径。
    func guestConfigPath(rootfs: URL) -> URL {
        switch self {
        case .apk:
            return rootfs.appendingPathComponent("data/etc/apk/repositories")
        case .pip:
            return rootfs.appendingPathComponent("data/root/.pip/pip.conf")
        case .npm:
            return rootfs.appendingPathComponent("data/root/.npmrc")
        }
    }

    /// 当前 Alpine 版本（仅 apk 需要；pip/npm 无版本概念）。
    func currentVersion() -> String? {
        guard self == .apk else { return nil }
        guard let url = try? MirrorManager.guestConfigURL(for: .apk),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let match = content.range(of: #"alpine/v\d+\.\d+"#, options: .regularExpression) else {
            return "v3.21"
        }
        return String(content[match].dropFirst("alpine/".count))
    }
}

/// 镜像源管理（自研）：探测、应用、持久化。三类源共用一套机制。
enum MirrorManager {
    /// 未部署 rootfs 时切换镜像源是无意义的（guest 配置不存在），
    /// 且会在宿主磁盘创建整棵 data/etc/apk 垃圾目录树，先拦截。
    static func ensureDeployed() throws {
        guard LinuxShellRuntime.isRootfsDeployed else {
            throw MirrorError.rootfsNotDeployed
        }
    }
    /// 当前选择的镜像（默认官方）。
    static func current(for kind: MirrorKind) -> MirrorEntry {
        let id = UserDefaults.standard.string(forKey: kind.selectionKey) ?? kind.defaultID
        return kind.mirrors.first { $0.id == id } ?? kind.mirrors.last!
    }

    /// 最近一次探测结果（[id: 延迟ms]；未探测过为空）。
    static func lastProbe(for kind: MirrorKind) -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: kind.probeKey) as? [String: Int] ?? [:]
    }

    /// 探测全部候选源（GET + Range，兼容 HEAD 被拒的源；失败记录为 -1）。
    /// - Returns: 可达源按延迟升序；不可达源也写入持久化（-1），UI 显示「超时」而非「未测试」。
    static func probe(_ kind: MirrorKind) async -> [MirrorProbeResult] {
        let version = kind.currentVersion()
        let results = await withTaskGroup(of: (MirrorEntry, Int).self) { group in
            for entry in kind.mirrors {
                group.addTask {
                    let ms = await Self.probeOne(kind, entry: entry, version: version)
                    return (entry, ms)  // -1 = 不可达
                }
            }
            var collected: [(MirrorEntry, Int)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        let reachable = results
            .filter { $0.1 >= 0 }
            .sorted { $0.1 < $1.1 }
            .map { MirrorProbeResult(entry: $0.0, latencyMs: $0.1) }
        // 记录全部结果（含失败 -1），UI 行尾能区分「超时」与「未测试」。
        var dict: [String: Int] = [:]
        for (entry, ms) in results { dict[entry.id] = ms }
        UserDefaults.standard.set(dict, forKey: kind.probeKey)
        return reachable
    }

    /// 单源探测：真实路径 GET(Range)，失败返回 -1。npm 探测端点 404 时回落根路径。
    private static func probeOne(_ kind: MirrorKind, entry: MirrorEntry, version: String?) async -> Int {
        guard let url = kind.probeURL(for: entry, version: version) else { return -1 }
        if let ms = await probeGET(url) { return ms }
        if kind == .npm, let base = URL(string: entry.url), let ms = await probeGET(base) {
            return ms
        }
        return -1
    }

    /// GET + Range(0-1023)：与真实下载路径一致（HEAD 常被镜像 405/403 拒绝）。
    /// 2xx/3xx 视为可达并返回耗时 ms；否则 nil。
    private static func probeGET(_ url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<400).contains(code) {
                return Int(Date().timeIntervalSince(start) * 1000)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// guest 配置文件的宿主路径。
    static func guestConfigURL(for kind: MirrorKind) throws -> URL {
        let rootfs = try LinuxShellRuntime.deployedRootfsURL()
        return kind.guestConfigPath(rootfs: rootfs)
    }

    /// 应用镜像源：写入 guest 配置文件，持久化选择。
    /// - Returns: 写入的文件内容（供 UI/日志展示）。
    @discardableResult
    static func apply(_ kind: MirrorKind, id: String) throws -> String {
        guard let entry = kind.mirrors.first(where: { $0.id == id }) else {
            throw MirrorError.unknownSource(id)
        }
        try ensureDeployed()
        let version = kind.currentVersion()
        let content = kind.configContent(entry: entry, version: version)
        let url = try guestConfigURL(for: kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(id, forKey: kind.selectionKey)
        return content
    }
}

/// 镜像源错误。
enum MirrorError: LocalizedError {
    case rootfsNotDeployed
    case unknownSource(String)

    var errorDescription: String? {
        switch self {
        case .rootfsNotDeployed:
            return L10n.l("mirror_rootfs_not_deployed")
        case .unknownSource(let id):
            return String(format: L10n.l("mirror_unknown_source"), id)
        }
    }
}
