// Python call arguments (LFM2): the root object is a keyword-argument list, `key=value` with
// unquoted identifier keys; every value is a Python literal. Strings are double quoted with the
// escapes Python and JSON decode alike, booleans and null are `True`, `False` and `None`, and
// lists and dicts otherwise follow JSON syntax.
extension JSONSchemaConverter {
    private static let pythonIdentifier = "[a-zA-Z_][a-zA-Z0-9_]*"

    /// One string character Python decodes like JSON: `\/` and surrogate escapes are left out,
    /// since Python keeps the former verbatim and cannot decode the latter.
    private static let pythonStringScalar = #"([^\x00-\x1F"\\\uD800-\uDFFF]|\\["\\bfnrt]|"#
        + #"\\u([0-9a-cA-CeEfF][0-9a-fA-F]{3}|[dD][0-7][0-9a-fA-F]{2}))"#

    /// Root parameters (level 1) are keyword arguments; deeper containers are lists and dicts.
    var isPythonKeywordLevel: Bool { style == .pythonic && level <= 1 }

    func pythonString(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if schema["pattern"] != nil || schema["format"] != nil { return try jsonString(schema, hint: hint) }
        let bounds = try stringBounds(schema)
        if !options.excludes.isEmpty {
            // Length bounds are dropped with exclusions, as in the JSON style.
            let body = try sharedRule(.excludedJSONString) { () throws(GrammarError) in
                try excludingString(Self.pythonStringScalar + "*", hint: "python_string_exclude", closing: "\"")
            }
            return sequence([literal("\""), ref(body)])
        }
        guard bounds.isBounded else { return regex("\"" + Self.pythonStringScalar + "*\"") }
        let characters = repeatExpr(regex(Self.pythonStringScalar), min: bounds.min, max: bounds.max, hint: hint + "_characters")
        return sequence([literal("\""), characters, literal("\"")])
    }

    static func pythonLiteral(_ value: JSONValue, itemSeparator: String, keySeparator: String) -> String {
        switch value {
        case .object(let members):
            "{" + members.map { JSONValue.quote($0.key) + keySeparator + pythonLiteral($0.value, itemSeparator: itemSeparator, keySeparator: keySeparator) }
                .joined(separator: itemSeparator) + "}"
        case .array(let values): "[" + values.map { pythonLiteral($0, itemSeparator: itemSeparator, keySeparator: keySeparator) }.joined(separator: itemSeparator) + "]"
        case .bool(let value): value ? "True" : "False"
        case .null: "None"
        case .string, .number: value.serialized()
        }
    }

    /// A constant: a keyword-argument list at the root, a Python literal elsewhere.
    func pythonConstant(_ value: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        if level == 0, let members = value.members {
            let properties = JSONValue.object(members.map { .init(key: $0.key, value: .object([.init(key: "const", value: $0.value)])) })
            let schema = JSONValue.object([.init(key: "properties", value: properties), .init(key: "required", value: .array(members.map { .string($0.key) })),
                                           .init(key: "additionalProperties", value: .bool(false))])
            let saved = anyOrder
            anyOrder = false
            defer { anyOrder = saved }
            return try object(schema, depth: depth, hint: hint)
        }
        guard allowedLiteral(value) else { return unsatisfiable() }
        let separators = options.anyWhitespace ? (", ", ": ") : (options.resolvedItemSeparator, options.resolvedKeySeparator)
        return literal(Self.pythonLiteral(value, itemSeparator: separators.0, keySeparator: separators.1))
    }

    private static func isPythonIdentifier(_ key: String) -> Bool {
        guard let first = key.utf8.first, !(48 ... 57).contains(first) else { return false }
        return key.utf8.allSatisfy { (97 ... 122).contains($0) || (65 ... 90).contains($0) || (48 ... 57).contains($0) || $0 == 95 }
    }

    /// `key=` for a declared keyword argument; a key outside the identifier form cannot be passed.
    func pythonKeyword(_ key: String) -> Int32 {
        Self.isPythonIdentifier(key) && allowedText(key) ? literal(key + "=") : unsatisfiable()
    }

    /// The identifier key of an additional keyword argument, excluding the declared names.
    func pythonDynamicKeyword(excluding names: [String], hint: String) throws(GrammarError) -> Int32 {
        if names.isEmpty, options.excludes.isEmpty {
            return sequence([builder.addCharacterClass([97 ... 122, 65 ... 90, 95 ... 95]),
                             builder.addCharacterClassStar([97 ... 122, 65 ... 90, 48 ... 57, 95 ... 95])])
        }
        return try excludingString(Self.pythonIdentifier, hint: hint + "_addl_key", names: names)
    }

    /// A keyword constrained by its `propertyNames` enum/const literals; other `propertyNames`
    /// constraints fall back to the identifier form, as for Gemma's bare keys.
    func pythonPropertyNamesKeyword(_ names: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if let values = names["enum"]?.array ?? names["const"].map({ [$0] }) {
            return choice(values.compactMap { value in
                guard let key = value.string, Self.isPythonIdentifier(key), allowedText(key) else { return nil }
                return literal(key)
            })
        }
        return try pythonDynamicKeyword(excluding: [], hint: hint)
    }
}
