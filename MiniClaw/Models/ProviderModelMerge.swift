import Foundation

/// 拉取模型时的合并规则。
///
/// 独立成纯函数（不碰 SwiftUI、不碰 store）的唯一目的：让"刷新会不会删掉我的模型"
/// 这件事可以被单元测试直接钉住。此前这段逻辑埋在 `ProviderDetailView` 的私有方法里，
/// 只能用真机手点验证，于是同一个 bug 反复出现（自定义模型被剔除）。
enum ProviderModelMerge {

    /// 把接口返回的模型并入现有列表。
    ///
    /// 规则：
    /// 1. **接口返回的模型**：以接口为准更新元数据（上下文窗口、最大输出、深度思考、模态），
    ///    但保留用户改名（`userRenamed == true`）、用户设置过的上下文/输出上限；
    /// 2. **接口没返回的既有模型**：一律保留（并集）；包括用户手填的自定义模型、
    ///    以及服务商此次没列出的模型。理由见下方注释；
    /// 3. 同 `modelId` 去重：先出现者胜，避免 `Dictionary(uniqueKeysWithValues:)` 撞键崩溃；
    /// 4. 顺序：接口返回的按接口顺序在前，被保留的按原顺序追加在后。
    ///
    /// - Parameters:
    ///   - existing: 当前列表（用户可见的权威列表）
    ///   - fetched: 本次接口返回的模型
    ///   - providerType: 用于查模型能力目录（模态校正）
    static func merge(
        existing: [ModelConfig],
        fetched: [ModelConfig],
        providerType: ProviderType
    ) -> [ModelConfig] {
        // 去重：同一 modelId 只保留第一条（旧数据可能有重复，直接建字典会崩）
        let previousModels = Dictionary(
            existing.map { ($0.modelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fetchedIds = Set(fetched.map { $0.modelId })

        var merged: [ModelConfig] = fetched.map { incoming in
            guard var current = previousModels[incoming.modelId] else { return incoming }

            // 用户手动改过名称则不再被拉取覆盖
            if !incoming.displayName.isEmpty, current.userRenamed != true {
                current.displayName = incoming.displayName
            }
            if incoming.contextLimit > 0 {
                current.contextLimit = incoming.contextLimit
            }
            if let maxOutputTokens = incoming.maxOutputTokens {
                current.maxOutputTokens = maxOutputTokens
            }
            current.deepThinking = incoming.deepThinking
            // 模态开关统一交给 BuiltinModelInfo.reconcile（厂商适配器目录为准 + 启发式兜底），
            // 不在此处重复手写易错的重置/回填逻辑。
            let info = LLMProviderFactory.modelCapabilities(
                providerType: providerType,
                modelID: incoming.modelId
            )
            BuiltinModelInfo.reconcile(info, modelId: incoming.modelId, config: &current)
            return current
        }

        // 并集：接口这次没返回的，一律原样保留。
        //
        // 为什么不做成「只保留 isCustom 的」：历史数据里用户手加过的模型没有标记
        //（旧版 `syncModelEntries` 恒写 isCustom=false），按标记判断等于让它们再被删一次。
        // 语义定为「用户可见列表是权威，接口只做补充/更新，绝不擅自删除」；
        // 要删由用户显式删除（列表左滑 → persist → 条目随之移除）。
        // 代价：服务商下架的模型会留在列表里，需要用户自己清理（后续可加「清理失效模型」）。
        merged.append(contentsOf: existing.filter { !fetchedIds.contains($0.modelId) })
        return merged
    }
}
