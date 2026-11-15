import XCTest
@testable import MiniClaw

/// 供应商模型合并规则（用户报告的「刷新后自定义模型消失」）。
///
/// 回归背景：`applyFetchedModels` 原先直接 `draft.models = fetched`，
/// 接口没返回的模型（= 用户手填的自定义模型）被整表替换掉；
/// 持久层 `syncModelEntries` 又因为 `isCustom` 恒为 false 而把它从 providers.json 删除。
final class ProviderModelMergeTests: XCTestCase {

    private func model(_ id: String, name: String = "", custom: Bool = false) -> ModelConfig {
        var m = ModelConfig()
        m.modelId = id
        m.displayName = name
        if custom { m.isCustom = true }
        return m
    }

    // MARK: - 核心：自定义模型不能被剔除

    func testCustomModelSurvivesRefresh() {
        let existing = [model("deepseek-chat"), model("my-local-model", custom: true)]
        let fetched = [model("deepseek-chat"), model("deepseek-reasoner")]

        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: fetched, providerType: .custom
        )

        XCTAssertTrue(merged.contains { $0.modelId == "my-local-model" }, "自定义模型必须保留")
        XCTAssertTrue(merged.contains { $0.modelId == "deepseek-reasoner" }, "新模型必须加入")
    }

    func testLegacyCustomModelWithoutFlagSurvives() {
        // 历史数据：用户加过、但没有 isCustom 标记
        let existing = [model("legacy-manual-model")]
        let fetched = [model("gpt-4o")]

        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: fetched, providerType: .custom
        )

        XCTAssertTrue(
            merged.contains { $0.modelId == "legacy-manual-model" },
            "没有标记的历史自定义模型也不能被删（否则等于没修）"
        )
    }

    func testEmptyFetchedListKeepsEverything() {
        let existing = [model("a"), model("b", custom: true)]
        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: [], providerType: .custom
        )
        XCTAssertEqual(merged.map(\.modelId), ["a", "b"])
    }

    // MARK: - 接口返回的模型：更新但尊重用户改动

    func testFetchedModelUpdatesContextLimit() {
        var existingModel = model("deepseek-chat")
        existingModel.contextLimit = 0
        var fetchedModel = model("deepseek-chat")
        fetchedModel.contextLimit = 128_000

        let merged = ProviderModelMerge.merge(
            existing: [existingModel], fetched: [fetchedModel], providerType: .custom
        )

        XCTAssertEqual(merged.first?.contextLimit, 128_000)
    }

    func testUserRenamedDisplayNameIsNotOverwritten() {
        var existingModel = model("deepseek-chat", name: "我的主力模型")
        existingModel.userRenamed = true
        let fetchedModel = model("deepseek-chat", name: "DeepSeek Chat")

        let merged = ProviderModelMerge.merge(
            existing: [existingModel], fetched: [fetchedModel], providerType: .custom
        )

        XCTAssertEqual(merged.first?.displayName, "我的主力模型")
    }

    func testDisplayNameUpdatedWhenUserDidNotRename() {
        let existingModel = model("deepseek-chat", name: "")
        let fetchedModel = model("deepseek-chat", name: "DeepSeek Chat")

        let merged = ProviderModelMerge.merge(
            existing: [existingModel], fetched: [fetchedModel], providerType: .custom
        )

        XCTAssertEqual(merged.first?.displayName, "DeepSeek Chat")
    }

    // MARK: - 去重与顺序

    func testDuplicateModelIdsDoNotCrash() {
        // 旧数据里可能出现同 ID 两条；建字典时若用 uniqueKeysWithValues 会直接崩
        let existing = [model("dup", name: "第一条"), model("dup", name: "第二条")]
        let fetched = [model("dup", name: "接口")]

        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: fetched, providerType: .custom
        )

        XCTAssertEqual(merged.filter { $0.modelId == "dup" }.count, 1)
    }

    func testOrderFetchedFirstPreservedAfter() {
        let existing = [model("kept", custom: true)]
        let fetched = [model("f1"), model("f2")]

        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: fetched, providerType: .custom
        )

        XCTAssertEqual(merged.map(\.modelId), ["f1", "f2", "kept"])
    }

    // MARK: - 自定义标记的延续

    func testCustomFlagPersistsWhenProviderStartsReturningIt() {
        let existing = [model("now-official", custom: true)]
        let fetched = [model("now-official")]

        let merged = ProviderModelMerge.merge(
            existing: existing, fetched: fetched, providerType: .custom
        )

        XCTAssertEqual(merged.first?.isCustom, true, "用户手动加过的模型身份不因接口收录而丢失")
    }
}
