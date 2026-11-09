// Compile-time optimizer: the pipeline that turns a normalized grammar into the form the
// matcher runs on (fused byte strings, inlined leaf rules, expanded repetitions, dead rules
// removed, derived lookaheads, nullability, and one automaton per rule).

enum GrammarOptimizer {
    static func apply(_ grammar: GrammarStorage) throws(GrammarError) -> GrammarStorage {
        var result = grammar
        ByteStringFuser.apply(&result)
        RuleInliner.apply(&result)
        result = RepetitionRangeExpander.apply(result)
        result = LazyBodyFlattener.apply(result)
        result = DeadCodeEliminator.apply(result)
        result = LookaheadAssertionAnalyzer.apply(result)
        result.allowEmptyRuleIDs = AllowEmptyRuleAnalyzer.apply(result)
        try validateLazyRules(result)
        RepetitionNormalizer.apply(&result)
        try GrammarFSMBuilder.apply(&result)
        result.isOptimized = true
        return result
    }

    /// Committed-shortest (lazy) matching needs the whole rule body in one automaton without
    /// rule references, so that the states of one occurrence are exactly those of the rule.
    private static func validateLazyRules(_ grammar: GrammarStorage) throws(GrammarError) {
        for rule in grammar.rules where rule.isLazy {
            let body = grammar.expr(rule.bodyExprID)
            if body.kind == .regex || body.kind == .substring { continue }
            guard body.kind == .choices else {
                throw .invalidGrammar("lazy rule '\(rule.name)' must have a terminal-like body")
            }
            for choiceID in body {
                let choice = grammar.expr(choiceID)
                if choice.kind == .emptyString { continue }
                for elementID in choice {
                    switch grammar.kind(of: elementID) {
                    case .byteString, .characterClass, .characterClassStar: continue
                    default:
                        throw .invalidGrammar(
                            "lazy rule '\(rule.name)' must have a terminal-like body (strings, character classes, and regexes that compile to a single FSM); rule references and repetition ranges are not supported"
                        )
                    }
                }
            }
        }
    }
}

// MARK: - In-place rewriting

/// Base for passes that rewrite a grammar in place: expressions are appended to the same arena
/// only where a rewrite happens, and changed ids propagate upwards. Stale expressions are
/// removed later by ``DeadCodeEliminator``.
struct InPlaceRewriter {
    var builder: GrammarBuilder
    /// Original expression id → rewritten id (or itself); `-1` while unvisited.
    private var memo: [Int32]

    init(storage: GrammarStorage) {
        builder = GrammarBuilder(storage: storage)
        memo = Array(repeating: -1, count: storage.exprCount)
    }

    /// Walks every rule body and lookahead; `rewrite` returns the new id of a sequence or
    /// choices expression (or the same id). Returns the resulting storage.
    mutating func run(rewrite: (inout InPlaceRewriter, _ exprID: Int32, _ kind: GrammarExprKind) -> Int32) -> GrammarStorage {
        let ruleCount = builder.ruleCount
        for index in 0 ..< ruleCount {
            let ruleID = Int32(index)
            let bodyID = builder.rule(ruleID).bodyExprID
            let newBodyID = visit(bodyID, rewrite: rewrite)
            if newBodyID != bodyID { builder.updateRuleBody(ruleID, newBodyID) }
            let lookaheadID = builder.rule(ruleID).lookaheadAssertionID
            if lookaheadID != -1 {
                let newLookaheadID = visit(lookaheadID, rewrite: rewrite)
                if newLookaheadID != lookaheadID { builder.updateLookaheadAssertion(ruleID, newLookaheadID) }
            }
        }
        return builder.finish(rootRuleID: builder.storage.rootRuleID)
    }

    mutating func visit(_ exprID: Int32, rewrite: (inout InPlaceRewriter, Int32, GrammarExprKind) -> Int32) -> Int32 {
        let memoized = memo[Int(exprID)]
        if memoized != -1 { return memoized }
        let kind = builder.storage.kind(of: exprID)
        let result: Int32
        switch kind {
        case .sequence, .choices: result = rewrite(&self, exprID, kind)
        default: result = exprID
        }
        memo[Int(exprID)] = result
        return result
    }

    /// Rebuilds a container by visiting each child; allocates nothing when no child changes.
    mutating func visitChildren(_ exprID: Int32, kind: GrammarExprKind, rewrite: (inout InPlaceRewriter, Int32, GrammarExprKind) -> Int32) -> Int32 {
        let children = Array(builder.expr(exprID).data)
        var newChildren: [Int32] = []
        var changed = false
        for (index, childID) in children.enumerated() {
            let newChildID = visit(childID, rewrite: rewrite)
            if !changed, newChildID != childID {
                changed = true
                newChildren.reserveCapacity(children.count)
                newChildren.append(contentsOf: children[..<index])
            }
            if changed { newChildren.append(newChildID) }
        }
        if !changed { return exprID }
        return kind == .sequence ? builder.addSequence(newChildren) : builder.addChoices(newChildren)
    }
}

/// Fuses adjacent byte strings in sequences and drops empty ones.
enum ByteStringFuser {
    static func apply(_ grammar: inout GrammarStorage) {
        var rewriter = InPlaceRewriter(storage: grammar)
        grammar = rewriter.run(rewrite: visit)
    }

    private static func visit(_ rewriter: inout InPlaceRewriter, _ exprID: Int32, _ kind: GrammarExprKind) -> Int32 {
        guard kind == .sequence else { return rewriter.visitChildren(exprID, kind: kind, rewrite: visit) }
        var previousIsByteString = false
        var needsRewrite = false
        for elementID in rewriter.builder.expr(exprID) {
            let element = rewriter.builder.expr(elementID)
            let isByteString = element.kind == .byteString
            if isByteString, previousIsByteString || element.isEmpty {
                needsRewrite = true
                break
            }
            previousIsByteString = isByteString
        }
        if !needsRewrite { return exprID }

        let elementIDs = Array(rewriter.builder.expr(exprID).data)
        var newElementIDs: [Int32] = []
        var index = 0
        while index < elementIDs.count {
            if rewriter.builder.storage.kind(of: elementIDs[index]) != .byteString {
                newElementIDs.append(elementIDs[index])
                index += 1
                continue
            }
            var fused: [Int32] = []
            var runEnd = index
            while runEnd < elementIDs.count {
                let element = rewriter.builder.expr(elementIDs[runEnd])
                if element.kind != .byteString { break }
                fused.append(contentsOf: element.data)
                runEnd += 1
            }
            if !fused.isEmpty {
                if runEnd - index == 1 {
                    newElementIDs.append(elementIDs[index])
                } else {
                    newElementIDs.append(rewriter.builder.addExpr(.byteString, fused))
                }
            }
            index = runEnd
        }
        return rewriter.builder.addSequence(newElementIDs)
    }
}

/// Inlines references that start a sequence when the referenced rule is a non-empty choice
/// of sequences without rule references (judged on the original grammar).
enum RuleInliner {
    private struct Context {
        var originalBodyIDs: [Int32]
        /// Per rule: `nil` unknown, else cached answer.
        var canInline: [Bool?]
    }

    static func apply(_ grammar: inout GrammarStorage) {
        var rewriter = InPlaceRewriter(storage: grammar)
        var context = Context(
            originalBodyIDs: grammar.rules.map(\.bodyExprID),
            canInline: Array(repeating: nil, count: grammar.ruleCount)
        )
        let source = grammar
        grammar = rewriter.run { rewriter, exprID, kind in
            visit(&rewriter, exprID, kind, &context, source)
        }
    }

    private static func visit(_ rewriter: inout InPlaceRewriter, _ exprID: Int32, _ kind: GrammarExprKind, _ context: inout Context, _ source: GrammarStorage) -> Int32 {
        let recurse: (inout InPlaceRewriter, Int32, GrammarExprKind) -> Int32 = { rewriter, id, kind in
            visit(&rewriter, id, kind, &context, source)
        }
        guard kind == .choices else { return rewriter.visitChildren(exprID, kind: kind, rewrite: recurse) }

        let choiceIDs = Array(rewriter.builder.expr(exprID).data)
        var newChoiceIDs: [Int32] = []
        var changed = false
        for (index, choiceID) in choiceIDs.enumerated() {
            let choice = rewriter.builder.expr(choiceID)
            var inlineRuleID: Int32 = -1
            if choice.kind == .sequence, choice.count > 0 {
                let first = rewriter.builder.expr(choice[0])
                if first.kind == .ruleRef, canInline(first[0], &context, rewriter.builder.storage, source) {
                    inlineRuleID = first[0]
                }
            }
            if inlineRuleID == -1 {
                let newChoiceID = rewriter.visit(choiceID, rewrite: recurse)
                if !changed, newChoiceID != choiceID {
                    changed = true
                    newChoiceIDs.reserveCapacity(choiceIDs.count)
                    newChoiceIDs.append(contentsOf: choiceIDs[..<index])
                }
                if changed { newChoiceIDs.append(newChoiceID) }
                continue
            }
            if !changed {
                changed = true
                newChoiceIDs.reserveCapacity(choiceIDs.count)
                newChoiceIDs.append(contentsOf: choiceIDs[..<index])
            }
            // Prepend each choice of the referenced rule to the rest of this sequence.
            var rest = Array(choice.data.dropFirst())
            for restIndex in rest.indices { rest[restIndex] = rewriter.visit(rest[restIndex], rewrite: recurse) }
            let refChoiceIDs = Array(rewriter.builder.expr(context.originalBodyIDs[Int(inlineRuleID)]).data)
            for refChoiceID in refChoiceIDs {
                let refChoice = rewriter.builder.expr(refChoiceID)
                assert(refChoice.kind == .sequence)
                var newSequence = Array(refChoice.data)
                for elementIndex in newSequence.indices {
                    newSequence[elementIndex] = rewriter.visit(newSequence[elementIndex], rewrite: recurse)
                }
                newSequence.append(contentsOf: rest)
                newChoiceIDs.append(rewriter.builder.addSequence(newSequence))
            }
        }
        if !changed { return exprID }
        return rewriter.builder.addChoices(newChoiceIDs)
    }

    private static func canInline(_ ruleID: Int32, _ context: inout Context, _ storage: GrammarStorage, _ source: GrammarStorage) -> Bool {
        if let cached = context.canInline[Int(ruleID)] { return cached }
        let rule = source.rule(ruleID)
        // Budgeted, captured, suffix/stop, lazy and temperature rules carry runtime semantics
        // that inlining would erase.
        if rule.maxTokens >= 0 || rule.maxChars >= 0 || !rule.captureName.isEmpty
            || source.suffixStopInfo(for: ruleID) != nil || rule.isLazy || rule.temperature != nil {
            context.canInline[Int(ruleID)] = false
            return false
        }
        var result = true
        let body = storage.expr(context.originalBodyIDs[Int(ruleID)])
        if body.kind != .choices || body.isEmpty {
            result = false
        } else {
            for choiceID in body {
                let choice = storage.expr(choiceID)
                if choice.kind == .emptyString {
                    result = false
                    break
                }
                assert(choice.kind == .sequence)
                if choice.contains(where: { storage.kind(of: $0) == .ruleRef }) {
                    result = false
                    break
                }
            }
        }
        context.canInline[Int(ruleID)] = result
        return result
    }
}

// MARK: - Dead code elimination

/// Ids of every rule reachable from the root (sorted).
enum UsedRulesAnalyzer {
    static func apply(_ grammar: GrammarStorage) -> [Int32] {
        var visited = Set<Int32>()
        var queue: [Int32] = [grammar.rootRuleID]
        var head = 0
        while head < queue.count {
            let ruleID = queue[head]
            head += 1
            guard visited.insert(ruleID).inserted else { continue }
            let rule = grammar.rule(ruleID)
            collect(grammar, grammar.expr(rule.bodyExprID), into: &queue)
            if rule.lookaheadAssertionID != -1 { collect(grammar, grammar.expr(rule.lookaheadAssertionID), into: &queue) }
            if let info = grammar.suffixStopInfo(for: ruleID), info.bodyRuleID != -1 {
                queue.append(info.bodyRuleID)
                queue.append(info.markerRuleID)
            }
        }
        return visited.sorted()
    }

    private static func collect(_ grammar: GrammarStorage, _ expr: GrammarExpr, into queue: inout [Int32]) {
        switch expr.kind {
        case .sequence, .choices:
            for childID in expr { collect(grammar, grammar.expr(childID), into: &queue) }
        case .ruleRef, .repeat:
            queue.append(expr[0])
        case .tagDispatch:
            for pair in grammar.tagDispatch(expr).tagRulePairs { queue.append(pair.ruleID) }
        case .tokenTagDispatch:
            for pair in grammar.tokenTagDispatch(expr).triggerRulePairs { queue.append(pair.ruleID) }
        default:
            break
        }
    }
}

/// Rebuilds the grammar with only the rules reachable from the root, renumbering them.
enum DeadCodeEliminator {
    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        let used = UsedRulesAnalyzer.apply(grammar)
        var builder = GrammarBuilder()
        var ruleIDMap: [Int32: Int32] = [:]
        for ruleID in used { ruleIDMap[ruleID] = builder.addEmptyRule(name: grammar.rule(ruleID).name) }
        var rewriter = GrammarRewriter(source: grammar, builder: builder)

        func visit(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> Int32 {
            switch expr.kind {
            case .ruleRef:
                return rewriter.builder.addRuleRef(ruleIDMap[expr[0]].unsafelyUnwrapped)
            case .repeat:
                return rewriter.builder.addRepeat(ruleID: ruleIDMap[expr[0]].unsafelyUnwrapped, min: expr[1], max: expr[2])
            case .tagDispatch:
                var dispatch = rewriter.source.tagDispatch(expr)
                for index in dispatch.tagRulePairs.indices {
                    dispatch.tagRulePairs[index].ruleID = ruleIDMap[dispatch.tagRulePairs[index].ruleID].unsafelyUnwrapped
                }
                return rewriter.builder.addTagDispatch(dispatch)
            case .tokenTagDispatch:
                var dispatch = rewriter.source.tokenTagDispatch(expr)
                for index in dispatch.triggerRulePairs.indices {
                    dispatch.triggerRulePairs[index].ruleID = ruleIDMap[dispatch.triggerRulePairs[index].ruleID].unsafelyUnwrapped
                }
                return rewriter.builder.addTokenTagDispatch(dispatch)
            default:
                return rewriter.copy(expr, visit: visit)
            }
        }

        for ruleID in used {
            let rule = grammar.rule(ruleID)
            let newRuleID = ruleIDMap[ruleID].unsafelyUnwrapped
            rewriter.currentRuleName = rule.name
            rewriter.builder.updateRuleBody(newRuleID, visit(&rewriter, grammar.expr(rule.bodyExprID)))
            if rule.lookaheadAssertionID != -1 {
                rewriter.builder.updateLookaheadAssertion(newRuleID, visit(&rewriter, grammar.expr(rule.lookaheadAssertionID)))
            }
            rewriter.builder.updateMaxTokens(newRuleID, rule.maxTokens)
            rewriter.builder.updateMaxChars(newRuleID, rule.maxChars)
            rewriter.builder.updateCaptureName(newRuleID, rule.captureName)
            if var info = grammar.suffixStopInfo(for: ruleID) {
                if info.bodyRuleID >= 0 {
                    info.bodyRuleID = ruleIDMap[info.bodyRuleID].unsafelyUnwrapped
                    info.markerRuleID = ruleIDMap[info.markerRuleID].unsafelyUnwrapped
                }
                rewriter.builder.updateSuffixStopInfo(newRuleID, info)
            }
            rewriter.builder.updateLazy(newRuleID, rule.isLazy)
            rewriter.builder.updateTemperature(newRuleID, rule.temperature)
            rewriter.builder.updateLookaheadExact(newRuleID, rule.isExactLookahead)
        }
        return rewriter.builder.finish(rootRuleID: ruleIDMap[grammar.rootRuleID].unsafelyUnwrapped)
    }
}

// MARK: - Lookahead assertions

/// Derives a lookahead assertion for every rule that occurs exactly once in a non-final
/// position and never as the last element of another rule: the elements following that
/// occurrence. Marks lookaheads as exact where the same condition holds.
enum LookaheadAssertionAnalyzer {
    private struct Info {
        var isTriggeredByDispatch = false
        var appearsLastInOtherRule = false
        var nonLastOccurrences = 0
        var suffixAfterFirstOccurrence: [Int32] = []

        var canUseDerivedLookahead: Bool {
            !isTriggeredByDispatch && !appearsLastInOtherRule && nonLastOccurrences == 1
        }
    }

    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        // A dispatch root still has ordinary nested rules whose unique trailing context can
        // resolve vocabulary tokens during compilation. The dispatch targets themselves stay
        // context dependent, as recorded by buildInfos.
        let infos = buildInfos(grammar)
        var builder = GrammarBuilder(storage: grammar)
        for index in 0 ..< grammar.ruleCount {
            let ruleID = Int32(index)
            if ruleID == grammar.rootRuleID { continue }
            let rule = grammar.rule(ruleID)
            if rule.lookaheadAssertionID != -1 {
                builder.updateLookaheadExact(ruleID, infos[index].canUseDerivedLookahead)
                continue
            }
            if infos[index].canUseDerivedLookahead {
                builder.updateLookaheadAssertion(ruleID, builder.addSequence(infos[index].suffixAfterFirstOccurrence))
                builder.updateLookaheadExact(ruleID, true)
            }
        }
        return builder.finish(rootRuleID: grammar.rootRuleID)
    }

    private static func buildInfos(_ grammar: GrammarStorage) -> [Info] {
        var infos = [Info](repeating: Info(), count: grammar.ruleCount)
        for index in 0 ..< grammar.ruleCount {
            let ruleID = Int32(index)
            let body = grammar.expr(grammar.rule(ruleID).bodyExprID)
            switch body.kind {
            case .tagDispatch:
                for pair in grammar.tagDispatch(body).tagRulePairs { infos[Int(pair.ruleID)].isTriggeredByDispatch = true }
                continue
            case .tokenTagDispatch:
                for pair in grammar.tokenTagDispatch(body).triggerRulePairs { infos[Int(pair.ruleID)].isTriggeredByDispatch = true }
                continue
            case .regex, .substring:
                continue
            default:
                break
            }
            assert(body.kind == .choices)
            for sequenceID in body {
                let sequence = grammar.expr(sequenceID)
                if sequence.kind != .sequence || sequence.isEmpty { continue }
                let last = grammar.expr(sequence[sequence.count - 1])
                if last.kind == .ruleRef, ruleID != last[0] { infos[Int(last[0])].appearsLastInOtherRule = true }
                for position in 0 ..< sequence.count - 1 {
                    let element = grammar.expr(sequence[position])
                    guard element.kind == .ruleRef else { continue }
                    let referenced = Int(element[0])
                    if infos[referenced].nonLastOccurrences == 0 {
                        infos[referenced].suffixAfterFirstOccurrence = Array(sequence.data.dropFirst(position + 1))
                    }
                    infos[referenced].nonLastOccurrences += 1
                }
            }
        }
        return infos
    }
}

// MARK: - Nullability

/// Inverted rule reference graph: for each rule, the rules that reference it.
enum RuleRefGraphFinder {
    static func apply(_ grammar: GrammarStorage) -> [[Int32]] {
        var graph = [[Int32]](repeating: [], count: grammar.ruleCount)
        for index in 0 ..< grammar.ruleCount {
            let ruleID = Int32(index)
            visit(grammar, grammar.expr(grammar.rule(ruleID).bodyExprID), from: ruleID, into: &graph)
        }
        for index in graph.indices {
            graph[index].sort()
            graph[index].removeDuplicatesSorted()
        }
        return graph
    }

    private static func visit(_ grammar: GrammarStorage, _ expr: GrammarExpr, from ruleID: Int32, into graph: inout [[Int32]]) {
        switch expr.kind {
        case .sequence, .choices:
            for childID in expr { visit(grammar, grammar.expr(childID), from: ruleID, into: &graph) }
        case .ruleRef, .repeat:
            graph[Int(expr[0])].append(ruleID)
        case .tagDispatch:
            for pair in grammar.tagDispatch(expr).tagRulePairs { graph[Int(pair.ruleID)].append(ruleID) }
        case .tokenTagDispatch:
            for pair in grammar.tokenTagDispatch(expr).triggerRulePairs { graph[Int(pair.ruleID)].append(ruleID) }
        default:
            break
        }
    }
}

/// Sorted ids of the rules that can match the empty string.
enum AllowEmptyRuleAnalyzer {
    static func apply(_ grammar: GrammarStorage) -> [Int32] {
        var emptyRules = Set<Int32>()
        for index in 0 ..< grammar.ruleCount {
            let ruleID = Int32(index)
            let body = grammar.expr(grammar.rule(ruleID).bodyExprID)
            switch body.kind {
            case .tagDispatch, .tokenTagDispatch, .substring:
                emptyRules.insert(ruleID)
                continue
            case .regex:
                // Parse errors are reported by the FSM builder later.
                if let matchesEmpty = try? RegexFSMBuilder.matchesEmpty(grammar.regexPattern(body)), matchesEmpty {
                    emptyRules.insert(ruleID)
                }
                continue
            default:
                break
            }
            assert(body.kind == .choices)
            if grammar.kind(of: body[0]) == .emptyString {
                emptyRules.insert(ruleID)
                continue
            }
            for sequenceID in body {
                let sequence = grammar.expr(sequenceID)
                if sequence.allSatisfy({ grammar.kind(of: $0) == .characterClassStar }) {
                    emptyRules.insert(ruleID)
                    break
                }
            }
        }

        // Propagate through referrers (Bellman-Ford style) until a fixed point.
        let graph = RuleRefGraphFinder.apply(grammar)
        var queue = Array(emptyRules)
        var head = 0
        while head < queue.count {
            let ruleID = queue[head]
            head += 1
            for referrer in graph[Int(ruleID)] where !emptyRules.contains(referrer) {
                let body = grammar.expr(grammar.rule(referrer).bodyExprID)
                assert(body.kind != .tagDispatch && body.kind != .tokenTagDispatch)
                let isEpsilon = body.contains { sequenceID in
                    let sequence = grammar.expr(sequenceID)
                    if sequence.kind == .emptyString { return true }
                    return sequence.allSatisfy { elementID in
                        let element = grammar.expr(elementID)
                        switch element.kind {
                        case .ruleRef: return emptyRules.contains(element[0])
                        case .characterClassStar: return true
                        case .repeat: return emptyRules.contains(element[0]) || element[1] == 0
                        default: return false
                        }
                    }
                }
                if isEpsilon {
                    emptyRules.insert(referrer)
                    queue.append(referrer)
                }
            }
        }
        return emptyRules.sorted()
    }
}

/// Marks repeated rules as exact-lookahead and relaxes the lower bound of repetitions whose
/// rule is nullable (the count cannot be enforced).
enum RepetitionNormalizer {
    static func apply(_ grammar: inout GrammarStorage) {
        for index in 0 ..< grammar.exprCount {
            let exprID = Int32(index)
            guard grammar.kind(of: exprID) == .repeat else { continue }
            let ruleID = grammar.expr(exprID)[0]
            grammar.rules[Int(ruleID)].isExactLookahead = true
            if grammar.allowsEmpty(ruleID) { grammar.setExprData(exprID, index: 1, value: 0) }
        }
    }
}
