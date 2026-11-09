// Gemma's argument spelling at every nesting level: object keys are unquoted, strings are
// delimited by the `<|"|>` token (`<escape>` for FunctionGemma) and have no escape sequences;
// numbers, booleans, null, arrays and objects otherwise follow JSON syntax.
extension JSONSchemaConverter {
    /// Gemma 4's and FunctionGemma's argument spellings.
    var isGemmaStyle: Bool { style == .gemma || style == .functionGemma }

    var gemmaStringDelimiter: String { style == .functionGemma ? "<escape>" : "<|\"|>" }
    private static let gemmaIdentifier = "[a-zA-Z_][a-zA-Z0-9_]*"

    /// The delimiter closes every string, so no string body or key may contain it. Registering
    /// it as an exclusion lets the shared exclusion machinery keep it out of pattern strings,
    /// literals and dynamic keys alike.
    var gemmaExcludes: [String] { options.excludes + [gemmaStringDelimiter] }

    private func gemmaString(_ body: Int32) -> Int32 {
        sequence([literal(gemmaStringDelimiter), body, literal(gemmaStringDelimiter)])
    }

    /// A regex body that cannot contain the delimiter whenever the automaton engine can build
    /// it, so a permissive pattern such as `.*` cannot close the string early. Other patterns
    /// keep the CFG expansion and are emitted verbatim, as the JSON converter does.
    func gemmaRegexBody(_ pattern: String, hint: String) throws(GrammarError) -> Int32 {
        if (try? RegexFSMBuilder.build(pattern)) != nil { return try excludingString(pattern, excludes: gemmaExcludes, hint: hint) }
        return try patternExpression(pattern, json: false)
    }

    func gemmaString(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if let format = schema["format"]?.string, let pattern = JSONSchemaFormats.pattern(for: format, raw: true) {
            return gemmaString(try gemmaRegexBody(pattern, hint: hint + "_format"))
        }
        if let pattern = try stringPattern(schema) { return gemmaString(try gemmaRegexBody(pattern, hint: hint + "_pattern")) }
        // Length bounds are dropped, as in the other excluding styles: unrolling the exclusion
        // automaton per character is prohibitively expensive.
        _ = try stringBounds(schema)
        let content = try sharedRule(.gemmaStringContent) { () throws(GrammarError) in
            builder.addTagDispatch(.init(loopAfterDispatch: false, excludes: gemmaExcludes.map { Array($0.utf8) }))
        }
        return gemmaString(ref(content))
    }

    /// Strings and keys are emitted raw, so exclusions are checked against the raw text.
    private func allowedGemmaValue(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): allowedText(text, excludes: gemmaExcludes)
        case .array(let items): items.allSatisfy(allowedGemmaValue)
        case .object(let members): members.allSatisfy { allowedText($0.key, excludes: gemmaExcludes) && allowedGemmaValue($0.value) }
        default: true
        }
    }

    private func serializeGemma(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): gemmaStringDelimiter + text + gemmaStringDelimiter
        case .array(let items): "[" + items.map(serializeGemma).joined(separator: ",") + "]"
        case .object(let members): "{" + members.map { $0.key + ":" + serializeGemma($0.value) }.joined(separator: ",") + "}"
        default: value.serialized()
        }
    }

    func gemmaLiteral(_ value: JSONValue) -> Int32 {
        allowedGemmaValue(value) ? literal(serializeGemma(value)) : unsatisfiable()
    }

    private func gemmaVariableName() throws(GrammarError) -> Int32 {
        try sharedRule(.gemmaVariableName) { () throws(GrammarError) in
            if !options.excludes.isEmpty { return try excludingString(Self.gemmaIdentifier, excludes: gemmaExcludes, hint: "gemma_variable_name") }
            return sequence([builder.addCharacterClass([97 ... 122, 65 ... 90, 95 ... 95]),
                             builder.addCharacterClassStar([97 ... 122, 65 ... 90, 48 ... 57, 95 ... 95])])
        }
    }

    /// Declared properties are emitted verbatim; this bounds the keys of additionalProperties
    /// to the identifier form of the other tool-calling styles.
    func gemmaDynamicKey(excluding names: [String], hint: String) throws(GrammarError) -> Int32 {
        if names.isEmpty { return ref(try gemmaVariableName()) }
        return try excludingString(Self.gemmaIdentifier, excludes: gemmaExcludes, hint: hint + "_addl_key", names: names)
    }

    /// A bare key constrained by a `propertyNames` pattern or by its enum/const literals;
    /// other `propertyNames` constraints do not apply to unquoted keys.
    func gemmaPropertyNamesKey(_ names: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if let pattern = try stringPattern(names) { return try patternKey(pattern, hint: hint) }
        if let values = names["enum"]?.array { return ref(builder.addRule(hint: hint, bodyExprID: gemmaKeyLiterals(values))) }
        if let value = names["const"] { return ref(builder.addRule(hint: hint, bodyExprID: gemmaKeyLiterals([value]))) }
        return ref(try gemmaVariableName())
    }

    /// Only a non-empty string names a property, and a bare key cannot contain an exclusion.
    private func gemmaKeyLiterals(_ values: [JSONValue]) -> Int32 {
        choice(values.compactMap { value in
            guard let key = value.string, !key.isEmpty, allowedText(key, excludes: gemmaExcludes) else { return nil }
            return literal(key)
        })
    }
}
