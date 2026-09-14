# LLM 厂商行为层（`behavior`）官方文档核对存档

本文把 7 家 LLM 厂商「OpenAI 兼容族」的 `behavior` 块**逐项核对结论**合并存档：每家的定稿 JSON、逐项官方出处（含 URL）、未确认项、表达力缺口。所有结论均以**厂商官方文档 / 官方 OpenAPI** 为依据，逐项核对日期 2026-09-14。本文只做**搬运 + 去重 + 排版**，不改写任何结论。

口径三条：

1. **范围**：只覆盖 **OpenAI 兼容族** 7 家 —— `openai` / `openrouter` / `grok`(xAI) / `deepseek` / `zhipu`(智谱 GLM) / `qwen`(通义千问) / `xiaomi`(小米 MiMo)。`anthropic` / `google` 的适配器**不接收** `behavior`，故不在本文范围。
2. **`nil` 与 `false`**：`nil` = 基类默认值；**`false` 只在官方明确说「不支持」时才写**，「官方参数表未收录」一律留 nil —— 后者属**负向依据**，正文每处均已标明。
3. **`promptCaching` 语义** = **是否支持服务端提示词缓存**（与「有没有客户端开关」无关）。

---

## 1. OpenAI

### 1.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "parallelToolCalls": true,
    "seed": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image", "audio"],
    "preserveReasoningContent": false
  },
  "extraBody": {},
  "samplingRules": {
    "disableWhenThinking": ["temperature", "top_p"],
    "temperatureRange": [0.0, 2.0]
  }
}
```

### 1.2 逐项出处表

依据范围：**仅 OpenAI 官方域名**。注：`platform.openai.com/docs/...` 现已 302 跳转到 `developers.openai.com/...`（同为 OpenAI 官方域名），下表统一给跳转后的规范 URL；官方页面自述「Markdown 版本可在页面 URL 后追加 `.md`」，本表 URL 均可加 `.md` 取到原文。

| 字段 | 结论 | 官方依据（URL + 原文摘录） |
|---|---|---|
| `capabilities.responseFormat` | `true` | https://developers.openai.com/api/reference/resources/chat ：`response_format: optional ResponseFormatText or ResponseFormatJSONSchema or ResponseFormatJSONObject`；`{ "type": "json_object" }` enables the older JSON mode…Using `json_schema` is preferred for models that support it。另见 https://developers.openai.com/api/docs/guides/structured-outputs ：「Both Structured Outputs and JSON mode are supported in the Responses API, **Chat Completions API**, Assistants API, Fine-tuning API and Batch API」。注意：`json_schema` 形式「only supported with the `gpt-4o-mini`, `gpt-4o-mini-2024-07-18`, and `gpt-4o-2024-08-06` model snapshots **and later**」（同页）——是模型级差异，厂商级填 `true` 成立。 |
| `capabilities.parallelToolCalls` | `true` | https://developers.openai.com/api/docs/guides/function-calling#parallel-function-calling ：「On supported models beginning with GPT-5, functions can be called in parallel…The model may choose to call multiple functions in a single turn. **You can prevent this by setting `parallel_tool_calls` to `false`**」（⇒ 默认可用多个调用）。字段名与类型见 https://developers.openai.com/api/reference/resources/chat ：`parallel_tool_calls: optional boolean`。**注意：官方未在任何页面写出该字段的显式默认值（"Defaults to…"）**，「默认 true」是从上面那句「要阻止就置 false」反推的，不是原文直接声明。 |
| `capabilities.seed` | `true`（仍支持，Beta） | https://developers.openai.com/api/reference/resources/chat ：`seed: optional number or null` /「This feature is in Beta. If specified, our system will make a best effort to sample deterministically…Determinism is not guaranteed」。另有专门指南章节 https://developers.openai.com/api/docs/guides/advanced-usage ：「we offer some control towards deterministic outputs by giving you access to the `seed` parameter」。**未弃用**：https://developers.openai.com/api/docs/deprecations 全文不含 `seed`/`temperature`/`top_p`/`parallel_tool_calls`/`json_object`。 |
| `capabilities.promptCaching` | `true` | 口径＝「是否支持服务端提示词缓存」。https://developers.openai.com/api/docs/guides/prompt-caching ：「**Prompt caching is enabled by default for supported OpenAI models.**」**服务端自动生效、无请求开关**（`prompt_cache_key` / `prompt_cache_options` / `prompt_cache_retention` 均为可选调优，不传也照样命中缓存）。详见第 1.5 节 (a)。 |
| `capabilities.reasoning` | `true` | https://developers.openai.com/api/docs/guides/reasoning ：`reasoning.effort` / Chat Completions 用顶层 `reasoning_effort`；https://developers.openai.com/api/reference/resources/chat ：`reasoning_effort: optional ReasoningEffort or null`「Constrains effort on reasoning for reasoning models」。 |
| `capabilities.supportedInputModalities` | `["text","image","audio"]` | https://developers.openai.com/api/reference/resources/chat ：`messages` 说明「different message types (**modalities**) are supported, like text, images, and audio」；`ChatCompletionContentPart = ChatCompletionContentPartText or ChatCompletionContentPartImage or ChatCompletionContentPartInputAudio or object { file, … }`，「Can contain text, image, or audio inputs」。音频输入另有专章 https://developers.openai.com/api/docs/guides/audio-chat-completions 。**模型级差异**：新推理模型页写「Input modalities: text, image」（如 https://developers.openai.com/api/docs/models/gpt-6-astra ），即 audio 仅部分模型（如 audio-preview 系）可用。 |
| `capabilities.preserveReasoningContent` | `false` | https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-across-calls ：「Persisted reasoning provides continuity; **it does not expose the model's raw reasoning. The reasoning items remain opaque, and the API does not return their reasoning text.**」且该机制属 Responses API（`previous_response_id` / `reasoning.context`）；https://developers.openai.com/api/docs/guides/latest-model/gpt-5.2 ：「**Passing CoT exists only in the Responses API**」。Chat Completions 的响应对象里**没有**任何 `reasoning` / `reasoning_content` 字段，只有 usage 的 `completion_tokens_details.reasoning_tokens`（https://developers.openai.com/api/reference/resources/chat ）。⇒ 带 tools 的后续请求没有任何「该回传的 reasoning_content」，显式 `false` 成立。 |
| `thinkingParam` | **不写入 JSON（表达力缺口，见第 1.4 节）** | 唯一有官方依据的是 `body="reasoning_effort"`：字段为请求体**顶层键**（https://developers.openai.com/api/reference/resources/chat 的 Body Parameters 直接列 `reasoning_effort`），且 https://developers.openai.com/api/docs/guides/reasoning 原文「Setting `reasoning.effort` (Responses) or **`reasoning_effort` (Chat Completions)** to `none` returns HTTP 400」。但 **`on`/`off` 该填什么值官方没有任何规定**，自选档位在某些模型上必然 400（详见第 1.5 节 (b)），故整块不写。 |
| `extraBody` | `{}` | OpenAI Chat Completions **没有**任何「无条件必须附带」的额外请求体字段：https://developers.openai.com/api/reference/resources/chat 全部 Body Parameters 均为 optional（`messages`/`model` 除外，属于基类已发的字段）。`prompt_cache_key`、`store`、`stream_options` 等都不是必填，故不塞进 `extraBody`。 |
| `samplingRules.disableWhenThinking` | `["temperature","top_p"]` | 三条官方依据叠加：① https://developers.openai.com/api/docs/guides/latest-model/gpt-5.2 「The following parameters are **only supported** when using GPT-5.2 with reasoning effort set to `none`: `temperature`, `top_p`, `logprobs`…Requests to GPT-5.2 or GPT-5.1 with any other reasoning effort setting, or to older GPT-5 models…that include these fields **will raise an error**.」② https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra 「**Unsupported parameters:** Remove `temperature`, `top_p`, and `top_logprobs`.」③ https://developers.openai.com/api/docs/guides/evals （Model grader constraints）：「`temperature` changes not supported for reasoning models.」 |
| `samplingRules.temperatureRange` | `[0.0, 2.0]` | https://developers.openai.com/api/reference/resources/chat ：「What sampling temperature to use, **between 0 and 2**.」（Responses 参考页同句：https://developers.openai.com/api/reference/resources/responses/methods/create ） |
| `samplingRules.topPRange` | **未确认 → 未写入 JSON** | https://developers.openai.com/api/reference/resources/chat 只写「where the model considers the results of the tokens with top_p probability mass. So 0.1 means only the tokens comprising the top 10% probability mass are considered.」——**没有给数值上下界**；Responses 参考页同样只有这句。所有示例值都是 `1`（默认观感），但这不构成范围声明。见第 1.4 节缺口 4。 |

### 1.3 未确认项（6 条）

| 未确认项 | 说明 | 我查过的页面 |
|---|---|---|
| `samplingRules.topPRange` | 官方参考页对 `top_p` **只做概率质量解释，未给数值上下界**；无法给出 [min,max] | /api/reference/resources/chat、/api/reference/resources/responses/methods/create |
| `parallel_tool_calls` 的**显式默认值** | 参考页只标 `optional boolean`，正文无 "Defaults to…"；「默认 true」是我从「要禁止就置 false」反推 | /api/reference/resources/chat、/api/docs/guides/function-calling、/api/docs/llms-full.txt 全文检索（`parallel_tool_calls` 出现 40+ 次，无默认值声明） |
| 推理模型**是否「禁止」还是「忽略」** `temperature`/`top_p` | GPT-5.2/Astra 页明确 `raise an error` / `Remove`；但**没有一句「所有 reasoning 模型一律禁止」的通用表述**，其余推理模型（o 系、gpt-5.4/5.5/5.6）是否同样报错**未确认** | /api/docs/guides/reasoning（全文无 temperature/top_p 字样）、/api/docs/models/gpt-5.5、gpt-5.6、gpt-6-astra、/api/reference/resources/chat、llms-full.txt 全文 |
| `none` 在**非 Astra** 推理模型上是否会 400 | 只知道 Astra 会 400；5.5/5.6 页把 `none` 列为 supported，但未说明具体报错行为边界 | 同上 |
| Chat Completions 下 audio **输入**支持的具体模型集合 | 官方只给「audio-preview 系可用」性质的表述，未给完整模型矩阵 | /api/reference/resources/chat、/api/docs/guides/audio-chat-completions、各模型页 |
| 官方对 `parallel_tool_calls` 是否有**模型白名单** | 指南写「On supported models beginning with GPT-5」，**未枚举白名单**，也未说明 GPT-5 以前是否完全不支持 | /api/docs/guides/function-calling |

**我查过的页面（全部为 OpenAI 官方域名）**

- https://developers.openai.com/api/reference/resources/chat （Chat Completions 参考，含所有请求/响应字段）
- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://developers.openai.com/api/docs/guides/reasoning
- https://developers.openai.com/api/docs/guides/prompt-caching
- https://developers.openai.com/api/docs/guides/structured-outputs
- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/guides/advanced-usage （seed / 可复现输出）
- https://developers.openai.com/api/docs/guides/latest-model/gpt-5.2 （parameter compatibility）
- https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra
- https://developers.openai.com/api/docs/models/gpt-5.5 、/gpt-5.6 、/gpt-6-astra
- https://developers.openai.com/api/docs/deprecations （全文无相关字段 ⇒ 未弃用）
- https://developers.openai.com/api/docs/guides/audio-chat-completions
- https://developers.openai.com/api/docs/llms-full.txt （API 文档全文导出，4.7 MB，用于全文检索 `reasoning_content` / `temperature not supported` / `parallel_tool_calls` 等）
- https://developers.openai.com/llms.txt 、https://developers.openai.com/api/docs/llms.txt （索引，用于确认无遗漏页面）

关键全文检索结果：

- `reasoning_content`：**在整份 API 文档全文导出中命中 0 次** —— OpenAI 不使用该字段名（它是 DeepSeek/some OpenAI-compatible 实现的字段名）。
- 含「temperature + not supported」的句子全库只有两处：evals 的 model grader constraints，以及 GPT-6 Astra 的 migration quickstart。

### 1.4 表达力缺口（用现有 12 个字段表达不出来的官方形态）

1. **思考强度档位**：`reasoning_effort`（low/medium/high/xhigh/max…）是强度概念，schema 里只有 `thinkingParam` 的 on/off 两档，表达不了多档。
2. **无法按模型差异化**：同一厂商不同模型 supported 集合不同（GPT-6 Astra 最低只能 `low`；GPT-5.5/5.6 还支持 `none`），厂商级单一 `thinkingParam` 无法表达。
3. **无法表达「显式关闭思考」**：语义上的关闭值 `none` 在 GPT-6 Astra 上直接 HTTP 400 ⇒ 我们只能选择不发该字段（等于用模型默认档）。
4. **`top_p` 无官方数值界** ⇒ `topPRange` 填不出来（`temperatureRange` 有「between 0 and 2」故可填）。
5. **可选服务端缓存调优参数无处安放**：`prompt_cache_key` / `prompt_cache_options` / `prompt_cache_retention` 是官方可选（非必填）字段，放 `extraBody` 会变成无条件附加、污染所有请求，现有 schema 没有「可选附加」位置。

### 1.5 补充：两个关键点的说明（原文保留）

**(a) `promptCaching` 为什么填 `true`（口径已定）**
官方原文：「Prompt caching is enabled by default for supported OpenAI models.」（https://developers.openai.com/api/docs/guides/prompt-caching 首段）——**服务端自动生效、无请求开关**。
`prompt_cache_key` / `prompt_cache_options` / `prompt_cache_retention` 都是**可选**调优项（同页「Prompt cache keys」「Cache lifetime」章节），不传也照样命中缓存，所以「有没有客户端开关」不影响结论。team-lead 已把六家口径统一为「**是否支持服务端提示词缓存**」⇒ 此处保持 `true`。

**(b) `thinkingParam` 为什么不写：`reasoning_effort` 是强度档位、不是开关**

1. `reasoning_effort` 是**强度档位**，不是布尔开关：API 参考页允许值清单为 `none, minimal, low, medium, high, xhigh, max`（https://developers.openai.com/api/reference/resources/chat ：「Currently supported values are `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`…Not all reasoning models support every value.」），文档按「用多少思考量」描述它们（https://developers.openai.com/api/docs/guides/reasoning 的 effort 表），没有任何「开关」语义。
2. 官方**未规定**「开启思考该传什么值 / 关闭思考该传什么值」——整份官方文档只在上述清单里给出「允许值集合」，从未给出「on/off 映射」。所以 `on`/`off` 两个取值是我们自己发明的，不是照官网抄的。
3. 这个「发明」会直接撞 400：官方模型页给的 supported 集合并不一致（GPT-5.5 `none/low/medium(default)/high/xhigh`；GPT-5.6 再加 `max`；GPT-6 Astra 只有 `low/medium/high/xhigh/max`，**无 `none`、无 `minimal`**，且「Setting `reasoning_effort` … to `none` returns HTTP 400」）。⇒ 任何固定的 on/off 取值都会在某些模型上失败。目标既然是「填了 key 不能直接报错」，就**宁可表达不了，也不发一个会 400 的值**，故整块删除。
4. 若将来官方出现明文「关思考应传 X / 开思考应传 Y」，按明文写回并引原句。
（各模型 supported 集合出处：https://developers.openai.com/api/docs/models/gpt-5.5 、/gpt-5.6 、/gpt-6-astra ；400 原文出处：https://developers.openai.com/api/docs/guides/reasoning 、https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra 「Limitations」）

---

## 2. OpenRouter

仅使用官方域名 `openrouter.ai`（文档站的 markdown 原文可由页面 URL 追加 `.md` 取得）。

### 2.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "parallelToolCalls": true,
    "seed": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image", "audio"],
    "preserveReasoningContent": true
  },
  "thinkingParam": {
    "body": "reasoning",
    "on": { "enabled": true },
    "off": { "effort": "none" }
  },
  "extraBody": {},
  "samplingRules": {
    "temperatureRange": [0.0, 2.0],
    "topPRange": [0.0, 1.0]
  }
}
```

### 2.2 逐项出处表

| 字段 | 结论 | 官方 URL |
|---|---|---|
| `capabilities.responseFormat` | `true`。请求体 `response_format`，支持 `{"type":"json_object"}` 与 `{"type":"json_schema","json_schema":{name,strict,schema}}`。原文："The `response_format` parameter allows you to enforce structured JSON responses from the model. OpenRouter supports two modes" | https://openrouter.ai/docs/api-reference/overview |
| `capabilities.parallelToolCalls` | `true`。原文："Key: `parallel_tool_calls` — Optional, boolean, Default: **true** … Whether to enable parallel function calling during tool use." | https://openrouter.ai/docs/api-reference/parameters |
| `capabilities.seed` | `true`。原文："Key: `seed` — Optional, integer … the inferencing will sample deterministically … Determinism is not guaranteed for some models." | https://openrouter.ai/docs/api-reference/parameters |
| `capabilities.promptCaching` | `true`（**注意语义**：缓存内容由上游各家实现并计费，OpenRouter 侧提供 provider sticky routing，并透传/翻译 `cache_control`、`prompt_cache_breakpoint`、`prompt_cache_options`；**没有** OpenRouter 自己的无条件必填请求体字段 ⇒ `extraBody` 保持空）。原文："the `cache_discount` field … "、"OpenRouter uses provider sticky routing to maximize cache hits" | https://openrouter.ai/docs/features/prompt-caching |
| `capabilities.reasoning` | `true`。统一请求参数 `reasoning`；响应里推理内容出现在 message 的 `reasoning` 字段，另有结构化 `reasoning_details`（`choices[].message.reasoning_details` / 流式 `choices[].delta.reasoning_details`）。原文："Reasoning tokens will appear in the `reasoning` field of each message, unless you decide to exclude them." | https://openrouter.ai/docs/use-cases/reasoning-tokens |
| `capabilities.supportedInputModalities` | `["text","image","audio"]`。请求体 `ContentPart = TextContent \| ImageContentPart`（`image_url`）；音频走同一端点：原文："Audio input requests use the `/api/v1/chat/completions` API with the `input_audio` content type. Audio files must be base64-encoded"（`{"type":"input_audio","input_audio":{"data":...,"format":"wav"}}`，不支持直传 URL） | 文本/图片：https://openrouter.ai/docs/api-reference/overview ；音频：https://openrouter.ai/docs/features/multimodal/audio |
| `capabilities.preserveReasoningContent` | `true`。原文："To preserve reasoning context across multiple turns, you can pass it back to the API in one of two ways: 1. `message.reasoning` (string) … 2. `message.reasoning_details` (array)"、"You can also use `reasoning_content` as an alias"；并注明"Preserving reasoning blocks is useful specifically for tool calling" | https://openrouter.ai/docs/use-cases/reasoning-tokens |
| `thinkingParam.body` | `"reasoning"`（OpenRouter Chat Completions 的真实字段名；顶层对象） | https://openrouter.ai/docs/use-cases/reasoning-tokens |
| `thinkingParam.on` | `{"enabled": true}`。原文："To enable reasoning with the default parameters: `\"enabled\": true` - Enables reasoning at the \"medium\" effort level with no exclusions." | https://openrouter.ai/docs/use-cases/reasoning-tokens |
| `thinkingParam.off` | `{"effort": "none"}`。原文："`\"effort\": \"none\"` - Disables reasoning entirely"。**⚠️ 风险项**：模型元数据 `mandatory: true` 时原文要求"When `true`, hide disable controls and do not send `effort: \"none\"` — **the model rejects it**." ⇒ 我们照官网填了这个形态，但它在 `reasoning.mandatory:true` 的模型上会**被拒请求**；使用前应读 `GET /api/v1/models` 的 `reasoning.mandatory`（`true` 时不下发该 off 值） | https://openrouter.ai/docs/use-cases/reasoning-tokens |
| `extraBody` | `{}`。官方**没有**任何"无条件必附"的请求体字段（不塞 `provider`/`session_id`/`transforms`）。 | — |
| `samplingRules.temperatureRange` | `[0.0, 2.0]`。原文："Key: `temperature` — Optional, float, 0.0 to 2.0" | https://openrouter.ai/docs/api-reference/parameters |
| `samplingRules.topPRange` | `[0.0, 1.0]`。请求模式注释 "`top_p?: number; // Range: (0, 1]`"；参数表 "Key: `top_p` — Optional, float, 0.0 to 1.0"（两处边界写法略有差异，取闭合 [0,1]） | https://openrouter.ai/docs/api-reference/overview ; https://openrouter.ai/docs/api-reference/parameters |
| `samplingRules.disableWhenThinking` | **未写入（未确认）**。官方 reasoning 页未声明开启思考后必须禁用 `temperature`/`top_p`；只说"the parameter is ignored"这类**按模型能力**的忽略行为，未与思考态绑定 | https://openrouter.ai/docs/use-cases/reasoning-tokens ; https://openrouter.ai/docs/api-reference/overview |

### 2.3 未确认项（3 条）

1. **`disableWhenThinking`**：官方未声明"思考开启时禁用 `temperature`/`top_p`"。已查：`/docs/use-cases/reasoning-tokens`、`/docs/api-reference/parameters`、`/docs/api-reference/overview`。已知的相关限制只有"按模型忽略"（如 `top_k` 对 OpenAI 模型不可用），与思考态无关 ⇒ 该字段**留空**，不猜。
2. **`promptCaching` 的落地方式未确认**：OpenRouter 无自有缓存参数；Anthropic/Gemini 系缓存需在 content block 上打 `cache_control`（属 message 结构，不在 12 字段内）。本项填 `true` 表示"该供应商链路上可用服务端缓存并可获得 `cached_tokens`/`cache_discount`"，如需精确控制请改用 message 级 `cache_control`。
3. **`thinkingParam.off` 的可用性依赖模型（风险项，见上表 ⚠️）**：`effort:"none"` 对 `mandatory: true` 模型会被拒（原文"the model rejects it"）。是否需要按 `GET /api/v1/models` 的 `reasoning.mandatory` 动态决定"能否下发 off"未确认 —— 本项已按官网原文填入，但**存在部分模型上失败的风险**，属表达力缺口（schema 无"按模型条件注入"的位置）。

### 2.4 表达力缺口

> **该家 md 未单列「表达力缺口」一节**；相关缺口原文出现在「未确认清单」第 3 条与下节，逐字保留如下。

- 未确认清单第 3 条（原文）：「……本项已按官网原文填入，但**存在部分模型上失败的风险**，属表达力缺口（schema 无"按模型条件注入"的位置）。」
- （对应上位缺口：⑤ 无法条件化 / ④ 无法按模型差异化）

**属于请求头 / 其他参数、不属这 12 个字段（不得塞进 `extraBody`，需经 `customHeaders` / 路由策略等其他通道承载）**

> 一句话：`HTTP-Referer`、`X-OpenRouter-Title`（旧名 `X-Title`）、`X-OpenRouter-Categories` 是**可选请求头**（⇒ 走 `customHeaders`）；`provider`、`session_id`、`prompt_cache_key` 是**请求体里的路由/会话策略字段**（与"厂商行为"无关）⇒ 都不属于本 schema 的 12 个字段，本块一律不写。

| 项 | 说明 | 官方 URL |
|---|---|---|
| `HTTP-Referer` | **可选请求头**（非必需），标识应用来源：原文"Identifies your app on openrouter.ai"。⇒ 经 `customHeaders` 承载，不入 `extraBody` | https://openrouter.ai/docs/api-reference/overview |
| `X-OpenRouter-Title`（旧名 `X-Title`）、`X-OpenRouter-Categories` | **可选请求头**，设置应用标题/市场分类。⇒ 经 `customHeaders` 承载，不入 `extraBody` | https://openrouter.ai/docs/api-reference/overview |
| `provider`（请求体字段） | **路由策略**（`order`/`allow_fallbacks`/`require_parameters`/`only`/`ignore`/`sort`/`quantizations`/`max_price`/`data_collection`/`zdr` 等），是"选路"，不是行为开关 ⇒ 不属这 12 个字段，由调用方按需传 | https://openrouter.ai/docs/guides/routing/provider-selection |
| `require_parameters` | 与 `disableWhenThinking` 最相关的一条：原文默认策略下"providers that don't support all the LLM parameters specified in your request can still receive the request, but will ignore unknown parameters"；`require_parameters: true` 时"the request won't even be routed to that provider"。若要求"参数必须被真正接受"，这比在本地禁用参数更符合厂商语义 | https://openrouter.ai/docs/guides/routing/provider-selection |
| `session_id` / `x-session-id` / `prompt_cache_key` | 粘性路由键（影响缓存命中），**可选**；`session_id` 也可用 `x-session-id` 请求头，≤256 字符 ⇒ 不属这 12 个字段 | https://openrouter.ai/docs/features/prompt-caching |
| `include_reasoning` | 已废弃别名（等价 `reasoning:{}` / `reasoning:{exclude:true}`），不采用 | https://openrouter.ai/docs/api-reference/parameters |

---

## 3. xAI / Grok（`grok`）

官方源：`docs.x.ai`（文档页 URL 追加 `.md` 可取 markdown 原文）+ 官方 OpenAPI `https://docs.x.ai/openapi.json`（`components.schemas.ChatRequest` / `ChoiceMessage`，机器可读，最权威）。

> **口径说明**：本家按**基类消费的 OpenAI 兼容 Chat Completions**（`POST /v1/chat/completions`）取值，字段名用该端点的真实字段名。官方已把 Chat Completions 标为 legacy：原文"Chat Completions is offered as a legacy endpoint. New features will come to the [Responses API] first."（https://docs.x.ai/developers/model-capabilities/legacy/chat-completions）。

### 3.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "parallelToolCalls": true,
    "seed": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image"]
  },
  "extraBody": {},
  "samplingRules": {
    "disableWhenThinking": ["presence_penalty", "frequency_penalty"],
    "temperatureRange": [0.0, 2.0],
    "topPRange": [0.0, 1.0]
  }
}
```

### 3.2 逐项出处表

| 字段 | 结论 | 官方 URL |
|---|---|---|
| `capabilities.responseFormat` | `true`。`response_format.type` 枚举 `text` / `json_object` / `json_schema`（`json_object` 标为 "Used for backward compatibility. Prefer to use `json_schema`"）。文档原文："use the `response_format` parameter … also accepts `\"json_object\"` … or `\"text\"` (the default)" | 结构定义：https://docs.x.ai/openapi.json ；文字：https://docs.x.ai/developers/model-capabilities/text/structured-outputs |
| `capabilities.parallelToolCalls` | `true`。OpenAPI：`parallel_tool_calls` `default: true`，"If set to false, the model can perform maximum one tool call."；指南原文："By default, parallel function calling is enabled … Disable with `parallel_tool_calls: false` in your request." | https://docs.x.ai/openapi.json ; https://docs.x.ai/developers/tools/function-calling |
| `capabilities.seed` | `true`。OpenAPI `ChatRequest.seed`（integer, int32）："our system will make a best effort to sample deterministically, such that repeated requests with the same `seed` and parameters should return the same result. Determinism is not guaranteed" | https://docs.x.ai/openapi.json |
| `capabilities.promptCaching` | `true`。原文："When consecutive requests share the same starting messages, the xAI API **automatically** caches them."；`ChatRequest.prompt_cache_key`："A stable cache key for best-effort sticky routing / prompt-cache hits across requests sharing a prompt prefix."；响应含 `prompt_tokens_details.cached_tokens` | https://docs.x.ai/developers/advanced-api-usage/prompt-caching ; https://docs.x.ai/openapi.json ; https://docs.x.ai/developers/model-capabilities/legacy/chat-completions |
| `capabilities.reasoning` | `true`（**保留；官方自相矛盾，已留档见未确认 3.3 #1**）。正向证据：OpenAPI `ChoiceMessage.reasoning_content`："The reasoning trace generated by the model."；deferred 文档原文："You can access the model's raw thinking trace via the `message.reasoning_content` of the chat completion response." | https://docs.x.ai/openapi.json ; https://docs.x.ai/developers/advanced-api-usage/deferred-chat-completions |
| `capabilities.supportedInputModalities` | `["text","image"]`（**不含 audio**）。图片：`content:[{"type":"image_url","image_url":{url,detail}}]`，限额 20MiB、`jpg/jpeg`/`png`；音频为**独立产品线**（Voice API：STT / TTS / speech-to-speech），非 Chat Completions 输入模态：原文"We have dedicated models and APIs for audio, image, and video capabilities." | https://docs.x.ai/developers/model-capabilities/legacy/chat-completions ; https://docs.x.ai/docs/models |
| `capabilities.preserveReasoningContent` | **未写入（未确认 3.3 #2）**。回传推理上下文（`include: ["reasoning.encrypted_content"]`）在参数映射表中标注为 Responses API 独有（Chat Completions 列为 `—`），Chat Completions 侧无对应文档 ⇒ 取基类默认 `false`，不猜 | https://docs.x.ai/developers/model-capabilities/text/comparison |
| `thinkingParam` | **未写入（按裁决 #2 删除）**。理由见 3.5 节「thinkingParam 为何不写」。 | https://docs.x.ai/developers/model-capabilities/text/reasoning |
| `extraBody` | `{}`（**含下面那条 `store` 更正**）。官方对 Chat Completions **没有**任何"无条件必附"的请求体字段。 | https://docs.x.ai/openapi.json |
| `samplingRules.disableWhenThinking` | `["presence_penalty","frequency_penalty"]`。官方原文："`presencePenalty`, `frequencyPenalty`, and `stop` cannot be used with reasoning models. **Requests that include them return an error.**"；OpenAPI 亦标注 `presence_penalty`: "(Not supported by `grok-3` and reasoning models)"、`frequency_penalty`: "(Not supported by reasoning models)" | https://docs.x.ai/developers/model-capabilities/text/reasoning ; https://docs.x.ai/openapi.json |
| `samplingRules.temperatureRange` | `[0.0, 2.0]`。OpenAPI：`minimum: 0`, `maximum: 2`, `default: 1`；原文"between 0 and 2"。**未列入 disableWhenThinking**：OpenAPI 未给 `temperature` 打 "(Not supported by reasoning models)" 标注，无官方依据 | https://docs.x.ai/openapi.json |
| `samplingRules.topPRange` | `[0.0, 1.0]`。OpenAPI：`maximum: 1`, `exclusiveMinimum: 0`, `default: 1`。**未列入 disableWhenThinking**：同上，无官方依据 | https://docs.x.ai/openapi.json |

### 3.3 未确认项（4 条）

1. **`capabilities.reasoning = true`（官方文档自相矛盾，已主动留档的未决点）**：
   - **正向证据（填 `true` 的依据）**：OpenAPI `components.schemas.ChoiceMessage.reasoning_content`："The reasoning trace generated by the model."　URL：https://docs.x.ai/openapi.json ；deferred 文档："You can access the model's raw thinking trace via the `message.reasoning_content` of the chat completion response."　URL：https://docs.x.ai/developers/advanced-api-usage/deferred-chat-completions
   - **反向证据（可能为 `false` 的依据）**：官方对比页表格 "Reasoning Models | Responses API: Full support with encrypted reasoning content | **Chat Completions API (Deprecated): No reasoning content returned**"（该列未区分"原始 trace"与"加密/摘要内容"）　URL：https://docs.x.ai/developers/model-capabilities/text/comparison
   - **裁决与处置**：保留 `true`。因 `capabilities.reasoning` 的**基类默认值即为 `true`**，填入 `true` **不改变行为**，不存在"多发了什么导致报错"的风险；且存在上述正向官方证据，填 `true` 不属于"替官网断言不支持"（我们只在**官网明确说不支持**时才写 `false`，此处是自相矛盾而非明确否定）。
   - **遗留动作**：**若后续确认确实不返回 reasoning 内容，应改为 `false`。**
2. **`preserveReasoningContent`**：Chat Completions 侧无任何"把 `reasoning_content` 回传到后续请求（带 tools）"的官方说明；`include`（`reasoning.encrypted_content`）在映射表中明确属 Responses API 独有。已查：`/developers/model-capabilities/text/comparison`、`/developers/model-capabilities/text/reasoning`、`/openapi.json` ⇒ 该字段**留空**（基类默认 `false`）。
3. **`promptCaching` 的一处措辞需要留意**：对比页把"Automatic caching of conversation history"归为 Responses API 优势、Chat Completions 侧写"Full history billed on each request"（指的是会话历史复用，不是 prefix 缓存）；而 prompt-caching 专页与 `ChatRequest.prompt_cache_key`、响应 `cached_tokens` 表明 Chat Completions 同样有自动 prefix 缓存。本项填 `true`，依据为后三者。
4. **音频输入**：xAI 音频能力（Voice API）是否对 Chat Completions 端点开放未确认；官方模型页将 audio 列为独立 API ⇒ 本项按不支持处理（不写 `audio`）。

### 3.4 表达力缺口（我们 schema 表达不了、但官网明确存在的形态）

1. **`reasoning_effort` 的强度档位无法表达**：官网档位为 `low` / `medium` / `high`（默认）/ `xhigh`（仅 grok-4.6+；在不支持的模型上被视为 `high`），我们的 `thinkingParam` 只有 on/off 两态，表达不了四档强度。（额外坑：`grok-4.20-multi-agent` 的同一参数语义是"协作 agent 数量（4 或 16）"而非推理深度。）
   URL：https://docs.x.ai/developers/model-capabilities/text/reasoning
2. **`stop` 无法列入 `disableWhenThinking`**：官网明确 `stop` 与推理模型互斥（"Requests that include them return an error"），但我们的执行器只认固定的 4 个参数名，`stop` 表达不了 ⇒ 需在执行器/调用侧另行处理（或明确不传 `stop`）。
   URL：https://docs.x.ai/developers/model-capabilities/text/reasoning
3. **（附）`reasoning_content` 的回传方式无语义位**：即便 Chat Completions 返回 `reasoning_content`，"把该内容回传给后续请求"的官方说明只存在于 Responses API 的 `include`，`preserveReasoningContent` 只能取默认 `false`（见未确认 3.3 #2）。

### 3.5 补充：`store` 更正 + `thinkingParam` 为何不写 + 按参数无效/报错限制

**⚠️ 重要更正：`store` 不是 Chat Completions 的字段（用于修正源码注释）**

**结论：`store: false` 属 Responses API（`/v1/responses`），不属 Chat Completions ⇒ 不应作为 Chat Completions 的 `extraBody`。本仓库源码注释里"Grok 的 `store:false` 当 extraBody"的举例是错的，需据本条修改。**

证据（均为官方域名）：

1. OpenAPI `components.schemas.ChatRequest` 的 `properties` 中**没有 `store`**（该请求体共 30 个字段：`deferred`、`frequency_penalty`、`logit_bias`、`logprobs`、`max_completion_tokens`、`max_tokens`、`messages`、`model`、`n`、`parallel_tool_calls`、`presence_penalty`、`prompt_cache_key`、`reasoning_effort`、`response_format`、`search_parameters`、`seed`、`service_tier`、`stop`、`stream`、`stream_options`、`temperature`、`tool_choice`、`tools`、`top_logprobs`、`top_p`、`user`、`web_search_options` 等，**无 `store`**）。
   URL：https://docs.x.ai/openapi.json
2. 官方对比页的参数映射表，`store` 一行的 **Chat Completions 列为 `—`**，原文：
   > `| — | store | Control server-side storage (default: true) |`
   > 并注明 "Server-side Storage | Responses API: Responses stored for 30 days | Chat Completions API (Deprecated): **No storage — manage history yourself**"
   URL：https://docs.x.ai/developers/model-capabilities/text/comparison
3. 要求 `store:false` 的官方上下文是 Responses API：原文"**If you do not want to store your previous request/response on the server, you can set `store: false` on the request.**"（该小节标题 "Disable storing previous request/response on server"，位于 Responses API 使用说明内）
   URL：https://docs.x.ai/docs/guides

**thinkingParam 为何不写（裁决 #2）**

1. **官网称推理不可关闭**：原文"If not specified, `reasoning_effort` defaults to `\"high\"`. **Reasoning cannot be disabled.**"
   URL：https://docs.x.ai/developers/model-capabilities/text/reasoning
2. **无官方"开关"字段**：`reasoning_effort` 是**强度档位**（`low`/`medium`/`high`/`xhigh`…），OpenAPI 定义："Constrains how hard a reasoning model thinks before responding."，不是 on/off 布尔。把它映射成我们 schema 的 `on`/`off` 是**我们的发明**，违背"照官网、不加多余动作"。
   URL：https://docs.x.ai/openapi.json ; https://docs.x.ai/developers/model-capabilities/text/reasoning
3. **未找到官方明文规定"开启思考该传什么值"**：官方只声明**默认档位**为 `"high"`，没有任何"启用思考时必须显式传 `reasoning_effort=<X>`"之类的表述 ⇒ 不构造 `on` 值。

**已知的"按参数无效/报错"限制（不属这 12 字段，供执行侧参考）**

| 参数 | 官方结论 | URL |
|---|---|---|
| `stop` | "(Not supported by reasoning models)"，传入报错 | https://docs.x.ai/openapi.json ; https://docs.x.ai/developers/model-capabilities/text/reasoning |
| `logit_bias` | "(Unsupported)"（整体不支持） | https://docs.x.ai/openapi.json |
| `logprobs` / `top_logprobs` | "Not supported by models `grok-4.20` and newer; the field will be silently ignored if set." | https://docs.x.ai/openapi.json |
| `max_tokens` | **[DEPRECATED]**，改用 `max_completion_tokens`（默认 128,000，不含推理/函数调用 token） | https://docs.x.ai/openapi.json |
| `tools` | 每次请求最多 350 个函数 | https://docs.x.ai/developers/tools/function-calling |
| HTTP 头 `x-grok-conv-id` | 官方**建议**设置以提升缓存命中（可选，非必需）⇒ 不塞 `extraBody` | https://docs.x.ai/developers/advanced-api-usage/prompt-caching |

---

## 4. DeepSeek

调研对象：DeepSeek API（Chat Completions，OpenAI 兼容格式）。官方文档域名：`api-docs.deepseek.com`。当前文档所载模型：`deepseek-flash`（= V4.1-Flash）、`deepseek-v4-pro`，以及兼容映射名 `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp`。

### 4.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "parallelToolCalls": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image"],
    "preserveReasoningContent": true
  },
  "thinkingParam": {
    "body": "thinking",
    "on": { "type": "enabled" },
    "off": { "type": "disabled" }
  },
  "samplingRules": {
    "disableWhenThinking": ["temperature"],
    "temperatureRange": [0.0, 2.0],
    "topPRange": [0.0, 1.0]
  }
}
```

### 4.2 逐项出处表（原「结论表」）

| 字段 | 结论 | 官方 URL + 原文依据 |
| --- | --- | --- |
| `capabilities.responseFormat` | `true` | https://api-docs.deepseek.com/zh-cn/guides/json_mode 「设置 `response_format` 参数为 `{'type': 'json_object'}`」；API 参考 `response_format.type` **Possible values: [text, json_object]**。**不支持 `json_schema`**（参数表仅有 text/json_object 两值） |
| `capabilities.parallelToolCalls` | `true` | https://api-docs.deepseek.com/zh-cn/guides/responses_api/ 兼容表：「`parallel_tool_calls` 忽略（并行工具调用始终开启）」；另 https://api-docs.deepseek.com/news/news0725/「It supports parallel function calls」。**注意：Chat Completions 请求体里没有 `parallel_tool_calls` 参数**，该能力恒开、无需传参 |
| `capabilities.promptCaching` | `true` | https://api-docs.deepseek.com/zh-cn/guides/kv_cache 「上下文硬盘缓存技术对**所有用户默认开启**，用户无需修改代码即可享用」；`usage.prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`。无需任何请求参数 |
| `capabilities.reasoning` | `true` | https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 「DeepSeek 模型支持思考模式：在输出最终回答之前，模型会先输出一段思维链内容」 |
| `reasoning` 响应字段名 | `reasoning_content`（与 `content` 同级；流式在 `delta.reasoning_content`） | 同上：「在思考模式下，思维链内容通过 `reasoning_content` 参数返回，与 `content` 同级」 |
| `capabilities.supportedInputModalities` | `["text","image"]` | https://api-docs.deepseek.com/zh-cn/guides/vision 「`deepseek-v4-flash-vision-exp` 模型支持在文本之外输入图片」；https://api-docs.deepseek.com/updates 「DeepSeek-V4.1-Flash … with native multimodal visual understanding」；API 参考 user message `content` 可为内容块数组（text / image_url / file）。**无任何音频输入证据** ⇒ 不含 audio |
| `capabilities.preserveReasoningContent` | **`true`（硬性，违反返回 400）** | https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 「携带了 `tools` 参数的请求，在后续所有请求中，**必须完整回传 `reasoning_content` 给 API**——即使该轮模型实际未进行工具调用。若您的代码中未正确回传 `reasoning_content`，**API 会返回 400 报错**。」英文页同：https://api-docs.deepseek.com/guides/thinking_mode |
| `thinkingParam.body` | `"thinking"` | API 参考 `thinking` object：`type` **Possible values: [enabled, disabled]，Default value: enabled** |
| `thinkingParam.on` | `{"type":"enabled"}` | 同上；https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 控制参数表 `{"thinking": {"type": "enabled/disabled"}}` |
| `thinkingParam.off` | `{"type":"disabled"}` | 同上 |
| `extraBody` | **不写**（无官方"无条件必填"字段） | — |
| `samplingRules.temperatureRange` | `[0.0, 2.0]` | https://api-docs.deepseek.com/zh-cn/api/create-chat-completion 「采样温度，介于 0 和 2 之间」；`Possible values: <= 2`，`Default value: 1` |
| `samplingRules.topPRange` | `[0.0, 1.0]` | 同上「取值必须大于 0 且不超过 1」；`Possible values: <= 1`，`Default value: 1`（严格是 (0,1]，取 0 非法） |
| `samplingRules.disableWhenThinking` | `["temperature"]`（**不含 top_p**） | https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 「思考模式**不支持** `temperature`、`presence_penalty`、`frequency_penalty` 参数。请注意，为了兼容已有软件，设置参数不会报错，但也不会生效。」+「`top_p` **在思考模式下生效**，但下限为 `0.95`：小于 `0.95` 的值会被抬升至 `0.95`。**在非思考模式下，该参数恒为 `1.0`，传入的值会被忽略。**」 |

### 4.3 未确认项（3 条）

| 项 | 状态 | 查过的官方页面 |
| --- | --- | --- |
| `seed` 是否被支持/是否报错 | **未确认**（负向依据：官方完整请求体参数表未收录 `seed`；**非官方否定**）。按 team-lead 裁决：json 中**不写该字段**，留 nil，不替官网断言"不支持" | `/zh-cn/api/create-chat-completion`、`/api/create-chat-completion`（完整 Body 表：model/messages/thinking/reasoning_effort/max_tokens/response_format/stop/stream/stream_options/temperature/top_p/tools/tool_choice/logprobs/top_logprobs/user_id + 两个 deprecated，无 seed）、`/zh-cn/guides/responses_api/`、`/updates` |
| 音频输入（audio） | 未确认；官方仅有图像输入文档，未见任何音频输入说明 | `/zh-cn/guides/vision/`、`/updates`、`/api/create-chat-completion` |
| `parallel_tool_calls` 作为**请求参数**是否被接受 | **未确认**（能力侧有正向依据故 `capabilities.parallelToolCalls=true`；但参数本身不出现在请求体 schema 中，是否接受该参数未确认）。json 中不写该参数相关字段 | `/zh-cn/api/create-chat-completion`、`/zh-cn/guides/responses_api/` |

### 4.4 表达力缺口

> **该家 md 未单列「表达力缺口」一节**；相关缺口原文出现在「重要补充」第 2 条，逐字保留如下。

- 重要补充第 2 条（原文）：「**本 schema 的 `thinkingParam` 只能表达一个 body 键**，无法同时表达 `reasoning_effort`（取值 `none/low/high/max`，`minimal→low`、`medium/xhigh→high`）。档位强度控制本 schema 表达不了，仅作记录。」
- （对应上位缺口：① 只能注入一个顶层键 / ③ 无法表达强度档位）

### 4.5 补充：重要补充（不新增字段，仅提示消费方）

1. **思考默认开启**：`thinking.type` 默认 `enabled`，`reasoning_effort` 默认 `high`（official：https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 「思考模式默认打开，且 effort 默认为 high」）。⇒ 若用户未选档位则不注入任何字段 = 思考开；只有选"关闭"时才需要注入 `{"thinking":{"type":"disabled"}}`（或 `reasoning_effort:"none"`）。
2. **本 schema 的 `thinkingParam` 只能表达一个 body 键**，无法同时表达 `reasoning_effort`（取值 `none/low/high/max`，`minimal→low`、`medium/xhigh→high`）。档位强度控制本 schema 表达不了，仅作记录。
3. **`top_p` 与 `disableWhenThinking` 的直觉相反**：DeepSeek 的 `top_p` 只在思考模式生效、非思考模式恒为 1.0 被忽略。因此**不要**把 `top_p` 放进 `disableWhenThinking`（放进去等于把唯一生效的场景关掉）。
4. 非思考模式下 `temperature` 生效；思考模式下禁用。`frequency_penalty` / `presence_penalty` 已被官方标记 deprecated「该参数已不再支持。传入该参数将不会产生任何效果」，与 thinking 无关。
5. 思考模式下 `tool_choice` **不支持** `required` 和指定具体 tool，会 400（https://api-docs.deepseek.com/zh-cn/api/create-chat-completion）。
6. 不带 tools 的多轮请求：`reasoning_content` 无需回传、传入也会被忽略（与带 tools 的要求相反）——官方两种口径都在 https://api-docs.deepseek.com/zh-cn/guides/thinking_mode。

**DeepSeek 的 `disableWhenThinking` 只放 `temperature`、不放 `top_p` —— 理由与出处**

官方 https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 原文：「思考模式不支持 `temperature`、`presence_penalty`、`frequency_penalty` 参数。请注意，为了兼容已有软件，设置参数不会报错，但也不会生效。」—— `temperature` 在思考模式下**不生效** ⇒ 应禁用（不发送）。
同一页对 `top_p` 的原文：「`top_p` **在思考模式下生效**，但下限为 `0.95`：小于 `0.95` 的值会被抬升至 `0.95`。**在非思考模式下，该参数恒为 `1.0`，传入的值会被忽略。**」—— `top_p` 的**唯一生效场景恰恰是思考模式**，非思考模式恒定被忽略 ⇒ 把 `top_p` 放进 `disableWhenThinking` 等于关掉它唯一能起作用的场景，故**不写入**。

**满足"必须回传 reasoning_content"是否需要额外请求参数**

**不需要。** 官方样例只做消息层面的原样回传，无任何额外请求字段：https://api-docs.deepseek.com/zh-cn/guides/thinking_mode 「`messages.append(response.choices[0].message)`」等价于 `messages.append({'role':'assistant','content':...,'reasoning_content':...,'tool_calls':...})`，「且在 Turn 2 的请求中，我们仍然携带着 Turn1 所产生的 `reasoning_content` 给 API」。⇒ 实现侧只需在带 tools 的后续请求中把 assistant 的 `reasoning_content` 原样带上，`extraBody` 保持为空。

---

## 5. 智谱 / GLM（`zhipu`）

调研对象：智谱开放平台 Chat Completions（`https://open.bigmodel.cn/api/paas/v4/chat/completions`，OpenAI 兼容）。官方文档域名：`docs.bigmodel.cn`（`open.bigmodel.cn/dev/api` 已 301 到 docs.bigmodel.cn）。当前文档所载模型：`glm-5.3` / `glm-5.3-flash` / `glm-5.2` / `glm-5.1` / `glm-5` / `glm-4.7` / `glm-4.6` / `glm-4.6v` / `glm-4.5` 等。

### 5.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image", "audio", "video"],
    "preserveReasoningContent": true
  },
  "thinkingParam": {
    "body": "thinking",
    "on": { "type": "enabled", "clear_thinking": false },
    "off": { "type": "disabled" }
  },
  "samplingRules": {
    "disableWhenThinking": [],
    "temperatureRange": [0.0, 1.0],
    "topPRange": [0.01, 1.0]
  }
}
```

### 5.2 逐项出处表（原「结论表」）

| 字段 | 结论 | 官方 URL + 原文依据 |
| --- | --- | --- |
| `capabilities.responseFormat` | `true` | https://docs.bigmodel.cn/api-reference/模型-api/对话补全 `response_format`：「指定模型的响应输出格式，默认为 `text`，仅文本模型支持此字段。`type` 取值收敛为三种：`text`（普通文本输出）、`json_object`（`JSON` 格式输出）」。**未提 `json_schema`** |
| `capabilities.promptCaching` | `true`（隐式缓存，无需参数） | https://docs.bigmodel.cn/cn/guide/capabilities/cache 「**自动缓存识别**：隐式缓存，智能识别重复的上下文内容，**无需手动配置**」；命中量在 `usage.prompt_tokens_details.cached_tokens` |
| `capabilities.reasoning` | `true` | https://docs.bigmodel.cn/cn/guide/capabilities/thinking 「深度思考(Thinking)…通过启用思维链(Chain of Thought)机制」 |
| `reasoning` 响应字段名 | `reasoning_content`（非流式 `message.reasoning_content`；流式 `delta.reasoning_content`） | https://docs.bigmodel.cn/api-reference/模型-api/对话补全 响应 schema `message.reasoning_content`；https://docs.bigmodel.cn/cn/guide/start/migrate-to-glm-new 「正确处理 `delta.reasoning_content` 与 `delta.content`」 |
| `capabilities.supportedInputModalities` | `["text","image","audio","video"]` | https://docs.bigmodel.cn/api-reference/模型-api/对话补全 页首：「…支持多模态（**文本、图片、音频、视频、文件**）」，Body 分「文本模型 / 视觉模型 / 音频模型」三类。图像 `type:"image_url"`、视频 `type:"video_url"`、文件 `type:"file"` 见 https://docs.bigmodel.cn/cn/guide/models/vlm/glm-4.6v 与 https://docs.bigmodel.cn/cn/guide/models （GLM-5.3-Flash「输入模态 视频、图像、文本、文件」）。**注：具体模态取决于所选模型，非全模型通用** |
| `capabilities.preserveReasoningContent` | `true`（官方要求回传，但**非 400 级强制**） | https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode 「**请记得返回历史的 `reasoning_content`，以保持推理连贯性。**」样例代码显式 `messages.append({"role":"assistant","content":content,"reasoning_content":reasoning,"tool_calls":[...]})`；另「保留式思考…您可以通过 `"clear_thinking": False` 在 API 端点中开启，**并需要将完整、未修改的 reasoning content 传回 API**」 |
| `thinkingParam.body` | `"thinking"` | https://docs.bigmodel.cn/api-reference/模型-api/对话补全 `thinking` object（「仅 `GLM-4.5` 及以上模型支持」）；https://docs.bigmodel.cn/cn/guide/capabilities/thinking 「`thinking.type`：`enabled`(默认) … `disabled`」 |
| `thinkingParam.on` | `{"type":"enabled","clear_thinking":false}` | `type`：https://docs.bigmodel.cn/cn/guide/capabilities/thinking 「`thinking.type`：`enabled`(默认) … `disabled`」；另 https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode 「GLM-5.3 / GLM-5.3-FLASH / GLM-5.2 / GLM-5.1 / GLM-5 / GLM-4.7 系列**默认开启 Thinking**」。`clear_thinking` **与 `type` 同在 `thinking` 对象内**（官方样例逐字）：同页 「"thinking" : { "type" : "enabled" , "clear_thinking" : False # False for Preserved Thinking }」，且 Round 1 / Round 2 两次请求均如此传参 |
| `thinkingParam.off` | `{"type":"disabled"}` | https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode 「如果您想关闭 thinking，请使用以下，注意 **GLM-5.3 / GLM-5.3-FLASH 强制思考不能关闭**：`"thinking": {"type": "disabled"}`」 |
| `extraBody` | **不写**（无官方"无条件必填"字段） | — |
| `samplingRules.temperatureRange` | `[0.0, 1.0]`（官方另有 `(0.0, 1.0]` 写法，见下） | https://docs.bigmodel.cn/api-reference/模型-api/对话补全 「取值范围为 `[0.0, 1.0]`，限两位小数」+ `Required range: 0 <= x <= 1`；默认值按系列：GLM-5.3/5.2/5.1/5/4.7/4.6 = `1.0`，GLM-4.5 = `0.6`，GLM-4 = `0.75` |
| `samplingRules.topPRange` | `[0.01, 1.0]` | 同上「取值范围为 `[0.01, 1.0]`，限两位小数」+ `Required range: 0.01 <= x <= 1`；默认 `0.95`（GLM-4 系列 `0.9`） |
| `samplingRules.disableWhenThinking` | `[]`（**thinking 下 temperature/top_p 均不禁用**） | **官方无此声明**（全文无"思考模式下 temperature/top_p 不生效/被忽略"之类表述）；且官方深度思考示例把两者并用：https://docs.bigmodel.cn/cn/guide/capabilities/thinking cURL 示例 `"thinking": {"type":"enabled"}` 与 `"temperature": 1.0` 共存，流式示例同理；https://docs.bigmodel.cn/cn/guide/start/migrate-to-glm-new 「`temperature` 默认为 1.0, `top_p` 默认为 0.95, 不建议同时调整两者」（措辞是"不建议同调"，不是"思考时禁用"） |

### 5.3 未确认项（5 条）

| 项 | 状态 | 查过的官方页面 |
| --- | --- | --- |
| `parallel_tool_calls` 是否被支持 | **未确认**（负向依据：官方完整 Body 参数表未收录 `parallel_tool_calls`，且 `tool_choice` 仅 `auto`；**非官方否定**）。另有弱正向迹象但不构成依据：`delta.tool_calls[*].index` 与样例中对多个 tool_call 的遍历。按 team-lead 裁决：json 中**不写该字段**，留 nil | `/api-reference/模型-api/对话补全`、`/cn/guide/capabilities/stream-tool`、`/cn/guide/capabilities/thinking-mode`、`/cn/guide/develop/openai/introduction` |
| `seed` 是否被支持 | **未确认**（负向依据：官方完整参数表未收录 `seed`；**非官方否定**）。按 team-lead 裁决：json 中**不写该字段**，留 nil | `/api-reference/模型-api/对话补全`、`/api-reference/模型-api/对话补全异步`、`/cn/guide/start/concept-param` |
| 音频输入的**请求内容块字段名**（如 `audio_url` / `input_audio`） | **未确认**：只查到端点声明支持音频、Body 有「音频模型」标签页；具体 content 块类型未取到官方字段名（平台音频能力多走 GLM-4-Voice / GLM-Realtime / GLM-ASR 等独立模型与端点）。模态列表里的 `audio` 依据为端点页首声明 + 模型概览 | `/api-reference/模型-api/对话补全`、`/cn/guide/start/model-overview` |
| `response_format` 是否支持 `json_schema` | **未确认**（页面文字为"取值收敛为三种：text、json_object"，只列出两种，无 json_schema） | `/api-reference/模型-api/对话补全` |
| `promptCaching` 是否有显式参数（如 cache_id / prompt_cache_key） | 未确认有显式参数；隐式缓存"无需手动配置"一句已足够支撑 `promptCaching: true` | `/cn/guide/capabilities/cache`、`/cn/best-practice` |

### 5.4 表达力缺口

> **该家 md 未单列「表达力缺口」一节**；相关缺口原文出现在「重要补充」第 2、3 条，逐字保留如下。

- 重要补充第 2 条（原文）：「**`reasoning_effort` 也能关思考**：官方 `reasoning_effort` 取值 `max/xhigh/high/medium/low/minimal/none`，默认 `max`，仅 GLM-5.2 及以上；「传入 `none` 或 `minimal` 模型会放弃思考」（https://docs.bigmodel.cn/api-reference/模型-api/对话补全）。GLM-5.3 / 5.3-FLASH 仅支持 `low/high/max`。本 schema 的 `thinkingParam` 只能表达一个 body 键，无法同时表达 `reasoning_effort`。」
- 重要补充第 3 条（副作用提示，原文）：「按官方说法该能力"主要推荐 Coding / Agent 场景使用"。若后续只想在带 tools 的轮次开启，需要更细的注入条件（本 schema 的 `thinkingParam` 只有 on/off 两档，无法表达）。」
- （对应上位缺口：① 只能注入一个顶层键 / ③ 无法表达强度档位 / ⑤ 无法条件化）

### 5.5 补充：重要补充（不新增字段，仅提示消费方）

1. **思考默认开启**：GLM-5.3 / 5.3-FLASH / 5.2 / 5.1 / 5 / 4.7 默认开启 Thinking；GLM-4.6 为"混合 thinking（自动开启）"。⇒ 不注入任何字段 = 思考开。
2. **`reasoning_effort` 也能关思考**：官方 `reasoning_effort` 取值 `max/xhigh/high/medium/low/minimal/none`，默认 `max`，仅 GLM-5.2 及以上；「传入 `none` 或 `minimal` 模型会放弃思考」（https://docs.bigmodel.cn/api-reference/模型-api/对话补全）。GLM-5.3 / 5.3-FLASH 仅支持 `low/high/max`。本 schema 的 `thinkingParam` 只能表达一个 body 键，无法同时表达 `reasoning_effort`。
3. **`preserveReasoningContent` 的落地细节（已按裁决落到 `thinkingParam.on`）**：标准 API 端点"保留式思考"**默认关闭**（Coding Plan 端点默认开启）；若要在标准端点真正保留思考上下文，需显式传 `thinking: {"type":"enabled","clear_thinking": false}`，且回传的 reasoning content 必须与模型原始生成序列**完全一致，不得重排或修改**（https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode）。
   - 已核实 `clear_thinking` **就在 `thinking` 对象内部**（官方样例：`extra_body = {"thinking": {"type": "enabled", "clear_thinking": False}}`），因此**不硬塞 extraBody**，直接写入 `thinkingParam.on`：
     `"on": { "type": "enabled", "clear_thinking": false }`；`"off": { "type": "disabled" }` 不变（关闭思考时无需该字段）。
   - 语义闭环：`preserveReasoningContent: true`（我要保留回传）+ `on` 带 `clear_thinking:false`（服务端允许保留）⇒ 二者必须成对出现，否则为"空承诺"。
   - 副作用提示：按官方说法该能力"主要推荐 Coding / Agent 场景使用"。若后续只想在带 tools 的轮次开启，需要更细的注入条件（本 schema 的 `thinkingParam` 只有 on/off 两档，无法表达）。
4. `do_sample`（默认 `true`）为本家特有：`do_sample=false` 时「`temperature` 和 `top_p` 参数将被忽略」（等价于官方推荐的可复现输出开关），本 schema 无对应字段。
5. `tool_stream`（默认 `false`，仅 GLM-5.3/5.2/5.1/5/5-Turbo/4.7/4.6）为流式工具调用开关，本 schema 无对应字段。
6. temperature 的两处官方写法不一致：同步 API 参考写 `[0.0, 1.0]` + `Required range: 0 <= x <= 1`；异步 API 参考文字写 `(0.0, 1.0]`；OpenAI 兼容页写「temperature 参数的区间为 (0,1)，`do_sample = False`（temperature = 0）在 OpenAI 调用中并不适用」（https://docs.bigmodel.cn/cn/guide/develop/openai/introduction）。取 `[0.0, 1.0]` 作为 schema 值。

---

## 6. Qwen（阿里云百炼 / DashScope）

接口形态：OpenAI 兼容模式的 Chat Completions
`POST https://{WorkspaceId}.{region}.maas.aliyuncs.com/compatible-mode/v1/chat/completions`
（非标准参数：Python SDK 走 `extra_body`；Node SDK / curl 直接放请求体顶层）

**校准说明（依据 team-lead 统一裁决）**：`capabilities.*` 只在「官方明确说不支持」时写 `false`；「官方参数表未收录」留 nil。Qwen 侧所有已确认项**均为官方明确支持**，故本家**不含任何 `false`**。

### 6.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "parallelToolCalls": true,
    "seed": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image", "audio", "video"],
    "preserveReasoningContent": true
  },
  "thinkingParam": {
    "body": "enable_thinking",
    "on": true,
    "off": false
  },
  "extraBody": {},
  "samplingRules": {
    "temperatureRange": [0.0, 2.0],
    "topPRange": [0.0, 1.0]
  }
}
```

### 6.2 逐项出处表

| 字段 | 取值 | 官方出处 | 依据原文（节选） |
|---|---|---|---|
| `capabilities.responseFormat` | `true` | https://help.aliyun.com/zh/document_detail/3016807.html | `response_format` 可选 `{"type":"text"}` / `{"type":"json_object"}` / `{"type":"json_schema",...}`；"若指定为 `{"type":"json_object"}`，需在提示词中明确指示模型输出JSON…否则会报错" |
| `capabilities.parallelToolCalls` | `true` | https://help.aliyun.com/zh/model-studio/qwen-function-calling ；参数表 https://help.aliyun.com/zh/document_detail/3016807.html | "可设置请求参数 `parallel_tool_calls` 为 `true`，这样返回对象中将包含所有需要调用的工具函数与入参信息"；参数表：`parallel_tool_calls` boolean，**默认 `false`**，可选 `true`/`false` |
| `capabilities.seed` | `true` | https://help.aliyun.com/zh/document_detail/3016807.html | `seed` integer，范围 `[0, 2^31−1]`，默认值因模型而异（qwen-vl-max/qvq-max 3407；qwen-vl-max-2024-02-01、qwen-vl-plus 无默认值；其余 1234） |
| `capabilities.promptCaching` | `true` | https://help.aliyun.com/zh/model-studio/context-cache ；https://help.aliyun.com/zh/model-studio/explicit-cache-guide | 上下文缓存两种模式：**显式缓存**（messages 里加 `"cache_control": {"type":"ephemeral"}`，单请求最多 4 个标记）与**隐式缓存**（自动、不可关闭）。命中量经 `usage.prompt_tokens_details.cached_tokens` 返回 |
| `capabilities.reasoning` | `true` | https://help.aliyun.com/zh/model-studio/deep-thinking | "思考内容通过 `reasoning_content` 字段返回，回复内容通过 `content` 字段返回"；流式 `delta.reasoning_content`；usage 有 `reasoning_tokens` |
| `capabilities.supportedInputModalities` | `["text","image","audio","video"]` | https://help.aliyun.com/zh/document_detail/3016807.html | user message `content` 数组 `type` 可选：`text` / `image_url` / `input_audio` / `video` / `video_url`。**注意：按模型而定**——`image_url` 需 Qwen-VL/Omni，`input_audio`/`video` 需 Qwen-Omni/Qwen-VL；纯文本 qwen-plus/qwen-max 仅 text |
| `capabilities.preserveReasoningContent` | `true` | https://help.aliyun.com/zh/document_detail/3016807.html ；https://help.aliyun.com/zh/model-studio/deep-thinking | **判据＝官网是否要求/建议必须回传**。厂商对应参数为 `preserve_thinking`（boolean）："是否将对话历史中 assistant 消息的 `reasoning_content` 拼接至模型输入"。**重要：**"使用 qwen3.8-max/qwen3.8-flash 时，`preserve_thinking` 默认为 true，**必须将历史对话中所有的 `reasoning_content` 完整回传**。不支持将 `reasoning_content` 拼接到 `content` 字段中回传。" ⇒ 官方对旗舰模型**硬性要求**必须回传 ⇒ `true`（**不**因 `preserve_thinking` 参数默认值为 false 而填 false——那是两件事） |
| `thinkingParam.body` | `"enable_thinking"` | https://help.aliyun.com/zh/model-studio/deep-thinking ；https://help.aliyun.com/zh/document_detail/3016807.html | "该参数非OpenAI标准参数。通过 Python SDK调用时，请放入 **extra_body** 对象中"；"若不使用 OpenAI SDK，而是通过 HTTP（如 curl）方式直接调用，则直接将 `enable_thinking` 与 `model`、`messages` 等参数一样放在请求体（body）的顶层"；Node SDK 作为顶层属性传 |
| `thinkingParam.on` / `.off` | `true` / `false` | 同上 | "混合思考模式：通过 `enable_thinking` 参数控制思考开关：设为 `true`：模型先思考再回复；设为 `false`：模型直接回复。" |
| `extraBody` | `{}` | — | 官方未要求任何无条件字段（`stream_options.{"include_usage":true}`、`thinking_budget`、`reasoning_effort` 都是可选，非必须） |
| `samplingRules.temperatureRange` | `[0.0, 2.0]` | https://help.aliyun.com/zh/document_detail/3016807.html | `temperature` float，取值范围 `[0, 2)`；"temperature与top_p均可以控制生成文本的多样性，建议只设置其中一个值" |
| `samplingRules.topPRange` | `[0.0, 1.0]` | 同上 | `top_p` float，取值范围 `(0, 1.0]` |
| `samplingRules.disableWhenThinking` | 省略（= 不注入任何禁用规则） | https://help.aliyun.com/zh/model-studio/deep-thinking | **官方未声明思考模式下禁止/忽略 temperature、top_p**。仅见下限收窄："qwen3.8-max/qwen3.8-flash（思考模式）…0.6 以下的 temperature 值会默认改为 0.6"，以及开源模型卡建议 "For thinking mode, use Temperature=0.6, TopP=0.95 … DO NOT use greedy decoding"（**建议**，非禁止）。故不写该字段 |

### 6.3 未确认项（2 条）

1. `samplingRules.disableWhenThinking` —— **官方无此声明**，故整个字段省略。官方未说思考模式下禁止/忽略 `temperature`、`top_p`，仅见下限收窄与最佳实践建议。查过页面：deep-thinking、OpenAI兼容-Chat、qwen-api-via-dashscope、compatible-mode 兼容页。
2. 思考档位参数（`thinking_budget` / `reasoning_effort`）**不属于本 schema 字段范围**，未纳入 `behavior`；仅记录：`thinking_budget` 支持 Qwen3.8/3.7/3.6/3.5/3/VL 与 GLM（阿里云直供）、Kimi（阿里云直供），kimi-k3 不支持；qwen3.8 系列 `reasoning_effort` 与 `thinking_budget` 不可同时设置（会报错），二者可互转。

**查过的官方页面（Qwen）**

- https://help.aliyun.com/zh/document_detail/3016807.html （OpenAI兼容-Chat 参数表）
- https://help.aliyun.com/zh/model-studio/deep-thinking （深度思考）
- https://help.aliyun.com/zh/model-studio/context-cache （上下文缓存）
- https://help.aliyun.com/zh/model-studio/explicit-cache-guide （显式缓存最佳实践）
- https://help.aliyun.com/zh/model-studio/qwen-function-calling （Function calling / parallel_tool_calls）
- https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope
- https://www.alibabacloud.com/help/tc/model-studio/qwen-api-via-dashscope （DashScope API 参考）

### 6.4 表达力缺口

> **该家 md 未单列「表达力缺口」一节**；相关缺口原文出现在「未确认清单」第 2 条与「关于 `preserveReasoningContent` 的取值理由」末段，逐字保留如下。

- 未确认清单第 2 条（原文）：「思考档位参数（`thinking_budget` / `reasoning_effort`）**不属于本 schema 字段范围**，未纳入 `behavior`……」
- 取值理由末段（原文）：「该字段是 provider 级，无法按模型区分；如需对旧混合思考模型（如 qwen-plus）单独关闭，建议按模型名分支。」
- （对应上位缺口：③ 无法表达强度档位 / ④ 无法按模型差异化）

### 6.5 补充：「仅思考模式」与非 OpenAI 字段备注

- **仅思考模式**模型（如 qwen3-235b-a22b-thinking-2507、qwq-plus、qwen3.7-max-preview）："模型始终在回复前进行思考，无法关闭。除无需设置 `enable_thinking` 参数外，请求格式与混合思考模式一致。" → 对这类模型注入 `enable_thinking: false` 无效，但官方未说明会报错。
- 软开关：`enable_thinking=true` 时可在提示词加 `/no_think` 关闭思考（仅适用于 Qwen3 开源版混合思考模型及 qwen-plus-2025-04-28）。
- `enable_thinking=true` 时 `max_tokens` 有效范围收窄为 `[1, 32768]`，超出返回 400（建议改用 `max_completion_tokens`）。

**关于 `preserveReasoningContent` 的取值理由（按 team-lead 裁决标准 2）**

语义是「**我们要不要保留**」——即带 tools 的后续请求里是否必须把 assistant 的 `reasoning_content` 回传给厂商（保留＝安全）。判据是官网是否**要求/建议**必须回传，而**不是**厂商参数的默认值。

- 官方对 `qwen3.8-max` / `qwen3.8-flash` **硬性要求**："`preserve_thinking` 默认为 true，**必须**将历史对话中所有的 `reasoning_content` 完整回传"；`qwen3.8-2.4t-a95b` 为 thinking-only，同样要求。⇒ 回传是**安全且必须**的 ⇒ 填 `true`。
- 反向证据（不采纳为判据）："多轮对话中，模型默认不会读取历史消息里的 `messages` 数组中的 `reasoning_content`"——这是 `preserve_thinking` **参数的默认值**描述，不是"禁止回传"。官方亦说明"若历史消息中不包含 `reasoning_content`，开启此参数不会报错，正常兼容"，即回传不会导致报错。
- 该字段是 provider 级，无法按模型区分；如需对旧混合思考模型（如 qwen-plus）单独关闭，建议按模型名分支。

---

## 7. Xiaomi（MiMo）

**结论先行：小米有公开可查的官方大模型 API 文档，且是完整 OpenAI 兼容 Chat Completions。**

- 官方开放平台：https://platform.xiaomimimo.com/ （根域 https://mimo.mi.com/ 为同一站点的另一入口）
- 请求地址：`POST https://api.xiaomimimo.com/v1/chat/completions`
- 鉴权：`api-key: $MIMO_API_KEY` 或 `Authorization: Bearer $MIMO_API_KEY`
- 另有 `/anthropic/v1/messages`（Claude 格式）与 `/v1/responses`；本家只针对 OpenAI 兼容 Chat Completions
- 主文档页：https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api （EN：https://mimo.mi.com/docs/en-US/api/chat/openai-api）

**校准说明（依据 team-lead 统一裁决）**：`capabilities.*` 只在「官方明确说不支持」时写 `false`；「官方参数表未收录」一律留 nil（不写进 JSON）。故本家**不含任何 `false`**；`seed`、`parallelToolCalls` 因仅属负向依据而**省略**，详见未确认清单。

### 7.1 定稿 `behavior`

```json
{
  "capabilities": {
    "responseFormat": true,
    "promptCaching": true,
    "reasoning": true,
    "supportedInputModalities": ["text", "image", "audio", "video"],
    "preserveReasoningContent": true
  },
  "thinkingParam": {
    "body": "thinking",
    "on": { "type": "enabled" },
    "off": { "type": "disabled" }
  },
  "extraBody": {},
  "samplingRules": {
    "disableWhenThinking": ["temperature", "top_p"],
    "temperatureRange": [0.0, 1.5],
    "topPRange": [0.01, 1.0]
  }
}
```

### 7.2 逐项出处表

| 字段 | 取值 | 官方出处 | 依据原文（节选） |
|---|---|---|---|
| `capabilities.responseFormat` | `true` | https://mimo.mi.com/docs/en-US/quick-start/usage-guide/text-generation/structured-output | 专页「Structured Outputs（JSON mode）」：支持的模型 mimo-v2.5-pro、mimo-v2.5；"response_format: Response format control parameter. Pass `{"type": "json_object"}` to enable JSON mode output." **仅 json_object；无 json_schema 证据** |
| `capabilities.parallelToolCalls` | **省略（nil）** | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api | **负向依据：官方参数表未收录** `parallel_tool_calls`（表中工具相关仅 `tools` / `tool_choice`；`tool_choice` "可选值：`auto`"，且"当 `tool_choice` 传入非 `auto` 值时，后端会默认移除该字段"）。官方并未明说"不支持"，故留 nil |
| `capabilities.seed` | **省略（nil）** | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api | **负向依据：官方参数表未收录** `seed`（表内为 messages/model/audio/frequency_penalty/max_completion_tokens/presence_penalty/response_format/stop/stream/thinking/temperature/tool_choice/tools/top_p）。官方并未明说"不支持"，故留 nil |
| `capabilities.promptCaching` | `true` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api ；https://platform.xiaomimimo.com/docs/zh-CN/usage-guide/multimodal-understanding/image-understanding | **依据是「响应字段」而非「参数文档」**：响应体有 `usage.prompt_tokens_details.cached_tokens` integer —— "命中缓存的 token 数量"；官方图片理解示例响应中实际出现 `"cached_tokens": 1081`。未见专门的「上下文缓存」文档，也无开启/关闭缓存的参数 |
| `capabilities.reasoning` | `true` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api | 有 `thinking` 参数；响应 `choices.message.reasoning_content`（"助手消息中最终答案之前的推理内容"）与流式 `choices.delta.reasoning_content`；usage 有 `completion_tokens_details.reasoning_tokens` |
| `capabilities.supportedInputModalities` | `["text","image","audio","video"]` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api ；图片理解 https://platform.xiaomimimo.com/docs/zh-CN/usage-guide/multimodal-understanding/image-understanding | usage 中含 `image_tokens`/`audio_tokens`/`video_tokens`；文档有「图像输入 / 音频输入 / 视频输入」示例章节。**注意按模型而定**：图片理解"当前仅支持 mimo-v2.5 模型"（mimo-v2.5-pro 为纯文本）；多模态另见 mimo-v2-omni |
| `capabilities.preserveReasoningContent` | `true` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api ；FAQ https://mimo.mi.com/docs/zh-CN/quick-start/faq/api-integration | **判据＝官网是否要求/建议必须回传**。`thinking` 与 `tools` 参数处两处强调："在思考模式下的多轮工具调用过程中，模型会在返回 `tool_calls` 字段的同时返回 `reasoning_content` 字段。若要继续对话，**建议在后续每次请求的 `messages` 数组中保留所有历史 `reasoning_content`**，以获得最佳表现。" FAQ 同款 curl 示例即把 `reasoning_content` 放回 assistant 消息。⇒ 官方建议保留 ⇒ `true` |
| `thinkingParam.body` | `"thinking"` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api | 顶层参数 `thinking` object，"这个参数用于控制模型是否启用思维链" |
| `thinkingParam.on` / `.off` | `{"type":"enabled"}` / `{"type":"disabled"}` | 同上 | `thinking.type` string 必选，"是否启用思维链"，"可选值：`enabled`，`disabled`"；`mimo-v2.5-pro`、`mimo-v2.5`、`mimo-v2-pro`、`mimo-v2-omni` **默认 `enabled`**，`mimo-v2-flash` 默认 `disabled` |
| `extraBody` | `{}` | — | 官方未要求任何无条件字段（`audio` 仅为 TTS 模型用；联网搜索通过 `tools` 中的 web_search 工具激活、且需先开通） |
| `samplingRules.disableWhenThinking` | `["temperature","top_p"]` | https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api | `thinking` 参数下："在思考模式下，`mimo-v2.5-pro`、`mimo-v2.5` 模型**不支持自定义 `temperature` 和 `top_p` 参数**。即使传入该参数，实际生效值也会被模型强制采用其推荐默认值 `1.0` 和 `0.95`。"（`temperature`、`top_p` 两处又各自重申一次） |
| `samplingRules.temperatureRange` | `[0.0, 1.5]` | 同上 | `temperature` number，"要使用的采样温度，**介于 0 和 1.5 之间**"，"所需范围：`[0, 1.5]`"；默认：mimo-v2.5-pro/v2.5/v2-pro/v2-omni = 1.0，mimo-v2-flash = 0.3 |
| `samplingRules.topPRange` | `[0.01, 1.0]` | 同上 | `top_p` number，默认 `0.95`，"所需范围：`[0.01, 1.0]`" |

### 7.3 未确认项（5 条）

1. **`response_format` 是否支持 `json_schema`** —— **未确认**。官方「Structured Outputs」专页只演示 `{"type":"json_object"}`，未出现 `json_schema`/`strict` 结构。同时官方参数表中 `response_format.type` 的描述自相矛盾（"仅为 `text`"，但同处又列出 `Text · object` 与 `JSON object · object` 两个子项）→ 按 `json_object` 可用判定为 `true`，`json_schema` 不确定。
2. **`seed` / `parallel_tool_calls`** —— **未确认（负向依据：官方参数表未收录）**，故 `xiaomi.json` 中**不写这两个键**（留 nil）。官方没有一句话说"不支持"，所以按裁决不写 `false`。若后续 MiniClaw 需要强制关闭这两项，请另行指定。
3. **`promptCaching` 的机制** —— **未确认**：依据仅为响应字段 `usage.prompt_tokens_details.cached_tokens`（含官方示例中的实际非零值 1081），属**响应侧证据，非参数文档依据**；**未找到**小米官方的「上下文缓存/缓存策略」说明页，也未找到任何开启/关闭缓存的参数。`true` 表示"服务端确实会缓存"，不代表有可控开关。
4. **思考档位（reasoning_effort / thinking_budget 之类）** —— **未确认/官方无此参数**：`thinking.type` 只有 `enabled`/`disabled` 两值，无强度档位（`low/medium/high` 等）。因此 `thinkingParam.on` 只能表达"开"，无法表达"档位"。官方 FAQ 另提到 "It is recommended to **disable thinking when calling tool calls**"（针对 reasoning_content 与 tool_calls 混在一起的不稳定问题）。
5. **输入模态按模型细分** —— 官方未给出一张"模型 × 模态"总表；当前已知：图片理解仅 mimo-v2.5；mimo-v2.5-pro 为纯文本；audio/video 输入的确切支持模型未在参数表中列明。

**查过的官方页面（Xiaomi）**

- https://platform.xiaomimimo.com/docs/zh-CN/api/chat/openai-api （中文 OpenAI Chat Completions 参数表，主依据）
- https://mimo.mi.com/docs/en-US/api/chat/openai-api （英文同页）
- https://platform.xiaomimimo.com/docs/en-US/api/chat/openai-api
- https://mimo.mi.com/docs/zh-CN/quick-start/faq/api-integration （FAQ：多轮工具调用 + reasoning_content；API Key / Base URL）
- https://mimo.mi.com/docs/en-US/quick-start/usage-guide/text-generation/structured-output （结构化输出）
- https://platform.xiaomimimo.com/docs/zh-CN/usage-guide/multimodal-understanding/image-understanding （图片理解，含 cached_tokens 实例）
- https://mimo.mi.com/ （平台主页）

> 未采信：apis.io、docs.empiriolabs.ai、docs.openclaw.ai、toolso.ai、www.mimo-v2.com 等第三方聚合/封装站 —— 均非小米官方域。

### 7.4 表达力缺口

> **该家 md 未单列「表达力缺口」一节**；相关缺口原文出现在「未确认清单」第 4 条，逐字保留如下。

- 未确认清单第 4 条（原文）：「**思考档位（reasoning_effort / thinking_budget 之类）** —— **未确认/官方无此参数**：`thinking.type` 只有 `enabled`/`disabled` 两值，无强度档位（`low/medium/high` 等）。因此 `thinkingParam.on` 只能表达"开"，无法表达"档位"。官方 FAQ 另提到 "It is recommended to **disable thinking when calling tool calls**"（针对 reasoning_content 与 tool_calls 混在一起的不稳定问题）。」
- （对应上位缺口：③ 无法表达强度档位 / ⑤ 无法条件化 —— FAQ 建议"调用工具调用时禁用思考"，但 schema 无法按"是否带 tools"条件化）

---

## 8. 表达力缺口汇总

把 7 家去重合并后的缺口一览。**实例**列为各家 md 原文中点名的官方形态；**影响哪家**为该缺口在哪些 provider 上实际出现。

| # | 缺口 | 实例 | 影响哪家 |
|---|---|---|---|
| ① | `thinkingParam` **只能注入一个顶层键** | DeepSeek：`thinking` 与 `reasoning_effort` 无法并存；智谱：`thinking` 与 `reasoning_effort` 无法并存；OpenAI：`reasoning_effort` 整块无法表达（on/off 无官方映射） | deepseek、zhipu、openai（grok 亦因其 `reasoning_effort` 无 on/off 映射而整块不写） |
| ② | `disableWhenThinking` **只认 4 个硬编码参数名**（temperature / top_p / frequency_penalty / presence_penalty） | xAI 官方明确 `stop` 与推理模型互斥（"Requests that include them return an error"），但 `stop` 表达不了 | grok |
| ③ | **无法表达"强度档位"** | OpenAI `reasoning_effort`（none/minimal/low/medium/high/xhigh/max）；xAI `reasoning_effort`（low/medium/high/xhigh）；智谱 `reasoning_effort`（max/xhigh/high/medium/low/minimal/none，GLM-5.3 仅 low/high/max）；DeepSeek `reasoning_effort`（none/low/high/max）；Qwen `thinking_budget` / `reasoning_effort`；Xiaomi 官方无档位参数（只有 enabled/disabled） | openai、grok、zhipu、deepseek、qwen、xiaomi |
| ④ | **无法按模型差异化** | OpenAI GPT-6 Astra 无 `none`（传 `none` 直接 400）而 5.5/5.6 支持；智谱 GLM-5.3/5.3-FLASH 强制思考不能关闭；xAI `grok-4.20-multi-agent` 的 `reasoning_effort` 语义变为"协作 agent 数量（4 或 16）"；Qwen `preserve_thinking` 对 qwen3.8-max/flash 硬性要求、旧混合模型不要求；Xiaomi 各模型 thinking 默认值不同（v2.5-pro=on / v2-flash=off）、模态按模型而定 | openai、zhipu、grok、qwen、xiaomi、deepseek |
| ⑤ | **无法条件化**（如"仅在带 tools 的轮次开启"） | 智谱：保留式思考"主要推荐 Coding / Agent 场景"，但 schema 只有 on/off，无法只在带 tools 轮次开；OpenRouter：`effort:"none"` 在 `reasoning.mandatory:true` 模型上会被拒，需按模型动态决定；Xiaomi：官方 FAQ 建议"调用 tool calls 时禁用思考"，但无法按"是否带 tools"条件化 | zhipu、openrouter、xiaomi |
| ⑥ | **请求头 / 路由策略类不属这 12 字段**（走 `customHeaders` 等其他通道） | OpenRouter：`HTTP-Referer`、`X-OpenRouter-Title`、`X-OpenRouter-Categories`（可选请求头）、`provider`、`require_parameters`、`session_id`、`prompt_cache_key`（路由/会话策略）；xAI：HTTP 头 `x-grok-conv-id`（官方建议设置以提升缓存命中） | openrouter、grok |
| ⑦ | `topPRange` 在官方未给数值界时**填不出** | OpenAI `top_p` 参考页只做概率质量解释、无上下界 ⇒ `topPRange` 未写入 JSON | openai |
| ⑧ | **"显式关闭思考"无安全取值** | OpenAI：语义关闭值 `none` 在 GPT-6 Astra 上直接 HTTP 400 ⇒ 只能不发该字段（等于用模型默认档） | openai |
| ⑨ | **可选的调优/结构类参数无处安放** | OpenAI：`prompt_cache_key` / `prompt_cache_options` / `prompt_cache_retention` 是可选字段，放 `extraBody` 会变成无条件附加、污染所有请求；OpenRouter：Anthropic/Gemini 系缓存需在 content block 上打 `cache_control`（属 message 结构，不在 12 字段内） | openai、openrouter |
| ⑩ | **"是否回传 reasoning" 无语义位** | xAI：Chat Completions 返回 `reasoning_content`，但"回传给后续请求"的官方说明只在 Responses API 的 `include` 里 ⇒ `preserveReasoningContent` 只能取默认 `false` | grok |
| ⑪ | **厂商特有开关无对应字段** | 智谱：`do_sample`（temperature/top_p 的启停）、`tool_stream`（流式工具调用开关）本 schema 都无对应字段 | zhipu |
| ⑫ | **`disableWhenThinking` 语义与厂商直觉相反，schema 无表达位** | DeepSeek：`top_p` 的唯一生效场景恰是思考模式 ⇒ 不能放进 `disableWhenThinking`，但 schema 无法表达"仅在某模式生效" | deepseek |

⚠️ **待复核（本汇总新增的一条跨家观察，非两 md 结论互斥）**：**区间写法口径不统一**。多家官方原文写的是**半开区间**，而各家 `behavior` 统一写成了**闭区间** —— 例如 OpenRouter `top_p` 官方注释为 `(0, 1]`、DeepSeek `top_p` 官方为「取值必须大于 0 且不超过 1」（严格 (0,1]）、Qwen `temperature` 官方为 `[0, 2)`、Qwen `top_p` 官方为 `(0, 1.0]`。各家 md 均已就地注明该差异，本文档保留原样、不自作取舍。**风险**：若执行器按闭区间下界发值（如 `top_p = 0.0` 或 `temperature = 0.0`），对官方下界为开区间的厂商可能被拒或被抬升（DeepSeek 明确 <0.95 会被抬至 0.95）。**建议**：由 team-lead 统一裁定「区间表达是否表达开闭」，再决定是否调整 schema 或执行器下界。

## 9. 对源码的更正

1. **`extraBody` 的注释示例已更正（2026-09-14，按 xAI 官方文档核对）**
   - 位置：`MiniClaw/MiniClaw/Models/ProviderModels.swift`（仓库相对路径 `MiniClaw/Models/ProviderModels.swift`），`ProviderBehaviorDecl.extraBody` 声明处（本机实测行号 **41–45**）。
   - 更正内容：**原先拿 Grok 的 `store:false` 当 `extraBody` 的例子是错的**。依据 xAI 官方：`store` **不在** Chat Completions 的 OpenAPI `ChatRequest.properties` 里（属 **Responses API** `/v1/responses`）；官方参数映射表中 `store` 一行的 Chat Completions 列为 `—`。源码注释现已改为：「**不要**拿 Grok 的 `store:false` 当例子 …… 本字段只应放**该厂商在 Chat Completions 官方文档里明确要求/必须的无条件请求体字段**」。
   - 出处：https://docs.x.ai/openapi.json ；https://docs.x.ai/developers/model-capabilities/text/comparison （详见本文 3.5 节）。
2. **xAI 官方已把 Chat Completions 标为 legacy / deprecated**
   - 原文："Chat Completions is offered as a legacy endpoint. New features will come to the [Responses API] first."（https://docs.x.ai/developers/model-capabilities/legacy/chat-completions）；官方对比页亦将该列标为 "Chat Completions API (Deprecated)"。⇒ 基类消费的 OpenAI 兼容端点虽仍可用，但新特性不会再落到该端点上，后续新增能力需评估 Responses API。
3. **记录：全库 7 家 `behavior` 一律不写 `anthropic` / `google`**
   - 二者的适配器**不接收** `behavior`（非 OpenAI 兼容族），故本轮核对不含这两家；本文档亦不含。
