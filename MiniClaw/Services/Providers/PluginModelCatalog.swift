import Foundation

// MARK: - 插件模型目录（模型能力数据 + 厂商行为声明的单一事实来源）
//
// 2026-09-01 起，厂商适配器零数据零兜底（唐唐拍板），model 插件包的 providers.json
// 承载两类声明，本类型聚合查询：
// - `models`：模型能力数据（`modelCapabilities(providerType:modelID:)` 精确匹配，
//   匹配不到返回 nil，调用方按默认值处理；不兜底、不猜测）
// - `behavior`：厂商行为声明（能力标志/思考参数映射/采样约束），由 OpenAI 兼容基类
//   通用执行器消费，替代原厂商薄壳适配器的覆写（薄壳已删除）
// - 内置无任何厂商预设；`apigateway` 仅协议网关模板（无厂商数据）。
// - 同一 providerType 多包声明时按目录序合并（模型后写覆盖同 modelId；行为取首个非 nil）。
//
// 缓存策略：按「全部 providers.json 的 path+mtime+size」指纹自失效——插件导入/删除/
// 启停（目录内容变化）后下一次查询自动重建，无需插件生命周期代码手动通知。
// 缓存状态收纳进锁保护的实例：Swift 6 下 static var 属非隔离全局可变状态不被允许，
// 「static let 常量 + @unchecked Sendable 实例 + NSLock」为标准并发安全模式。

enum PluginModelCatalog {

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [ProviderType: Entry] = [:]
        private var fingerprint: String = ""

        /// 指纹命中返回缓存；否则在锁内重建。
        func load(fingerprint fp: String, build: () -> [ProviderType: Entry]) -> [ProviderType: Entry] {
            lock.lock(); defer { lock.unlock() }
            if fp == fingerprint { return cache }
            let built = build()
            cache = built
            fingerprint = fp
            return built
        }
    }

    /// 单个 providerType 的聚合视图。
    struct Entry {
        var models: [String: BuiltinModelInfo] = [:]
        var behavior: ProviderBehaviorDecl? = nil
    }

    /// 聚合已安装 model 插件的全部声明。
    static func catalog() -> [ProviderType: Entry] {
        let fs = FileSystemManager.shared
        var items: [(path: String, mtime: Date, size: Int)] = []
        for dir in fs.allPluginDirectories() {
            let p = dir.appendingPathComponent("providers.json")
            if let attr = try? FileManager.default.attributesOfItem(atPath: p.path),
               let mtime = attr[.modificationDate] as? Date,
               let size = attr[.size] as? Int {
                items.append((p.path, mtime, size))
            }
        }
        let fp = items
            .map { "\($0.path)|\($0.mtime.timeIntervalSince1970)|\($0.size)" }
            .sorted()
            .joined(separator: "\n")

        return store.load(fingerprint: fp) {
            var result: [ProviderType: Entry] = [:]
            for it in items.sorted(by: { $0.path < $1.path }) {
                guard let data = FileManager.default.contents(atPath: it.path),
                      let decls = try? JSONDecoder().decode([ModelPluginProviderDecl].self, from: data)
                else { continue }
                for decl in decls {
                    guard let pt = ProviderType(flexibleID: decl.providerType) else { continue }
                    var entry = result[pt] ?? Entry()
                    for m in decl.models ?? [] where !m.modelId.isEmpty {
                        entry.models[m.modelId] = Self.info(from: m)
                    }
                    if entry.behavior == nil { entry.behavior = decl.behavior }
                    result[pt] = entry
                }
            }
            return result
        }
    }

    /// 能力精确匹配（对齐原适配器 `builtinModels[modelID]` 语义）。
    static func modelCapabilities(providerType: ProviderType, modelID: String) -> BuiltinModelInfo? {
        catalog()[providerType]?.models[modelID]
    }

    /// 厂商行为声明（OpenAI 兼容族基类消费；该 providerType 无声明时返回 nil = 基类默认行为）。
    static func behavior(providerType: ProviderType) -> ProviderBehaviorDecl? {
        catalog()[providerType]?.behavior
    }

    // MARK: - 声明 → 能力信息 映射

    /// ModelPluginModelDecl → BuiltinModelInfo。文本输入/输出是基线模态，
    /// 声明未提及（nil）时视为开启；未声明任何模态标志时数组为 nil（UI 走默认）。
    private static func info(from m: ModelPluginModelDecl) -> BuiltinModelInfo {
        BuiltinModelInfo(
            displayName: m.displayName,
            contextWindow: m.contextLimit,
            maxOutputTokens: m.maxOutputTokens,
            deepThinking: m.deepThinking,
            input: inputModalities(m),
            output: outputModalities(m),
            apiFormats: m.apiFormats,
            responsesSupported: m.responsesSupported,
            specialConstraints: m.specialConstraints,
            pricing: m.pricing
        )
    }

    private static func inputModalities(_ m: ModelPluginModelDecl) -> [String]? {
        guard m.inputImage != nil || m.inputAudio != nil || m.inputVideo != nil || m.inputText != nil
        else { return nil }
        var out: [String] = []
        if m.inputText ?? true { out.append("text") }
        if m.inputImage == true { out.append("image") }
        if m.inputAudio == true { out.append("audio") }
        if m.inputVideo == true { out.append("video") }
        return out
    }

    private static func outputModalities(_ m: ModelPluginModelDecl) -> [String]? {
        guard m.outputImage != nil || m.outputAudio != nil || m.outputText != nil
        else { return nil }
        var out: [String] = []
        if m.outputText ?? true { out.append("text") }
        if m.outputImage == true { out.append("image") }
        if m.outputAudio == true { out.append("audio") }
        return out
    }
}
