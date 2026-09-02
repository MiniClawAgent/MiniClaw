import Foundation

// MARK: - 供应商适配协议(参考 LLMProvider 设计,融合 MiniClaw 需求)
//
// 设计原则:
// 1. 薄协议:适配器只负责「认证 + 请求构造 + 流式解析 + 能力声明」,传输层质量
//    (Data 级行缓冲/收尾残留处理/[DONE] 完整性判定/session 生命周期)由基类保证。
// 2. 每厂商一个文件:加新供应商 = 新建一个文件实现本协议 + 工厂注册一行;
//    OpenAI 兼容厂商继承 OpenAIProviderAdapter 只覆写差异(同款模式)。
// 3. 能力声明:参数适配走 capabilities,不支持的参数显式拒绝而非静默丢弃。
// 4. iCloud 同步预备:ProviderType 增加 .unsupported + decoded()(见 SettingsModels),
//    同步来的旧实例/未知厂商不会因解码失败而丢配置。

/// 供应商能力声明:该厂商支持什么。
struct ProviderCapabilities: Sendable {
    /// 是否支持 response_format(JSON 输出等)
    var supportsResponseFormat: Bool = false
    /// 是否支持并行工具调用
    var supportsParallelToolCalls: Bool = false
    /// 是否支持 seed
    var supportsSeed: Bool = false
    /// 是否支持服务端提示词缓存(Anthropic cache_control 等)
    var supportsPromptCaching: Bool = false
    /// 是否支持推理/思考输出(reasoning_content / thinking)
    var supportsReasoning: Bool = false
    /// 支持的输入模态(文本恒支持)
    var supportedInputModalities: Set<String> = ["text"]
}

/// 流式事件(适配器产出,LLMClient 桥接给上层回调)。
enum LLMStreamEvent: Sendable {
    case token(String)
    case reasoning(String)
    case toolCall(ToolCall)
    /// 工具参数流式增量（模型正在生成 tool_use 参数）：partialArgs 为累计的部分 JSON。
    case toolCallStreaming(id: String, name: String, partialArgs: String, bytes: Int)
    case usage(prompt: Int, completion: Int, cachedRead: Int, cachedWrite: Int)
    case finishReason(String?)
}

/// 流式请求参数包(与 LLMClient.streamChat 的参数面对齐)。
struct LLMStreamRequest: Sendable {
    var model: String
    var messages: [ChatCompletionMessage]
    var tools: [ToolSchema]?
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var reasoningEffort: String?
    /// 思考/深度档位:字符串语义与引擎一致(nil=跟随默认,"off"=关闭,档位值=深度)。
    /// 各适配器按官方参数映射(Anthropic effort、Gemini thinkingLevel、智谱 thinking 开关)。
    var thinkingLevel: String?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var seed: Int?
    var responseFormat: ResponseFormat?
    var parallelToolCalls: Bool?
    var stream: Bool = true
}

/// 流式句柄:任务句柄(供取消)+ 事件流。
struct LLMStreamHandle {
    let task: URLSessionDataTask
    let events: AsyncThrowingStream<LLMStreamEvent, Error>
}

// MARK: - 内置模型目录
//
// 模型维护并入厂商适配器文件:每个适配器携带该厂商的内置模型能力目录(编译期,静态),
// 取代旧的 model_catalog.json 种子 + ModelCatalog 运行时档案机制。
// 模型列表从 API 拉取后,按 providerType 找到适配器,以模型名查询能力;
// 目录未收录的模型走名称启发式兜底(推理模型/语音模型识别),保证未知模型可用。

/// 单条模型能力记录。字段均为可选,缺失表示「未知」,由名称启发式兜底。
/// 字段清单对齐「模型适配资料完整」纪律(铁律 2):模型 ID/显示名、context、maxOutput、
/// 思考与档位、模态、支持的 API 格式、模型级 Responses 支持、缓存、特殊约束、知识截止、定价。
struct BuiltinModelInfo: Sendable, Equatable {
    /// 显示名称(可选,留空则回退模型 ID)。
    var displayName: String?
    /// 上下文窗口(词元 数)。
    var contextWindow: Int?
    /// 单次最大输出 词元 数。
    var maxOutputTokens: Int?
    /// 是否支持深度思考 / 推理。
    var deepThinking: Bool?
    /// 深度思考可选档位(省略时 UI 用默认 [low, medium, high, xhigh, max])。
    var thinkingLevels: [String]?
    /// 输入模态 词元:text / image / audio / video / file。
    var input: [String]?
    /// 输出模态 词元:text / image / audio。
    var output: [String]?
    /// 支持的 API 格式(如 ["chat/completions", "responses", "anthropic"])。
    var apiFormats: [String]?
    /// 模型级是否支持 Responses API(与 apiFormats 互补;DeepSeek 仅 v4-flash)。
    var responsesSupported: Bool?
    /// 特殊参数约束(思考模式禁用的参数、回传要求等,文本说明)。
    var specialConstraints: String?
    /// 知识截止日期(官网公布时填写)。
    var knowledgeCutoff: String?
    /// 定价说明(每百万 token,官网公布时填写)。
    var pricing: String?

    init(displayName: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
         deepThinking: Bool? = nil, thinkingLevels: [String]? = nil,
         input: [String]? = nil, output: [String]? = nil,
         apiFormats: [String]? = nil, responsesSupported: Bool? = nil,
         specialConstraints: String? = nil, knowledgeCutoff: String? = nil,
         pricing: String? = nil) {
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.deepThinking = deepThinking
        self.thinkingLevels = thinkingLevels
        self.input = input
        self.output = output
        self.apiFormats = apiFormats
        self.responsesSupported = responsesSupported
        self.specialConstraints = specialConstraints
        self.knowledgeCutoff = knowledgeCutoff
        self.pricing = pricing
    }
}

// MARK: - ModelConfig 模态工具(迁移自旧 ModelCatalog,单一实现)

extension BuiltinModelInfo {
    /// 由 ModelConfig 的布尔开关生成输入模态 词元 数组(仅含 text 时返回 nil)。
    static func inputTokens(from c: ModelConfig) -> [String]? {
        var t = ["text"]
        if c.inputImage { t.append("image") }
        if c.inputAudio { t.append("audio") }
        if c.inputVideo { t.append("video") }
        return t.count > 1 ? t : nil
    }

    static func outputTokens(from c: ModelConfig) -> [String]? {
        var t = ["text"]
        if c.outputImage { t.append("image") }
        if c.outputAudio { t.append("audio") }
        return t.count > 1 ? t : nil
    }

    /// 由模态 词元 数组回填 ModelConfig 的布尔开关。
    static func applyModalities(_ tokens: [String]?, to c: inout ModelConfig) {
        guard let tokens else { return }
        for tk in tokens {
            switch tk {
            case "text", "file", "document": c.inputText = true
            case "image": c.inputImage = true
            case "audio": c.inputAudio = true
            case "video": c.inputVideo = true
            default: break
            }
        }
    }

    static func applyOutputModalities(_ tokens: [String]?, to c: inout ModelConfig) {
        guard let tokens else { return }
        for tk in tokens {
            switch tk {
            case "text": c.outputText = true
            case "image": c.outputImage = true
            case "audio": c.outputAudio = true
            default: break
            }
        }
    }

    /// 纯语音模型名称启发式(迁移自旧 ModelCatalog.applyVoiceModelHeuristic,语义一致):
    /// TTS(文本进/音频出)与 ASR(音频进/文本出)按方向修正文本模态。
    static func applyVoiceModelHeuristic(modelId: String, to config: inout ModelConfig) {
        let s = modelId.lowercased()
        let isTTS = s.contains("tts") || s.contains("vits") || s.contains("vocoder")
            || s.contains("cosyvoice") || s.contains("fish-speech") || s.contains("seed-tts")
            || s.contains("openvoice") || s.contains("bark") || s.contains("musicgen")
            || s.contains("audiocraft") || s.contains("sambert") || s.contains("speech")
            || s.contains("voice") || s.contains("wav2vec") || s.contains("paraformer")
            || s.contains("funasr")
        let isASR = s.contains("asr") || s.contains("stt") || s.contains("whisper")
            || s.contains("speech-to-text") || s.contains("speech-recognition")
        guard isTTS || isASR else { return }
        config.inputText = false
        config.outputText = false
        config.inputAudio = false
        config.outputAudio = false
        if isTTS {
            config.inputText = true
            config.outputAudio = true
        } else {
            config.inputAudio = true
            config.outputText = true
        }
    }

    /// 单一权威入口:用能力信息校正 ModelConfig 的模态开关(迁移自旧 ModelCatalog.reconcileModalities)。
    /// 规则:能力条目(适配器目录)有模态标注时以条目为准(重置全部模态后回填);
    /// 无标注时按名称语音启发式修正;否则保留原值。
    static func reconcile(_ info: BuiltinModelInfo?, modelId: String, config: inout ModelConfig) {
        guard let info, info.input != nil || info.output != nil else {
            applyVoiceModelHeuristic(modelId: modelId, to: &config)
            return
        }
        config.inputText = false; config.inputImage = false; config.inputAudio = false; config.inputVideo = false
        config.outputText = false; config.outputImage = false; config.outputAudio = false
        if let inTok = info.input, !inTok.isEmpty { applyModalities(inTok, to: &config) }
        if let outTok = info.output, !outTok.isEmpty { applyOutputModalities(outTok, to: &config) }
    }
}

/// 供应商适配器协议。
protocol LLMProviderAdapter: Sendable {
    /// 适配器名称(日志/诊断)。
    var name: String { get }
    /// 能力声明。
    var capabilities: ProviderCapabilities { get }

    /// 发起流式请求:构造(认证+URL+Body)→ 发送 → 解析 SSE → 产出事件流。
    /// 实现方必须保证:任何路径(成功/失败/取消)事件流必然终结(finish),绝不挂死;
    /// 服务端终帧缺失视为截断错误(LLMError.streamTruncated),不静默当成功。
    func streamChat(request: LLMStreamRequest) -> LLMStreamHandle

    /// 非流式请求(标题生成/上下文压缩等)。默认实现基于 streamChat 收集首段文本。
    func sendChat(request: LLMStreamRequest) async throws -> String

    /// HTTP 错误分类(状态码 + 响应体 → 语义化错误;无法识别返回 nil 由调用方兜底)。
    func classifyHTTPError(statusCode: Int, body: String) -> LLMError?
}

extension LLMProviderAdapter {
    /// 默认非流式实现:复用流式链路,累积全部 词元 直至完成。
    func sendChat(request: LLMStreamRequest) async throws -> String {
        var req = request
        req.stream = false
        let handle = streamChat(request: req)
        var output = ""
        do {
            for try await event in handle.events {
                if case .token(let t) = event { output += t }
            }
        } catch {
            throw error
        }
        return output
    }
}
