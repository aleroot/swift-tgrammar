// MiniMax M3's recursive namespace-prefixed XML: every property and array item is an element
// `]<]minimax[>[<name>value]<]minimax[>[</name>`. Element names must be known when the grammar
// is built, so schemas needing runtime names or unconstrained values are rejected.
extension JSONSchemaConverter {
    private static let miniMaxM3Namespace = "]<]minimax[>["
    private static let miniMaxM3ItemName = "item"

    func miniMaxM3String() throws(GrammarError) -> Int32 {
        try sharedRule(.xmlString) { () throws(GrammarError) in
            builder.addTagDispatch(.init(loopAfterDispatch: false, excludes: [Array(Self.miniMaxM3Namespace.utf8)]))
        }
    }

    func miniMaxM3String(_ schema: JSONValue) throws(GrammarError) -> Int32 {
        let knownFormat = schema["format"]?.string.flatMap { JSONSchemaFormats.pattern(for: $0, raw: true) } != nil
        guard try stringPattern(schema) == nil, !knownFormat, try !stringBounds(schema).isBounded else {
            throw .unsupported("String pattern, recognized format, and length constraints are not supported by minimax_m3_xml because they cannot be combined with the namespace-marker exclusion")
        }
        return ref(try miniMaxM3String())
    }

    private static func validateElementName(_ name: String) throws(GrammarError) {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains(">") else { throw .conversion("Invalid minimax_m3_xml element name: \(name)") }
        guard name.utf8.contains(where: { ![9, 10, 11, 12, 13, 32].contains($0) }) else { throw .conversion("minimax_m3_xml element names cannot be blank") }
    }

    func miniMaxM3Element(_ name: String, value: Int32) throws(GrammarError) -> Int32 {
        try Self.validateElementName(name)
        return sequence([literal(Self.miniMaxM3Namespace + "<" + name + ">"), ref(value), literal(Self.miniMaxM3Namespace + "</" + name + ">")])
    }

    func miniMaxM3Validate(_ spec: ObjectSpec) throws(GrammarError) {
        guard spec.additional == nil, spec.patterns.isEmpty, spec.propertyNames == nil else {
            throw .unsupported("minimax_m3_xml requires fixed object property names; additionalProperties, unevaluatedProperties, patternProperties, and propertyNames are not supported")
        }
        for property in spec.properties { try Self.validateElementName(property.key) }
    }

    func miniMaxM3Literal(_ value: JSONValue, hint: String) throws(GrammarError) -> Int32 {
        switch value {
        case .string(let text):
            guard !text.contains(Self.miniMaxM3Namespace) else { throw .conversion("A minimax_m3_xml string literal cannot contain the namespace marker") }
            return literal(text)
        case .object(let members):
            return sequence(try members.map { member throws(GrammarError) in
                try miniMaxM3Element(member.key, value: builder.addRule(hint: "literal_" + member.key, bodyExprID: try miniMaxM3Literal(member.value, hint: hint)))
            })
        case .array(let items):
            return sequence(try items.enumerated().map { index, item throws(GrammarError) in
                try miniMaxM3Element(Self.miniMaxM3ItemName, value: builder.addRule(hint: "literal_item_\(index)", bodyExprID: try miniMaxM3Literal(item, hint: hint)))
            })
        default: return literal(value.serialized())
        }
    }

    /// Items are `<item>` elements separated by whitespace. A prefixItems entry constrains its
    /// position without making it mandatory: the chain can stop once minItems is satisfied.
    func miniMaxM3Array(_ spec: ArraySpec, depth: Int, hint: String) throws(GrammarError) -> Int32 {
        let whitespace = whitespace()
        let items = try spec.prefix.enumerated().map { index, schema throws(GrammarError) in
            try miniMaxM3Element(Self.miniMaxM3ItemName, value: try rule(schema, depth: depth + 1, hint: hint + "_item_\(index)"))
        }
        let additional = try spec.additional.map { schema throws(GrammarError) in
            try miniMaxM3Element(Self.miniMaxM3ItemName, value: try rule(schema, depth: depth + 1, hint: hint + "_additional"))
        }
        if items.isEmpty {
            guard let additional, spec.max != 0 else { return empty() }
            let rest = repeatExpr(sequence([whitespace, additional]), min: Swift.max(0, spec.min - 1), max: spec.max < 0 ? -1 : Swift.max(0, spec.max - 1), hint: hint + "_items")
            let nonempty = sequence([whitespace, additional, rest, whitespace])
            return spec.min == 0 ? choice([nonempty, empty()]) : nonempty
        }
        var tail = empty()
        if let additional {
            tail = repeatExpr(sequence([whitespace, additional]), min: Swift.max(0, spec.min - items.count),
                              max: spec.max < 0 ? -1 : Swift.max(0, spec.max - items.count), hint: hint + "_additional_items")
        }
        for index in stride(from: items.count - 2, through: 0, by: -1) {
            let emitted = index + 1
            var body = empty()
            if spec.max < 0 || emitted < spec.max {
                let continuation = sequence([whitespace, items[index + 1], tail])
                body = emitted >= spec.min ? choice([continuation, empty()]) : continuation
            }
            tail = ref(builder.addRule(hint: hint + "_prefix_tail_\(index)", bodyExprID: body))
        }
        if spec.max == 0 { return empty() }
        let nonempty = sequence([whitespace, items[0], tail, whitespace])
        return spec.min == 0 ? choice([nonempty, empty()]) : nonempty
    }
}
