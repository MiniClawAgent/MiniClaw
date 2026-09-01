import Foundation

// MARK: - 插件模型目录（模型能力数据的单一事实来源）
//
// 2026-09-01 起，模型能力数据不再内嵌于厂商适配器（各适配器的 builtinModels 已删除，
// 适配器瘦身仅保留请求行为），统一由 model 插件包的 providers.json 声明承载：
// - 内置 8 家厂商各有一个 com.miniclaw.builtin.<vendor> 包（project.yml 逐文件登记）；
// - 第三方 model 插件包按同一格式提供新厂商的模型数据，无需改代码；
// - 同一 providerType 有多个包声明时按目录序合并（后写覆盖同 modelId）。
//
// 消费点：
// - `modelCapabilities(providerType:modelID:)`：拉取到的模型 ID 与插件声明精确匹配，
//   匹配不到返回 nil（调用方按默认值处理；不兜底、不猜测——唐唐 2026-09-01 拍板）。
//
// 缓存策略：按「全部 providers.json 的 path+mtime+size」指纹自失效——插件导入/删除/
// 启停（目录内容变化）后下一次查询自动重建，无需插件生命周期代码手动通知。

enum PluginModelCatalog {

    private static let lock = NSLock()
    private static var cache: [ProviderType: [String: BuiltinModelInfo]] = [:]
    private static var fingerprint: String = ""

    /// 聚合已安装 model 插件的模型声明。
    static func catalog() -> [ProviderType: [String: BuiltinModelInfo]] {
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

        lock.lock(); defer { lock.unlock() }
        if fp == fingerprint { return cache }

        var result: [ProviderType: [String: BuiltinModelInfo]] = [:]
        for it in items.sorted(by: { $0.path < $1.path }) {
            guard let data = FileManager.default.contents(atPath: it.path),
                  let decls = try? JSONDecoder().decode([ModelPluginProviderDecl].self, from: data)
            else { continue }
            for decl in decls {
                guard let pt = ProviderType(flexibleID: decl.providerType) else { continue }
                var bucket = result[pt] ?? [:]
                for m in decl.models ?? [] where !m.modelId.isEmpty {
                    bucket[m.modelId] = Self.info(from: m)
                }
                result[pt] = bucket
            }
        }
        cache = result
        fingerprint = fp
        return result
    }

    /// 能力精确匹配（对齐原适配器 `builtinModels[modelID]` 语义）。
    static func modelCapabilities(providerType: ProviderType, modelID: String) -> BuiltinModelInfo? {
        catalog()[providerType]?[modelID]
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
