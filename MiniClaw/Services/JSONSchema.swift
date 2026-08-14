import Foundation

/// JSON Schema 的兼容表示：常用字段保持强类型访问，未知字段原样保留并重新编码。
/// 这样 MCP 的 oneOf/anyOf/$defs/additionalProperties 等约束不会在转发给模型时丢失。
struct JSONSchema: Codable, Sendable, Equatable {
    var type: String
    var properties: [String: JSONProperty]?
    var required: [String]?
    private var additionalFields: [String: JSONSchemaValue]
    private var includesType: Bool

    init(
        type: String,
        properties: [String: JSONProperty]? = nil,
        required: [String]? = nil,
        additionalFields: [String: JSONSchemaValue] = [:]
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.additionalFields = additionalFields
        self.includesType = true
    }

    init(rawObject: [String: JSONSchemaValue]) {
        if case .string(let value)? = rawObject["type"] {
            type = value
            includesType = true
        } else {
            type = "object"
            includesType = false
        }
        if case .object(let values)? = rawObject["properties"] {
            properties = values.mapValues { value in
                if case .object(let object) = value { return JSONProperty(rawObject: object) }
                return JSONProperty(type: "string")
            }
        } else {
            properties = nil
        }
        if case .array(let values)? = rawObject["required"] {
            required = values.compactMap { value in
                if case .string(let string) = value { return string }
                return nil
            }
        } else {
            required = nil
        }
        additionalFields = rawObject.filter { !["type", "properties", "required"].contains($0.key) }
    }

    var rawObject: [String: JSONSchemaValue] {
        var object = additionalFields
        if includesType { object["type"] = .string(type) }
        if let properties {
            object["properties"] = .object(properties.mapValues { .object($0.rawObject) })
        }
        if let required { object["required"] = .array(required.map(JSONSchemaValue.string)) }
        return object
    }

    init(from decoder: Decoder) throws {
        let value = try JSONSchemaValue(from: decoder)
        guard case .object(let object) = value else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON Schema 必须是对象"))
        }
        self.init(rawObject: object)
    }

    func encode(to encoder: Encoder) throws {
        try JSONSchemaValue.object(rawObject).encode(to: encoder)
    }

    struct JSONProperty: Codable, Sendable, Equatable {
        var type: String
        var description: String?
        var `enum`: [String]?
        /// 当 type 为 "array" 时描述元素结构。
        var items: JSONSchema?
        /// 嵌套 object 的属性结构（Gemini 降级转换也会递归读取）。
        var properties: [String: JSONProperty]?
        var required: [String]?
        private var additionalFields: [String: JSONSchemaValue]
        private var includesType: Bool

        init(
            type: String,
            description: String? = nil,
            enum: [String]? = nil,
            items: JSONSchema? = nil,
            properties: [String: JSONProperty]? = nil,
            required: [String]? = nil,
            additionalFields: [String: JSONSchemaValue] = [:]
        ) {
            self.type = type
            self.description = description
            self.enum = `enum`
            self.items = items
            self.properties = properties
            self.required = required
            self.additionalFields = additionalFields
            self.includesType = true
        }

        init(rawObject: [String: JSONSchemaValue]) {
            if case .string(let value)? = rawObject["type"] {
                type = value
                includesType = true
            } else {
                type = "string"
                includesType = false
            }
            if case .string(let value)? = rawObject["description"] { description = value } else { description = nil }
            if case .array(let values)? = rawObject["enum"] {
                `enum` = values.compactMap { if case .string(let string) = $0 { return string }; return nil }
            } else { `enum` = nil }
            if case .object(let value)? = rawObject["items"] { items = JSONSchema(rawObject: value) } else { items = nil }
            if case .object(let values)? = rawObject["properties"] {
                properties = values.mapValues { value in
                    if case .object(let object) = value { return JSONProperty(rawObject: object) }
                    return JSONProperty(type: "string")
                }
            } else { properties = nil }
            if case .array(let values)? = rawObject["required"] {
                required = values.compactMap { if case .string(let string) = $0 { return string }; return nil }
            } else { required = nil }
            additionalFields = rawObject.filter {
                !["type", "description", "enum", "items", "properties", "required"].contains($0.key)
            }
        }

        var rawObject: [String: JSONSchemaValue] {
            var object = additionalFields
            if includesType { object["type"] = .string(type) }
            if let description { object["description"] = .string(description) }
            if let `enum` { object["enum"] = .array(`enum`.map(JSONSchemaValue.string)) }
            if let items { object["items"] = .object(items.rawObject) }
            if let properties {
                object["properties"] = .object(properties.mapValues { .object($0.rawObject) })
            }
            if let required { object["required"] = .array(required.map(JSONSchemaValue.string)) }
            return object
        }

        init(from decoder: Decoder) throws {
            let value = try JSONSchemaValue(from: decoder)
            guard case .object(let object) = value else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON Schema 属性必须是对象"))
            }
            self.init(rawObject: object)
        }

        func encode(to encoder: Encoder) throws {
            try JSONSchemaValue.object(rawObject).encode(to: encoder)
        }
    }
}
