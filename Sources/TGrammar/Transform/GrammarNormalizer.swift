// Shared machinery for passes that rebuild a grammar expression by expression. A rewriter
// re-declares every rule of the source (so rule ids are preserved), then lets the concrete pass
// decide how each expression is re-emitted into the builder.

/// Default expression rewriting: deep-copies expressions into `builder`, recursing into
/// sequences, choices and tag dispatches. Passes override by supplying a `visit` closure that
/// receives the pass itself for recursion.
struct GrammarRewriter {
    let source: GrammarStorage
    var builder: GrammarBuilder
    var currentRuleName = ""

    init(source: GrammarStorage, builder: GrammarBuilder = GrammarBuilder()) {
        self.source = source
        self.builder = builder
    }

    /// Declares one empty rule per source rule so the ids of the rebuilt grammar line up.
    mutating func declareRules() {
        for rule in source.rules { builder.addEmptyRule(name: rule.name) }
    }

    /// Copies every attribute of the source rule onto the rebuilt rule with the same id.
    mutating func copyAttributes(ruleID: Int32) {
        let rule = source.rule(ruleID)
        builder.updateMaxTokens(ruleID, rule.maxTokens)
        builder.updateMaxChars(ruleID, rule.maxChars)
        builder.updateCaptureName(ruleID, rule.captureName)
        if let info = source.suffixStopInfo(for: ruleID) { builder.updateSuffixStopInfo(ruleID, info) }
        builder.updateLazy(ruleID, rule.isLazy)
        builder.updateTemperature(ruleID, rule.temperature)
        builder.updateLookaheadExact(ruleID, rule.isExactLookahead)
    }

    /// Deep-copies an expression, calling `visit` for every node so a pass can intercept.
    mutating func copy(_ expr: GrammarExpr, visit: (inout GrammarRewriter, GrammarExpr) -> Int32) -> Int32 {
        switch expr.kind {
        case .sequence:
            var children: [Int32] = []
            children.reserveCapacity(expr.count)
            for child in expr { children.append(visit(&self, source.expr(child))) }
            return builder.addSequence(children)
        case .choices:
            var children: [Int32] = []
            children.reserveCapacity(expr.count)
            for child in expr { children.append(visit(&self, source.expr(child))) }
            return builder.addChoices(children)
        case .tagDispatch:
            return builder.addTagDispatch(source.tagDispatch(expr))
        default:
            return builder.addExpr(expr)
        }
    }

    /// Runs a whole-grammar rewrite: declares rules, visits each body and lookahead, finishes.
    mutating func rewrite(
        body: (inout GrammarRewriter, GrammarExpr) -> Int32,
        lookahead: (inout GrammarRewriter, GrammarExpr) -> Int32
    ) -> GrammarStorage {
        declareRules()
        for index in 0 ..< source.ruleCount {
            let ruleID = Int32(index)
            let rule = source.rule(ruleID)
            currentRuleName = rule.name
            builder.updateRuleBody(ruleID, body(&self, source.expr(rule.bodyExprID)))
            if rule.lookaheadAssertionID != -1 {
                builder.updateLookaheadAssertion(ruleID, lookahead(&self, source.expr(rule.lookaheadAssertionID)))
            }
            copyAttributes(ruleID: ruleID)
        }
        return builder.finish(rootRuleID: source.rootRuleID)
    }
}

/// Collapses single-element sequences and choices, and single-character classes into byte
/// strings: `(("a"))` → `"a"`, `[a-a]` → `"a"`.
enum SingleElementExprEliminator {
    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        var rewriter = GrammarRewriter(source: grammar)
        return rewriter.rewrite(body: visit, lookahead: visit)
    }

    private static func visit(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> Int32 {
        switch expr.kind {
        case .sequence:
            if expr.count == 1 { return visit(&rewriter, rewriter.source.expr(expr[0])) }
            return rewriter.copy(expr, visit: visit)
        case .choices:
            if expr.count == 1 { return visit(&rewriter, rewriter.source.expr(expr[0])) }
            return rewriter.copy(expr, visit: visit)
        case .characterClass:
            if expr.count == 3, expr[0] == 0, expr[1] == expr[2] {
                return rewriter.builder.addByteString(UTF8Codec.encode(expr[1]))
            }
            return rewriter.builder.addExpr(expr)
        default:
            return rewriter.copy(expr, visit: visit)
        }
    }
}

/// Renames the root rule to `root` (moving any other rule called `root` out of the way) so that
/// downstream passes and printers can rely on the name.
enum RootRuleRenamer {
    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        if grammar.rootRule.name == "root" { return grammar }
        var result = grammar
        var names = Set<String>()
        var clashingRuleID: Int? = nil
        for (index, rule) in grammar.rules.enumerated() {
            if rule.name == "root" { clashingRuleID = index }
            names.insert(rule.name)
        }
        result.rules[Int(grammar.rootRuleID)].name = "root"
        if let clashingRuleID {
            for counter in 0 ... grammar.ruleCount {
                let candidate = "root_\(counter)"
                if !names.contains(candidate) {
                    result.rules[clashingRuleID].name = candidate
                    break
                }
            }
        }
        return result
    }
}

/// Brings every rule into the canonical shape expected by the matcher:
/// `rule ::= ("" | (e1 e2 ...) | (e3 ...) | ...)` where each element is a leaf (byte string,
/// character class, rule reference, repeat, token set) and only the first choice may be empty.
/// Nested choices inside a sequence, tag dispatches, regexes and substrings are hoisted into new
/// rules. Lookahead assertions become flat sequences.
enum StructureNormalizer {
    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        var rewriter = GrammarRewriter(source: SingleElementExprEliminator.apply(grammar))
        return rewriter.rewrite(body: visitRuleBody, lookahead: visitLookahead)
    }

    private static func visitLookahead(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> Int32 {
        switch expr.kind {
        case .sequence:
            return rewriter.builder.addSequence(flattenSequence(&rewriter, expr))
        case .choices:
            preconditionFailure("Choices in lookahead assertion are not supported yet")
        case .emptyString:
            preconditionFailure("Empty string should not be in lookahead assertion")
        case .tagDispatch:
            preconditionFailure("TagDispatch should not be in lookahead assertion")
        case .regex:
            preconditionFailure("Regex should not be in lookahead assertion")
        case .substring:
            preconditionFailure("Substring should not be in lookahead assertion")
        case .byteString, .characterClass, .characterClassStar, .ruleRef, .repeat, .token, .excludeToken, .tokenTagDispatch:
            return rewriter.builder.addSequence([rewriter.builder.addExpr(expr)])
        }
    }

    private static func visitRuleBody(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> Int32 {
        switch expr.kind {
        case .sequence:
            let sequence = rewriter.builder.addSequence(flattenSequence(&rewriter, expr))
            return rewriter.builder.addChoices([sequence])
        case .choices:
            return rewriter.builder.addChoices(flattenChoices(&rewriter, expr))
        case .emptyString:
            return rewriter.builder.addChoices([rewriter.builder.addEmptyString()])
        case .byteString, .characterClass, .characterClassStar, .ruleRef, .repeat, .token, .excludeToken:
            let leaf = rewriter.builder.addExpr(expr)
            return rewriter.builder.addChoices([rewriter.builder.addSequence([leaf])])
        case .tagDispatch:
            return rewriter.builder.addTagDispatch(rewriter.source.tagDispatch(expr))
        case .tokenTagDispatch:
            let ruleID = hoist(&rewriter, rewriter.builder.addExpr(expr))
            return rewriter.builder.addChoices([rewriter.builder.addSequence([rewriter.builder.addRuleRef(ruleID)])])
        case .regex, .substring:
            return rewriter.builder.addExpr(expr)
        }
    }

    /// Moves an expression into a fresh rule named after the current rule and returns its id.
    private static func hoist(_ rewriter: inout GrammarRewriter, _ exprID: Int32) -> Int32 {
        rewriter.builder.addRule(hint: rewriter.currentRuleName, bodyExprID: exprID)
    }

    /// Returns the flattened alternatives; an empty-string alternative, if any, comes first.
    private static func flattenChoices(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> [Int32] {
        var choices: [Int32] = []
        var foundEmpty = false
        for childID in expr {
            let child = rewriter.source.expr(childID)
            switch child.kind {
            case .sequence:
                let elements = flattenSequence(&rewriter, child)
                if elements.isEmpty { foundEmpty = true } else { choices.append(rewriter.builder.addSequence(elements)) }
            case .choices:
                let nested = flattenChoices(&rewriter, child)
                if rewriter.builder.expr(nested[0]).kind == .emptyString {
                    foundEmpty = true
                    choices.append(contentsOf: nested.dropFirst())
                } else {
                    choices.append(contentsOf: nested)
                }
            case .emptyString:
                foundEmpty = true
            case .byteString, .characterClass, .characterClassStar, .ruleRef, .repeat, .token, .excludeToken:
                let leaf = rewriter.builder.addExpr(child)
                choices.append(rewriter.builder.addSequence([leaf]))
            case .tagDispatch:
                let dispatch = rewriter.builder.addTagDispatch(rewriter.source.tagDispatch(child))
                let ruleID = hoist(&rewriter, dispatch)
                choices.append(rewriter.builder.addSequence([rewriter.builder.addRuleRef(ruleID)]))
            case .tokenTagDispatch, .regex, .substring:
                let ruleID = hoist(&rewriter, rewriter.builder.addExpr(child))
                choices.append(rewriter.builder.addSequence([rewriter.builder.addRuleRef(ruleID)]))
            }
        }
        if foundEmpty { choices.insert(rewriter.builder.addEmptyString(), at: 0) }
        return choices
    }

    /// Returns the flattened elements of a sequence; nested sequences are spliced in, nested
    /// choices with more than one alternative become a reference to a hoisted rule.
    private static func flattenSequence(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> [Int32] {
        var elements: [Int32] = []
        for childID in expr {
            let child = rewriter.source.expr(childID)
            switch child.kind {
            case .sequence:
                elements.append(contentsOf: flattenSequence(&rewriter, child))
            case .choices:
                let nested = flattenChoices(&rewriter, child)
                if nested.count == 1 {
                    let only = rewriter.builder.expr(nested[0])
                    if only.kind != .emptyString { elements.append(contentsOf: only.data) }
                } else {
                    let choices = rewriter.builder.addChoices(nested)
                    let ruleID = hoist(&rewriter, choices)
                    elements.append(rewriter.builder.addRuleRef(ruleID))
                }
            case .emptyString:
                break
            case .byteString, .characterClass, .characterClassStar, .ruleRef, .repeat, .token, .excludeToken:
                elements.append(rewriter.builder.addExpr(child))
            case .tagDispatch:
                let dispatch = rewriter.builder.addTagDispatch(rewriter.source.tagDispatch(child))
                elements.append(rewriter.builder.addRuleRef(hoist(&rewriter, dispatch)))
            case .tokenTagDispatch, .regex, .substring:
                elements.append(rewriter.builder.addRuleRef(hoist(&rewriter, rewriter.builder.addExpr(child))))
            }
        }
        return elements
    }
}

/// The normalization applied by ``Grammar/init(ebnf:rootRule:)`` after parsing.
enum GrammarNormalizer {
    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        StructureNormalizer.apply(RootRuleRenamer.apply(grammar))
    }
}
