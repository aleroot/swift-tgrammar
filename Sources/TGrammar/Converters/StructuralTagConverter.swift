final class StructuralTagConverter {
    private var builder = GrammarBuilder()
    private let tokenizerInfo: TokenizerInfo?
    private init(tokenizerInfo: TokenizerInfo?) { self.tokenizerInfo = tokenizerInfo }

    private struct EndContext: Hashable {
        var strings: [String] = []
        var tokens: [GrammarToken] = []
    }

    /// Identical formats in identical end contexts share one rule, as upstream dedupes by format
    /// fingerprint: tool sets that repeat a schema or a delimiter compile it once.
    private struct VisitKey: Hashable {
        let format: StructuralFormat
        let context: EndContext
    }
    private var visited: [VisitKey: Int32] = [:]

    static func convert(_ format: StructuralFormat, tokenizerInfo: TokenizerInfo?) throws(GrammarError) -> GrammarStorage {
        let converter = Self(tokenizerInfo: tokenizerInfo)
        let content: Int32
        do { content = try converter.visit(format, context: .init()) } catch { throw error.structuralTagError }
        let root = converter.builder.addRule(hint: "root", bodyExprID: converter.builder.addRuleRef(content))
        return GrammarNormalizer.apply(converter.builder.finish(rootRuleID: root))
    }

    private func sequence(_ expressions: [Int32]) -> Int32 { builder.addSequence(expressions) }
    private func choice(_ expressions: [Int32]) -> Int32 { builder.addChoices(expressions) }
    private func ref(_ id: Int32) -> Int32 { builder.addRuleRef(id) }
    private func rule(_ hint: String, _ expression: Int32) -> Int32 { builder.addRule(hint: hint, bodyExprID: expression) }
    private func literal(_ value: String) -> Int32 { value.isEmpty ? builder.addEmptyString() : builder.addByteString(value) }

    private func resolve(_ token: GrammarToken) throws(GrammarError) -> Int32 {
        switch token {
        case .id(let id):
            guard id >= 0 else { throw .conversion("Token IDs must be non-negative") }
            if let tokenizerInfo, Int(id) >= tokenizerInfo.vocabSize { throw .conversion("Token ID \(id) is outside the vocabulary") }
            return id
        case .piece(let piece):
            guard let tokenizerInfo else { throw .conversion("Token pieces require tokenizerInfo") }
            guard let id = tokenizerInfo.tokenID(for: piece) else { throw .conversion("Token piece not found: \(piece)") }
            return id
        }
    }

    private func resolved(_ tokens: [GrammarToken]) throws(GrammarError) -> [Int32] {
        Array(Set(try tokens.map { token throws(GrammarError) in try resolve(token) })).sorted()
    }
    private func limit(_ value: Int?, named name: String) throws(GrammarError) -> Int32 {
        guard let value else { return -1 }
        guard value >= 0, let result = Int32(exactly: value) else { throw .conversion("\(name) must be a non-negative 32-bit integer") }
        return result
    }
    private func boundary(_ value: TagBoundary) throws(GrammarError) -> Int32 {
        switch value {
        case .text(let text): return literal(text)
        case .token(let token): return builder.addTokenSet([try resolve(token)])
        }
    }
    private func end(_ tag: StructuralTag) throws(GrammarError) -> Int32 {
        guard !tag.ends.isEmpty else { throw .conversion("A tag needs at least one end delimiter") }
        let ends = choice(try tag.ends.map { value throws(GrammarError) in try boundary(value) })
        return tag.ends.count == 1 ? ends : ref(rule("tag_end", ends))
    }
    private func context(_ tag: StructuralTag) -> EndContext {
        var result = EndContext()
        for end in tag.ends {
            switch end {
            case .text(let text): if !text.isEmpty { result.strings.append(text) }
            case .token(let token): result.tokens.append(token)
            }
        }
        return result
    }
    private func tagExpression(_ tag: StructuralTag, droppingPrefix prefix: String = "", depth: Int) throws(GrammarError) -> Int32 {
        let begin: Int32
        if case .text(let text) = tag.begin { begin = literal(String(text.dropFirst(prefix.count))) }
        else { begin = try boundary(tag.begin) }
        return sequence([begin, ref(try visit(tag.content, context: context(tag), depth: depth + 1)), try end(tag)])
    }

    private func visit(_ format: StructuralFormat, context: EndContext, depth: Int = 0) throws(GrammarError) -> Int32 {
        // As upstream, which caps format nesting for the native stack.
        guard depth <= 100 else { throw .conversion("Formats are nested deeper than 100 levels") }
        try StackGuard.check()
        let key = VisitKey(format: format, context: context)
        if let ruleID = visited[key] { return ruleID }
        let ruleID = try visitUncached(format, context: context, depth: depth)
        visited[key] = ruleID
        return ruleID
    }

    private func visitUncached(_ format: StructuralFormat, context: EndContext, depth: Int) throws(GrammarError) -> Int32 {
        switch format {
        case .literal(let text): return rule("const_string", literal(text))
        case .jsonSchema(let schema, let options): return builder.importGrammar(try JSONSchemaConverter.convert(schema, options: options))
        case .grammar(let grammar): return builder.importGrammar(grammar.storage)
        case .lark(let source): return builder.importGrammar(try LarkConverter.convert(source, tokenizer: tokenizerInfo, named: [:]))
        case .regex(let pattern): return builder.importGrammar(try Grammar(regex: pattern).storage)
        case .anyText(let excludes, let maxTokens, let maxCharacters):
            let strings = Array(Set(excludes + context.strings)).sorted()
            guard strings.allSatisfy({ !$0.isEmpty }) else { throw .conversion("Text excludes must not be empty") }
            let body = strings.isEmpty ? builder.addCharacterClassStar([0 ... 0x10FFFF])
                : builder.addTagDispatch(.init(loopAfterDispatch: false, excludes: strings.map { Array($0.utf8) }))
            let tokenLimit = try limit(maxTokens, named: "maxTokens")
            let charLimit = try limit(maxCharacters, named: "maxCharacters")
            let id = rule("any_text", tokenLimit == 0 ? literal("") : body)
            builder.updateMaxTokens(id, tokenLimit)
            builder.updateMaxChars(id, charLimit)
            return id
        case .sequence(let formats):
            return rule("sequence", sequence(try formats.map { value throws(GrammarError) in ref(try visit(value, context: context, depth: depth + 1)) }))
        case .choice(let formats):
            guard !formats.isEmpty else { throw .conversion("A structural choice must not be empty") }
            return rule("or", choice(try formats.map { value throws(GrammarError) in ref(try visit(value, context: context, depth: depth + 1)) }))
        case .optional(let child):
            return rule("optional", choice([literal(""), ref(try visit(child, context: context, depth: depth + 1))]))
        case .oneOrMore(let child): return try repetition(child, context: context, minimum: 1, maximum: nil, depth: depth)
        case .zeroOrMore(let child): return try repetition(child, context: context, minimum: 0, maximum: nil, depth: depth)
        case .repeated(let child, let min, let max): return try repetition(child, context: context, minimum: min, maximum: max, depth: depth)
        case .tag(let tag): return rule("tag", try tagExpression(tag, depth: depth))
        case .triggeredTags(let triggers, let tags, let atLeastOne, let stopAfterFirst, let excludes):
            guard !triggers.isEmpty, !tags.isEmpty, triggers.allSatisfy({ !$0.isEmpty }) else { throw .conversion("triggeredTags requires non-empty triggers and tags") }
            for (i, trigger) in triggers.enumerated() {
                for (j, other) in triggers.enumerated() where i != j && trigger.hasPrefix(other) {
                    throw .conversion("Triggers must not be prefixes of one another")
                }
            }
            var groups = Array(repeating: [Int32](), count: triggers.count)
            var firstChoices: [Int32] = []
            for tag in tags {
                guard case .text(let begin) = tag.begin else { throw .conversion("Tags in triggeredTags require string begins") }
                let matching = triggers.indices.filter { begin.hasPrefix(triggers[$0]) }
                guard matching.count == 1 else { throw .conversion("Each tag must match exactly one trigger") }
                let i = matching[0]
                groups[i].append(try tagExpression(tag, droppingPrefix: triggers[i], depth: depth))
                if atLeastOne { firstChoices.append(try tagExpression(tag, depth: depth)) }
            }
            guard groups.allSatisfy({ !$0.isEmpty }) else { throw .conversion("Each trigger must dispatch to at least one tag") }
            if atLeastOne && stopAfterFirst { return rule("triggered_tags", choice(firstChoices)) }
            let pairs = triggers.indices.map { i in (Array(triggers[i].utf8), rule("triggered_tags_group", choice(groups[i]))) }
            let dispatch = builder.addTagDispatch(.init(tagRulePairs: pairs, loopAfterDispatch: !stopAfterFirst, excludes: (excludes + context.strings).map { Array($0.utf8) }))
            if atLeastOne {
                return rule("triggered_tags", sequence([choice(firstChoices), ref(rule("triggered_tags_sub", dispatch))]))
            }
            return rule("triggered_tags", dispatch)
        case .tagsWithSeparator(let tags, let separator, let atLeastOne, let stopAfterFirst):
            guard !tags.isEmpty else { throw .conversion("tagsWithSeparator requires tags") }
            let tagsRule = rule("tags_with_separator_tags", choice(try tags.map { tag throws(GrammarError) in try tagExpression(tag, depth: depth) }))
            let head = ref(tagsRule)
            var body = head
            if !stopAfterFirst {
                let item = rule("tags_with_separator_item", sequence([literal(separator), head]))
                body = sequence([head, builder.addRepeat(ruleID: item, min: 0, max: -1)])
            }
            return rule("tags_with_separator", atLeastOne ? body : choice([literal(""), body]))
        case .dispatch(let rules, let loop, let excludes):
            guard rules.allSatisfy({ !$0.trigger.isEmpty }) else { throw .conversion("Dispatch triggers must not be empty") }
            var pairs: [(tag: [UInt8], ruleID: Int32)] = []
            for item in rules { pairs.append((Array(item.trigger.utf8), try visit(item.content, context: context, depth: depth + 1))) }
            return rule("tag_dispatch", builder.addTagDispatch(.init(tagRulePairs: pairs, loopAfterDispatch: loop, excludes: (excludes + context.strings).map { Array($0.utf8) })))
        case .token(let token): return rule("token", builder.addTokenSet([try resolve(token)]))
        case .excludingTokens(let tokens): return rule("exclude_token", builder.addExcludeTokenSet(try resolved(tokens + context.tokens)))
        case .anyTokens(let excludes, let maxTokens):
            let limit = try limit(maxTokens, named: "maxTokens")
            let item = rule("any_tokens_inner", builder.addExcludeTokenSet(try resolved(excludes + context.tokens)))
            // Right-recursive as upstream: any_tokens ::= "" | any_tokens_inner any_tokens.
            let id = builder.addEmptyRule(hint: "any_tokens")
            builder.updateRuleBody(id, limit == 0 ? literal("") : choice([literal(""), sequence([ref(item), ref(id)])]))
            builder.updateMaxTokens(id, limit)
            return id
        case .tokenTriggeredTags(let triggers, let tags, let atLeastOne, let stopAfterFirst, let excludes):
            let ids = try resolved(triggers)
            guard !ids.isEmpty, !tags.isEmpty else { throw .conversion("tokenTriggeredTags requires triggers and tags") }
            var groups: [Int32: [Int32]] = [:]
            var firstChoices: [Int32] = []
            for tag in tags {
                guard case .token(let token) = tag.begin else { throw .conversion("Token-triggered tags require token format begins") }
                let id = try resolve(token)
                guard ids.contains(id) else { throw .conversion("Tag begin does not match a trigger token") }
                let rest = sequence([ref(try visit(tag.content, context: self.context(tag), depth: depth + 1)), try end(tag)])
                groups[id, default: []].append(rest)
                firstChoices.append(sequence([builder.addTokenSet([id]), rest]))
            }
            guard ids.allSatisfy({ groups[$0] != nil }) else { throw .conversion("Every trigger token must dispatch to a tag") }
            if atLeastOne && stopAfterFirst { return rule("token_triggered_tags", choice(firstChoices)) }
            let pairs = ids.map { ($0, rule("token_triggered_tags_group", choice(groups[$0]!))) }
            let dispatch = builder.addTokenTagDispatch(.init(triggerRulePairs: pairs, loopAfterDispatch: !stopAfterFirst, excludes: try resolved(excludes + context.tokens)))
            let body = atLeastOne ? sequence([choice(firstChoices), ref(rule("token_triggered_tags_sub", dispatch))]) : dispatch
            return rule("token_triggered_tags", body)
        case .tokenDispatch(let rules, let loop, let excludes):
            var pairs: [(tokenID: Int32, ruleID: Int32)] = []
            for item in rules { pairs.append((try resolve(item.trigger), try visit(item.content, context: context, depth: depth + 1))) }
            return rule("token_tag_dispatch", builder.addTokenTagDispatch(.init(triggerRulePairs: pairs, loopAfterDispatch: loop, excludes: try resolved(excludes + context.tokens))))
        case .captured(let name, let child):
            guard !name.isEmpty else { throw .conversion("Capture names must not be empty") }
            let id = rule("capture", ref(try visit(child, context: context, depth: depth + 1)))
            builder.updateCaptureName(id, name)
            return id
        case .temperature(let value, let child):
            guard value.isFinite, value >= 0 else { throw .conversion("Temperature must be finite and non-negative") }
            let id = rule("temperature", ref(try visit(child, context: context, depth: depth + 1)))
            builder.updateTemperature(id, value)
            return id
        }
    }

    private func repetition(_ child: StructuralFormat, context: EndContext, minimum: Int, maximum: Int?, depth: Int) throws(GrammarError) -> Int32 {
        let min = try limit(minimum, named: "minimum")
        let max = try limit(maximum, named: "maximum")
        guard max == -1 || min <= max else { throw .conversion("minimum exceeds maximum") }
        let content = try visit(child, context: context, depth: depth + 1)
        return rule("repeat", builder.addRepeat(ruleID: content, min: min, max: max))
    }
}

extension GrammarError {
    /// Conversion failures of a structural tag carry upstream's `InvalidStructuralTagError`
    /// prefix, so messages read the same as XGrammar's.
    var structuralTagError: GrammarError {
        let prefix = "Invalid structural tag error: "
        guard case .conversion(let message) = self, !message.hasPrefix(prefix) else { return self }
        return .conversion(prefix + message)
    }
}
