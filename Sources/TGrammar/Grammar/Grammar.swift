// The public grammar value: an immutable, normalized context-free grammar that describes the
// structure of generated text. Build one from EBNF, JSON Schema, a regular expression or a
// structural tag, then compile it against a tokenizer to constrain decoding.

/// A context-free grammar in the normalized internal form.
///
/// `Grammar` is a reference type so that large grammars are shared cheaply between the compiler,
/// compiled grammars and matchers; it is immutable after construction and therefore `Sendable`.
/// Equality and hashing are by identity.
public final class Grammar: Sendable, CustomStringConvertible, Hashable {
    let storage: GrammarStorage
    /// Pointer-backed view for the parser; present once the grammar is optimized.
    let parserTables: ParserTables?

    init(storage: GrammarStorage) {
        self.storage = storage
        parserTables = storage.isOptimized ? ParserTables(storage) : nil
    }

    public static func == (lhs: Grammar, rhs: Grammar) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: Construction

    /// Parses a grammar written in the EBNF dialect and normalizes it.
    ///
    /// - Parameters:
    ///   - ebnf: The grammar source.
    ///   - rootRule: Name of the rule to start matching from.
    public convenience init(ebnf: String, rootRule: String = "root") throws(GrammarError) {
        let parsed = try EBNFParser.parse(ebnf, rootRule: rootRule)
        self.init(storage: GrammarNormalizer.apply(parsed))
    }

    /// Parses EBNF without normalization. Exposed for tests and tooling that want to inspect the
    /// raw parse result.
    static func parseEBNF(_ ebnf: String, rootRule: String = "root") throws(GrammarError) -> Grammar {
        Grammar(storage: try EBNFParser.parse(ebnf, rootRule: rootRule))
    }

    // MARK: Inspection

    /// The rules in definition order; the index is the rule id.
    public var rules: [GrammarRule] { storage.rules }

    /// Id of the root rule.
    public var rootRuleID: Int32 { storage.rootRuleID }

    /// The root rule.
    public var rootRule: GrammarRule { storage.rootRule }

    /// Number of rules.
    public var ruleCount: Int { storage.ruleCount }

    /// Looks up a rule by id.
    public func rule(_ id: Int32) -> GrammarRule { storage.rule(id) }

    /// Looks up an expression by id.
    public func expr(_ id: Int32) -> GrammarExpr { storage.expr(id) }

    /// The grammar in EBNF form. Printing is normalized and can be parsed again with
    /// ``init(ebnf:rootRule:)``.
    public var description: String { GrammarPrinter(storage).printGrammar() }
}
