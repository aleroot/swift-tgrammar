extension GrammarBuilder {
    /// Imports a subgrammar into this arena, remapping every rule/expression reference.
    /// Attributes and hidden capture suffixes follow their rules across the import.
    mutating func importGrammar(_ source: GrammarStorage) -> Int32 {
        let ids = source.rules.map { addEmptyRule(hint: $0.name) }
        var expressions: [Int32: Int32] = [:]
        func copy(_ old: Int32, into builder: inout GrammarBuilder) -> Int32 {
            if let id = expressions[old] { return id }
            let expr = source.expr(old)
            let result: Int32
            switch expr.kind {
            case .ruleRef: result = builder.addRuleRef(ids[Int(expr[0])])
            case .repeat: result = builder.addRepeat(ruleID: ids[Int(expr[0])], min: expr[1], max: expr[2])
            case .sequence, .choices:
                let children = expr.data.map { copy($0, into: &builder) }
                result = builder.addExpr(expr.kind, children)
            case .tagDispatch:
                var dispatch = source.tagDispatch(expr)
                dispatch.tagRulePairs = dispatch.tagRulePairs.map { ($0.tag, ids[Int($0.ruleID)]) }
                result = builder.addTagDispatch(dispatch)
            case .tokenTagDispatch:
                var dispatch = source.tokenTagDispatch(expr)
                dispatch.triggerRulePairs = dispatch.triggerRulePairs.map { ($0.tokenID, ids[Int($0.ruleID)]) }
                result = builder.addTokenTagDispatch(dispatch)
            default: result = builder.addExpr(expr)
            }
            expressions[old] = result
            return result
        }
        for (index, oldRule) in source.rules.enumerated() {
            let id = ids[index]
            updateRuleBody(id, copy(oldRule.bodyExprID, into: &self))
            if oldRule.lookaheadAssertionID >= 0 { updateLookaheadAssertion(id, copy(oldRule.lookaheadAssertionID, into: &self)) }
            var suffix = source.suffixStopInfo(for: Int32(index))
            if suffix != nil {
                suffix!.ruleID = id
                if suffix!.bodyRuleID >= 0 { suffix!.bodyRuleID = ids[Int(suffix!.bodyRuleID)] }
                if suffix!.markerRuleID >= 0 { suffix!.markerRuleID = ids[Int(suffix!.markerRuleID)] }
            }
            copyAttributes(of: oldRule, suffixStopInfo: suffix, to: id)
        }
        return ids[Int(source.rootRuleID)]
    }
}

extension Grammar {
    /// Matches any one of the supplied grammars. Subgrammar rules retain their attributes.
    public static func union(_ grammars: [Grammar]) throws(GrammarError) -> Grammar {
        guard !grammars.isEmpty else { throw .invalidGrammar("A union requires at least one grammar") }
        // As upstream, the new root is declared first so subgrammar roots become root_1, root_2, ...
        var builder = GrammarBuilder()
        let root = builder.addEmptyRule(name: "root")
        let alternatives = grammars.map { builder.addRuleRef(builder.importGrammar($0.storage)) }
        builder.updateRuleBody(root, builder.addChoices(alternatives))
        return Grammar(storage: GrammarNormalizer.apply(builder.finish(rootRuleID: root)))
    }

    /// Matches the supplied grammars in sequence.
    public static func concatenating(_ grammars: [Grammar]) -> Grammar {
        var builder = GrammarBuilder()
        let root = builder.addEmptyRule(name: "root")
        let parts = grammars.map { builder.addRuleRef(builder.importGrammar($0.storage)) }
        builder.updateRuleBody(root, builder.addSequence(parts))
        return Grammar(storage: GrammarNormalizer.apply(builder.finish(rootRuleID: root)))
    }

    /// Matches contiguous Unicode scalars from `source`, useful for extractive generation.
    public static func substring(of source: String) -> Grammar {
        substring(chunks: source.unicodeScalars.map(String.init))
    }

    /// Matches contiguous whole chunks. Use `source.map(String.init)` for grapheme boundaries,
    /// or supply token/word chunks when extraction must preserve those boundaries.
    public static func substring(chunks: [String]) -> Grammar {
        var builder = GrammarBuilder()
        let root = builder.addRule(name: "root", bodyExprID: builder.addSubstring(chunks.map { Array($0.utf8) }))
        return Grammar(storage: GrammarNormalizer.apply(builder.finish(rootRuleID: root)))
    }
}
