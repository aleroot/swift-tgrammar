// Cohere's recursive tool-call values: `<cofl:value name="key" type="raw|json|dict|list">`.
// Object properties use named wrappers, array items unnamed ones, and the type attribute is
// correlated with the schema alternative the value follows.
extension JSONSchemaConverter {
    private static let cohereKeyEntities: [(scalar: UInt32, entity: String)] = [(38, "&amp;"), (60, "&lt;"), (62, "&gt;"), (34, "&quot;")]

    private static func serializeCohereKey(_ key: String) throws(GrammarError) -> String {
        guard !key.unicodeScalars.contains(where: { $0.value == 0 }) else { throw .conversion("Cohere property names cannot contain NUL") }
        var serialized = ""
        for scalar in key.unicodeScalars {
            if let entity = cohereKeyEntities.first(where: { $0.scalar == scalar.value }) { serialized += entity.entity }
            else { serialized.unicodeScalars.append(scalar) }
        }
        return serialized
    }

    private func cohereKey() throws(GrammarError) -> Int32 {
        try sharedRule(.cohereKey) { () throws(GrammarError) in regex(#"([^\x00"&<>]|&amp;|&lt;|&gt;|&quot;)+"#) }
    }

    private func cohereAnyScalar() throws(GrammarError) -> Int32 {
        try sharedRule(.cohereAnyScalar) { () throws(GrammarError) in
            choice(try ["number", "boolean", "null"].map { type throws(GrammarError) in ref(try rule(Self.typeSchema(type), depth: 1, hint: "json_\(type)")) })
        }
    }

    /// The recursive sequence of unnamed any-valued items of an unconstrained list.
    private func cohereAnyList() throws(GrammarError) -> Int32 {
        try sharedRule(.cohereAnyList) { () throws(GrammarError) in
            repeatExpr(sequence([literal(xmlWrapper.keyPrefix), try cohereAnySuffix()]), min: 0, hint: "cohere_any_list_items")
        }
    }

    /// Wrapping the aggregate any-value body under every type would create a type/body cross
    /// product, so each wrapper references its matching component.
    private func cohereAnySuffix() throws(GrammarError) -> Int32 {
        choice([try cohereSuffix(type: literal("raw"), value: try xmlString()),
                try cohereSuffix(type: literal("json"), value: try cohereAnyScalar()),
                try cohereSuffix(type: literal("dict"), value: try xmlObject()),
                try cohereSuffix(type: literal("list"), value: try cohereAnyList())])
    }

    /// The aggregate body of an unconstrained value when it is not wrapped by a parameter.
    func cohereAnyBody(depth: Int) throws(GrammarError) -> Int32 {
        choice([ref(try xmlString()), ref(try cohereAnyScalar()), ref(try xmlObject()), ref(try cohereAnyList())])
    }

    func cohereString(_ schema: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        if let pattern = try rawPatternExpression(schema) { return pattern }
        let bounds = try stringBounds(schema)
        if bounds.isBounded { return repeatExpr(anyCharacter(), min: bounds.min, max: bounds.max, hint: hint + "_characters") }
        // An unrecognised format keeps the JSON string, as upstream does.
        return schema["format"] != nil ? try jsonString(schema, hint: hint) : ref(try xmlString())
    }

    private static func cohereType(ofLiteral value: JSONValue) -> String { value.string != nil ? "raw" : "json" }

    /// The type attribute of a schema that renders as a single wrapper.
    private func cohereTypePattern(_ schema: JSONValue) -> Int32 {
        if let value = schema["const"] { return literal(Self.cohereType(ofLiteral: value)) }
        if let values = schema["enum"]?.array {
            let types = Set(values.map(Self.cohereType(ofLiteral:)))
            return literal(types.count == 1 ? types.first! : "json")
        }
        switch schema["type"]?.string ?? inferredType(schema) {
        case "string": return literal("raw")
        case "object": return literal("dict")
        case "array": return literal("list")
        default: return literal("json")
        }
    }

    private func cohereSuffix(type: Int32, value: Int32) throws(GrammarError) -> Int32 {
        sequence([literal(" type=\""), type, literal("\"" + xmlWrapper.keySuffix), xmlValue(value), literal(xmlWrapper.parameterSuffix)])
    }

    /// Whether `schema` accepts any value: `true`, `{}` or the multi-branch `allOf` fallback.
    private func isCohereAny(_ schema: JSONValue) -> Bool {
        if Self.isUnconstrained(schema) { return true }
        if let values = schema["allOf"]?.array, values.count != 1 { return true }
        return schema.members != nil && schema["type"] == nil && schema["$ref"] == nil && schema["const"] == nil && schema["enum"] == nil
            && schema["anyOf"] == nil && schema["oneOf"] == nil && schema["allOf"] == nil && inferredType(schema) == nil
    }

    /// The attribute, value and closing tag of a wrapper for `schema`; `value` is the caller's
    /// rule for it. Mixed enums and unions get one alternative per option.
    private func cohereParameterSuffix(_ schema: JSONValue, value: Int32?, hint: String) throws(GrammarError) -> Int32 {
        if let pointer = schema["$ref"]?.string {
            if let cached = referenceSuffixRules[pointer] { return ref(cached) }
            // Register before resolving so a schema leading back to this URI reuses the rule.
            let id = builder.addEmptyRule(hint: hint + "_cohere_param")
            referenceSuffixRules[pointer] = id
            builder.updateRuleBody(id, try cohereParameterSuffix(resolve(pointer), value: value, hint: hint))
            return ref(id)
        }
        if isCohereAny(schema) { return try cohereAnySuffix() }
        if let options = try compositeOptions(schema, splitEnums: cohereMixedEnum(schema)) {
            return choice(try options.enumerated().map { index, option throws(GrammarError) in
                try cohereParameterSuffix(option, value: nil, hint: hint + "_cohere_case_\(index)")
            })
        }
        let valueRule = if let value { value } else { try rule(schema, depth: 1, hint: hint) }
        return try cohereSuffix(type: cohereTypePattern(schema), value: valueRule)
    }

    private func cohereMixedEnum(_ schema: JSONValue) -> Bool {
        guard let values = schema["enum"]?.array, !values.isEmpty else { return false }
        return Set(values.map(Self.cohereType(ofLiteral:))).count > 1
    }

    private func coherePrefix(name: String?, keyExpr: Int32?) throws(GrammarError) -> Int32 {
        var elements = [literal(xmlWrapper.keyPrefix)]
        if let name { elements.append(literal(" name=\"" + (try Self.serializeCohereKey(name)) + "\"")) }
        else if let keyExpr { elements += [literal(" name=\""), keyExpr, literal("\"")] }
        return sequence(elements)
    }

    func cohereParameter(name: String, schema: JSONValue, value: Int32, hint: String) throws(GrammarError) -> Int32 {
        sequence([try coherePrefix(name: name, keyExpr: nil), try cohereParameterSuffix(schema, value: value, hint: hint)])
    }

    func cohereParameter(keyExpr: Int32, schema: JSONValue, value: Int32, hint: String) throws(GrammarError) -> Int32 {
        sequence([try coherePrefix(name: nil, keyExpr: keyExpr), try cohereParameterSuffix(schema, value: value, hint: hint)])
    }

    private func cohereItem(_ schema: JSONValue, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        let value = isCohereAny(schema) ? nil : try rule(schema, depth: depth + 1, hint: hint)
        return sequence([try coherePrefix(name: nil, keyExpr: nil), try cohereParameterSuffix(schema, value: value, hint: hint)])
    }

    /// Array items are unnamed wrappers, emitted back to back.
    func cohereArray(_ spec: ArraySpec, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        level += 1
        defer { level -= 1 }
        let items = try spec.prefix.enumerated().map { index, schema throws(GrammarError) in try cohereItem(schema, depth: depth, hint: hint + "_item_\(index)") }
        let additional = try spec.additional.map { schema throws(GrammarError) in try cohereItem(schema, depth: depth, hint: hint + "_additional") }
        if items.isEmpty {
            guard let additional, spec.max != 0 else { return empty() }
            return repeatExpr(additional, min: spec.min, max: spec.max, hint: hint + "_items")
        }
        let prefix = sequence(items)
        guard let additional else { return prefix }
        return sequence([prefix, repeatExpr(additional, min: Swift.max(0, spec.min - items.count), max: spec.max < 0 ? -1 : spec.max - items.count, hint: hint + "_additional_items")])
    }

    /// Ordinary key characters exclude NUL, the entity-encoded characters and the scalars the
    /// trie handles; the alternatives together exclude exactly the declared names.
    func cohereDynamicKey(excluding names: [String], hint: String) throws(GrammarError) -> Int32 {
        if names.isEmpty { return ref(try cohereKey()) }
        let trie = JSONKeyAutomata.Trie(names)
        func body(_ index: Int, depth: Int) throws(GrammarError) -> Int32 {
            let node = trie.nodes[index]
            var choices: [Int32] = []
            if depth > 0, !node.terminal { choices.append(empty()) }
            let optionalSuffix = choice([empty(), ref(try cohereKey())])
            var excluded: [CodepointRange] = [0 ... 0] + Self.cohereKeyEntities.map { $0.scalar ... $0.scalar } + node.edges.keys.map { UInt32($0) ... UInt32($0) }
            CodepointRanges.normalize(&excluded)
            choices.append(sequence([builder.addCharacterClass(CodepointRanges.complement(excluded).map { Int32($0.lowerBound) ... Int32($0.upperBound) }), optionalSuffix]))
            for entity in Self.cohereKeyEntities where node.edges[Int32(entity.scalar)] == nil {
                choices.append(sequence([literal(entity.entity), optionalSuffix]))
            }
            for scalar in node.edges.keys.sorted() {
                let spelling = try Self.serializeCohereKey(String(UnicodeScalar(UInt32(scalar))!))
                choices.append(sequence([literal(spelling), try body(node.edges[scalar]!, depth: depth + 1)]))
            }
            return choice(choices)
        }
        return ref(builder.addRule(hint: hint + "_cohere_addl_key", bodyExprID: try body(0, depth: 0)))
    }
}
