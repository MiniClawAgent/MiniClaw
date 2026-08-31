import Foundation
import UIKit
import AVFoundation
import NaturalLanguage
import UserNotifications

// 注：apple-healthkit 的真实现已迁至 HealthKitTools.swift（此处占位实现已删除）。

// MARK: - 7. apple-homekit (HomeKit)

// 注：apple-homekit 的真实现已迁至 HomeKitTools.swift（此处占位实现已删除）。

// MARK: - 8. apple-location (CoreLocation)

// 注：apple-location 的真实现已迁至 LocationTools.swift（此处占位实现已删除）。

// MARK: - 9. apple-maps (MapKit)

struct AppleMapsTool: AgentTool {
    let name = "apple-maps"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-maps",
            description: L10n.l("maps_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_map_actions"), enum: ["search_poi", "route", "eta"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("poi_search_keyword")),
                    "from": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_origin")),
                    "to": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_destination")),
                    "transport_type": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_transit_mode"), enum: ["driving", "walking", "transit"]),
                    "limit": JSONSchema.JSONProperty(type: "integer", description: L10n.l("param_result_limit")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_maps"))
    }
}

// MARK: - 10. apple-media (MediaPlayer)

struct AppleMediaTool: AgentTool {
    let name = "apple-media"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-media",
            description: L10n.l("music_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_music_actions"), enum: ["play", "pause", "next", "previous", "search", "info"]),
                    "query": JSONSchema.JSONProperty(type: "string", description: L10n.l("search_keyword_alt")),
                ],
                required: ["action"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        return ToolResult(success: false, text: L10n.l("not_implemented_media"))
    }
}

// MARK: - 11. apple-nfc (CoreNFC)

// 注：apple-nfc 已整体移除（v1 用不上，且会额外索取 NFC 读取权限）。
// 权限描述 `NFCReaderUsageDescription` 与 L10n 的 nfc 相关 key 一并摘除。

// MARK: - 12. apple-nlp (NaturalLanguage)

struct AppleNLPTool: AgentTool {
    let name = "apple-nlp"
    let schema = ToolSchema(
        type: "function",
        function: ToolSchema.FunctionDef(
            name: "apple-nlp",
            description: L10n.l("nlp_tool_desc"),
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "action": JSONSchema.JSONProperty(type: "string", description: L10n.l("op_nlp_actions"), enum: ["language", "detect_entities", "sentiment", "tokenize"]),
                    "text": JSONSchema.JSONProperty(type: "string", description: L10n.l("param_text_to_analyze")),
                ],
                required: ["action", "text"]
            )
        )
    )

    func execute(_ parameters: [String: Any]) async throws -> ToolResult {
        guard let action = parameters["action"] as? String,
              let text = parameters["text"] as? String else {
            throw ToolError.invalidParameters(L10n.l("err_missing_action_text"))
        }
        switch action {
        case "language":
            let result: String = await MainActor.run {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                let lang = recognizer.dominantLanguage?.rawValue ?? L10n.l("unknown")
                let conf = recognizer.languageHypotheses(withMaximum: 3)
                    .map { "\($0.key.rawValue): \(String(format: "%.0f%%", $0.value * 100))" }
                    .joined(separator: ", ")
                return String(format: L10n.l("apple_language"), lang, conf)
            }
            return ToolResult(success: true, text: result)

        case "sentiment":
            let result: String = await MainActor.run {
                let tagger = NLTagger(tagSchemes: [.sentimentScore])
                tagger.string = text
                let (score, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let s = Double(score?.rawValue ?? "0") ?? 0
                let label = s > 0.3 ? L10n.l("sentiment_positive") : (s < -0.3 ? L10n.l("sentiment_negative") : L10n.l("sentiment_neutral"))
                return L10n.l("sentiment_label") + label + " (score: " + String(format: "%.2f", s) + ")"
            }
            return ToolResult(success: true, text: result)

        case "tokenize":
            let tokens: [String] = await MainActor.run {
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                var t: [String] = []
                tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                    t.append(String(text[range]))
                    return true
                }
                return t
            }
            return ToolResult(success: true, text: String(format: L10n.l("tokenizer_result"), tokens.count, tokens.joined(separator: " | ")))

        case "detect_entities":
            let result: String = await MainActor.run {
                let tagger = NLTagger(tagSchemes: [.nameType])
                tagger.string = text
                var entities: [String: [String]] = [:]
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
                    if let tag = tag, tag != .other {
                        let word = String(text[range])
                        entities[tag.rawValue, default: []].append(word)
                    }
                    return true
                }
                if entities.isEmpty { return L10n.l("no_named_entities") }
                return entities.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "\n")
            }
            return ToolResult(success: true, text: result)

        default:
            return ToolResult(success: false, text: String(format: L10n.l("apple_unsupported_action"), action))
        }
    }
}

