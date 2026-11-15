import Foundation
import MediaPlayer
import AVFoundation

// MARK: - 跨 actor 边界的数据

/// 统一结果。`MPMediaItem` / `MPMediaItemCollection` 不是 Sendable，
/// 输出文本在桥接层内就地组装后回传。
private struct MusicOutcome: Sendable {
    let success: Bool
    let text: String

    static func ok(_ text: String) -> MusicOutcome { MusicOutcome(success: true, text: text) }
    static func fail(_ text: String) -> MusicOutcome { MusicOutcome(success: false, text: text) }
}

// MARK: - apple-media (MediaPlayer)

/// 媒体播放工具：读取正在播放的曲目、控制系统播放器、搜索媒体库。
///
/// ## 读「正在播放」用 MPNowPlayingInfoCenter 而非 systemMusicPlayer.nowPlayingItem
/// `nowPlayingItem` 的解档会触发一次媒体库 DSID 查询，在最坏情况下能把主线程拖到
/// 看门狗超时（0x8BADF00D）。`MPNowPlayingInfoCenter` 给的是
/// 系统当前播放信息字典——读起来轻，且**对任何正在播放的 App 都有效**，
/// 而不是只认系统音乐播放器。播放状态仍取自 `systemMusicPlayer.playbackState`。
///
/// ## 明确不做的
/// - **设置系统音量**：iOS 没有公开 API（流传的 `MPVolumeView` 改 slider 属私有行为，
///   上架风险远大于收益）。`volume` 只读，给了 `level` 会明确告知。
/// - **后台播放**：本 App 不声明音频后台模式，切后台即停。
struct AppleMediaTool: AgentTool {
    let name = "apple_media"
    /// 会改变用户设备上的播放状态，重试前必须经用户确认。
    let resumePolicy: ResumePolicy = .requiresUserConfirmation

    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple_media",
            description: String(localized: "music_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "op_music_actions"),
                        enum: ["now_playing", "play", "pause", "toggle", "next", "previous", "volume", "search", "play_search"]
                    ),
                    "query": JSONSchema.JSONProperty(type: "string", description: String(localized: "search_keyword_alt")),
                    "media_type": JSONSchema.JSONProperty(
                        type: "string",
                        description: String(localized: "param_music_type"),
                        enum: ["song", "album", "artist", "playlist"]
                    ),
                    "level": JSONSchema.JSONProperty(type: "number", description: String(localized: "param_volume_level")),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: String(localized: "param_result_limit")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String else {
            throw ToolError.invalidParameters(String(localized: "err_missing_action"))
        }

        switch action {
        case "now_playing", "play", "pause", "toggle", "next", "previous", "volume":
            let outcome = await MusicBridge.control(action,
                                                    level: Self.double(parameters["level"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "search":
            guard let query = Self.string(parameters["query"]), !query.isEmpty else {
                return ToolResult(success: false, text: String(localized: "music_need_query"))
            }
            let outcome = await MusicBridge.search(query: query,
                                                   type: Self.string(parameters["media_type"]),
                                                   limit: Self.int(parameters["limit"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        case "play_search":
            guard let query = Self.string(parameters["query"]), !query.isEmpty else {
                return ToolResult(success: false, text: String(localized: "music_need_query"))
            }
            let outcome = await MusicBridge.playSearch(query: query,
                                                       type: Self.string(parameters["media_type"]))
            return ToolResult(success: outcome.success, text: outcome.text)

        default:
            return ToolResult(success: false, text: String(localized: "music_unknown_action") + action)
        }
    }
}

// MARK: - 入参摊平

extension AppleMediaTool {
    private static func string(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - MainActor 桥接层

/// MediaPlayer 的对象都不是 Sendable，且播放器状态必须在主线程读取，
/// 故统一收在 MainActor 内。
@MainActor
private enum MusicBridge {
    private static var player: MPMusicPlayerController { .systemMusicPlayer }

    // MARK: 播放控制 / 状态读取

    static func control(_ action: String, level: Double?) async -> MusicOutcome {
        switch action {
        case "play":
            player.play()
            return .ok(String(localized: "music_play_started"))
        case "pause":
            player.pause()
            return .ok(String(localized: "music_pause_done"))
        case "toggle":
            let paused = player.playbackState == .playing
            if paused { player.pause() } else { player.play() }
            return .ok(String(localized: "music_toggle_done") + (paused ? String(localized: "music_state_paused") : String(localized: "music_state_playing")))
        case "next":
            player.skipToNextItem()
            return .ok(String(localized: "music_next_done"))
        case "previous":
            player.skipToPreviousItem()
            return .ok(String(localized: "music_previous_done"))
        case "volume":
            // iOS 没有公开的「设置系统音量」API，只读是可为、写入不可为
            if level != nil { return .fail(String(localized: "music_volume_readonly")) }
            let value = AVAudioSession.sharedInstance().outputVolume
            return .ok(String(localized: "music_volume_label") + String(format: "%.0f%%", value * 100))
        default:
            return nowPlaying()
        }
    }

    /// 正在播放的曲目。无曲目时明确说「没有」，避免模型自己脑补。
    ///
    /// 不标 `async`：读取播放信息字典与播放器状态都是同步的主线程操作，
    /// 标了反而要调用方补无意义的 `await`。
    static func nowPlaying() -> MusicOutcome {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        guard let info, !info.isEmpty else {
            return .ok(String(localized: "music_no_track") + String(localized: "music_state_label") + stateName(player.playbackState))
        }
        var lines: [String] = [String(localized: "music_now_playing_header")]
        if let title = info[MPMediaItemPropertyTitle] as? String, !title.isEmpty {
            lines.append(String(localized: "music_title_label") + title)
        }
        if let artist = info[MPMediaItemPropertyArtist] as? String, !artist.isEmpty {
            lines.append(String(localized: "music_artist_label") + artist)
        }
        if let album = info[MPMediaItemPropertyAlbumTitle] as? String, !album.isEmpty {
            lines.append(String(localized: "music_album_label") + album)
        }
        if let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
           let total = info[MPMediaItemPropertyPlaybackDuration] as? Double, total > 0 {
            lines.append(String(localized: "music_progress_label") + clock(elapsed) + " / " + clock(total))
        }
        lines.append(String(localized: "music_state_label") + stateName(player.playbackState))
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: 媒体库搜索

    static func search(query: String, type: String?, limit: Int?) async -> MusicOutcome {
        guard await ensureLibraryAccess() else { return .fail(String(localized: "music_denied")) }
        let items = items(for: query, type: type)
        guard !items.isEmpty else { return .ok(String(localized: "music_search_no_result") + query) }
        let cap = max(limit ?? 20, 1)
        let shown = Array(items.prefix(cap))
        var lines: [String] = [String(localized: "music_search_header") + "\(shown.count)/\(items.count)"]
        for item in shown {
            var parts = ["- " + (item.title ?? String(localized: "unknown"))]
            if let artist = item.artist, !artist.isEmpty { parts.append(artist) }
            if let album = item.albumTitle, !album.isEmpty { parts.append(album) }
            lines.append(parts.joined(separator: " | "))
        }
        return .ok(lines.joined(separator: "\n"))
    }

    static func playSearch(query: String, type: String?) async -> MusicOutcome {
        guard await ensureLibraryAccess() else { return .fail(String(localized: "music_denied")) }
        let items = items(for: query, type: type)
        guard let first = items.first else { return .ok(String(localized: "music_search_no_result") + query) }
        // 命中不止一首时整批入队，符合「搜到什么就播什么」的直觉
        player.setQueue(with: MPMediaItemCollection(items: items))
        player.play()
        return .ok(String(localized: "music_play_started") + "\n" + String(localized: "music_title_label") + (first.title ?? String(localized: "unknown")))
    }

    // MARK: 授权

    /// 只有搜索媒体库才需要授权；读正在播放与控制播放走系统接口，不需要。
    private static func ensureLibraryAccess() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: break
        default: return false
        }
        return await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: 辅助

    private static func items(for query: String, type: String?) -> [MPMediaItem] {
        let predicate: MPMediaPropertyPredicate
        switch type {
        case "album":
            predicate = MPMediaPropertyPredicate(value: query,
                                                 forProperty: MPMediaItemPropertyAlbumTitle,
                                                 comparisonType: .contains)
        case "artist":
            predicate = MPMediaPropertyPredicate(value: query,
                                                 forProperty: MPMediaItemPropertyArtist,
                                                 comparisonType: .contains)
        default:
            predicate = MPMediaPropertyPredicate(value: query,
                                                 forProperty: MPMediaItemPropertyTitle,
                                                 comparisonType: .contains)
        }
        let base: MPMediaQuery
        switch type {
        case "album":    base = MPMediaQuery.albums()
        case "artist":   base = MPMediaQuery.artists()
        case "playlist": base = MPMediaQuery.playlists()
        default:         base = MPMediaQuery.songs()
        }
        let mediaQuery = base
        mediaQuery.addFilterPredicate(predicate)
        // 歌曲查询直接给 items；专辑/艺人/歌单返回的是集合，展开成曲目列表
        switch type {
        case "album", "artist", "playlist":
            return mediaQuery.collections?.flatMap { $0.items } ?? []
        default:
            return mediaQuery.items ?? []
        }
    }

    private static func stateName(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .playing:     return String(localized: "music_state_playing")
        case .paused:      return String(localized: "music_state_paused")
        case .stopped:     return String(localized: "music_state_stopped")
        case .interrupted: return String(localized: "music_state_interrupted")
        default:           return String(localized: "unknown")
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
