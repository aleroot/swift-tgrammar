// Rewrites lazy rule bodies into a terminal-like form where possible: unwraps the
// single-reference chains produced by regex conversion, and flattens the right-recursive plus
// pattern (`x ::= cc x | cc`) and star pattern (`x ::= cc x | ""`) into `cc cc*` / `cc*`.
// Grammars without lazy rules are returned unchanged.

struct LazyBodyFlattener {
    private var rewriter: GrammarRewriter
    private var source: GrammarStorage { rewriter.source }

    static func apply(_ grammar: GrammarStorage) -> GrammarStorage {
        guard grammar.rules.contains(where: \.isLazy) else { return grammar }
        var flattener = LazyBodyFlattener(rewriter: GrammarRewriter(source: grammar))
        return flattener.run()
    }

    private mutating func run() -> GrammarStorage {
        rewriter.declareRules()
        for index in 0 ..< source.ruleCount {
            let ruleID = Int32(index)
            let rule = source.rule(ruleID)
            rewriter.currentRuleName = rule.name
            let bodyID = rule.isLazy ? buildFlattenedLazyBody(rule.bodyExprID) : copy(source.expr(rule.bodyExprID))
            rewriter.builder.updateRuleBody(ruleID, bodyID)
            if rule.lookaheadAssertionID != -1 {
                rewriter.builder.updateLookaheadAssertion(ruleID, copy(source.expr(rule.lookaheadAssertionID)))
            }
            rewriter.copyAttributes(ruleID: ruleID)
        }
        return rewriter.builder.finish(rootRuleID: source.rootRuleID)
    }

    private mutating func copy(_ expr: GrammarExpr) -> Int32 { Self.deepCopy(&rewriter, expr) }

    private static func deepCopy(_ rewriter: inout GrammarRewriter, _ expr: GrammarExpr) -> Int32 {
        rewriter.copy(expr, visit: deepCopy)
    }

    private mutating func buildFlattenedLazyBody(_ bodyExprID: Int32) -> Int32 {
        let bodyKind = source.kind(of: bodyExprID)
        if bodyKind == .regex || bodyKind == .substring { return copy(source.expr(bodyExprID)) }

        // Unwrap chains of single rule references (r ::= (x), x ::= (y), …).
        var currentBodyID = bodyExprID
        var currentRuleID: Int32 = -1
        for _ in 0 ..< 64 {
            let body = source.expr(currentBodyID)
            guard body.kind == .choices, body.count == 1 else { break }
            let choice = source.expr(body[0])
            guard choice.kind == .sequence, choice.count == 1 else { break }
            let element = source.expr(choice[0])
            guard element.kind == .ruleRef, !source.rule(element[0]).isLazy else { break }
            currentRuleID = element[0]
            currentBodyID = source.rule(currentRuleID).bodyExprID
        }

        let body = source.expr(currentBodyID)
        guard body.kind == .choices else { return copy(body) }
        var repeatElements: [Int32] = []
        if currentRuleID != -1, tryEmitRepeatPattern(body, selfRuleID: currentRuleID, into: &repeatElements) {
            return rewriter.builder.addChoices([rewriter.builder.addSequence(repeatElements)])
        }
        var newChoiceIDs: [Int32] = []
        for choiceID in body {
            let choice = source.expr(choiceID)
            guard choice.kind == .sequence else {
                newChoiceIDs.append(copy(choice))
                continue
            }
            var elements: [Int32] = []
            guard flattenSequence(choice, into: &elements, depth: 0) else {
                // Not flattenable; copy as is and let validation report the error.
                return copy(body)
            }
            newChoiceIDs.append(rewriter.builder.addSequence(elements))
        }
        return rewriter.builder.addChoices(newChoiceIDs)
    }

    /// Appends the flattened elements of `sequence`, splicing references whose body is a single
    /// terminal-like sequence or a repeat pattern, and coalescing single-character alternations
    /// into character classes. Returns `false` if some element cannot be flattened.
    private mutating func flattenSequence(_ sequence: GrammarExpr, into elements: inout [Int32], depth: Int) -> Bool {
        if depth > 64 { return false }
        for elementID in sequence {
            let element = source.expr(elementID)
            switch element.kind {
            case .byteString, .characterClass, .characterClassStar:
                elements.append(rewriter.builder.addExpr(element))
                continue
            case .ruleRef:
                break
            default:
                return false
            }
            let refRule = source.rule(element[0])
            if refRule.isLazy { return false }
            let refBody = source.expr(refRule.bodyExprID)
            if tryEmitRepeatPattern(refBody, selfRuleID: element[0], into: &elements) { continue }
            if refBody.kind == .choices, refBody.count == 1 {
                let onlyChoice = source.expr(refBody[0])
                if onlyChoice.kind == .emptyString { continue }
                if onlyChoice.kind == .sequence, flattenSequence(onlyChoice, into: &elements, depth: depth + 1) { continue }
            }
            var ranges: [ClosedRange<Codepoint>] = []
            if collectSingleCharRanges(elementID, into: &ranges, depth: 0) {
                elements.append(rewriter.builder.addCharacterClass(Self.unionRanges(ranges)))
                continue
            }
            return false
        }
        return true
    }

    /// Resolves an expression matching exactly one character into the ranges it accepts.
    private func collectSingleCharRanges(_ exprID: Int32, into ranges: inout [ClosedRange<Codepoint>], depth: Int) -> Bool {
        if depth > 64 { return false }
        let expr = source.expr(exprID)
        if expr.kind == .characterClass {
            appendPositiveRanges(expr, into: &ranges)
            return true
        }
        if expr.kind == .byteString, expr.count == 1 {
            ranges.append(expr[0] ... expr[0])
            return true
        }
        guard expr.kind == .ruleRef else { return false }
        let rule = source.rule(expr[0])
        if rule.isLazy { return false }
        let body = source.expr(rule.bodyExprID)
        guard body.kind == .choices else { return false }
        for choiceID in body {
            let choice = source.expr(choiceID)
            guard choice.kind == .sequence, choice.count == 1, collectSingleCharRanges(choice[0], into: &ranges, depth: depth + 1) else {
                return false
            }
        }
        return true
    }

    private mutating func tryEmitRepeatPattern(_ body: GrammarExpr, selfRuleID: Int32, into elements: inout [Int32]) -> Bool {
        tryEmitPlusPattern(body, selfRuleID: selfRuleID, into: &elements)
            || tryEmitGeneralizedPlusPattern(body, selfRuleID: selfRuleID, into: &elements)
            || tryEmitStarPattern(body, selfRuleID: selfRuleID, into: &elements)
    }

    /// `self ::= e1 self | … | e1 | …` with single-character elements whose recursive and base
    /// unions coincide → `cc cc*` over the union.
    private mutating func tryEmitGeneralizedPlusPattern(_ body: GrammarExpr, selfRuleID: Int32, into elements: inout [Int32]) -> Bool {
        guard body.kind == .choices else { return false }
        var recursiveRanges: [ClosedRange<Codepoint>] = []
        var baseRanges: [ClosedRange<Codepoint>] = []
        for choiceID in body {
            let choice = source.expr(choiceID)
            guard choice.kind == .sequence else { return false }
            if choice.count == 1 {
                guard collectSingleCharRanges(choice[0], into: &baseRanges, depth: 0) else { return false }
                continue
            }
            if choice.count == 2 {
                let tail = source.expr(choice[1])
                if tail.kind == .ruleRef, tail[0] == selfRuleID, collectSingleCharRanges(choice[0], into: &recursiveRanges, depth: 0) {
                    continue
                }
            }
            return false
        }
        recursiveRanges = Self.unionRanges(recursiveRanges)
        baseRanges = Self.unionRanges(baseRanges)
        // With differing sets (e.g. `self ::= a self | b`, which is a*b) the language is not (a|b)+.
        guard !recursiveRanges.isEmpty, recursiveRanges == baseRanges else { return false }
        elements.append(rewriter.builder.addCharacterClass(recursiveRanges))
        elements.append(rewriter.builder.addCharacterClassStar(recursiveRanges))
        return true
    }

    /// `self ::= e self | e` with `e` star-expressible → `e e*` (or `e*` when `e` is a star).
    private mutating func tryEmitPlusPattern(_ body: GrammarExpr, selfRuleID: Int32, into elements: inout [Int32]) -> Bool {
        guard body.kind == .choices, body.count == 2 else { return false }
        for recursivePosition in 0 ..< 2 {
            let recursive = source.expr(body[recursivePosition])
            let base = source.expr(body[1 - recursivePosition])
            guard recursive.kind == .sequence, recursive.count == 2, base.kind == .sequence, base.count == 1 else { continue }
            let element = source.expr(recursive[0])
            let tail = source.expr(recursive[1])
            let baseElement = source.expr(base[0])
            guard tail.kind == .ruleRef, tail[0] == selfRuleID, element.kind == baseElement.kind, element.data.elementsEqual(baseElement.data) else {
                continue
            }
            let resolvedID = resolveStarExpressible(recursive[0])
            if resolvedID == -1 {
                // Not a single terminal; e may still be a single-character alternation.
                var ranges: [ClosedRange<Codepoint>] = []
                guard collectSingleCharRanges(recursive[0], into: &ranges, depth: 0) else { continue }
                ranges = Self.unionRanges(ranges)
                elements.append(rewriter.builder.addCharacterClass(ranges))
                elements.append(rewriter.builder.addCharacterClassStar(ranges))
                return true
            }
            let resolved = source.expr(resolvedID)
            if resolved.kind == .characterClassStar {
                elements.append(rewriter.builder.addExpr(resolved))
                return true
            }
            var ranges: [ClosedRange<Codepoint>] = []
            var isNegated = false
            if resolved.kind == .characterClass {
                isNegated = resolved[0] != 0
                var index = 1
                while index + 1 < resolved.count {
                    ranges.append(resolved[index] ... resolved[index + 1])
                    index += 2
                }
            } else {
                ranges.append(resolved[0] ... resolved[0])
            }
            elements.append(rewriter.builder.addExpr(resolved))
            elements.append(rewriter.builder.addCharacterClassStar(ranges, isNegated: isNegated))
            return true
        }
        return false
    }

    /// `self ::= "" | e1 self | e2 self | …` with each `e` resolving to ranges → `(e1|e2|…)*`.
    private mutating func tryEmitStarPattern(_ body: GrammarExpr, selfRuleID: Int32, into elements: inout [Int32]) -> Bool {
        guard body.kind == .choices else { return false }
        var hasEmpty = false
        var ranges: [ClosedRange<Codepoint>] = []
        for choiceID in body {
            let choice = source.expr(choiceID)
            if choice.kind == .emptyString {
                hasEmpty = true
                continue
            }
            guard choice.kind == .sequence, choice.count == 2 else { return false }
            let tail = source.expr(choice[1])
            guard tail.kind == .ruleRef, tail[0] == selfRuleID else { return false }
            guard collectStarRanges(choice[0], into: &ranges, depth: 0) else { return false }
        }
        guard hasEmpty, !ranges.isEmpty else { return false }
        elements.append(rewriter.builder.addCharacterClassStar(Self.unionRanges(ranges)))
        return true
    }

    /// Resolves an expression repeated under an enclosing star into the ranges it repeats
    /// over (under a star, classes, stars, single bytes and alternations/recursions over them
    /// are all equivalent to the union of their ranges).
    private func collectStarRanges(_ exprID: Int32, into ranges: inout [ClosedRange<Codepoint>], depth: Int) -> Bool {
        if depth > 64 { return false }
        let expr = source.expr(exprID)
        if expr.kind == .characterClass || expr.kind == .characterClassStar {
            appendPositiveRanges(expr, into: &ranges)
            return true
        }
        if expr.kind == .byteString, expr.count == 1 {
            ranges.append(expr[0] ... expr[0])
            return true
        }
        guard expr.kind == .ruleRef else { return false }
        let ruleID = expr[0]
        let rule = source.rule(ruleID)
        if rule.isLazy { return false }
        let body = source.expr(rule.bodyExprID)
        guard body.kind == .choices else { return false }
        var hasEmpty = false
        var baseElements: [Int32] = []
        var recursiveElements: [Int32] = []
        for choiceID in body {
            let choice = source.expr(choiceID)
            if choice.kind == .emptyString {
                hasEmpty = true
                continue
            }
            guard choice.kind == .sequence else { return false }
            if choice.count == 1 {
                baseElements.append(choice[0])
                continue
            }
            if choice.count == 2 {
                let tail = source.expr(choice[1])
                if tail.kind == .ruleRef, tail[0] == ruleID {
                    recursiveElements.append(choice[0])
                    continue
                }
            }
            return false
        }
        // Safe shapes: an alternation, a star, and a plus. Mixed shapes like (a self | b) are
        // a*b, whose star is not the union, so they are rejected.
        let collect: [Int32]
        if recursiveElements.isEmpty {
            collect = baseElements
        } else if baseElements.isEmpty, hasEmpty {
            collect = recursiveElements
        } else if recursiveElements.count == 1, baseElements.count == 1, !hasEmpty, exprsEqual(recursiveElements[0], baseElements[0]) {
            collect = recursiveElements
        } else if !hasEmpty {
            var recursiveRanges: [ClosedRange<Codepoint>] = []
            var baseRanges: [ClosedRange<Codepoint>] = []
            for elementID in recursiveElements {
                guard collectSingleCharRanges(elementID, into: &recursiveRanges, depth: depth + 1) else { return false }
            }
            for elementID in baseElements {
                guard collectSingleCharRanges(elementID, into: &baseRanges, depth: depth + 1) else { return false }
            }
            recursiveRanges = Self.unionRanges(recursiveRanges)
            guard recursiveRanges == Self.unionRanges(baseRanges) else { return false }
            ranges.append(contentsOf: recursiveRanges)
            return true
        } else {
            return false
        }
        for elementID in collect {
            guard collectStarRanges(elementID, into: &ranges, depth: depth + 1) else { return false }
        }
        return true
    }

    private func exprsEqual(_ lhsID: Int32, _ rhsID: Int32) -> Bool {
        let lhs = source.expr(lhsID)
        let rhs = source.expr(rhsID)
        return lhs.kind == rhs.kind && lhs.data.elementsEqual(rhs.data)
    }

    /// Appends the positive ranges of a (possibly negated) character class.
    private func appendPositiveRanges(_ expr: GrammarExpr, into ranges: inout [ClosedRange<Codepoint>]) {
        var classRanges: [ClosedRange<Codepoint>] = []
        var index = 1
        while index + 1 < expr.count {
            classRanges.append(expr[index] ... expr[index + 1])
            index += 2
        }
        if expr[0] == 0 {
            ranges.append(contentsOf: classRanges)
            return
        }
        classRanges = Self.unionRanges(classRanges)
        var next: Codepoint = 0
        for range in classRanges {
            if range.lowerBound > next { ranges.append(next ... range.lowerBound - 1) }
            next = max(next, range.upperBound + 1)
        }
        if next <= 0x10FFFF { ranges.append(next ... 0x10FFFF) }
    }

    /// Sorts the ranges and merges overlapping or adjacent ones.
    static func unionRanges(_ ranges: [ClosedRange<Codepoint>]) -> [ClosedRange<Codepoint>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Codepoint>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Resolves through chains of non-lazy single-reference rules to a character class, a
    /// single-byte string or a character class star; `-1` otherwise.
    private func resolveStarExpressible(_ exprID: Int32) -> Int32 {
        var currentID = exprID
        for _ in 0 ..< 64 {
            let current = source.expr(currentID)
            if current.kind == .characterClass || current.kind == .characterClassStar || (current.kind == .byteString && current.count == 1) {
                return currentID
            }
            guard current.kind == .ruleRef else { return -1 }
            let refRule = source.rule(current[0])
            if refRule.isLazy { return -1 }
            let refBody = source.expr(refRule.bodyExprID)
            guard refBody.kind == .choices, refBody.count == 1 else { return -1 }
            let onlyChoice = source.expr(refBody[0])
            guard onlyChoice.kind == .sequence, onlyChoice.count == 1 else { return -1 }
            currentID = onlyChoice[0]
        }
        return -1
    }
}
