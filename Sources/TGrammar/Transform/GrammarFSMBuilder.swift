// Builds one automaton per rule and packs them into the grammar's complete FSM. Each rule body
// is streamed element by element into a fresh `FSM` (byte strings become chains, classes become
// UTF-8 range edges, references become rule edges, repetitions become repeat edges), then
// reduced with epsilon simplification and equivalent-state merging.

struct GrammarFSMBuilder {
    /// Bytes that must be escaped inside a JSON string literal: control characters, `"`, `\`.
    static let jsonStringForbiddenBytes: ByteSet = {
        var set = ByteSet(range: 0x00 ... 0x1F)
        set.insert(UInt8(ascii: "\""))
        set.insert(UInt8(ascii: "\\"))
        return set
    }()

    private var target: FSM
    private let ruleName: String?
    private let makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory?

    private init(target: FSM, ruleName: String? = nil, makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory? = nil) {
        self.target = target
        self.ruleName = ruleName
        self.makeRepeatRule = makeRepeatRule
    }

    /// The built automaton, moved out so that the reducers that follow edit it in place
    /// instead of copying storage still shared with the builder.
    private consuming func finish() -> FSM { target }

    // MARK: Whole-grammar entry point

    struct RegexRuleKey: Hashable, Sendable { var pattern: [UInt8]; var isJSONString: Bool }
    /// Reduced automata of regex rule bodies. Converters emit the same regex for many rules
    /// (every JSON string value, for one), in grammar after grammar; building and reducing it
    /// dominated optimization. An automaton depends only on its pattern unless building it
    /// created repeat rules, and those are never stored.
    static let regexRuleAutomata = BoundedMemo<RegexRuleKey, FSMWithStartEnd>(capacity: 256)

    static func apply(_ grammar: inout GrammarStorage) throws(GrammarError) {
        var complete = CompactFSMAppender()
        var perRule: [(start: Int32, ends: [Int32], edgeCount: Int, nodeCount: Int)] = []
        let originalRuleCount = grammar.ruleCount
        // Compiling a regex rule may append rules (large bounded repetitions become repeat
        // edges referencing new rules); the count is re-read so they get automata as well.
        var builder = GrammarBuilder(storage: grammar)
        var ruleID: Int32 = 0
        while Int(ruleID) < builder.ruleCount {
            let body = builder.storage.expr(builder.storage.rule(ruleID).bodyExprID)
            let regexKey = body.kind == .regex
                ? RegexRuleKey(pattern: builder.storage.regexPattern(body), isJSONString: builder.storage.regexIsJSONString(body))
                : nil
            var createdRepeatRules = false
            let fsm: FSMWithStartEnd
            if let regexKey, let memoized = regexRuleAutomata.value(for: regexKey) {
                fsm = memoized
            } else {
                fsm = try buildRuleFSM(builder.storage, ruleID: ruleID) { hint, regex in
                    createdRepeatRules = true
                    let id = builder.addRule(hint: hint, bodyExprID: builder.addRegex(regex))
                    builder.updateLookaheadExact(id, true)
                    return id
                }
                if let regexKey, !createdRepeatRules { regexRuleAutomata.insert(fsm, for: regexKey) }
            }
            perRule.append(complete.append(fsm))
            ruleID += 1
        }
        grammar = builder.finish(rootRuleID: grammar.rootRuleID)

        // Rules created during FSM building missed the nullability analysis; new ids are larger
        // than all existing ones, so appending keeps the list sorted.
        for index in originalRuleCount ..< grammar.ruleCount {
            let body = grammar.expr(grammar.rule(Int32(index)).bodyExprID)
            assert(body.kind == .regex)
            if let matchesEmpty = try? RegexFSMBuilder.matchesEmpty(grammar.regexPattern(body)), matchesEmpty {
                grammar.allowEmptyRuleIDs.append(Int32(index))
            }
        }

        let compact = complete.finish()
        grammar.completeFSM = compact
        grammar.perRuleFSMs = perRule.map { entry in
            CompactFSMWithStartEndWithSize(
                fsm: CompactFSMWithStartEnd(fsm: compact, start: entry.start, ends: entry.ends),
                edgeCount: entry.edgeCount,
                nodeCount: entry.nodeCount
            )
        }
    }

    private static func buildRuleFSM(_ grammar: GrammarStorage, ruleID: Int32, makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory?) throws(GrammarError) -> FSMWithStartEnd {
        let rule = grammar.rule(ruleID)
        return try buildExpressionFSM(grammar.expr(rule.bodyExprID), grammar, ruleName: rule.name, makeRepeatRule: makeRepeatRule)
    }

    static func buildExpressionFSM(_ expr: GrammarExpr, _ grammar: GrammarStorage, ruleName: String? = nil, makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory? = nil) throws(GrammarError) -> FSMWithStartEnd {
        var fsm = FSM()
        let start = fsm.addState()
        var builder = GrammarFSMBuilder(target: fsm, ruleName: ruleName, makeRepeatRule: makeRepeatRule)
        var ends: [Int32] = []
        try builder.build(expr, grammar, from: start, ends: &ends)
        var result = FSMWithStartEnd(fsm: builder.finish(), start: start, ends: ends)
        if expr.kind != .tagDispatch, expr.kind != .tokenTagDispatch {
            result = result.reduced()
        }
        return result
    }

    // MARK: Standalone element automata (used by the converters)

    static func ruleRef(_ expr: GrammarExpr) -> FSMWithStartEnd {
        standalone { builder, start, ends in builder.buildRuleRef(expr, from: start, ends: &ends) }
    }

    static func characterClass(_ expr: GrammarExpr) -> FSMWithStartEnd {
        standalone { builder, start, ends in
            if expr.kind == .characterClassStar {
                builder.buildCharacterClassStar(expr, from: start, ends: &ends)
            } else {
                builder.buildCharacterClass(expr, from: start, ends: &ends)
            }
        }
    }

    static func byteString(_ expr: GrammarExpr) -> FSMWithStartEnd {
        standalone { builder, start, ends in builder.buildByteString(expr, from: start, ends: &ends) }
    }

    static func token(_ expr: GrammarExpr) -> FSMWithStartEnd {
        standalone { builder, start, ends in builder.buildToken(expr, from: start, ends: &ends) }
    }

    static func excludeToken(_ expr: GrammarExpr) -> FSMWithStartEnd {
        standalone { builder, start, ends in builder.buildExcludeToken(expr, from: start, ends: &ends) }
    }

    static func tokenTagDispatch(_ dispatch: TokenTagDispatch) -> FSMWithStartEnd {
        standalone { builder, start, ends in builder.buildTokenTagDispatch(dispatch, from: start, ends: &ends) }
    }

    static func sequence(_ expr: GrammarExpr, _ grammar: GrammarStorage) throws(GrammarError) -> FSMWithStartEnd {
        var fsm = FSM()
        let start = fsm.addState()
        var builder = GrammarFSMBuilder(target: fsm)
        var ends: [Int32] = []
        try builder.buildSequence(expr, grammar, from: start, ends: &ends)
        return FSMWithStartEnd(fsm: builder.finish(), start: start, ends: ends)
    }

    static func choices(_ expr: GrammarExpr, _ grammar: GrammarStorage) throws(GrammarError) -> FSMWithStartEnd {
        try buildExpressionFSM(expr, grammar)
    }

    /// The automaton of a regex pattern, reduced. `isJSONString` excludes the bytes that must
    /// be escaped in a JSON string literal from every byte transition.
    static func regex(_ pattern: [UInt8], isJSONString: Bool = false) throws(GrammarError) -> FSMWithStartEnd {
        let result = isJSONString
            ? try RegexFSMBuilder.build(pattern, forbidding: jsonStringForbiddenBytes)
            : try RegexFSMBuilder.build(pattern)
        return result.reduced()
    }

    /// Automaton of a tag dispatch: an Aho-Corasick trie of the triggers, each trigger's end
    /// state leading through its rule back to the start (or to a final state).
    static func tagDispatch(_ dispatch: TagDispatch) -> FSMWithStartEnd? {
        buildTagDispatchFSM(triggers: dispatch.tagRulePairs, loopAfterDispatch: dispatch.loopAfterDispatch, excludes: dispatch.excludes)
    }

    static func buildTagDispatchFSM(triggers: [(tag: [UInt8], ruleID: Int32)], loopAfterDispatch: Bool, excludes: [[UInt8]]) -> FSMWithStartEnd? {
        guard let trie = TrieFSMBuilder.build(patterns: triggers.map(\.tag), excludedPatterns: excludes, allowOverlap: true, addBackEdges: true) else {
            return nil
        }
        var fsm = trie.fsm.fsm
        let start = trie.fsm.start
        // Every state but the trie's own end states accepts.
        var ends: [Int32] = []
        for state in 0 ..< Int32(fsm.stateCount) where !trie.fsm.isEndState(state) { ends.append(state) }
        for (index, trigger) in triggers.enumerated() {
            let next: Int32
            if loopAfterDispatch {
                next = start
            } else {
                next = fsm.addState()
                ends.append(next)
            }
            fsm.addRuleEdge(from: trie.patternEndStates[index], to: next, ruleID: trigger.ruleID)
        }
        return FSMWithStartEnd(fsm: fsm, start: start, ends: ends)
    }

    private static func standalone(_ body: (inout GrammarFSMBuilder, Int32, inout [Int32]) -> Void) -> FSMWithStartEnd {
        var fsm = FSM()
        let start = fsm.addState()
        var builder = GrammarFSMBuilder(target: fsm)
        var ends: [Int32] = []
        body(&builder, start, &ends)
        return FSMWithStartEnd(fsm: builder.finish(), start: start, ends: ends)
    }

    // MARK: Expression lowering

    // Not inlined: sequences and choices recurse through here, and inlining the whole dispatch
    // into each of their call sites made them ~38 KB of machine code for no measurable gain.
    @inline(never)
    private mutating func build(_ expr: GrammarExpr, _ grammar: GrammarStorage, from start: Int32, ends: inout [Int32]) throws(GrammarError) {
        switch expr.kind {
        case .emptyString:
            ends = [start]
        case .byteString:
            buildByteString(expr, from: start, ends: &ends)
        case .characterClass:
            buildCharacterClass(expr, from: start, ends: &ends)
        case .characterClassStar:
            buildCharacterClassStar(expr, from: start, ends: &ends)
        case .ruleRef:
            buildRuleRef(expr, from: start, ends: &ends)
        case .repeat:
            ends.removeAll()
            let end = target.addState()
            target.addRepeatEdge(from: start, to: end, ruleID: expr[0], lower: expr[1], upper: expr[2])
            ends.append(end)
        case .token:
            buildToken(expr, from: start, ends: &ends)
        case .excludeToken:
            buildExcludeToken(expr, from: start, ends: &ends)
        case .sequence:
            try buildSequence(expr, grammar, from: start, ends: &ends)
        case .choices:
            try buildChoices(expr, grammar, from: start, ends: &ends)
        case .regex:
            try buildRegex(grammar.regexPattern(expr), isJSONString: grammar.regexIsJSONString(expr), from: start, ends: &ends)
        case .substring:
            append(SuffixAutomaton.build(chunks: grammar.substringChunks(expr)), from: start, ends: &ends)
        case .tagDispatch:
            guard let fsm = Self.tagDispatch(grammar.tagDispatch(expr)) else { throw .compilation("Failed to build tag dispatch FSM") }
            append(fsm, from: start, ends: &ends)
        case .tokenTagDispatch:
            buildTokenTagDispatch(grammar.tokenTagDispatch(expr), from: start, ends: &ends)
        }
    }

    private mutating func buildByteString(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        var current = start
        for byte in expr {
            let next = target.addState()
            let value = Int32(UInt8(truncatingIfNeeded: byte))
            target.addEdge(from: current, to: next, min: value, max: value)
            current = next
        }
        ends.append(current)
    }

    private mutating func buildRuleRef(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        let end = target.addState()
        target.addRuleEdge(from: start, to: end, ruleID: expr[0])
        ends.append(end)
    }

    private mutating func buildToken(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        let end = target.addState()
        target.addTokenEdge(from: start, to: end, tokenIDs: expr.data)
        ends.append(end)
    }

    private mutating func buildExcludeToken(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        let end = target.addState()
        target.addExcludeTokenEdge(from: start, to: end, tokenIDs: expr.data)
        ends.append(end)
    }

    private mutating func buildCharacterClass(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        let end = target.addState()
        addCharacterClassTransitions(expr, from: start, to: end)
        ends.append(end)
    }

    private mutating func buildCharacterClassStar(_ expr: GrammarExpr, from start: Int32, ends: inout [Int32]) {
        ends.removeAll()
        addCharacterClassTransitions(expr, from: start, to: start)
        ends.append(start)
    }

    private mutating func addCharacterClassTransitions(_ expr: GrammarExpr, from: Int32, to: Int32) {
        if expr[0] != 0 {
            // Complement the code point ranges before encoding them; complementing bytes would
            // let [^\x00-\U0010ffff] accept every multi-byte character.
            var excluded: [ClosedRange<UInt32>] = []
            var index = 1
            while index + 1 < expr.count {
                excluded.append(UInt32(bitPattern: expr[index]) ... UInt32(bitPattern: expr[index + 1]))
                index += 2
            }
            excluded.sort { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound < $1.upperBound }
            var next: UInt32 = 0
            for range in excluded {
                if range.lowerBound > next {
                    UTF8Ranges.addCodepointRangeEdges(&target, from: from, to: to, low: next, high: min(range.lowerBound - 1, UTF8Ranges.maxCodepoint))
                }
                if range.upperBound >= UTF8Ranges.maxCodepoint { return }
                next = max(next, range.upperBound + 1)
            }
            if next <= UTF8Ranges.maxCodepoint {
                UTF8Ranges.addCodepointRangeEdges(&target, from: from, to: to, low: next, high: UTF8Ranges.maxCodepoint)
            }
        } else {
            var index = 1
            while index + 1 < expr.count {
                UTF8Ranges.addCodepointRangeEdges(&target, from: from, to: to, low: UInt32(bitPattern: expr[index]), high: UInt32(bitPattern: expr[index + 1]))
                index += 2
            }
        }
    }

    private mutating func buildSequence(_ expr: GrammarExpr, _ grammar: GrammarStorage, from start: Int32, ends: inout [Int32]) throws(GrammarError) {
        ends.removeAll()
        if expr.isEmpty {
            ends.append(start)
            return
        }
        try build(grammar.expr(expr[0]), grammar, from: start, ends: &ends)
        var nextEnds: [Int32] = []
        for index in 1 ..< expr.count {
            let elementStart = target.addState()
            try build(grammar.expr(expr[index]), grammar, from: elementStart, ends: &nextEnds)
            for previousEnd in ends { target.addEpsilonEdge(from: previousEnd, to: elementStart) }
            swap(&ends, &nextEnds)
        }
    }

    private mutating func buildChoices(_ expr: GrammarExpr, _ grammar: GrammarStorage, from start: Int32, ends: inout [Int32]) throws(GrammarError) {
        ends.removeAll()
        var nonEmptyCount = 0
        var nullable = false
        for choiceID in expr {
            if grammar.kind(of: choiceID) == .emptyString { nullable = true } else { nonEmptyCount += 1 }
        }
        if nonEmptyCount == 0 {
            ends.append(start)
            return
        }
        if nonEmptyCount == 1, !nullable {
            for choiceID in expr where grammar.kind(of: choiceID) != .emptyString {
                try build(grammar.expr(choiceID), grammar, from: start, ends: &ends)
                return
            }
        }
        var branchEnds: [Int32] = []
        for choiceID in expr {
            let choice = grammar.expr(choiceID)
            if choice.kind == .emptyString { continue }
            let branchStart = target.addState()
            try build(choice, grammar, from: branchStart, ends: &branchEnds)
            target.addEpsilonEdge(from: start, to: branchStart)
            ends.append(contentsOf: branchEnds)
        }
        if nullable {
            let nullableState = target.addState()
            target.addEpsilonEdge(from: start, to: nullableState)
            ends.append(nullableState)
        }
    }

    /// Splices a standalone automaton in at `start`. A still-empty target is replaced outright.
    private mutating func append(_ fsm: FSMWithStartEnd, from start: Int32, ends: inout [Int32]) {
        let targetIsEmpty = target.stateCount == 1 && start == 0 && target.edges(of: 0).isEmpty && target.auxData.isEmpty && fsm.start == 0
        if targetIsEmpty {
            ends = fsm.ends
            target = fsm.fsm
            return
        }
        let mapping = target.addFSM(fsm.fsm)
        target.addEpsilonEdge(from: start, to: mapping[Int(fsm.start)])
        ends = fsm.ends.map { mapping[Int($0)] }
    }

    private mutating func buildRegex(_ pattern: [UInt8], isJSONString: Bool, from start: Int32, ends: inout [Int32]) throws(GrammarError) {
        let hint = ruleName ?? ""
        let built: FSMWithStartEnd
        do {
            built = isJSONString
                ? try RegexFSMBuilder.build(pattern, forbidding: Self.jsonStringForbiddenBytes, makeRepeatRule: makeRepeatRule, ruleHint: hint)
                : try RegexFSMBuilder.build(pattern, makeRepeatRule: makeRepeatRule, ruleHint: hint)
        } catch {
            let regexText = String(decoding: pattern, as: UTF8.self)
            if let ruleName {
                throw .compilation("Failed to build the automaton for rule \(ruleName) with regex \(regexText): \(error.message)")
            }
            throw .compilation("Failed to build the automaton for regex \(regexText): \(error.message)")
        }
        append(built, from: start, ends: &ends)
    }

    private mutating func buildTokenTagDispatch(_ dispatch: TokenTagDispatch, from start: Int32, ends: inout [Int32]) {
        let triggerCount = dispatch.triggerRulePairs.count
        var dispatchStates: [Int32] = []
        dispatchStates.reserveCapacity(triggerCount)
        for _ in 0 ..< triggerCount { dispatchStates.append(target.addState()) }

        var endState: Int32 = -1
        ends = [start]
        if !dispatch.loopAfterDispatch {
            endState = target.addState()
            ends.append(endState)
        }

        var excludedTokenIDs = dispatch.triggerRulePairs.map(\.tokenID)
        excludedTokenIDs.append(contentsOf: dispatch.excludes)
        excludedTokenIDs.sort()
        excludedTokenIDs.removeDuplicatesSorted()

        for (index, pair) in dispatch.triggerRulePairs.enumerated() {
            let dispatchTarget = dispatch.loopAfterDispatch ? start : endState
            target.addTokenEdge(from: start, to: dispatchStates[index], tokenIDs: CollectionOfOne(pair.tokenID))
            target.addRuleEdge(from: dispatchStates[index], to: dispatchTarget, ruleID: pair.ruleID)
        }
        target.addExcludeTokenEdge(from: start, to: start, tokenIDs: excludedTokenIDs)
    }
}
