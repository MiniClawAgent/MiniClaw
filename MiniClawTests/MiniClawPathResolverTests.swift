import XCTest
import Foundation
@testable import MiniClaw

/// 路径统一改造的表驱动回归测试（2026-09-13）。
///
/// 覆盖：
/// 1. 两种写法 `/var/MiniClaw/<host>/…` 与 `miniclaw://<host>/…` **必须解析成同一个值**（写法统一的核心）；
/// 2. 未知 host / 裸相对路径 / 宿主绝对路径 / 目录穿越一律 nil；
/// 3. `MiniClawHost` 的「会话独享」「Agent 可写」集合与 `SessionFileRouter.sessionSubdirs`
///    及原 `validateWrite(.agent)` 放行集合一致（回归钉子）；`subagent` 故意不在资源白名单；
/// 4. `guestPath` / `markdownURL` 序列化往返幂等，且不出现 `sessions/<uuid>`；
/// 5. `resolveAgentPath` 的兼容回落（`/var/MiniClaw/` 根、未列举 host、穿越错误类型）行为不变；
/// 6. 端到端：真实文件系统上 `.strict` 与 `.displayFallback` 都命中会话目录，文件删除后展示解析返回 nil。
@MainActor
final class MiniClawPathResolverTests: XCTestCase {

    // MARK: - 1/2 解析矩阵

    private struct ParseCase {
        let input: String
        let host: MiniClawHost?
        let relative: String?
        let note: String
    }

    func testParseMatrix() {
        let cases: [ParseCase] = [
            .init(input: "/var/MiniClaw/attachments/x.png", host: .attachments, relative: "x.png", note: "var 写法"),
            .init(input: "miniclaw://attachments/x.png", host: .attachments, relative: "x.png", note: "miniclaw 写法"),
            .init(input: "/var/MiniClaw/attachments/a/b.png", host: .attachments, relative: "a/b.png", note: "保留子目录"),
            .init(input: "/var/MiniClaw/attachments", host: .attachments, relative: "", note: "host 根"),
            .init(input: "miniclaw://unknownhost/x", host: nil, relative: nil, note: "未知 host"),
            .init(input: "attachments/x.png", host: nil, relative: nil, note: "裸相对路径"),
            .init(input: "/var/mobile/Containers/Data/Application/x/attachments/x.png", host: nil, relative: nil, note: "宿主绝对路径"),
            .init(input: "/var/MiniClaw/../../Documents/x.png", host: nil, relative: nil, note: "目录穿越（var 写法）"),
            .init(input: "miniclaw://attachments/../shared/x", host: nil, relative: nil, note: "目录穿越（miniclaw 写法)"),
            .init(input: "miniclaw://subagent/x", host: nil, relative: nil, note: "subagent 故意不在资源白名单"),
            .init(input: "/var/MiniClaw/subagent/x", host: nil, relative: nil, note: "subagent 故意不在资源白名单")
        ]
        for c in cases {
            let resource = MiniClawResource(rawValue: c.input, sessionID: UUID())
            XCTAssertEqual(resource?.host, c.host, "host 不符：\(c.note) \(c.input)")
            XCTAssertEqual(resource?.relative, c.relative, "relative 不符：\(c.note) \(c.input)")
        }
    }

    func testTwoSpellingsParseToIdenticalValue() {
        let sessionID = UUID()
        for (varPath, miniclawPath) in [
            ("/var/MiniClaw/attachments/x.png", "miniclaw://attachments/x.png"),
            ("/var/MiniClaw/attachments/a/b.png", "miniclaw://attachments/a/b.png"),
            ("/var/MiniClaw/workspace", "miniclaw://workspace"),
            ("/var/MiniClaw/shared/dir/f.txt", "miniclaw://shared/dir/f.txt")
        ] {
            let a = MiniClawResource(rawValue: varPath, sessionID: sessionID)
            let b = MiniClawResource(rawValue: miniclawPath, sessionID: sessionID)
            XCTAssertNotNil(a, varPath)
            XCTAssertEqual(a, b, "两种写法必须解析成同一个值：\(varPath) vs \(miniclawPath)")
        }
    }

    func testSharedIsNotSessionExclusive() {
        let resource = MiniClawResource(rawValue: "miniclaw://shared/x", sessionID: nil)
        XCTAssertEqual(resource?.host, .shared)
        XCTAssertEqual(resource?.host.isSessionExclusive, false)
    }

    // MARK: - 3 集合一致性（回归钉子）

    func testSessionExclusiveSetMatchesRouterSubdirs() {
        let derived = Set(MiniClawHost.allCases.filter(\.isSessionExclusive).map(\.rawValue))
        XCTAssertEqual(derived, Set(SessionFileRouter.sessionSubdirs),
                       "会话独享集合必须与 iSH 路由表 sessionSubdirs 一致")
        XCTAssertTrue(MiniClawHost.subagent.isSessionExclusive, "subagent 必须含在会话独享集合内")
    }

    func testAgentWritableSetMatchesValidateWrite() {
        let derived = Set(MiniClawHost.allCases.filter(\.isAgentWritable).map(\.rawValue))
        XCTAssertEqual(derived, ["shared", "skills", "workspace", "attachments"],
                       "Agent 可写集合必须与 validateWrite(.agent) 放行集合一致")
        XCTAssertEqual(Set(MiniClawHost.allCases.filter(\.isAgentWritableSessionExclusive).map(\.rawValue)),
                       ["workspace", "attachments"],
                       "Agent 可写的会话独享子目录应为 workspace/attachments")
    }

    func testResourceWhitelistIsNineHostsWithoutSubagent() {
        let addressable = Set(MiniClawHost.allCases.filter(\.isResolvableResource).map(\.rawValue))
        XCTAssertEqual(addressable.count, 9, "资源白名单为 9 个 host")
        XCTAssertFalse(addressable.contains("subagent"), "subagent 故意不在白名单")
    }

    // MARK: - 4 序列化往返

    func testSerializationRoundTrip() {
        let sessionID = UUID()
        for input in ["/var/MiniClaw/attachments/x.png", "miniclaw://workspace/a/b.txt",
                      "/var/MiniClaw/mounts/foo/sub", "/var/MiniClaw/attachments",
                      "/var/MiniClaw/skills/demo/SKILL.md"] {
            guard let resource = MiniClawResource(rawValue: input, sessionID: sessionID) else {
                XCTFail("应能解析：\(input)")
                continue
            }
            XCTAssertEqual(resource.guestPath, "/var/MiniClaw/" + resource.hostRelativePath, input)
            XCTAssertEqual(resource.markdownURL, "miniclaw://" + resource.hostRelativePath, input)
            XCTAssertFalse(resource.guestPath.contains("sessions/"), "模型可见路径不含 sessions/<uuid>：\(input)")
            XCTAssertEqual(MiniClawResource(rawValue: resource.guestPath, sessionID: sessionID)?.guestPath,
                           resource.guestPath, "guestPath 往返：\(input)")
            XCTAssertEqual(MiniClawResource(rawValue: resource.markdownURL, sessionID: sessionID)?.markdownURL,
                           resource.markdownURL, "markdownURL 往返：\(input)")
        }
    }

    // MARK: - 5 resolveAgentPath 兼容回落（改造前后行为一致）

    func testResolveAgentPathRootStillResolvesToFlatRoot() throws {
        // ① `/var/MiniClaw/` 根：miniclaw-debug 不传 path 时列根目录依赖它
        let root = try FileSystemManager.shared.resolveAgentPath("/var/MiniClaw/")
        XCTAssertEqual(root.standardizedFileURL.path,
                       FileSystemManager.shared.miniClawRoot.standardizedFileURL.path)
    }

    func testResolveAgentPathUnlistedHostStillFallsBackToFlat() throws {
        // ② 未列举 host（models/config/plugins…）走扁平根，行为与改造前一致
        let url = try FileSystemManager.shared.resolveAgentPath("/var/MiniClaw/models/x.json")
        XCTAssertEqual(url.standardizedFileURL.path,
                       FileSystemManager.shared.miniClawRoot
                           .appendingPathComponent("models/x.json").standardizedFileURL.path)
    }

    func testResolveAgentPathKeepsOriginalErrorTypes() {
        // ③ 穿越仍抛 .pathEscapesRoot（而非统一的 .absolutePathRequired）
        XCTAssertThrowsError(try FileSystemManager.shared.resolveAgentPath("/var/MiniClaw/../../Documents/x.png")) { error in
            guard case FileError.pathEscapesRoot = error else {
                return XCTFail("应为 pathEscapesRoot，实际 \(error)")
            }
        }
        // 非 miniclaw 形态仍抛 .absolutePathRequired
        for bad in ["attachments/x.png", "/var/mobile/Containers/Data/Application/x/attachments/x.png"] {
            XCTAssertThrowsError(try FileSystemManager.shared.resolveAgentPath(bad)) { error in
                guard case FileError.absolutePathRequired = error else {
                    return XCTFail("\(bad) 应为 absolutePathRequired，实际 \(error)")
                }
            }
        }
    }

    func testResolveMiniClawResourceURLRejectsUnknownHost() {
        XCTAssertNil(FileSystemManager.shared.resolveMiniClawResourceURL("miniclaw://unknownhost/x"))
        XCTAssertNil(FileSystemManager.shared.resolveMiniClawResourceURL("/var/mobile/Containers/x.png"))
        XCTAssertNil(FileSystemManager.shared.resolveMiniClawResourceURL("attachments/x.png"))
    }

    // MARK: - 6 端到端（真实文件系统，测完清理）

    func testStrictAndDisplayFallbackHitSessionDirectory() throws {
        let fm = FileManager.default
        let sessionID = UUID()
        // 随机文件名：确保扁平区没有同名文件，避免"回落命中扁平"造成假阳性
        let name = "e2e-\(UUID().uuidString).txt"
        let sessionDir = SessionFileRouter.sessionsHostBase
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let fileURL = sessionDir
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(name)
        // 无论断言在哪一步失败，都必须清掉本用例写下的会话目录
        defer { try? fm.removeItem(at: sessionDir) }

        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("e2e".utf8).write(to: fileURL)

        let resource = try XCTUnwrap(
            MiniClawResource(rawValue: "/var/MiniClaw/attachments/\(name)", sessionID: sessionID))

        // `.strict` → 会话目录
        let strict = try FileSystemManager.shared.url(for: resource, policy: .strict)
        XCTAssertEqual(strict.standardizedFileURL.path, fileURL.standardizedFileURL.path,
                       "strict 应落到会话目录")

        // `.displayFallback` → 同一会话目录（而不是扁平）
        let display = try XCTUnwrap(FileSystemManager.shared.resolveMiniClawResourceURL(
            "miniclaw://attachments/\(name)", sessionID: sessionID))
        XCTAssertEqual(display.standardizedFileURL.path, fileURL.standardizedFileURL.path,
                       "displayFallback 应命中会话目录")

        // 删除文件后：扁平区无同名文件 → 展示解析返回 nil
        try fm.removeItem(at: fileURL)
        XCTAssertNil(FileSystemManager.shared.resolveMiniClawResourceURL(
            "miniclaw://attachments/\(name)", sessionID: sessionID),
                     "文件删除且扁平无同名时应返回 nil")
    }
}
