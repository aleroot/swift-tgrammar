// Entry points used by the test suite to exercise individual stages of the pipeline, mirroring
// `xgrammar.testing`. Not part of the public API.

enum GrammarTesting {
    /// Parses EBNF and returns the raw, un-normalized grammar.
    static func parseWithoutNormalization(_ ebnf: String, rootRule: String = "root") throws(GrammarError) -> Grammar {
        try Grammar.parseEBNF(ebnf, rootRule: rootRule)
    }

    static func structureNormalizer(_ grammar: Grammar) -> Grammar {
        Grammar(storage: StructureNormalizer.apply(grammar.storage))
    }

    // Single optimizer passes, as upstream's `GrammarFunctor`. Storage is a value, so the input
    // grammar is never mutated.

    static func ruleInliner(_ grammar: Grammar) -> Grammar {
        var storage = grammar.storage
        RuleInliner.apply(&storage)
        return Grammar(storage: storage)
    }

    static func byteStringFuser(_ grammar: Grammar) -> Grammar {
        var storage = grammar.storage
        ByteStringFuser.apply(&storage)
        return Grammar(storage: storage)
    }

    static func deadCodeEliminator(_ grammar: Grammar) -> Grammar {
        Grammar(storage: DeadCodeEliminator.apply(grammar.storage))
    }

    static func lookaheadAssertionAnalyzer(_ grammar: Grammar) -> Grammar {
        Grammar(storage: LookaheadAssertionAnalyzer.apply(grammar.storage))
    }

    /// Runs the whole optimizer pipeline (what the compiler does before building masks).
    static func optimize(_ grammar: Grammar) throws(GrammarError) -> Grammar {
        Grammar(storage: try GrammarOptimizer.apply(grammar.storage))
    }

    /// Builds the per-rule automata of an otherwise untouched grammar.
    static func fsmBuilder(_ grammar: Grammar) throws(GrammarError) -> Grammar {
        var storage = grammar.storage
        try GrammarFSMBuilder.apply(&storage)
        return Grammar(storage: storage)
    }

    /// `Rule i: name, FSM: CompactFSM(...)` per rule, one per line.
    static func printGrammarFSMs(_ grammar: Grammar) -> String {
        let storage = grammar.storage
        precondition(storage.perRuleFSMs.count == storage.ruleCount, "The grammar has no per-rule FSMs; build them first")
        var result = ""
        for (index, rule) in storage.rules.enumerated() {
            result += "Rule \(index): \(rule.name), FSM: "
            if let fsm = storage.perRuleFSMs[index] { result += fsm.fsm.description } else { result += "None" }
            result += "\n"
        }
        return result
    }

    /// Whether the automaton of `ruleID` accepts `string` on its own (rule edges never match).
    static func isRuleFSMAccepting(_ grammar: Grammar, ruleID: Int32, _ string: String) -> Bool {
        guard let fsm = grammar.storage.perRuleFSMs[Int(ruleID)] else { return false }
        return fsm.fsm.accepts(string)
    }
}
