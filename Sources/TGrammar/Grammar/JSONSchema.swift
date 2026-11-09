import Foundation

/// An ordered JSON Schema. Source JSON preserves property order and numeric literals.
///
/// Build schemas with the factories below, or load an existing tool's parameter schema.
/// Conversion happens once, before token generation; schema objects never enter the hot path.
public struct JSONSchema: Sendable, Hashable, CustomStringConvertible {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }

    public init(json: String) throws(GrammarError) {
        let value = try JSONValue.parse(json)
        guard value.members != nil || value.bool != nil else { throw .conversion("Schema should be an object or bool") }
        self.value = value
    }

    public init(data: Data) throws(GrammarError) {
        guard let source = String(data: data, encoding: .utf8) else { throw .conversion("Schema is not UTF-8") }
        try self.init(json: source)
    }

    public var description: String { value.serialized() }

    /// A property in generation order. Optional properties can be omitted.
    public struct Property: Sendable, Hashable {
        public let name: String
        public let schema: JSONSchema
        public let isRequired: Bool

        public init(_ name: String, _ schema: JSONSchema, required: Bool = false) {
            self.name = name
            self.schema = schema
            isRequired = required
        }
    }

    public static let any = JSONSchema(.bool(true))
    public static let boolean = JSONSchema(.object([.init(key: "type", value: .string("boolean"))]))
    public static let null = JSONSchema(.object([.init(key: "type", value: .string("null"))]))

    public static func string(minLength: Int? = nil, maxLength: Int? = nil, pattern: String? = nil, format: String? = nil) -> Self {
        var members: [JSONValue.Member] = [.init(key: "type", value: .string("string"))]
        if let minLength { members.append(.init(key: "minLength", value: .number(String(minLength)))) }
        if let maxLength { members.append(.init(key: "maxLength", value: .number(String(maxLength)))) }
        if let pattern { members.append(.init(key: "pattern", value: .string(pattern))) }
        if let format { members.append(.init(key: "format", value: .string(format))) }
        return .init(.object(members))
    }

    public static func integer(minimum: Int64? = nil, maximum: Int64? = nil, multipleOf: Int64? = nil) -> Self {
        var members: [JSONValue.Member] = [.init(key: "type", value: .string("integer"))]
        if let minimum { members.append(.init(key: "minimum", value: .number(String(minimum)))) }
        if let maximum { members.append(.init(key: "maximum", value: .number(String(maximum)))) }
        if let multipleOf { members.append(.init(key: "multipleOf", value: .number(String(multipleOf)))) }
        return .init(.object(members))
    }

    public static func number(minimum: Double? = nil, maximum: Double? = nil) -> Self {
        var members: [JSONValue.Member] = [.init(key: "type", value: .string("number"))]
        if let minimum { members.append(.init(key: "minimum", value: .number(String(minimum)))) }
        if let maximum { members.append(.init(key: "maximum", value: .number(String(maximum)))) }
        return .init(.object(members))
    }

    public static func enumeration(_ values: [String]) -> Self {
        .init(.object([.init(key: "enum", value: .array(values.map(JSONValue.string)))]))
    }

    public static func constant(_ value: String) -> Self {
        .init(.object([.init(key: "const", value: .string(value))]))
    }

    public static func object(properties: [Property], additionalProperties: JSONSchema? = nil) -> Self {
        .init(.object([
            .init(key: "type", value: .string("object")),
            .init(key: "properties", value: .object(properties.map { .init(key: $0.name, value: $0.schema.value) })),
            .init(key: "required", value: .array(properties.filter(\.isRequired).map { .string($0.name) })),
            .init(key: "additionalProperties", value: additionalProperties?.value ?? .bool(false)),
        ]))
    }

    public static func array(items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil) -> Self {
        var members: [JSONValue.Member] = [.init(key: "type", value: .string("array")), .init(key: "items", value: items.value)]
        if let minItems { members.append(.init(key: "minItems", value: .number(String(minItems)))) }
        if let maxItems { members.append(.init(key: "maxItems", value: .number(String(maxItems)))) }
        return .init(.object(members))
    }

    public static func anyOf(_ schemas: [JSONSchema]) -> Self {
        .init(.object([.init(key: "anyOf", value: .array(schemas.map(\.value)))]))
    }

    public static func reference(_ pointer: String) -> Self {
        .init(.object([.init(key: "$ref", value: .string(pointer))]))
    }
}

/// Formatting and generation policy for JSON Schema conversion.
public struct JSONSchemaOptions: Sendable, Hashable {
    /// How tool arguments are spelled. `json` is ordinary JSON; the others are model-specific
    /// parameter encodings in which the root object becomes a list of tagged parameters.
    public enum Style: String, Sendable, Hashable, CaseIterable {
        case json
        /// `<parameter=key>value</parameter>`; raw strings, JSON for other values.
        case qwenXML = "qwen_xml"
        /// `<parameter name="key">value</parameter>`.
        case miniMaxXML = "minimax_xml"
        /// MiniMax M3 recursive namespace-prefixed XML elements.
        case miniMaxM3XML = "minimax_m3_xml"
        /// `<｜DSML｜parameter name="key" string="true|false">value</｜DSML｜parameter>`.
        case deepSeekXML = "deepseek_xml"
        /// DeepSeek V4.1: space-prefixed `<｜DSML｜ parameter ...>` tags.
        case deepSeekV41XML = "deepseek_v4_1_xml"
        /// `<arg_key>key</arg_key><arg_value>value</arg_value>`.
        case glmXML = "glm_xml"
        /// Recursive `<cofl:value name="key" type="raw|json|dict|list">` wrappers.
        case cohereXML = "cohere_xml"
        /// `<|open|>argument key="key" type="type"<|sep|>value<|close|>argument<|sep|>`.
        case kimiK3XML = "kimi_k3_xml"
        /// Gemma arguments: unquoted keys and `<|"|>`-delimited strings at every level.
        case gemma
        /// `<atem:parameter name="key">value</atem:parameter>`, Muse Glimmer's ATEM parameters.
        /// A Swift addition; XGrammar has no such style.
        case atemXML = "atem_xml"
        /// FunctionGemma arguments: Gemma's spelling with `<escape>` as the string delimiter.
        /// A Swift addition; XGrammar has no such style.
        case functionGemma = "function_gemma"
        /// Python keyword arguments, `key="value", n=1`, with Python literals as values:
        /// double-quoted strings, `True`/`False`/`None`, lists and dicts. Used by LFM2's
        /// `[name(key=value)]` calls. A Swift addition; XGrammar has no such style.
        case pythonic
    }
    public var style: Style
    /// Allow arbitrary JSON whitespace between structural elements.
    ///
    /// Off by default, unlike XGrammar's `any_whitespace=True`: output then follows one
    /// canonical layout (`{"a": 1, "b": [1, 2]}`, or `indent`), which is also the fastest to
    /// decode. With unbounded whitespace a model whose preferred token is masked out can keep
    /// choosing whitespace until its token limit (observed with greedy LFM2-2.6B). If you enable
    /// it for generation, also set `maxWhitespaceCount`.
    public var anyWhitespace: Bool
    /// Omitted additionalProperties/items are forbidden in strict mode.
    public var strict: Bool
    /// Allow known object properties in any order (each at most once).
    public var anyOrder: Bool
    /// Maximum consecutive whitespace codepoints; `nil` is unlimited.
    public var maxWhitespaceCount: Int?
    /// Exact pretty-print indentation when `anyWhitespace` is false.
    public var indent: Int?
    /// The separator between array items and object members; `nil` uses `","` with any
    /// whitespace or an indent and `", "` otherwise. With any whitespace it is surrounded by
    /// optional whitespace. Unconstrained values (`{}`) stay on one line and use it too, with
    /// `", "` as their default under an indent.
    public var itemSeparator: String?
    /// The separator between an object key and its value; `nil` uses `":"` with any whitespace
    /// and `": "` otherwise.
    public var keySeparator: String?
    /// Substrings forbidden in emitted unconstrained string content and keys. Patterns and
    /// formats retain their own contract. As upstream, length bounds are dropped when set.
    public var excludes: [String]

    public init(anyWhitespace: Bool = false, strict: Bool = true, anyOrder: Bool = false,
                maxWhitespaceCount: Int? = nil, indent: Int? = nil,
                itemSeparator: String? = nil, keySeparator: String? = nil, style: Style = .json,
                excludes: [String] = []) {
        self.style = style
        self.anyWhitespace = anyWhitespace
        self.strict = strict
        self.anyOrder = anyOrder
        self.maxWhitespaceCount = maxWhitespaceCount
        self.indent = indent
        self.itemSeparator = itemSeparator
        self.keySeparator = keySeparator
        self.excludes = excludes
    }

    var resolvedItemSeparator: String { itemSeparator ?? (anyWhitespace || indent != nil ? "," : ", ") }
    var resolvedKeySeparator: String { keySeparator ?? (anyWhitespace ? ":" : ": ") }
    /// The separator of unconstrained values, which are generated on one line.
    var compactItemSeparator: String { itemSeparator ?? (anyWhitespace ? "," : ", ") }
}

extension Grammar {
    public convenience init(jsonSchema: JSONSchema, options: JSONSchemaOptions = .init()) throws(GrammarError) {
        self.init(storage: try JSONSchemaConverter.convert(jsonSchema, options: options))
    }

    public convenience init(jsonSchema: String, options: JSONSchemaOptions = .init()) throws(GrammarError) {
        try self.init(jsonSchema: JSONSchema(json: jsonSchema), options: options)
    }
}

extension GrammarCompiler {
    public func compile(jsonSchema: JSONSchema, options: JSONSchemaOptions = .init()) throws(GrammarError) -> CompiledGrammar {
        try cached(.jsonSchema(jsonSchema, options)) { () throws(GrammarError) in
            try compileUncached(Grammar(jsonSchema: jsonSchema, options: options))
        }
    }

    public func compile(jsonSchema: String, options: JSONSchemaOptions = .init()) throws(GrammarError) -> CompiledGrammar {
        try compile(jsonSchema: JSONSchema(json: jsonSchema), options: options)
    }
}
