// JSON Schema -> grammar arena. Construction is separate from matching: all schema traversal,
// reference resolution and formatting decisions are paid once, at compilation.
//
// Tool-argument styles layer three encodings. The root object is a parameter list; each
// parameter value is raw text (strings) or JSON (everything else); anything nested deeper is
// plain JSON. `level` counts the containers entered so far and selects the encoding. The
// recursive styles (Cohere, MiniMax M3) and Gemma's spelling live in their own extensions and
// hook into the same object/array/string construction.
final class JSONSchemaConverter {
    typealias Style = JSONSchemaOptions.Style

    struct RuleKey: Hashable {
        let schema: JSONValue
        let depth: Int
        let context: Int
        /// Rules of unconstrained values, generated without indentation.
        let compact: Bool
    }
    var builder = GrammarBuilder()
    var rules: [RuleKey: Int32] = [:]
    let document: JSONValue
    private(set) var options: JSONSchemaOptions
    /// Whether unconstrained-value rules are being generated (see ``any(depth:)``).
    private var compact = false
    var style: Style { options.style }
    /// Containers entered so far: 0 at the root, 1 inside a root parameter, 2+ nested JSON.
    var level = 0
    /// Rules the formatting hooks need to recognise, created on first use.
    var shared: [SharedRule: Int32] = [:]
    enum SharedRule: Hashable {
        case whitespace, jsonCharacter, excludedJSONString
        case xmlString, xmlVariableName, xmlObject, xmlAny
        case cohereKey, cohereAnyScalar, cohereAnyList
        case gemmaStringContent, gemmaVariableName
    }
    /// Parameter-suffix rules shared by every `$ref` to the same target (DeepSeek, Cohere).
    var referenceSuffixRules: [String: Int32] = [:]
    /// Whether `anyOrder` currently applies; literal objects keep their declared order.
    var anyOrder: Bool

    init(_ schema: JSONSchema, options: JSONSchemaOptions) {
        document = schema.value
        self.options = options
        anyOrder = options.anyOrder
    }

    static func convert(_ schema: JSONSchema, options: JSONSchemaOptions) throws(GrammarError) -> GrammarStorage {
        guard options.indent.map({ $0 >= 0 && $0 <= 256 }) ?? true else { throw .conversion("indent must be between 0 and 256") }
        guard options.maxWhitespaceCount.map({ $0 >= 0 && $0 <= Int32.max }) ?? true else { throw .conversion("maxWhitespaceCount must be a non-negative Int32") }
        guard options.excludes.allSatisfy({ !$0.isEmpty }) else { throw .conversion("JSONSchema format's excludes must be an array of non-empty strings") }
        switch options.style {
        case .json, .gemma, .functionGemma, .pythonic: break
        case .cohereXML, .miniMaxM3XML:
            guard options.excludes.isEmpty else { throw .unsupported("JSONSchemaFormat.excludes is not supported for \(options.style.rawValue)") }
        default:
            // XML formatting adds whitespace outside a raw string's rule: an exclusion that starts
            // or ends with whitespace could straddle that boundary and be bypassed.
            let padding: Set<UInt8> = [9, 10, 13, 32]
            guard options.excludes.allSatisfy({ !padding.contains($0.utf8.first!) && !padding.contains($0.utf8.last!) }) else {
                throw .conversion("XML string excludes must not start or end with formatting whitespace")
            }
        }
        let converter = Self(schema, options: options)
        let root = try converter.rule(schema.value, depth: 0, hint: "root")
        return GrammarNormalizer.apply(converter.builder.finish(rootRuleID: root))
    }

    // MARK: Expression helpers

    func literal(_ value: String) -> Int32 { builder.addByteString(value) }
    func empty() -> Int32 { builder.addEmptyString() }
    func ref(_ rule: Int32) -> Int32 { builder.addRuleRef(rule) }
    func sequence(_ exprs: [Int32]) -> Int32 { exprs.count == 1 ? exprs[0] : builder.addSequence(exprs) }
    /// An empty choice accepts nothing; emitting it as such keeps the grammar well formed.
    func choice(_ exprs: [Int32]) -> Int32 { exprs.isEmpty ? unsatisfiable() : exprs.count == 1 ? exprs[0] : builder.addChoices(exprs) }
    func repeatExpr(_ expr: Int32, min: Int, max: Int = -1, hint: String = "repeat") -> Int32 {
        builder.addRepeat(exprID: expr, min: Int32(min), max: Int32(max), nameHint: hint)
    }
    func regex(_ source: String, json: Bool = false) -> Int32 { builder.addRegex(source.utf8, isJSONString: json) }
    func unsatisfiable() -> Int32 { builder.addCharacterClass([0 ... 0x10FFFF], isNegated: true) }
    func anyCharacter() -> Int32 { builder.addCharacterClass([0 ... 0x10FFFF]) }

    func sharedRule(_ kind: SharedRule, _ make: () throws(GrammarError) -> Int32) throws(GrammarError) -> Int32 {
        if let id = shared[kind] { return id }
        let id = builder.addEmptyRule(hint: Self.sharedRuleHint(kind))
        shared[kind] = id // Declared first: the body may refer back to the rule.
        builder.updateRuleBody(id, try make())
        return id
    }

    private static func sharedRuleHint(_ kind: SharedRule) -> String {
        switch kind {
        case .whitespace: "json_ws"
        case .jsonCharacter: "json_char"
        case .excludedJSONString: "json_string_exclude"
        case .xmlString: "xml_string"
        case .xmlVariableName: "xml_variable_name"
        case .xmlObject: "xml_object"
        case .xmlAny: "xml_any"
        case .cohereKey: "cohere_key"
        case .cohereAnyScalar: "cohere_any_scalar"
        case .cohereAnyList: "cohere_any_list"
        case .gemmaStringContent: "gemma_string_content"
        case .gemmaVariableName: "gemma_variable_name"
        }
    }

    func patternExpression(_ source: String, json: Bool) throws(GrammarError) -> Int32 {
        // Use the compact regex automaton when it can represent the contract. Upstream keeps
        // Unicode JSON patterns and expressions made unmatchable by JSON byte filtering as CFGs.
        if !json || source.utf8.allSatisfy({ (0x20 ... 0x7E).contains($0) }) {
            do {
                let parsed = try RegexFSMBuilder.build(Array(source.utf8), forbidding: json ? GrammarFSMBuilder.jsonStringForbiddenBytes : ByteSet())
                if parsed.reachableStates().contains(where: parsed.isEndState) { return regex(source, json: json) }
            } catch { /* The CFG converter supports additional regex constructs. */ }
        }
        return ref(builder.importGrammar(try Grammar(regex: source).storage))
    }

    private struct ExclusionKey: Hashable, Sendable { var pattern: String; var excludes: [String] }
    private static let exclusionAutomata = BoundedMemo<ExclusionKey, FSMWithStartEnd>(capacity: 64)

    /// The minimal DFA of `pattern` without any of `excludes`, memoized: the same string body and
    /// exclusions recur in every schema of a tool set.
    private static func excludingAutomaton(_ pattern: String, excludes: [String]) throws(GrammarError) -> FSMWithStartEnd {
        let key = ExclusionKey(pattern: pattern, excludes: excludes)
        if let cached = exclusionAutomata.value(for: key) { return cached }
        let parsed = try RegexFSMBuilder.build(pattern)
        guard let exclusion = GrammarFSMBuilder.tagDispatch(.init(loopAfterDispatch: false, excludes: excludes.map { Array($0.utf8) })) else {
            throw .conversion("Cannot build string exclusions")
        }
        // The product of the regex and exclusion automata is far from minimal (397 states against
        // 39 for the JSON string body); every state becomes a rule with masks of its own.
        let filtered = try FSMWithStartEnd.intersect(parsed, exclusion).minimized(maxStates: 1_000_000)
        exclusionAutomata.insert(filtered, for: key)
        return filtered
    }

    /// The regex automaton for `pattern` with every exclusion removed, as a leaf rule.
    func excludingString(_ pattern: String, excludes: [String]? = nil, hint: String, closing: String = "", names: [String] = []) throws(GrammarError) -> Int32 {
        var filtered = try Self.excludingAutomaton(pattern, excludes: excludes ?? options.excludes)
        if !names.isEmpty {
            // Names sharing a suffix collapse under minimization (40 tool-style names: 6,379
            // states to 238), which keeps the product and its rules small.
            let keys = try JSONKeyAutomata.keysExcluding(names).minimized(maxStates: 1_000_000)
            filtered = try FSMWithStartEnd.intersect(filtered, keys).minimized(maxStates: 1_000_000)
        }
        return try builder.addLeafFSM(filtered, hint: hint, closing: closing)
    }

    /// Whether unconstrained text may contain `text`; raw spellings are checked as written,
    /// JSON spellings after escaping.
    func allowedText(_ text: String, excludes: [String]? = nil) -> Bool {
        (excludes ?? options.excludes).allSatisfy { !text.contains($0) }
    }

    func allowedLiteral(_ value: JSONValue, raw: Bool = false) -> Bool {
        guard !options.excludes.isEmpty else { return true }
        if let string = value.string {
            return allowedText(raw ? string : String(JSONValue.quote(string).dropFirst().dropLast()))
        }
        if let values = value.array { return values.allSatisfy { allowedLiteral($0) } }
        if let members = value.members {
            return members.allSatisfy { allowedLiteral(.string($0.key)) && allowedLiteral($0.value) }
        }
        return true
    }

    // MARK: Whitespace and separators

    func whitespace() -> Int32 {
        // Unbounded whitespace stays inline, as upstream's `[ \n\r\t]*`: it then belongs to the
        // enclosing rule's automaton, whose token masks stay precise. A separate rule would end
        // with no lookahead and leave every whitespace-led token uncertain at decode time.
        if options.maxWhitespaceCount == nil { return builder.addCharacterClassStar([9 ... 10, 13 ... 13, 32 ... 32]) }
        if let id = shared[.whitespace] { return ref(id) }
        let char = builder.addCharacterClass([9 ... 10, 13 ... 13, 32 ... 32])
        let id = builder.addRule(hint: "json_ws", bodyExprID: repeatExpr(char, min: 0, max: options.maxWhitespaceCount ?? -1, hint: "json_ws"))
        shared[.whitespace] = id
        return ref(id)
    }

    /// Parameter lists and recursive XML elements separate members with whitespace only.
    var whitespaceSeparated: Bool {
        switch style {
        case .json, .gemma, .functionGemma, .pythonic: false
        case .cohereXML, .miniMaxM3XML: true
        default: level <= 1
        }
    }

    func startSeparator(depth: Int) -> Int32 {
        if whitespaceSeparated || options.anyWhitespace { return whitespace() }
        guard let indent = options.indent else { return empty() }
        return literal("\n" + String(repeating: " ", count: (depth + 1) * indent))
    }
    func middleSeparator(depth: Int) -> Int32 {
        if whitespaceSeparated { return whitespace() }
        if options.anyWhitespace { return sequence([whitespace(), literal(options.resolvedItemSeparator), whitespace()]) }
        return sequence([literal(options.resolvedItemSeparator), startSeparator(depth: depth)])
    }
    func endSeparator(depth: Int) -> Int32 {
        if whitespaceSeparated || options.anyWhitespace { return whitespace() }
        guard let indent = options.indent else { return empty() }
        return literal("\n" + String(repeating: " ", count: depth * indent))
    }
    func colon() -> Int32 {
        options.anyWhitespace ? sequence([whitespace(), literal(options.resolvedKeySeparator), whitespace()]) : literal(options.resolvedKeySeparator)
    }

    // MARK: Rules

    var context: Int {
        switch style {
        case .json, .gemma, .functionGemma, .miniMaxM3XML: 0
        case .cohereXML, .pythonic: level == 0 ? 0 : 1
        default: min(level, 2)
        }
    }

    func rule(_ schema: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        guard depth < 512 else { throw .conversion("Schema is nested deeper than 512 levels") }
        try StackGuard.check()
        if let pointer = schema["$ref"] {
            guard let pointer = pointer.string else { throw .conversion("$ref must be a string") }
            return try rule(resolve(pointer), depth: depth, hint: hint)
        }
        if let direct = try directRule(schema) { return direct }
        let key = RuleKey(schema: schema, depth: options.anyWhitespace || options.indent == nil ? 0 : depth, context: context, compact: compact)
        // Scalar values cannot recurse, so each occurrence gets its own rule: a rule referenced
        // once has an exact lookahead derived from what follows it, which resolves the tokens
        // that close the value at compile time instead of replaying them at every decode step.
        let isScalar = renderedType(schema).map { ["string", "number", "boolean", "null"].contains($0) } ?? false
        if !isScalar, let cached = rules[key] { return cached }
        let id = builder.addEmptyRule(hint: hint)
        if !isScalar { rules[key] = id } // Declare before traversing children: recursive $refs share this rule.
        let body = try expression(schema, depth: depth, hint: hint)
        builder.updateRuleBody(id, body)
        return id
    }

    /// Shared rules the property formatters recognise by identity: raw strings keep their own
    /// whitespace, and unconstrained parameter lists reuse one rule.
    private func directRule(_ schema: JSONValue) throws(GrammarError) -> Int32? {
        switch style {
        case .json, .gemma, .functionGemma, .pythonic: return nil
        case .miniMaxM3XML: return Self.isUnconstrainedString(schema) ? try miniMaxM3String() : nil
        case .cohereXML: return Self.isUnconstrainedString(schema) ? try xmlString() : nil
        default:
            guard level <= 1 else { return nil }
            if Self.isUnconstrainedString(schema) { return try xmlString() }
            if Self.isUnconstrained(schema) { return level == 0 ? try xmlObject() : try xmlAny() }
            return nil
        }
    }

    static func isUnconstrainedString(_ schema: JSONValue) -> Bool {
        schema["type"]?.string == "string" && ["pattern", "format", "minLength", "maxLength", "enum", "const"].allSatisfy { schema[$0] == nil }
    }

    /// `true`, `{}` and schemas with only annotations accept any value.
    static func isUnconstrained(_ schema: JSONValue) -> Bool {
        if schema.bool == true { return true }
        guard let members = schema.members else { return false }
        return members.allSatisfy { ["title", "description", "default", "examples", "$schema", "$id", "$comment", "$defs", "definitions"].contains($0.key) }
    }

    /// The JSON type a schema always renders as, when that can be decided without resolving
    /// references or combinators. Integers and numbers both render as `number`.
    func renderedType(_ schema: JSONValue?) -> String? {
        guard let schema, schema.members != nil else { return nil }
        if let type = schema["type"]?.string { return type == "integer" ? "number" : type }
        if schema["type"] != nil || schema["$ref"] != nil || schema["anyOf"] != nil || schema["oneOf"] != nil || schema["allOf"] != nil { return nil }
        if let value = schema["const"] { return Self.jsonType(of: value) }
        if let values = schema["enum"]?.array {
            let types = Set(values.map(Self.jsonType(of:)))
            return types.count == 1 ? types.first : nil
        }
        return inferredType(schema)
    }

    static func jsonType(of value: JSONValue) -> String {
        switch value {
        case .string: "string"
        case .number: "number"
        case .bool: "boolean"
        case .null: "null"
        case .object: "object"
        case .array: "array"
        }
    }

    func inferredType(_ schema: JSONValue) -> String? {
        if ["properties", "additionalProperties", "unevaluatedProperties", "patternProperties", "propertyNames"].contains(where: { schema[$0] != nil }) { return "object" }
        if ["items", "prefixItems", "unevaluatedItems"].contains(where: { schema[$0] != nil }) { return "array" }
        return nil
    }

    /// The alternatives of a union-like schema, each rendered with its own attributes by the
    /// DeepSeek and Cohere wrappers. Mixed enums split into constants.
    func compositeOptions(_ schema: JSONValue?, splitEnums: Bool) throws(GrammarError) -> [JSONValue]? {
        guard let schema, schema.members != nil else { return nil }
        for keyword in ["anyOf", "oneOf"] {
            if let value = schema[keyword] {
                guard let values = value.array, !values.isEmpty else { throw .conversion("\(keyword) must be a non-empty array") }
                return values
            }
        }
        if let value = schema["allOf"] {
            guard let values = value.array, !values.isEmpty else { throw .conversion("allOf must be a non-empty array") }
            return values.count == 1 ? values : nil
        }
        if let types = schema["type"]?.array, !types.isEmpty {
            guard types.allSatisfy({ $0.string != nil }) else { throw .conversion("type must contain type names") }
            return types.map { schema.replacing("type", with: $0) }
        }
        if splitEnums, let values = schema["enum"]?.array, !values.isEmpty {
            return values.map { .object([.init(key: "const", value: $0)]) }
        }
        return nil
    }

    func expression(_ schema: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        if let bool = schema.bool {
            guard bool else { throw .conversion("Schema 'false' cannot accept any value") }
            return try any(depth: depth)
        }
        guard schema.members != nil else { throw .conversion("Schema should be an object or bool") }
        if let pointer = schema["$ref"] {
            guard let pointer = pointer.string else { throw .conversion("$ref must be a string") }
            return ref(try rule(resolve(pointer), depth: depth, hint: hint))
        }
        if let value = schema["const"] { return try constant(value, depth: depth, hint: hint) }
        if let value = schema["enum"] {
            guard let values = value.array, !values.isEmpty else { throw .conversion("enum array must not be empty") }
            return try enumeration(values, depth: depth, hint: hint)
        }
        for keyword in ["anyOf", "oneOf"] {
            if let value = schema[keyword] {
                guard let values = value.array, !values.isEmpty else { throw .conversion("\(keyword) must be a non-empty array") }
                // Upstream uses union semantics for oneOf when branches cannot be proven disjoint.
                return choice(try values.enumerated().map { index, value throws(GrammarError) in
                    ref(try rule(value, depth: depth, hint: hint + "_case_\(index)"))
                })
            }
        }
        if let value = schema["allOf"] {
            guard let values = value.array, !values.isEmpty else { throw .conversion("allOf must be a non-empty array") }
            if values.count == 1 { return try expression(values[0], depth: depth, hint: hint) }
            // Compatible branches are intersected. Upstream renders every multi-branch allOf as an
            // unconstrained value; branches that cannot be intersected keep that fallback.
            let merged: JSONValue
            do { merged = try merge(values) } catch .unsupported { return try any(depth: depth) }
            return try expression(merged, depth: depth, hint: hint)
        }
        if let types = schema["type"]?.array {
            // As upstream, an empty type array is the schema without `type`.
            if types.isEmpty { return try expression(schema.removing("type"), depth: depth, hint: hint) }
            guard types.allSatisfy({ $0.string != nil }) else { throw .conversion("type must contain type names") }
            return choice(try types.map { type throws(GrammarError) in
                ref(try rule(schema.replacing("type", with: type), depth: depth, hint: hint + "_type"))
            })
        }
        if schema["type"] != nil, schema["type"]?.string == nil { throw .conversion("Type should be a string") }
        guard let type = schema["type"]?.string ?? inferredType(schema) else { return try any(depth: depth) }
        switch type {
        case "string": return try string(schema, hint: hint)
        case "integer": return try integer(schema, hint: hint)
        case "number":
            // As upstream, multipleOf is validated but not enforced on numbers.
            _ = try Self.multipleOf(schema)
            if ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"].contains(where: { schema[$0] != nil }) {
                return regex(try DecimalRangePattern.make(schema))
            }
            return regex(#"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?"#)
        case "boolean": return style == .pythonic ? choice([literal("True"), literal("False")]) : choice([literal("true"), literal("false")])
        case "null": return literal(style == .pythonic ? "None" : "null")
        case "array": return try array(schema, depth: depth, hint: hint)
        case "object": return try object(schema, depth: depth, hint: hint)
        default: throw .conversion("Unsupported type \"\(type)\"")
        }
    }

    /// Resolves `pointer` and follows further pure `$ref` hops, rejecting a chain that returns to
    /// a reference already on it without passing through schema content (it would only yield
    /// self-referencing rules that accept nothing).
    func resolve(_ pointer: String) throws(GrammarError) -> JSONValue {
        var chain = [pointer]
        var target = try resolveOnce(pointer)
        while let next = target["$ref"]?.string {
            let seen = chain.contains(next)
            chain.append(next)
            if seen { throw .conversion("Circular $ref chain with no schema content: " + chain.joined(separator: " -> ")) }
            target = try resolveOnce(next)
        }
        return target
    }

    /// Resolves one local reference. The fragment is a JSON Pointer (RFC 6901 section 6): URI
    /// percent-encoding is undone first, then the pointer splits on `/` (an empty token is the key
    /// `""`), then each token decodes `~1` and `~0`. Objects are indexed by key; arrays only by a
    /// canonical zero-based index.
    private func resolveOnce(_ pointer: String) throws(GrammarError) -> JSONValue {
        guard pointer.hasPrefix("#") else { throw .unsupported("Only local JSON Schema references are supported: \(pointer)") }
        if pointer == "#" { return document }
        guard pointer.hasPrefix("#/") else { throw .conversion("Invalid JSON pointer: \(pointer)") }
        var value = document
        for component in Self.percentDecoded(pointer.utf8.dropFirst(2)).split(separator: "/", omittingEmptySubsequences: false) {
            let key = String(component).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if value.members != nil {
                guard let next = value[key] else { throw .conversion("Cannot find field '\(key)' in \(pointer)") }
                value = next
            } else if let array = value.array {
                let isCanonical = !key.isEmpty && key.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
                    && (key.utf8.count == 1 || key.utf8.first != UInt8(ascii: "0"))
                guard isCanonical, let index = Int(key), index < array.count else {
                    throw .conversion("Cannot find array index '\(key)' in \(pointer)")
                }
                value = array[index]
            } else {
                throw .conversion("Cannot find field '\(key)' in \(pointer)")
            }
        }
        return value
    }

    /// Decodes URI percent-encoding (`%2F` -> `/`); malformed sequences are kept verbatim.
    private static func percentDecoded(_ bytes: Substring.UTF8View) -> String {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            if input[i] == UInt8(ascii: "%"), i + 2 < input.count, let high = hex(input[i + 1]), let low = hex(input[i + 2]) {
                output.append(high << 4 | low)
                i += 3
            } else {
                output.append(input[i])
                i += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func merge(_ values: [JSONValue]) throws(GrammarError) -> JSONValue {
        var result = JSONValue.object([])
        for value in values {
            guard let members = value.members else { throw .unsupported("allOf requires object schemas") }
            for member in members {
                if let previous = result[member.key], previous != member.value {
                    switch member.key {
                    case "properties":
                        var combined = previous
                        for property in member.value.members ?? [] {
                            if let old = combined[property.key] { combined = combined.replacing(property.key, with: try merge([old, property.value])) }
                            else { combined = combined.replacing(property.key, with: property.value) }
                        }
                        result = result.replacing(member.key, with: combined)
                    case "required":
                        var combined = previous.array ?? []
                        for value in member.value.array ?? [] where !combined.contains(value) { combined.append(value) }
                        result = result.replacing(member.key, with: .array(combined))
                    case "minimum", "exclusiveMinimum", "minLength", "minItems", "minProperties":
                        guard let a = previous.double, let b = member.value.double else { throw .conversion("Invalid \(member.key)") }
                        result = result.replacing(member.key, with: a >= b ? previous : member.value)
                    case "maximum", "exclusiveMaximum", "maxLength", "maxItems", "maxProperties":
                        guard let a = previous.double, let b = member.value.double else { throw .conversion("Invalid \(member.key)") }
                        result = result.replacing(member.key, with: a <= b ? previous : member.value)
                    case "title", "description", "$defs", "definitions": break
                    default: throw .unsupported("Cannot intersect allOf keyword \(member.key)")
                    }
                } else { result = result.replacing(member.key, with: member.value) }
            }
        }
        return result
    }

    /// Counts become Int32 repetition bounds; an upper bound beyond that range is unbounded.
    func bound(_ schema: JSONValue, _ name: String, default defaultValue: Int = 0) throws(GrammarError) -> Int {
        guard let value = schema[name] else { return defaultValue }
        guard let integer = value.integer else { throw .conversion("\(name) must be an integer") }
        if integer < 0 {
            // As upstream, a negative item minimum is no minimum.
            if name == "minItems" || name == "minContains" { return 0 }
            throw .conversion("\(name) must be a non-negative integer")
        }
        if integer > Int32.max {
            guard name.hasPrefix("max") else { throw .conversion("\(name) must not exceed \(Int32.max)") }
            return -1
        }
        return Int(integer)
    }

    // MARK: Literals

    func constant(_ value: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .gemma, .functionGemma: return gemmaLiteral(value)
        case .pythonic: return try pythonConstant(value, depth: depth, hint: hint)
        case .miniMaxM3XML: return try miniMaxM3Literal(value, hint: hint)
        case .cohereXML: return literal(Self.rawText(value))
        case .json: break
        default:
            guard level <= 1 else { break }
            if level == 0, let members = value.members {
                // A root object constant is still a parameter list. Its order stays fixed even
                // with anyOrder: the general any-order rule would permit repeated keys.
                let properties = JSONValue.object(members.map { .init(key: $0.key, value: .object([.init(key: "const", value: $0.value)])) })
                let schema = JSONValue.object([.init(key: "properties", value: properties), .init(key: "required", value: .array(members.map { .string($0.key) })),
                                               .init(key: "additionalProperties", value: .bool(false))])
                let saved = anyOrder
                anyOrder = false
                defer { anyOrder = saved }
                return try object(schema, depth: depth, hint: hint)
            }
            return allowedLiteral(value, raw: true) ? literal(Self.rawText(value)) : unsatisfiable()
        }
        return allowedLiteral(value) ? literal(value.serialized()) : unsatisfiable()
    }

    /// Strings are emitted as written; other literals keep their JSON spelling.
    static func rawText(_ value: JSONValue) -> String { value.string ?? value.serialized() }

    func enumeration(_ values: [JSONValue], depth: Int, hint: String) throws(GrammarError) -> Int32 {
        if style == .json {
            let allowed = values.filter { allowedLiteral($0) }
            return allowed.isEmpty ? unsatisfiable() : choice(allowed.map { literal($0.serialized()) })
        }
        return choice(try values.map { value throws(GrammarError) in try constant(value, depth: depth, hint: hint) })
    }

    // MARK: Strings

    func jsonCharacter() -> Int32 {
        if let id = shared[.jsonCharacter] { return ref(id) }
        let raw = builder.addCharacterClass([0 ... 31, 34 ... 34, 92 ... 92], isNegated: true)
        let escaped = choice([regex(#"\\["\\/bfnrt]"#), regex(JSONStringPatterns.unicodeEscape())])
        let id = builder.addRule(hint: "json_char", bodyExprID: choice([raw, escaped]))
        shared[.jsonCharacter] = id
        return ref(id)
    }

    struct StringBounds {
        var min: Int
        var max: Int
        var isBounded: Bool { min != 0 || max != -1 }
    }

    func stringBounds(_ schema: JSONValue) throws(GrammarError) -> StringBounds {
        let bounds = StringBounds(min: try bound(schema, "minLength"), max: try bound(schema, "maxLength", default: -1))
        guard bounds.max == -1 || bounds.min <= bounds.max else { throw .conversion("minLength is greater than maxLength") }
        return bounds
    }

    func stringPattern(_ schema: JSONValue) throws(GrammarError) -> String? {
        guard let pattern = schema["pattern"] else { return nil }
        guard let source = pattern.string else { throw .conversion("pattern must be a string") }
        return source
    }

    func string(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .gemma, .functionGemma: return try gemmaString(schema, hint: hint)
        case .pythonic: return try pythonString(schema, hint: hint)
        case .miniMaxM3XML: return try miniMaxM3String(schema)
        case .cohereXML: return try cohereString(schema, hint: hint)
        case .json: return try jsonString(schema, hint: hint)
        default: return level <= 1 ? try rawParameterString(schema, hint: hint) : try jsonString(schema, hint: hint)
        }
    }

    func jsonString(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        let bounds = try stringBounds(schema)
        if let pattern = try stringPattern(schema) {
            return sequence([literal("\""), try patternExpression(pattern, json: true), literal("\"")])
        }
        if let format = schema["format"]?.string, let pattern = JSONSchemaFormats.pattern(for: format, raw: false) {
            // Upstream's built-in formats use CFG expansion: their quoted-string patterns and
            // optional URI paths need the regex converter's full grammar representation.
            return sequence([literal("\""), ref(builder.importGrammar(try Grammar(regex: pattern).storage)), literal("\"")])
        }
        // Count Unicode characters, rather than UTF-8 bytes. Escape sequences consume one
        // decoded character; a surrogate pair is kept together when length is bounded.
        // Keep the loop in one automaton. A CFG repetition of a one-character subrule makes
        // virtually every multi-character vocabulary token cross a rule boundary, forcing
        // expensive replay at every generated token. A length bound repeats the one-character
        // automaton through a counted edge: unrolled, every position would be an automaton state
        // with a mask of its own.
        if !options.excludes.isEmpty {
            let body = try sharedRule(.excludedJSONString) { () throws(GrammarError) in
                try excludingString(JSONStringPatterns.scalar + "*", hint: "json_string_exclude", closing: "\"")
            }
            return sequence([literal("\""), ref(body)])
        }
        guard bounds.isBounded else { return regex("\"" + JSONStringPatterns.scalar + "*\"") }
        let characters = repeatExpr(regex(JSONStringPatterns.scalar), min: bounds.min, max: bounds.max, hint: hint + "_characters")
        return sequence([literal("\""), characters, literal("\"")])
    }

    /// A raw string regex for a known format or an explicit pattern.
    func rawPatternExpression(_ schema: JSONValue) throws(GrammarError) -> Int32? {
        if let format = schema["format"]?.string, let pattern = JSONSchemaFormats.pattern(for: format, raw: true) {
            return ref(builder.importGrammar(try Grammar(regex: pattern).storage))
        }
        if let pattern = try stringPattern(schema) { return try patternExpression(pattern, json: false) }
        return nil
    }

    // MARK: Any

    func any(depth: Int) throws(GrammarError) -> Int32 {
        switch style {
        case .miniMaxM3XML: throw .unsupported("minimax_m3_xml does not support unconstrained schemas")
        case .cohereXML: return level == 0 ? ref(try xmlObject()) : try cohereAnyBody(depth: depth)
        case .pythonic where level == 0:
            // Any keyword arguments: Python calls have no unconstrained root value.
            return try object(.object([.init(key: "type", value: .string("object")), .init(key: "additionalProperties", value: .bool(true))]),
                              depth: depth, hint: "root")
        case .json, .gemma, .functionGemma, .pythonic: break
        default:
            if level == 0 { return ref(try xmlObject()) }
            if level == 1 { return ref(try xmlAny()) }
        }
        // Unconstrained values are compact whatever the indentation, as upstream's basic rules:
        // an indented unconstrained value would need a rule per depth without end.
        if compact { return try anyValue(depth: depth) }
        let saved = options
        compact = true
        options.indent = nil
        options.itemSeparator = options.compactItemSeparator
        defer {
            options = saved
            compact = false
        }
        return try anyValue(depth: 0)
    }

    private func anyValue(depth: Int) throws(GrammarError) -> Int32 {
        choice(try Self.anyValueSchemas.map { schema throws(GrammarError) in ref(try rule(schema, depth: depth, hint: "json_value")) })
    }

    static let anyValueSchemas: [JSONValue] = [
        .object([.init(key: "type", value: .string("string"))]),
        .object([.init(key: "type", value: .string("number"))]),
        .object([.init(key: "type", value: .string("boolean"))]),
        .object([.init(key: "type", value: .string("null"))]),
        .object([.init(key: "type", value: .string("array")), .init(key: "items", value: .bool(true))]),
        .object([.init(key: "type", value: .string("object")), .init(key: "additionalProperties", value: .bool(true))]),
    ]
    static func typeSchema(_ type: String) -> JSONValue { .object([.init(key: "type", value: .string(type))]) }

    // MARK: Numbers

    /// The validated `multipleOf` of a numeric schema: upstream rejects only non-numbers and
    /// values that are not positive.
    static func multipleOf(_ schema: JSONValue) throws(GrammarError) -> Double? {
        guard let raw = schema["multipleOf"] else { return nil }
        guard let value = raw.double, value.isFinite else { throw .conversion("multipleOf must be a number") }
        guard value > 0 else { throw .conversion("multipleOf must be greater than 0") }
        return value
    }

    func integer(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        func integerBound(_ name: String) throws(GrammarError) -> Int64? {
            guard let value = schema[name] else { return nil }
            if let number = value.integer { return number }
            guard let double = value.double, double == double.rounded(.towardZero) else { throw .conversion("Integer constraint must be a whole number") }
            // The text was not an Int64; a whole double here is outside the signed 64-bit range
            // (or is ±2^63 after precision loss), as upstream rejects.
            guard double > -9_223_372_036_854_775_808.0, double < 9_223_372_036_854_775_808.0 else {
                throw .conversion("Integer constraint \(name) exceeds the signed 64-bit limit")
            }
            return Int64(double)
        }
        var low = try integerBound("minimum"), high = try integerBound("maximum")
        if let value = try integerBound("exclusiveMinimum") {
            guard value < .max else { throw .conversion("Unsatisfiable integer range") }
            low = max(low ?? .min, value + 1)
        }
        if let value = try integerBound("exclusiveMaximum") {
            guard value > .min else { throw .conversion("Unsatisfiable integer range") }
            high = min(high ?? .max, value - 1)
        }
        guard low == nil || high == nil || low! <= high! else { throw .conversion("Unsatisfiable integer range") }
        // As upstream, a multipleOf the integer grammar cannot express (a fraction, a divisor
        // above 1024, a half-bounded or wider than 10,000-integer range) is ignored, keeping
        // only the range; only a non-positive or non-numeric value is an error.
        if let divisor = try Self.multipleOf(schema), divisor == divisor.rounded(), divisor <= 1024 {
            let divisor = Int64(divisor)
            if let low, let high {
                let span = high.subtractingReportingOverflow(low)
                if !span.overflow, span.partialValue <= 10000 {
                    var values: [Int32] = []
                    var number = low
                    while true {
                        if number % divisor == 0 { values.append(literal(String(number))) }
                        if number == high { break }
                        number += 1
                    }
                    guard !values.isEmpty else { throw .conversion("range contains no multipleOf value") }
                    return choice(values)
                }
            } else if low == nil && high == nil {
                let count = Int(divisor)
                let states = (0 ..< count).map { builder.addEmptyRule(hint: hint + "_mod_\($0)") }
                for state in 0 ..< count {
                    var transitions: [Int32] = []
                    if state == 0 { transitions.append(empty()) }
                    for digit in 0 ... 9 {
                        transitions.append(sequence([literal(String(digit)), ref(states[(state * 10 + digit) % count])]))
                    }
                    builder.updateRuleBody(states[state], choice(transitions))
                }
                let first = choice((1 ... 9).map { digit in sequence([literal(String(digit)), ref(states[digit % count])]) })
                return choice([literal("0"), sequence([choice([empty(), literal("-")]), first])])
            }
        }
        return regex(IntegerRangePattern.make(minimum: low, maximum: high))
    }

    // MARK: Arrays

    struct ArraySpec {
        var prefix: [JSONValue]
        /// `nil` forbids items beyond the prefix.
        var additional: JSONValue?
        var min: Int
        var max: Int
    }

    func arraySpec(_ schema: JSONValue) throws(GrammarError) -> ArraySpec {
        let prefix: [JSONValue]
        if let value = schema["prefixItems"] {
            guard let items = value.array else { throw .conversion("prefixItems must be an array") }
            for item in items {
                if item.bool == false { throw .conversion("prefixItems contains false") }
                guard item.members != nil || item.bool == true else { throw .conversion("prefixItems must be an array of objects or booleans") }
            }
            prefix = items
        } else { prefix = [] }
        let unrestricted = ["items", "prefixItems", "unevaluatedItems", "minItems", "maxItems", "minContains"].allSatisfy { schema[$0] == nil }
        let additional = schema["items"] ?? schema["unevaluatedItems"] ?? .bool(!options.strict || unrestricted)
        guard additional.members != nil || additional.bool != nil else {
            throw .conversion("\(schema["items"] == nil ? "unevaluatedItems" : "items") must be a boolean or an object")
        }
        let min = try max(bound(schema, "minItems"), bound(schema, "minContains"))
        let max = try bound(schema, "maxItems", default: -1)
        guard max < 0 || min <= max else { throw .conversion("minItems is greater than maxItems: \(min) > \(max)") }
        guard max < 0 || prefix.count <= max else { throw .conversion("maxItems is less than the number of prefixItems: \(max) < \(prefix.count)") }
        guard additional.bool != false || min <= prefix.count else { throw .conversion("minItems is greater than the number of prefixItems, but additional items are not allowed: \(min) > \(prefix.count)") }
        return .init(prefix: prefix, additional: additional.bool == false ? nil : additional, min: min, max: max)
    }

    func array(_ schema: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        let spec = try arraySpec(schema)
        switch style {
        case .cohereXML: return try cohereArray(spec, depth: depth, hint: hint)
        case .miniMaxM3XML: return try miniMaxM3Array(spec, depth: depth, hint: hint)
        default: break
        }
        level += 1
        defer { level -= 1 }
        let itemRules = try spec.prefix.enumerated().map { index, value throws(GrammarError) in
            try rule(value, depth: depth + 1, hint: hint + "_item_\(index)")
        }
        let middle = middleSeparator(depth: depth)
        let end = endSeparator(depth: depth)
        let emptyArray = sequence([literal("["), options.anyWhitespace ? whitespace() : empty(), literal("]")])
        if spec.prefix.isEmpty {
            guard let additional = spec.additional, spec.max != 0 else { return emptyArray }
            let item = ref(try rule(additional, depth: depth + 1, hint: hint + "_item"))
            let tail = repeatExpr(sequence([middle, item]), min: Swift.max(0, spec.min - 1), max: spec.max < 0 ? -1 : spec.max - 1)
            let nonempty = sequence([literal("["), startSeparator(depth: depth), item, tail, end, literal("]")])
            return spec.min == 0 ? choice([emptyArray, nonempty]) : nonempty
        }
        var tail = empty()
        if let additional = spec.additional {
            let item = ref(try rule(additional, depth: depth + 1, hint: hint + "_additional"))
            tail = repeatExpr(sequence([middle, item]), min: Swift.max(0, spec.min - spec.prefix.count), max: spec.max < 0 ? -1 : spec.max - spec.prefix.count)
        }
        for index in spec.prefix.indices.reversed() {
            let part = sequence([index == 0 ? empty() : middle, ref(itemRules[index]), tail])
            let body = index >= spec.min ? choice([empty(), part]) : part
            tail = ref(builder.addRule(hint: hint + "_suffix_\(index)", bodyExprID: body))
        }
        let nonempty = sequence([literal("["), startSeparator(depth: depth), tail, end, literal("]")])
        return spec.min == 0 ? choice([emptyArray, nonempty]) : nonempty
    }

    // MARK: Objects

    struct ObjectSpec {
        var properties: [JSONValue.Member]
        var required: Set<String>
        var patterns: [JSONValue.Member]
        var propertyNames: JSONValue?
        /// `nil` forbids properties beyond the declared ones.
        var additional: JSONValue?
        var min: Int
        var max: Int
    }

    func objectSpec(_ schema: JSONValue) throws(GrammarError) -> ObjectSpec {
        let properties = schema["properties"]?.members ?? []
        if schema["properties"] != nil, schema["properties"]?.members == nil { throw .conversion("properties must be an object") }
        let required: Set<String>
        if let value = schema["required"] {
            guard let names = value.array, names.allSatisfy({ $0.string != nil }) else { throw .conversion("required must be an array of strings") }
            required = Set(names.compactMap(\.string))
        } else { required = [] }
        guard required.isSubset(of: Set(properties.map(\.key))) else { throw .conversion("Required property is not declared in properties") }
        let min = try bound(schema, "minProperties")
        let max = try bound(schema, "maxProperties", default: -1)
        guard max < 0 || min <= max else { throw .conversion("minProperties is greater than maxProperties: \(min) > \(max)") }
        guard max < 0 || required.count <= max else { throw .conversion("maxProperties is less than the number of required properties") }
        let unrestricted = ["properties", "required", "patternProperties", "propertyNames", "minProperties", "maxProperties"].allSatisfy { schema[$0] == nil }
        let additional = schema["additionalProperties"] ?? schema["unevaluatedProperties"] ?? .bool(!options.strict || unrestricted)
        guard additional.members != nil || additional.bool != nil else { throw .conversion("additionalProperties must be a boolean or an object") }
        if let names = schema["propertyNames"] {
            guard names.members != nil else { throw .conversion("propertyNames must be an object") }
            if let type = names["type"]?.string, type != "string" { throw .conversion("propertyNames must be an object that validates string") }
        }
        let patterns = schema["patternProperties"]?.members ?? []
        if schema["patternProperties"] != nil, schema["patternProperties"]?.members == nil { throw .conversion("patternProperties must be an object") }
        return .init(properties: properties, required: required, patterns: patterns, propertyNames: schema["propertyNames"],
                     additional: additional.bool == false ? nil : additional, min: min, max: max)
    }

    func object(_ schema: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        let spec = try objectSpec(schema)
        if style == .miniMaxM3XML { try miniMaxM3Validate(spec) }
        level += 1
        defer { level -= 1 }
        let braces: Bool
        switch style {
        case .json, .gemma, .functionGemma: braces = true
        case .cohereXML, .miniMaxM3XML: braces = false
        default: braces = level > 1
        }
        let middle = middleSeparator(depth: depth)
        let first = startSeparator(depth: depth)
        let end = endSeparator(depth: depth)
        var extraChoices: [Int32] = []
        for pattern in spec.patterns {
            let key = try patternKey(pattern.key, hint: hint + "_pattern_key")
            let value = try rule(pattern.value, depth: depth + 1, hint: hint + "_pattern")
            extraChoices.append(try formatOtherProperty(key: key, value: value, schema: pattern.value, hint: hint))
        }
        if spec.additional != nil || (spec.propertyNames != nil && spec.properties.isEmpty) {
            let key: Int32
            if let names = spec.propertyNames {
                key = try propertyNamesKey(names, hint: hint + "_key")
            } else {
                key = try dynamicKey(excluding: spec.properties.map(\.key), hint: hint)
            }
            let valueSchema = spec.additional ?? .bool(true)
            let value = try rule(valueSchema, depth: depth + 1, hint: hint + "_additional")
            extraChoices.append(try formatOtherProperty(key: key, value: value, schema: valueSchema, hint: hint))
        }
        guard !extraChoices.isEmpty || spec.min <= spec.properties.count else { throw .conversion("minProperties exceeds declared properties") }
        let extra = extraChoices.isEmpty ? nil : choice(extraChoices)
        let fields = try spec.properties.map { property throws(GrammarError) in
            let value = try rule(property.value, depth: depth + 1, hint: hint + "_" + property.key)
            return try formatProperty(key: property.key, value: value, schema: property.value, hint: hint)
        }
        struct TailKey: Hashable { var index: Int; var count: Int; var started: Bool; var used: UInt64 }
        var tails: [TailKey: Int32] = [:]
        let anyOrder = self.anyOrder, properties = spec.properties, required = spec.required, max = spec.max
        // With anyOrder, each state records which declared properties were used, so a key can
        // appear at most once and every required key must. That is one rule per subset, so at
        // most `trackedLimit` properties are tracked, required ones first; the rest may appear
        // any number of times. Should more than that many be required, their presence is
        // enforced by count alone, like upstream's any-order approximation.
        let trackedLimit = 12
        var bit = [UInt64?](repeating: nil, count: properties.count)
        if anyOrder {
            let order = properties.indices.filter { required.contains(properties[$0].key) } + properties.indices.filter { !required.contains(properties[$0].key) }
            for (position, i) in order.prefix(trackedLimit).enumerated() { bit[i] = 1 << UInt64(position) }
        }
        let untrackedRequired = properties.indices.contains { bit[$0] == nil && required.contains(properties[$0].key) }
        let min = anyOrder && untrackedRequired ? Swift.max(spec.min, required.count) : spec.min
        let counted = min > 0 || max >= 0
        // MiniMax M3 elements are not padded: an empty element body is exactly empty.
        let emptyContent = style == .miniMaxM3XML ? empty() : (whitespaceSeparated || options.anyWhitespace ? whitespace() : empty())
        // The closing brace ends every terminal alternative of the tail chain, as upstream's
        // `root_part_* [ \n\r\t]* "}"`. With the brace outside, the last tail rule would be
        // nullable and every value lookahead derived from it would complete at once, leaving
        // each token that closes a value uncertain.
        let closingBrace = braces ? literal("}") : nil
        func closed(_ elements: [Int32]) -> Int32 { sequence(elements + (closingBrace.map { [$0] } ?? [])) }
        // Whether a tail state can still close the object: the required properties left fit under
        // maxProperties and enough properties are left to reach minProperties. Transitions into
        // other states would be dead ends that the token mask still allows (a model could pick
        // `"key3"` first when only `"key1"` or `"key2"` can still lead to three properties).
        let untracked = properties.indices.contains { bit[$0] == nil }
        func viable(index: Int, count: Int, used: UInt64) -> Bool {
            let pending = properties.indices.count { i in
                guard required.contains(properties[i].key) else { return false }
                return anyOrder ? bit[i].map { used & $0 == 0 } ?? false : i >= index
            }
            if max >= 0, count + pending > max { return false }
            if extra != nil || (anyOrder && untracked) { return true }
            let available = anyOrder ? properties.indices.count { bit[$0].map { used & $0 == 0 } ?? false } : fields.count - index
            return count + available >= min
        }
        func tail(index: Int, count rawCount: Int, started: Bool, used: UInt64 = 0) -> Int32 {
            // Without maxProperties, counts beyond the minimum are indistinguishable.
            let count = max < 0 ? Swift.min(rawCount, min) : rawCount
            let key = TailKey(index: anyOrder ? 0 : index, count: counted ? count : 0, started: started, used: used)
            if let id = tails[key] { return ref(id) }
            let id = builder.addEmptyRule(hint: hint + "_tail")
            tails[key] = id
            var choices: [Int32] = []
            let remainingRequired = properties.indices.contains { i in
                guard required.contains(properties[i].key) else { return false }
                return anyOrder ? bit[i].map { used & $0 == 0 } ?? false : i >= index
            }
            if !remainingRequired, count >= min { choices.append(closed([started ? end : emptyContent])) }
            if max < 0 || count < max {
                let separator = started ? middle : first
                if anyOrder {
                    for i in properties.indices {
                        let next = bit[i].map { used | $0 } ?? used
                        guard bit[i].map({ used & $0 == 0 }) ?? true, viable(index: 0, count: count + 1, used: next) else { continue }
                        choices.append(sequence([separator, fields[i], tail(index: 0, count: count + 1, started: true, used: next)]))
                    }
                    if let extra, viable(index: 0, count: count + 1, used: used) {
                        choices.append(sequence([separator, extra, tail(index: 0, count: count + 1, started: true, used: used)]))
                    }
                } else {
                    if index < fields.count {
                        if viable(index: index + 1, count: count + 1, used: 0) {
                            choices.append(sequence([separator, fields[index], tail(index: index + 1, count: count + 1, started: true)]))
                        }
                        if !required.contains(properties[index].key), viable(index: index + 1, count: count, used: 0) {
                            choices.append(tail(index: index + 1, count: count, started: started))
                        }
                    }
                    if !remainingRequired, let extra {
                        let minimum = Swift.max(0, min - count - 1)
                        let maximum = max < 0 ? -1 : max - count - 1
                        let extras = repeatExpr(sequence([middle, extra]), min: minimum, max: maximum, hint: hint + "_extras")
                        choices.append(closed([separator, extra, extras, end]))
                    }
                }
            }
            builder.updateRuleBody(id, choice(choices))
            return ref(id)
        }
        let content = tail(index: 0, count: 0, started: false)
        return braces ? sequence([literal("{"), content]) : content
    }

    // MARK: Property formatting hooks

    /// A declared property with its value rule.
    func formatProperty(key: String, value: Int32, schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .gemma, .functionGemma: return sequence([allowedText(key, excludes: gemmaExcludes) ? literal(key) : unsatisfiable(), colon(), ref(value)])
        case .pythonic: if level <= 1 { return sequence([pythonKeyword(key), ref(value)]) }
        case .miniMaxM3XML: return try miniMaxM3Element(key, value: value)
        case .cohereXML: return try cohereParameter(name: key, schema: schema, value: value, hint: hint)
        case .json: break
        default: if level <= 1 { return try xmlParameter(key: key, value: value, schema: schema, hint: hint) }
        }
        return sequence([allowedLiteral(.string(key)) ? literal(JSONValue.quote(key)) : unsatisfiable(), colon(), ref(value)])
    }

    /// A property whose key is matched by `key` rather than spelled out.
    func formatOtherProperty(key: Int32, value: Int32, schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .cohereXML: return try cohereParameter(keyExpr: key, schema: schema, value: value, hint: hint)
        case .pythonic: if level <= 1 { return sequence([key, literal("="), ref(value)]) }
        case .json, .gemma, .functionGemma, .miniMaxM3XML: break
        default: if level <= 1 { return try xmlParameter(keyExpr: key, value: value, schema: schema, hint: hint) }
        }
        return sequence([key, colon(), ref(value)])
    }

    /// Keys of additional properties, excluding the declared names.
    func dynamicKey(excluding names: [String], hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .gemma, .functionGemma: return try gemmaDynamicKey(excluding: names, hint: hint)
        case .pythonic: if level <= 1 { return try pythonDynamicKeyword(excluding: names, hint: hint) }
        case .cohereXML: return try cohereDynamicKey(excluding: names, hint: hint)
        case .json, .miniMaxM3XML: break
        default: if level <= 1 { return ref(try xmlVariableName()) }
        }
        return try jsonKey(excluding: names, hint: hint)
    }

    /// The key of a `patternProperties` entry.
    func patternKey(_ pattern: String, hint: String) throws(GrammarError) -> Int32 {
        switch style {
        case .gemma, .functionGemma: return ref(builder.addRule(hint: hint, bodyExprID: try gemmaRegexBody(pattern, hint: hint)))
        case .pythonic: if level <= 1 { return ref(builder.addRule(hint: hint, bodyExprID: try patternExpression(pattern, json: false))) }
        case .json, .miniMaxM3XML: break
        default: return ref(try rule(.object([.init(key: "type", value: .string("string")), .init(key: "pattern", value: .string(pattern))]), depth: 0, hint: hint))
        }
        return sequence([literal("\""), regex(pattern, json: true), literal("\"")])
    }

    /// The key rule for `propertyNames`, which always describes a string.
    func propertyNamesKey(_ names: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if isGemmaStyle { return try gemmaPropertyNamesKey(names, hint: hint) }
        if isPythonKeywordLevel { return try pythonPropertyNamesKeyword(names, hint: hint) }
        return ref(try rule(names.replacing("type", with: .string("string")), depth: 0, hint: hint))
    }

    // A decoded-character trie prevents additionalProperties from matching a named key through
    // either its literal spelling or a JSON Unicode escape ("city" and "\u0063ity").
    func jsonKey(excluding names: [String], hint: String) throws(GrammarError) -> Int32 {
        if !options.excludes.isEmpty {
            return sequence([literal("\""), try excludingString(JSONStringPatterns.scalar + "*", hint: hint + "_key_exclude", closing: "\"", names: names)])
        }
        if names.isEmpty { return sequence([literal("\""), repeatExpr(jsonCharacter(), min: 0), literal("\"")]) }
        let trie = JSONKeyAutomata.Trie(names)
        let ids = trie.nodes.indices.map { builder.addEmptyRule(hint: hint + "_key_exclude_\($0)") }
        let fallback = sequence([repeatExpr(jsonCharacter(), min: 0), literal("\"")])
        for index in trie.nodes.indices {
            let node = trie.nodes[index]
            var choices: [Int32] = node.terminal ? [] : [literal("\"")]
            let outgoing = node.edges.keys.sorted()
            for cp in outgoing {
                var spellings: [Int32] = []
                if cp >= 32, cp != 34, cp != 92 { spellings.append(builder.addCharacterClass([cp ... cp])) }
                spellings.append(regex(JSONStringPatterns.unicodeEscape(for: cp)))
                if let escaped = JSONStringPatterns.shortEscape(for: cp) { spellings.append(literal("\\" + escaped)) }
                choices.append(sequence([choice(spellings), ref(ids[node.edges[cp]!])]))
            }
            let forbidden = outgoing + Array(0 ... 31) + [34, 92]
            var others = [builder.addCharacterClass(forbidden.sorted().map { $0 ... $0 }, isNegated: true)]
            for (cp, suffix) in JSONStringPatterns.shortEscapes where !outgoing.contains(cp) {
                others.append(literal("\\" + suffix))
            }
            others.append(regex(JSONStringPatterns.unicodeEscape(excluding: outgoing)))
            choices.append(sequence([choice(others), fallback]))
            builder.updateRuleBody(ids[index], choice(choices))
        }
        return sequence([literal("\""), ref(ids[0])])
    }
}
