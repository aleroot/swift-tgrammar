// Incremental construction of grammar storage. Used by the EBNF parser, the converters and every
// rewriting pass. Rules can be declared first (so bodies may forward-reference them) and filled in
// later with `updateRuleBody`.

struct GrammarBuilder {
    private(set) var storage = GrammarStorage()
    private var ruleIDsByName: [String: Int32] = [:]
    private var nextCountPerHint: [String: Int] = [:]

    init() {}

    /// Starts from an existing storage, e.g. to append rules to a copy of another grammar.
    init(storage: GrammarStorage) {
        self.storage = storage
        for (index, rule) in storage.rules.enumerated() {
            ruleIDsByName[rule.name] = Int32(index)
        }
    }

    // MARK: Expressions

    @discardableResult
    mutating func addExpr(_ kind: GrammarExprKind, _ payload: some Collection<Int32>) -> Int32 {
        storage.append(kind, payload)
    }

    /// Copies an expression record (possibly from another grammar) verbatim.
    @discardableResult
    mutating func addExpr(_ expr: GrammarExpr) -> Int32 {
        storage.append(expr.kind, expr.data)
    }

    mutating func addByteString(_ bytes: some Collection<UInt8>) -> Int32 {
        var payload: [Int32] = []
        payload.reserveCapacity(bytes.count)
        for byte in bytes { payload.append(Int32(byte)) }
        return storage.append(.byteString, payload)
    }

    mutating func addByteString(_ string: String) -> Int32 {
        var copy = string
        return copy.withUTF8 { addByteString($0) }
    }

    mutating func addRegex(_ pattern: some Collection<UInt8>, isJSONString: Bool = false) -> Int32 {
        var payload: [Int32] = [isJSONString ? 1 : 0]
        payload.reserveCapacity(pattern.count &+ 1)
        for byte in pattern { payload.append(Int32(byte)) }
        return storage.append(.regex, payload)
    }

    mutating func addSubstring(_ chunks: [[UInt8]]) -> Int32 {
        var payload: [Int32] = []
        payload.reserveCapacity(chunks.reduce(chunks.count) { $0 &+ $1.count })
        for chunk in chunks {
            payload.append(Int32(chunk.count))
            for byte in chunk { payload.append(Int32(byte)) }
        }
        return storage.append(.substring, payload)
    }

    mutating func addCharacterClass(_ ranges: [ClosedRange<Codepoint>], isNegated: Bool = false) -> Int32 {
        var payload: [Int32] = [isNegated ? 1 : 0]
        payload.reserveCapacity(ranges.count &* 2 &+ 1)
        for range in ranges {
            payload.append(range.lowerBound)
            payload.append(range.upperBound)
        }
        return storage.append(.characterClass, payload)
    }

    mutating func addCharacterClassStar(_ ranges: [ClosedRange<Codepoint>], isNegated: Bool = false) -> Int32 {
        var payload: [Int32] = [isNegated ? 1 : 0]
        payload.reserveCapacity(ranges.count &* 2 &+ 1)
        for range in ranges {
            payload.append(range.lowerBound)
            payload.append(range.upperBound)
        }
        return storage.append(.characterClassStar, payload)
    }

    mutating func addEmptyString() -> Int32 { storage.append(.emptyString, EmptyCollection()) }

    mutating func addTokenSet(_ tokenIDs: [Int32]) -> Int32 { storage.append(.token, tokenIDs) }

    mutating func addExcludeTokenSet(_ tokenIDs: [Int32]) -> Int32 { storage.append(.excludeToken, tokenIDs) }

    mutating func addRuleRef(_ ruleID: Int32) -> Int32 { storage.append(.ruleRef, CollectionOfOne(ruleID)) }

    mutating func addSequence(_ exprIDs: [Int32]) -> Int32 { storage.append(.sequence, exprIDs) }

    mutating func addChoices(_ exprIDs: [Int32]) -> Int32 { storage.append(.choices, exprIDs) }

    mutating func addTagDispatch(_ dispatch: TagDispatch) -> Int32 {
        var payload: [Int32] = []
        payload.reserveCapacity(dispatch.tagRulePairs.count &* 2 &+ GrammarStorage.tagDispatchTrailingWords)
        for pair in dispatch.tagRulePairs {
            payload.append(addByteString(pair.tag))
            payload.append(pair.ruleID)
        }
        payload.append(dispatch.loopAfterDispatch ? 1 : 0)
        let excludeIDs = dispatch.excludes.map { addByteString($0) }
        payload.append(addChoices(excludeIDs))
        return storage.append(.tagDispatch, payload)
    }

    mutating func addTokenTagDispatch(_ dispatch: TokenTagDispatch) -> Int32 {
        var payload: [Int32] = [Int32(dispatch.triggerRulePairs.count)]
        payload.reserveCapacity(dispatch.triggerRulePairs.count &* 2 &+ dispatch.excludes.count &+ 3)
        for pair in dispatch.triggerRulePairs {
            payload.append(pair.tokenID)
            payload.append(pair.ruleID)
        }
        payload.append(dispatch.loopAfterDispatch ? 1 : 0)
        payload.append(Int32(dispatch.excludes.count))
        payload.append(contentsOf: dispatch.excludes)
        return storage.append(.tokenTagDispatch, payload)
    }

    /// `ruleID{min, max}`; `max == -1` means unbounded.
    mutating func addRepeat(ruleID: Int32, min: Int32, max: Int32) -> Int32 {
        storage.append(.repeat, [ruleID, min, max])
    }

    /// Repeats an arbitrary expression by wrapping it in a fresh rule unless it already is a
    /// rule reference.
    mutating func addRepeat(exprID: Int32, min: Int32, max: Int32, nameHint: String) -> Int32 {
        let expr = storage.expr(exprID)
        let ruleID = expr.kind == .ruleRef ? expr[0] : addRule(name: newRuleName(hint: nameHint), bodyExprID: exprID)
        return addRepeat(ruleID: ruleID, min: min, max: max)
    }

    // MARK: Rules

    @inline(__always)
    func expr(_ id: Int32) -> GrammarExpr { storage.expr(id) }

    @inline(__always)
    func rule(_ id: Int32) -> GrammarRule { storage.rule(id) }

    var ruleCount: Int { storage.rules.count }

    func ruleID(named name: String) -> Int32? { ruleIDsByName[name] }

    @discardableResult
    mutating func addRule(_ rule: GrammarRule) -> Int32 {
        precondition(ruleIDsByName[rule.name] == nil, "Rule \"\(rule.name)\" is already defined.")
        let id = Int32(storage.rules.count)
        storage.rules.append(rule)
        ruleIDsByName[rule.name] = id
        return id
    }

    @discardableResult
    mutating func addRule(name: String, bodyExprID: Int32) -> Int32 {
        addRule(GrammarRule(name: name, bodyExprID: bodyExprID))
    }

    /// Adds a rule whose name is derived from `hint`.
    @discardableResult
    mutating func addRule(hint: String, bodyExprID: Int32) -> Int32 {
        addRule(name: newRuleName(hint: hint), bodyExprID: bodyExprID)
    }

    /// Declares a rule whose body is filled in later.
    @discardableResult
    mutating func addEmptyRule(name: String) -> Int32 {
        addRule(name: name, bodyExprID: -1)
    }

    @discardableResult
    mutating func addEmptyRule(hint: String) -> Int32 {
        addRule(name: newRuleName(hint: hint), bodyExprID: -1)
    }

    /// Returns `hint` when free, otherwise `hint_N` with a per-hint counter that skips taken names.
    mutating func newRuleName(hint: String) -> String {
        // Converter hints can contain JSON property names, including punctuation and Unicode.
        // Explicit rule names retain their spelling; generated names must remain valid EBNF.
        @inline(__always) func isNameByte(_ value: UInt32) -> Bool {
            switch value {
            case 65 ... 90, 97 ... 122, 48 ... 57, 95, 45: true
            default: false
            }
        }
        // Hints are nearly always valid already; only others are rebuilt scalar by scalar.
        var hint = hint
        if !hint.utf8.allSatisfy({ isNameByte(UInt32($0)) }) {
            var sanitized = ""
            for scalar in hint.unicodeScalars {
                sanitized.unicodeScalars.append(isNameByte(scalar.value) ? scalar : "_")
            }
            hint = sanitized
        }
        if hint.isEmpty { hint = "rule" }
        if let first = hint.utf8.first, (48 ... 57).contains(first) { hint = "_" + hint }
        if ruleIDsByName[hint] == nil { return hint }
        var counter = max(nextCountPerHint[hint] ?? 1, 1)
        var candidate = "\(hint)_\(counter)"
        while ruleIDsByName[candidate] != nil {
            counter += 1
            candidate = "\(hint)_\(counter)"
        }
        nextCountPerHint[hint] = counter
        return candidate
    }

    mutating func updateRuleBody(_ ruleID: Int32, _ bodyExprID: Int32) {
        storage.rules[Int(ruleID)].bodyExprID = bodyExprID
    }

    mutating func updateLookaheadAssertion(_ ruleID: Int32, _ exprID: Int32) {
        storage.rules[Int(ruleID)].lookaheadAssertionID = exprID
    }

    mutating func updateLookaheadExact(_ ruleID: Int32, _ isExact: Bool = true) {
        storage.rules[Int(ruleID)].isExactLookahead = isExact
    }

    mutating func updateMaxTokens(_ ruleID: Int32, _ maxTokens: Int32) {
        storage.rules[Int(ruleID)].maxTokens = maxTokens
    }

    mutating func updateMaxChars(_ ruleID: Int32, _ maxChars: Int32) {
        storage.rules[Int(ruleID)].maxChars = maxChars
    }

    mutating func updateCaptureName(_ ruleID: Int32, _ name: String) {
        storage.rules[Int(ruleID)].captureName = name
    }

    mutating func updateLazy(_ ruleID: Int32, _ isLazy: Bool) {
        storage.rules[Int(ruleID)].isLazy = isLazy
    }

    mutating func updateTemperature(_ ruleID: Int32, _ temperature: Float?) {
        storage.rules[Int(ruleID)].temperature = temperature
    }

    mutating func updateSuffixStopInfo(_ ruleID: Int32, _ info: SuffixStopInfo) {
        storage.setSuffixStopInfo(info, for: ruleID)
    }

    /// Copies every per-rule attribute except name and body.
    mutating func copyAttributes(of source: GrammarRule, suffixStopInfo: SuffixStopInfo?, to ruleID: Int32) {
        var rule = storage.rules[Int(ruleID)]
        rule.isExactLookahead = source.isExactLookahead
        rule.maxTokens = source.maxTokens
        rule.maxChars = source.maxChars
        rule.captureName = source.captureName
        rule.isLazy = source.isLazy
        rule.temperature = source.temperature
        storage.rules[Int(ruleID)] = rule
        if let suffixStopInfo { storage.setSuffixStopInfo(suffixStopInfo, for: ruleID) }
    }

    // MARK: Finishing

    /// Finalizes the storage with the given root rule.
    func finish(rootRuleName: String) throws(GrammarError) -> GrammarStorage {
        guard let id = ruleIDsByName[rootRuleName] else {
            throw GrammarError.invalidGrammar("The root rule with name \"\(rootRuleName)\" is not found.")
        }
        return finish(rootRuleID: id)
    }

    func finish(rootRuleID: Int32) -> GrammarStorage {
        precondition(rootRuleID >= 0 && Int(rootRuleID) < storage.rules.count, "The root rule id \(rootRuleID) is out of bound.")
        var result = storage
        result.rootRuleID = rootRuleID
        return result
    }
}
