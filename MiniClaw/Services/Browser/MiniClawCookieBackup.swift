import Foundation
import WebKit

private let logger = AppLogger(category: "CookieBackup")

///
///
/// Mitigation: before every browser_use / miniclaw-browser-use action (throttled
/// 1. snapshot every cookie in `WKWebsiteDataStore.default()` with its FULL
/// metadata (domain / path / expires / secure / HttpOnly), rendered as a
/// per-domain Netscape cookies.txt file (`<registrable-domain>.txt`), and
/// 2. re-inject any backed-up cookie that is no longer present in the live
/// store (the ITP-wipe recovery path). Live cookies always win over the
/// backup; expired entries are pruned.
///
///
@MainActor
final class MiniClawCookieBackup {
    public static let shared = MiniClawCookieBackup()

    public static let syncInterval: TimeInterval = 60

    public static let domainRetention: TimeInterval = 30*24*3600

    public static let maxDomains = 1000

    private var lastSyncAt: Date?
    private var syncing = false
    private var lastLoggedKeys: Set<String> = []

    private struct BackupCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Double?
        var secure: Bool
        var httpOnly: Bool

        var key: String { "\(domain)|\(path)|\(name)" }

        var logLabel: String {
            var attrs: [String] = ["len=\(value.count)"]
            if let expires {
                attrs.append("exp=\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expires)))")
            } else {
                attrs.append("SESSION")
            }
            if httpOnly { attrs.append("HttpOnly") }
            return "\(name)[\(attrs.joined(separator: " "))]"
        }

        init(name: String,value: String,domain: String,path: String,
             expires: Double?,secure: Bool,httpOnly: Bool) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expires = expires
            self.secure = secure
            self.httpOnly = httpOnly
        }

        init(from cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate?.timeIntervalSince1970
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
        }

        func toHTTPCookie() -> HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }
            return HTTPCookie(properties: properties)
        }
    }

    private var backupDirURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("BrowserCookieBackup", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    private func cookieFileURL(domain: String) -> URL {
        backupDirURL.appendingPathComponent("\(domain).txt")
    }

    private var visitMapURL: URL {
        backupDirURL.appendingPathComponent(".lastVisit.json")
    }

    private static func registrableDomain(_ domain: String) -> String {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let parts = bare.split(separator: ".")
        guard parts.count>2 else { return bare }
        return parts.suffix(2).joined(separator: ".")
    }

    public func noteVisit(url: URL?) {
        guard let host = url?.host else { return }
        let domain = Self.registrableDomain(host)
        var map = loadVisitMap()
        map[domain] = Date().timeIntervalSince1970
        persistVisitMap(map)
    }

    public func reconcileDomainAfterUserEdit(_ rawDomain: String) async {
        let key = Self.registrableDomain(rawDomain)
        let live = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let remaining = live
            .filter { Self.registrableDomain($0.domain) == key }
            .map { BackupCookie(from: $0) }
        if remaining.isEmpty {
            deleteCookieItem(domain: key)
            var visits = loadVisitMap()
            if visits.removeValue(forKey: key) != nil { persistVisitMap(visits) }
            logger.info("forgot backup for \(key) (user cleared it in Browser Settings)")
        } else {
            writeProtected(Self.renderNetscape(remaining), to: cookieFileURL(domain: key), label: "\(key).txt")
            logger.info("reconciled backup for \(key) to \(remaining.count) remaining cookie(s) after user edit")
        }
    }

    public func forgetAll() {
        try? FileManager.default.removeItem(at: backupDirURL)
        logger.info("cleared entire cookie backup (user cleared all website data)")
    }

    public func syncIfNeeded() async {
        if let last = lastSyncAt,Date().timeIntervalSince(last)<Self.syncInterval { return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        lastSyncAt = Date()

        let store = WKWebsiteDataStore.default().httpCookieStore
        let live = await store.allCookies()
        let now = Date().timeIntervalSince1970

        var visits = loadVisitMap()
        for cookie in live {
            visits[Self.registrableDomain(cookie.domain)] = now
        }
        var droppedDomains = Set(visits.filter { now-$0.value>Self.domainRetention }.keys)

        let liveDomains = Set(live.map { Self.registrableDomain($0.domain) })
        let survivors = visits.keys.filter { !droppedDomains.contains($0) }
        if survivors.count>Self.maxDomains {
            let evictable = survivors
                .filter { !liveDomains.contains($0) }
                .sorted { (visits[$0] ?? 0)<(visits[$1] ?? 0) } // oldest first
            let overflow = survivors.count-Self.maxDomains
            for domain in evictable.prefix(overflow) {
                droppedDomains.insert(domain)
            }
        }
        let expiredDomains = droppedDomains

        var merged: [String: BackupCookie] = [:]
        for entry in loadBackup() {
            if let e = entry.expires,e <= now { continue }
            if expiredDomains.contains(Self.registrableDomain(entry.domain)) { continue }
            merged[entry.key] = entry
        }
        var liveKeys = Set<String>()
        for cookie in live {
            let entry = BackupCookie(from: cookie)
            liveKeys.insert(entry.key)
            merged[entry.key] = entry
        }

        for domain in expiredDomains {
            let ageDays = Int((now-(visits[domain] ?? now))/86400)
            let reason = ageDays>Int(Self.domainRetention/86400)
                ? "unvisited \(ageDays)d"
                : "over \(Self.maxDomains)-domain cap"
            visits.removeValue(forKey: domain)
            deleteCookieItem(domain: domain)
            logger.info("dropped domain \(domain) (\(reason))")
        }
        persistVisitMap(visits)
        persistBackup(Array(merged.values))

        logBackupSummary(merged)

        var restoredCount = 0
        for (key,entry) in merged.sorted(by: { $0.key<$1.key }) where !liveKeys.contains(key) {
            guard let cookie = entry.toHTTPCookie() else {
                logger.error("failed to rebuild cookie \(key) from backup — skipping")
                continue
            }
            await store.setCookie(cookie)
            restoredCount += 1
            // 逐条 RESTORED 已删（一次恢复可达数十条，刷屏无诊断价值）；
            // 汇总行见函数尾部 "restored N missing cookie(s)"。
        }

        if restoredCount == 0 {
            logger.info("sync: \(live.count) live cookie(s) backed up, nothing to restore")
        } else {
            logger.info("sync: \(live.count) live cookie(s) backed up, restored \(restoredCount) missing cookie(s) from backup")
        }
    }

    private func logBackupSummary(_ merged: [String: BackupCookie]) {
        let keys = Set(merged.keys)
        let domains = Set(merged.values.map(\.domain))
        guard keys != lastLoggedKeys else {
            logger.info("backup unchanged: \(merged.count) cookie(s) across \(domains.count) domain(s)")
            return
        }
        lastLoggedKeys = keys

        logger.info("backup updated: \(merged.count) cookie(s) across \(domains.count) domain(s)")
        let byDomain = Dictionary(grouping: merged.values,by: \.domain)
        for (domain,entries) in byDomain.sorted(by: { $0.key<$1.key }) {
            let labels = entries.sorted { $0.name<$1.name }.map(\.logLabel)
            logger.info(" backup \(domain): \(labels.joined(separator: ", "))")
        }
    }

    private func loadBackup() -> [BackupCookie] {
        var entries: [BackupCookie] = []
        for (_,text) in allCookieFiles() {
            entries.append(contentsOf: Self.parseNetscape(text))
        }
        return entries
    }

    private func persistBackup(_ entries: [BackupCookie]) {
        let byDomain = Dictionary(grouping: entries) { Self.registrableDomain($0.domain) }
        for (domain,cookies) in byDomain {
            let text = Self.renderNetscape(cookies)
            let url = cookieFileURL(domain: domain)
            if let existing = try? String(contentsOf: url,encoding: .utf8),existing == text { continue }
            writeProtected(text, to: url, label: "\(domain).txt")
        }
        let liveNames = Set(byDomain.keys.map { "\($0).txt" })
        for (domain, _) in allCookieFiles() where !liveNames.contains("\(domain).txt") {
            try? FileManager.default.removeItem(at: cookieFileURL(domain: domain))
        }
    }

    private func allCookieFiles() -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDirURL,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        for file in files where file.pathExtension == "txt" {
            guard let text = try? String(contentsOf: file,encoding: .utf8) else {
                logger.error("backup file unreadable: \(file.lastPathComponent) — skipping")
                continue
            }
            result[file.deletingPathExtension().lastPathComponent] = text
        }
        return result
    }

    private func deleteCookieItem(domain: String) {
        try? FileManager.default.removeItem(at: cookieFileURL(domain: domain))
    }

    private func loadVisitMap() -> [String: Double] {
        guard let data = try? Data(contentsOf: visitMapURL),
              let map = try? JSONDecoder().decode([String: Double].self,from: data) else { return [:] }
        return map
    }

    private func persistVisitMap(_ map: [String: Double]) {
        guard let data = try? JSONEncoder().encode(map),
              let text = String(data: data,encoding: .utf8) else { return }
        writeProtected(text, to: visitMapURL, label: ".lastVisit.json")
    }

    private func writeProtected(_ text: String,to url: URL,label: String) {
        do {
            try text.write(to: url,atomically: true,encoding: .utf8)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch {
            logger.error("failed to persist \(label): \(error.localizedDescription)")
        }
    }

    /// domain, includeSubdomains(TRUE/FALSE), path, secure(TRUE/FALSE),
    /// expiry(unix seconds; 0 = session cookie), name, value
    private static func renderNetscape(_ cookies: [BackupCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Written by MiniClaw — do not edit while the app runs", ""]
        for c in cookies.sorted(by: { ($0.domain,$0.path,$0.name)<($1.domain,$1.path,$1.name) }) {
            let domainField = (c.httpOnly ? "#HttpOnly_" : "") + c.domain
            let includeSubdomains = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = c.secure ? "TRUE" : "FALSE"
            let expiry = c.expires.map { String(Int($0)) } ?? "0"
            lines.append([domainField,includeSubdomains,c.path,secure,expiry,c.name,c.value]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseNetscape(_ text: String) -> [BackupCookie] {
        var result: [BackupCookie] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") {
                continue // comment
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 7 else { continue }
            let expiry = Double(fields[4]) ?? 0
            var entry = BackupCookie(name: fields[5],value: fields[6],
                                     domain: fields[0],path: fields[2],
                                     expires: expiry>0 ? expiry : nil,
                                     secure: fields[3] == "TRUE",
                                     httpOnly: httpOnly)
            if fields[1] == "TRUE" && !entry.domain.hasPrefix(".") {
                entry.domain = "." + entry.domain
            }
            result.append(entry)
        }
        return result
    }
}
