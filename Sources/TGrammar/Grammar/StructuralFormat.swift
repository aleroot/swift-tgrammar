/// A tokenizer-level symbol. String pieces are resolved against the tokenizer vocabulary.
public enum GrammarToken: Sendable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case id(Int32)
    case piece(String)
    public init(integerLiteral value: Int32) { self = .id(value) }
    public init(stringLiteral value: String) { self = .piece(value) }
}

/// A literal text delimiter or an atomic tokenizer symbol.
public enum TagBoundary: Sendable, Hashable, ExpressibleByStringLiteral {
    case text(String)
    case token(GrammarToken)
    public init(stringLiteral value: String) { self = .text(value) }
}

/// A region delimited by known text or tokens.
public struct StructuralTag: Sendable, Hashable {
    public let begin: TagBoundary
    public let content: StructuralFormat
    public let ends: [TagBoundary]

    public init(begin: TagBoundary, content: StructuralFormat, end: TagBoundary) {
        self.begin = begin
        self.content = content
        ends = [end]
    }
    public init(begin: TagBoundary, content: StructuralFormat, ends: [TagBoundary]) {
        self.begin = begin
        self.content = content
        self.ends = ends
    }
}

/// A declarative description of structured text, tool calls and reasoning regions.
///
/// Compose formats, wrap them in tags, then compile one matcher per generated sequence.
/// Unlimited regions automatically inherit the end delimiter of their nearest enclosing tag.
public indirect enum StructuralFormat: Sendable, Hashable {
    case literal(String)
    case jsonSchema(JSONSchema, options: JSONSchemaOptions = .init())
    case grammar(Grammar)
    /// A Lark grammar (with a `start` rule). Named special tokens such as `<|tool|>` resolve
    /// against the vocabulary the format is compiled with; `@name` references are unavailable.
    case lark(String)
    case regex(String)
    case anyText(excluding: [String] = [], maxTokens: Int? = nil, maxCharacters: Int? = nil)
    case sequence([StructuralFormat])
    case choice([StructuralFormat])
    case optional(StructuralFormat)
    case oneOrMore(StructuralFormat)
    case zeroOrMore(StructuralFormat)
    case repeated(StructuralFormat, minimum: Int, maximum: Int? = nil)
    case tag(StructuralTag)
    case triggeredTags(triggers: [String], tags: [StructuralTag], atLeastOne: Bool = false, stopAfterFirst: Bool = false, excluding: [String] = [])
    case tagsWithSeparator([StructuralTag], separator: String, atLeastOne: Bool = false, stopAfterFirst: Bool = false)
    case dispatch([TextDispatch], loop: Bool = true, excluding: [String] = [])
    case token(GrammarToken)
    case excludingTokens([GrammarToken])
    case anyTokens(excluding: [GrammarToken] = [], maxTokens: Int? = nil)
    case tokenTriggeredTags(triggers: [GrammarToken], tags: [StructuralTag], atLeastOne: Bool = false, stopAfterFirst: Bool = false, excluding: [GrammarToken] = [])
    case tokenDispatch([TokenDispatch], loop: Bool = true, excluding: [GrammarToken] = [])
    case captured(String, StructuralFormat)
    case temperature(Float, StructuralFormat)

    public struct TextDispatch: Sendable, Hashable {
        public let trigger: String
        public let content: StructuralFormat
        public init(_ trigger: String, _ content: StructuralFormat) { self.trigger = trigger; self.content = content }
    }
    public struct TokenDispatch: Sendable, Hashable {
        public let trigger: GrammarToken
        public let content: StructuralFormat
        public init(_ trigger: GrammarToken, _ content: StructuralFormat) { self.trigger = trigger; self.content = content }
    }

    /// Reads XGrammar's structural_tag JSON format, including string or atomic token boundaries.
    public init(json: String) throws(GrammarError) {
        do {
            let value = try JSONValue.parse(json)
            try self.init(value["type"]?.string == "structural_tag" ? value["format"] ?? .null : value)
        } catch {
            throw error.structuralTagError
        }
    }

    private init(_ value: JSONValue) throws(GrammarError) {
        try StackGuard.check()
        let type: String
        if let explicit = value["type"]?.string { type = explicit }
        else if value["begin"] != nil, value["end"] != nil, value["content"] != nil { type = "tag" }
        else { throw .conversion("A structural format requires a type") }
        func text(_ key: String) throws(GrammarError) -> String {
            guard let result = value[key]?.string else { throw .conversion("\(key) must be a string") }
            return result
        }
        func texts(_ key: String) throws(GrammarError) -> [String] {
            guard let raw = value[key] else { return [] }
            guard let array = raw.array, array.allSatisfy({ $0.string != nil }) else { throw .conversion("\(key) must be an array of strings") }
            return array.compactMap(\.string)
        }
        func schemaExcludes() throws(GrammarError) -> [String] {
            guard let raw = value["excludes"] else { return [] }
            guard let array = raw.array, array.allSatisfy({ !($0.string ?? "").isEmpty }) else {
                throw .conversion("JSONSchema format's excludes must be an array of non-empty strings")
            }
            return array.compactMap(\.string)
        }
        func budget(_ key: String) throws(GrammarError) -> Int? {
            guard let raw = value[key], raw != .null else { return nil }
            guard let n = raw.integer, n >= 0, n <= Int32.max else { throw .conversion("\(key) must be a non-negative 32-bit integer") }
            return Int(n)
        }
        func flag(_ key: String, default fallback: Bool = false) throws(GrammarError) -> Bool {
            guard let raw = value[key] else { return fallback }
            guard let boolean = raw.bool else { throw .conversion("\(key) must be a boolean") }
            return boolean
        }
        func token(_ value: JSONValue) throws(GrammarError) -> GrammarToken {
            if let piece = value.string { return .piece(piece) }
            if let n = value.integer, let id = Int32(exactly: n), id >= 0 { return .id(id) }
            throw .conversion("Token must be an integer ID or a vocabulary piece")
        }
        func tokens(_ key: String) throws(GrammarError) -> [GrammarToken] {
            guard let raw = value[key] else { return [] }
            guard let array = raw.array else { throw .conversion("\(key) must be an array") }
            return try array.map { value throws(GrammarError) in try token(value) }
        }
        func child(_ key: String = "content") throws(GrammarError) -> Self {
            guard let raw = value[key] else { throw .conversion("Missing \(key)") }
            return try Self(raw)
        }
        func elements() throws(GrammarError) -> [Self] {
            guard let array = value["elements"]?.array else { throw .conversion("elements must be an array") }
            return try array.map { value throws(GrammarError) in try Self(value) }
        }
        func boundary(_ raw: JSONValue) throws(GrammarError) -> TagBoundary {
            if let string = raw.string { return .text(string) }
            guard raw["type"]?.string == "token", let rawToken = raw["token"] else { throw .conversion("A tag boundary must be text or a token format") }
            return .token(try token(rawToken))
        }
        func tags() throws(GrammarError) -> [StructuralTag] {
            guard let array = value["tags"]?.array else { throw .conversion("tags must be an array") }
            return try array.map { value throws(GrammarError) in
                guard case .tag(let tag) = try Self(value) else { throw .conversion("tags must contain tag formats") }
                return tag
            }
        }
        let atLeastOne = try flag("at_least_one")
        let stopAfterFirst = try flag("stop_after_first")
        switch type {
        case "const_string": self = .literal(try text("value"))
        case "json_schema", "qwen_xml_parameter":
            guard let raw = value["json_schema"] else { throw .conversion("Missing json_schema") }
            let styleName = type == "qwen_xml_parameter" ? "qwen_xml" : value["style"]?.string ?? "json"
            guard let style = JSONSchemaOptions.Style(rawValue: styleName) else { throw .unsupported("JSON Schema style \(styleName) is not yet supported") }
            let schema = try raw.string.map { source throws(GrammarError) in try JSONSchema(json: source) } ?? JSONSchema(raw)
            self = .jsonSchema(schema, options: .init(anyWhitespace: true, anyOrder: try flag("any_order"), maxWhitespaceCount: try budget("max_whitespace_cnt"), style: style, excludes: try schemaExcludes()))
        case "grammar":
            guard let source = value["grammar"]?.string, !source.isEmpty else {
                throw .conversion("Grammar format must have a grammar field with a non-empty string")
            }
            switch value["syntax"] {
            case nil, .string("ebnf"): self = .grammar(try Grammar(ebnf: source))
            case .string("lark"): self = .lark(source)
            default: throw .conversion(#"Grammar format's syntax must be "ebnf" or "lark""#)
            }
        case "regex": self = .regex(try text("pattern"))
        case "any_text": self = .anyText(excluding: try texts("excludes"), maxTokens: try budget("max_tokens"), maxCharacters: try budget("max_chars"))
        case "sequence":
            let elements = try elements()
            guard !elements.isEmpty else { throw .conversion("Sequence format must have at least one element") }
            self = .sequence(elements)
        case "or": self = .choice(try elements())
        case "optional": self = .optional(try child())
        case "plus": self = .oneOrMore(try child())
        case "star": self = .zeroOrMore(try child())
        case "repeat":
            guard let min = value["min"]?.integer, let max = value["max"]?.integer,
                  min >= 0, min <= Int32.max, max == -1 || (max >= min && max <= Int32.max) else { throw .conversion("Invalid repetition bounds") }
            self = .repeated(try child(), minimum: Int(min), maximum: max == -1 ? nil : Int(max))
        case "tag":
            guard let begin = value["begin"], let end = value["end"] else { throw .conversion("A tag requires begin and end") }
            let ends = try (end.array ?? [end]).map { value throws(GrammarError) in try boundary(value) }
            self = .tag(.init(begin: try boundary(begin), content: try child(), ends: ends))
        case "triggered_tags": self = .triggeredTags(triggers: try texts("triggers"), tags: try tags(), atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst, excluding: try texts("excludes"))
        case "tags_with_separator": self = .tagsWithSeparator(try tags(), separator: try text("separator"), atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst)
        case "token":
            guard let raw = value["token"] else { throw .conversion("Missing token") }
            self = .token(try token(raw))
        case "exclude_token": self = .excludingTokens(try tokens("exclude_tokens"))
        case "any_tokens": self = .anyTokens(excluding: try tokens("exclude_tokens"), maxTokens: try budget("max_tokens"))
        case "token_triggered_tags": self = .tokenTriggeredTags(triggers: try tokens("trigger_tokens"), tags: try tags(), atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst, excluding: try tokens("exclude_tokens"))
        case "dispatch", "token_dispatch":
            guard let rows = value["rules"]?.array else { throw .conversion("rules must be an array") }
            if type == "dispatch" {
                let rules = try rows.map { row throws(GrammarError) -> TextDispatch in
                    guard let pair = row.array, pair.count == 2, let trigger = pair[0].string else { throw .conversion("Invalid dispatch rule") }
                    return .init(trigger, try Self(pair[1]))
                }
                self = .dispatch(rules, loop: try flag("loop", default: true), excluding: try texts("excludes"))
            } else {
                let rules = try rows.map { row throws(GrammarError) -> TokenDispatch in
                    guard let pair = row.array, pair.count == 2 else { throw .conversion("Invalid token dispatch rule") }
                    return .init(try token(pair[0]), try Self(pair[1]))
                }
                self = .tokenDispatch(rules, loop: try flag("loop", default: true), excluding: try tokens("exclude_tokens"))
            }
        default: throw .unsupported("Unknown structural format: \(type)")
        }
    }
}

extension Grammar {
    public convenience init(structuralFormat: StructuralFormat, tokenizerInfo: TokenizerInfo? = nil) throws(GrammarError) {
        self.init(storage: try StructuralTagConverter.convert(structuralFormat, tokenizerInfo: tokenizerInfo))
    }
    public convenience init(structuralTagJSON: String, tokenizerInfo: TokenizerInfo? = nil) throws(GrammarError) {
        try self.init(structuralFormat: StructuralFormat(json: structuralTagJSON), tokenizerInfo: tokenizerInfo)
    }
}

extension GrammarCompiler {
    public func compile(structuralFormat: StructuralFormat) throws(GrammarError) -> CompiledGrammar {
        try compile(Grammar(structuralFormat: structuralFormat, tokenizerInfo: tokenizerInfo))
    }
    public func compile(structuralTagJSON: String) throws(GrammarError) -> CompiledGrammar {
        try compile(structuralFormat: StructuralFormat(json: structuralTagJSON))
    }
}
