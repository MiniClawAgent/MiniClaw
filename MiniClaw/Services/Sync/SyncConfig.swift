import Foundation

/// 同步配置常量。对齐 SyncV2Bootstrap。
enum SyncConstants {
    /// CloudKit Container ID（对齐 Apple Developer Portal 注册的 container）。
    /// ⚠️ 开源后请替换成**你自己的** container（`iCloud.com.<你的TeamID>.MiniClaw`），
    /// 否则 iCloud 同步会因无权访问而失败；不需要同步可忽略。
    static let cloudKitContainerID = "iCloud.com.LZ84D5PQ38.MiniClaw"

    /// CloudKit Shared Zone 名称（所有同步数据共享一个 zone，对齐 ）
    static let sharedZoneName = "MiniClawSync"

    /// 默认防抖延迟（秒）
    static let debounceDelay: TimeInterval = 3.0

    /// 后台发送延迟倍率
    static let backgroundSendMultiplier: TimeInterval = 4.0

    /// 蜂窝网络延迟倍率
    static let cellularSendMultiplier: TimeInterval = 2.0

    /// 最近 N 天的记忆日志参与同步
    static let memoryDailySyncWindowDays: Int = 30
}
