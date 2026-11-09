// Expands `rule{m,n}` repetitions. Small bounds are unzipped into chains of optional rules
// (`rest_k ::= "" | expr rest_{k+1}`); large bounds keep a counted repeat edge executed by the
// parser; length-bounded JSON string bodies stay as one counted edge so the matcher can decide
// most tokens from the bounds alone.

struct RepetitionRangeExpander {
    static let unzipThreshold: Int64 = 128

    private var rewriter: GrammarRewriter
    /// The first byte of the element after the repetition being visited, if it is a byte string.
    private var followByte: UInt8? = nil
    /// Set when a repetition is kept as a counted repeat edge.
    private var countedRepetition = false
    private let hasCharBudgetRules: Bool
    private let hasLazyRules: Bool
    /// `(kind, payload…, lower, upper, followByte|-1)` → resulting expression id. Identical
    /// repetitions (e.g. thousands of whitespace bounds from a JSON schema) share one expansion.
    private var repetitionCache: [[Int64]: Int32] = [:]
    /// Body rule of the counted repetitions of each character class + follow byte.
    private var countedBodyRuleIDs: [[Int32]: Int32] = [:]

    private var source: GrammarStorage { rewriter.source }

    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        var expander = RepetitionRangeExpander(
            rewriter: GrammarRewriter(source: grammar),
            hasCharBudgetRules: grammar.rules.contains { $0.maxChars >= 0 },
            hasLazyRules: grammar.rules.contains { $0.isLazy }
        )
        return expander.run()
    }

    private mutating func run() -> GrammarStorage {
        rewriter.declareRules()
        for index in 0 ..< source.ruleCount {
            let ruleID = Int32(index)
            let rule = source.rule(ruleID)
            rewriter.currentRuleName = rule.name
            rewriter.builder.updateRuleBody(ruleID, visit(source.expr(rule.bodyExprID)))
            if rule.lookaheadAssertionID != -1 {
                rewriter.builder.updateLookaheadAssertion(ruleID, visit(source.expr(rule.lookaheadAssertionID)))
            }
            rewriter.copyAttributes(ruleID: ruleID)
        }
        return rewriter.builder.finish(rootRuleID: source.rootRuleID)
    }

    private mutating func visit(_ expr: GrammarExpr) -> Int32 {
        switch expr.kind {
        case .repeat:
            return handleRepetitionRange(ruleID: expr[0], lower: Int64(expr[1]), upper: Int64(expr[2]))
        case .sequence:
            return visitSequence(expr)
        case .choices:
            var children: [Int32] = []
            children.reserveCapacity(expr.count)
            for childID in expr { children.append(visit(source.expr(childID))) }
            return rewriter.builder.addChoices(children)
        case .tagDispatch:
            return rewriter.builder.addTagDispatch(source.tagDispatch(expr))
        default:
            return rewriter.builder.addExpr(expr)
        }
    }

    /// Records the byte following each repetition and moves a counted repetition (with the
    /// byte string after it) into a rule of its own, so the repeat edge leaves its source state
    /// alone (the parser returns to that state after every repetition).
    private mutating func visitSequence(_ expr: GrammarExpr) -> Int32 {
        var sequenceIDs: [Int32] = []
        var index = 0
        while index < expr.count {
            followByte = nil
            countedRepetition = false
            let elementExpr = source.expr(expr[index])
            let isRepeat = elementExpr.kind == .repeat
            if isRepeat, index + 1 < expr.count {
                let next = source.expr(expr[index + 1])
                if next.kind == .byteString, next.count > 0 { followByte = UInt8(truncatingIfNeeded: next[0]) }
            }
            let elementID = visit(elementExpr)
            if !isRepeat || !countedRepetition {
                sequenceIDs.append(elementID)
                index += 1
                continue
            }
            countedRepetition = false
            let followID = visit(source.expr(expr[index + 1]))
            let countedRuleID = rewriter.builder.addRule(
                hint: rewriter.currentRuleName + "_counted",
                bodyExprID: rewriter.builder.addChoices([rewriter.builder.addSequence([elementID, followID])])
            )
            sequenceIDs.append(rewriter.builder.addRuleRef(countedRuleID))
            index += 2
        }
        followByte = nil
        return rewriter.builder.addSequence(sequenceIDs)
    }

    private mutating func handleRepetitionRange(ruleID: Int32, lower: Int64, upper: Int64) -> Int32 {
        var exprID = rewriter.builder.addRuleRef(ruleID)
        let refRule = source.rule(ruleID)
        let refBody = source.expr(refRule.bodyExprID)
        // Keep the reference to budgeted, suffix/stop, lazy and temperature rules: replacing it
        // with the rule's content would erase the rule the runtime semantics apply to.
        if refRule.maxTokens < 0, refRule.maxChars < 0, source.suffixStopInfo(for: ruleID) == nil, !refRule.isLazy,
           refRule.temperature == nil, refBody.kind == .choices, refBody.count == 1 {
            let refChoice = source.expr(refBody[0])
            if refChoice.count == 1 {
                // Visit the element rather than copying it: a nested repetition must be expanded
                // too. The byte after this repetition does not follow a nested one.
                let saved = followByte
                followByte = nil
                exprID = visit(source.expr(refChoice[0]))
                followByte = saved
            }
        }

        // A length-bounded JSON string body (a repetition of a negative character class, or of
        // the escape-aware one-character regex) stays one counted edge when the byte after it
        // cannot start a repetition.
        var repeated = rewriter.builder.expr(exprID)
        var counted = false
        if let follow = followByte, follow < 0x80, !hasCharBudgetRules, (lower == 0 && upper != -1) || !hasLazyRules {
            if repeated.kind == .characterClass, repeated[0] != 0 {
                let value = Int32(follow)
                var excluded = false
                var rangeIndex = 1
                while rangeIndex + 1 < repeated.count {
                    excluded = excluded || (repeated[rangeIndex] <= value && value <= repeated[rangeIndex + 1])
                    rangeIndex += 2
                }
                counted = excluded
            } else if repeated.kind == .ruleRef, refBody.kind == .regex, !source.regexIsJSONString(refBody),
                      refRule.maxTokens < 0, refRule.maxChars < 0, source.suffixStopInfo(for: ruleID) == nil, !refRule.isLazy,
                      refRule.temperature == nil, refRule.lookaheadAssertionID == -1, refRule.captureName.isEmpty,
                      regexCannotStart(with: follow, source.regexPattern(refBody)) {
                counted = true
                exprID = visit(refBody)
                repeated = rewriter.builder.expr(exprID)
            }
        }
        countedRepetition = counted

        var cacheKey: [Int64] = []
        cacheKey.reserveCapacity(repeated.count + 4)
        cacheKey.append(Int64(repeated.kind.rawValue))
        for value in repeated { cacheKey.append(Int64(value)) }
        cacheKey.append(lower)
        cacheKey.append(upper)
        cacheKey.append(counted ? Int64(followByte.unsafelyUnwrapped) : -1)
        if let cached = repetitionCache[cacheKey] { return cached }

        let result = expandRepetitionRange(exprID: exprID, lower: lower, upper: upper, counted: counted)
        repetitionCache[cacheKey] = result
        return result
    }

    /// Whether no match of a non-nullable `pattern` starts with `byte`.
    private func regexCannotStart(with byte: UInt8, _ pattern: [UInt8]) -> Bool {
        guard let matchesEmpty = try? RegexFSMBuilder.matchesEmpty(pattern), !matchesEmpty,
              let fsm = try? RegexFSMBuilder.build(pattern).simplifyingEpsilon() else { return false }
        let value = Int32(byte)
        return fsm.fsm.edges(of: fsm.start).allSatisfy { $0.isCharRange && !($0.min <= value && value <= $0.max) }
    }

    private mutating func expandRepetitionRange(exprID: Int32, lower rawLower: Int64, upper rawUpper: Int64, counted: Bool) -> Int32 {
        precondition(rawLower >= 0 && (rawUpper == -1 || rawUpper >= rawLower), "Invalid repetition range {\(rawLower), \(rawUpper)}")
        let threshold = Self.unzipThreshold
        let ruleName = rewriter.currentRuleName

        if counted {
            let repeated = rewriter.builder.expr(exprID)
            var bodyKey = Array(repeated.data)
            bodyKey.append(Int32(followByte.unsafelyUnwrapped))
            let bodyRuleID: Int32
            if let existing = countedBodyRuleIDs[bodyKey] {
                bodyRuleID = existing
            } else {
                // A regex stays the whole rule body, as the regex builder's repeat rules are.
                bodyRuleID = rewriter.builder.addRule(
                    hint: ruleName + "_repeat",
                    bodyExprID: repeated.kind == .regex ? exprID : rewriter.builder.addChoices([rewriter.builder.addSequence([exprID])])
                )
                countedBodyRuleIDs[bodyKey] = bodyRuleID
            }
            // The parser needs a finite upper bound; Int32.max stands for unbounded.
            return rewriter.builder.addRepeat(ruleID: bodyRuleID, min: Int32(rawLower), max: rawUpper == -1 ? Int32.max : Int32(rawUpper))
        }

        var lower = rawLower
        var upper = rawUpper
        if (upper != -1 && upper <= threshold) || (upper == -1 && lower <= threshold) {
            return unzipRepetitionRange(exprID: exprID, lower: lower, upper: upper)
        }

        // Large bounds: {lower, upper} → {lower, threshold-1} | {threshold, upper}, with the
        // second part as a counted repeat of a fresh rule plus `threshold` unrolled copies.
        var choices: [Int32] = []
        if lower < threshold {
            choices.append(rewriter.builder.addSequence([unzipRepetitionRange(exprID: exprID, lower: lower, upper: threshold - 1)]))
            lower = threshold
        }

        var infiniteRepetitionID: Int32? = nil
        var repeatedSequence: [Int32] = []
        if upper == -1 {
            let ruleExpr = rewriter.builder.expr(exprID)
            if ruleExpr.kind == .characterClass {
                var ranges: [ClosedRange<Codepoint>] = []
                var index = 1
                while index + 1 < ruleExpr.count {
                    ranges.append(ruleExpr[index] ... ruleExpr[index + 1])
                    index += 2
                }
                infiniteRepetitionID = rewriter.builder.addCharacterClassStar(ranges, isNegated: ruleExpr[0] != 0)
            } else {
                let unboundedRuleID = rewriter.builder.addEmptyRule(hint: ruleName + "_repeat_inf")
                let recursion = rewriter.builder.addSequence([exprID, rewriter.builder.addRuleRef(unboundedRuleID)])
                let choice = rewriter.builder.addChoices([rewriter.builder.addEmptyString(), recursion])
                rewriter.builder.updateRuleBody(unboundedRuleID, choice)
                infiniteRepetitionID = rewriter.builder.addRuleRef(unboundedRuleID)
            }
            upper = lower
        }

        let repeatName = ruleName + "_repeat_1"
        assert(lower >= threshold && upper >= lower)
        if let infiniteRepetitionID { repeatedSequence.append(infiniteRepetitionID) }

        if upper != threshold {
            assert(upper > threshold)
            let bodyID = rewriter.builder.addChoices([rewriter.builder.addSequence([exprID])])
            let newRuleID = rewriter.builder.addRule(hint: repeatName, bodyExprID: bodyID)
            let repeatRef = rewriter.builder.addChoices([rewriter.builder.addSequence([
                rewriter.builder.addRepeat(ruleID: newRuleID, min: Int32(lower - threshold), max: Int32(upper - threshold)),
            ])])
            let innerRuleID = rewriter.builder.addRule(hint: repeatName + "_inner", bodyExprID: repeatRef)
            repeatedSequence.append(rewriter.builder.addRuleRef(innerRuleID))
            let lookahead = [Int32](repeating: exprID, count: Int(threshold))
            rewriter.builder.updateLookaheadAssertion(newRuleID, rewriter.builder.addSequence(lookahead))
        }

        for _ in 0 ..< threshold { repeatedSequence.append(exprID) }
        choices.append(rewriter.builder.addSequence(repeatedSequence))
        let resultRuleID = rewriter.builder.addRule(hint: ruleName, bodyExprID: rewriter.builder.addChoices(choices))
        return rewriter.builder.addRuleRef(resultRuleID)
    }

    /// Unzips `{l}`, `{l,}` and `{l, r}` into explicit sequences and optional-tail rules.
    private mutating func unzipRepetitionRange(exprID: Int32, lower: Int64, upper: Int64) -> Int32 {
        let ruleName = rewriter.currentRuleName
        var elements = [Int32](repeating: exprID, count: Int(lower))

        if upper == lower {
            let resultRuleID = rewriter.builder.addRule(hint: ruleName, bodyExprID: rewriter.builder.addChoices([rewriter.builder.addSequence(elements)]))
            return rewriter.builder.addRuleRef(resultRuleID)
        }

        if upper == -1 {
            // expr × l, then rest ::= "" | expr rest
            let newRuleID = rewriter.builder.addEmptyRule(name: rewriter.builder.newRuleName(hint: ruleName))
            let selfRef = rewriter.builder.addRuleRef(newRuleID)
            let body = rewriter.builder.addChoices([rewriter.builder.addEmptyString(), rewriter.builder.addSequence([exprID, selfRef])])
            rewriter.builder.updateRuleBody(newRuleID, body)
            elements.append(rewriter.builder.addRuleRef(newRuleID))
            let resultRuleID = rewriter.builder.addRule(hint: ruleName, bodyExprID: rewriter.builder.addChoices([rewriter.builder.addSequence(elements)]))
            return rewriter.builder.addRuleRef(resultRuleID)
        }

        // expr × l, then rest_1 ::= "" | expr rest_2, …, rest_{r-l} ::= "" | expr
        var restRuleIDs: [Int32] = []
        for _ in 0 ..< (upper - lower) {
            restRuleIDs.append(rewriter.builder.addEmptyRule(name: rewriter.builder.newRuleName(hint: ruleName)))
        }
        for index in 0 ..< Int(upper - lower - 1) {
            let nextRef = rewriter.builder.addRuleRef(restRuleIDs[index + 1])
            let body = rewriter.builder.addChoices([rewriter.builder.addEmptyString(), rewriter.builder.addSequence([exprID, nextRef])])
            rewriter.builder.updateRuleBody(restRuleIDs[index], body)
        }
        let lastBody = rewriter.builder.addChoices([rewriter.builder.addEmptyString(), rewriter.builder.addSequence([exprID])])
        rewriter.builder.updateRuleBody(restRuleIDs[restRuleIDs.count - 1], lastBody)
        elements.append(rewriter.builder.addRuleRef(restRuleIDs[0]))
        let resultRuleID = rewriter.builder.addRule(hint: ruleName, bodyExprID: rewriter.builder.addChoices([rewriter.builder.addSequence(elements)]))
        return rewriter.builder.addRuleRef(resultRuleID)
    }
}
