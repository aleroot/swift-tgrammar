import Testing
@testable import TGrammar

/// Ports of the remaining cases of test_max_chars.py, test_temperature.py,
/// test_recursion_depth.py and test_structural_tag_converter.py
/// (test_structural_tag_max_whitespace_cnt_compile_cache) not covered by RuntimeSafeguardTests.
@Suite("Budget and temperature (upstream)")
struct BudgetTemperatureUpstreamTests {
    private static let text = "TEXT: /(\\\\n|.)*/"
    private static let reasoning = "start: reasoning \">\"\nreasoning[max_chars=2]: TEXT\n" + text

    private func compile(lark source: String, _ info: TokenizerInfo, cacheEnabled: Bool = false) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: info, cacheEnabled: cacheEnabled).compile(lark: source)
    }
    private func info(_ pieces: [String], stop: [Int32]? = nil) throws -> TokenizerInfo {
        if let stop { return try TokenizerInfo(encodedVocab: pieces, stopTokenIDs: stop) }
        return try TokenizerInfo(encodedVocab: pieces)
    }
    private func allowed(_ matcher: inout GrammarMatcher) -> [Int32] { matcher.nextTokenBitmask().allowedTokenIDs }
    private func allowed(_ compiled: CompiledGrammar, after prefix: String) -> [Int32]? {
        var matcher = GrammarMatcher(compiled)
        guard matcher.acceptString(prefix) else { return nil }
        return matcher.nextTokenBitmask().allowedTokenIDs
    }
    private func acceptsTokens(_ compiled: CompiledGrammar, _ tokens: [Int32]) -> Bool {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        for token in tokens where !matcher.acceptToken(token) { return false }
        return matcher.isTerminated
    }
    private func approx(_ value: Float?, _ expected: Float) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= 1e-6 * max(1, abs(expected))
    }

    // MARK: test_max_chars.py

    @Test func maxCharsCountsCodepointsAcrossTokenBoundaries() throws {
        let compiled = try compile(lark: Self.reasoning, info(["a", "ab", "abc", "a>", "ab>", ">", "中", "中文", "中文>"]))
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        #expect(allowed(&matcher) == [0, 1, 3, 4, 5, 6, 7, 8])
        let first = matcher.acceptToken(4)
        #expect(first && matcher.isTerminated)
        #expect(acceptsTokens(compiled, [8]))
        var other = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let rejected = other.acceptToken(2), accepted = other.acceptToken(4)
        #expect(!rejected && accepted && other.isTerminated)
    }

    @Test func maxCharsAcceptStringIsTransactional() throws {
        let compiled = try compile(lark: Self.reasoning, Upstream.emptyTokenizer)
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let rejected = matcher.acceptString("中文a>"), accepted = matcher.acceptString("中文>")
        #expect(!rejected && accepted && matcher.isTerminated)
    }

    @Test func maxCharsZeroClosesAtRuleEntry() throws {
        let compiled = try compile(lark: "start: value \">\"\nvalue[max_chars=0]: TEXT\n" + Self.text, info(["a", ">"]))
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        #expect(allowed(&matcher) == [1])
        let rejected = matcher.acceptToken(0), accepted = matcher.acceptToken(1)
        #expect(!rejected && accepted && matcher.isTerminated)
    }

    @Test func maxCharsCodepointSplitAcrossTokens() throws {
        let info = try TokenizerInfo(encodedVocab: [[UInt8(0xE4)], [0xB8], [0xAD], [UInt8(ascii: ">")]])
        let compiled = try compile(lark: "start: reasoning \">\"\nreasoning[max_chars=1]: TEXT\n" + Self.text, info)
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        #expect(allowed(&matcher) == [0, 3])
        let a = matcher.acceptToken(0)
        #expect(a && allowed(&matcher).contains(1))
        let b = matcher.acceptToken(1)
        #expect(b && allowed(&matcher).contains(2))
        let c = matcher.acceptToken(2)
        #expect(c && allowed(&matcher) == [3])
        let d = matcher.acceptToken(3)
        #expect(d && matcher.isTerminated)
    }

    @Test func maxCharsNestedBudgetAndPerOccurrence() throws {
        let info = try info(["x", "a", "b", "c", ":", ">"])
        let nested = try compile(lark: "start: outer \">\"\nouter[max_chars=3]: \"x\" inner\ninner[max_chars=5]: TEXT\n" + Self.text, info)
        var matcher = GrammarMatcher(nested, terminateWithoutStopToken: true)
        let fits = matcher.acceptString("xab>")
        #expect(fits && matcher.isTerminated)
        matcher.reset()
        let overflows = matcher.acceptString("xabc>")
        #expect(!overflows)
        let repeated = try compile(lark: "start: item \":\" item \">\"\nitem[max_chars=2]: /[a-z]*/", info)
        var other = GrammarMatcher(repeated, terminateWithoutStopToken: true)
        let both = other.acceptString("ab:ab>")
        #expect(both && other.isTerminated)
    }

    @Test func maxCharsCombinesWithMaxTokens() throws {
        let info = try info(["a", "ab", ">"])
        let compiled = try compile(lark: "start: reasoning \">\"\nreasoning[max_tokens=2, max_chars=3]: TEXT\n" + Self.text, info)
        func acceptsWithMasks(_ tokens: [Int32]) -> Bool {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            for token in tokens {
                guard matcher.nextTokenBitmask().allows(token) else { return false }
                let accepted = matcher.acceptToken(token)
                #expect(accepted)
            }
            return matcher.isTerminated
        }
        #expect(acceptsWithMasks([1, 0, 2]))
        #expect(!acceptsWithMasks([0, 0, 0, 2]))
        #expect(!acceptsWithMasks([1, 1, 2]))
    }

    @Test func maxCharsCombinesWithTemperature() throws {
        let compiled = try compile(lark: "start: value \">\"\nvalue[max_chars=2, temperature=0.7]: /[a-z]*/", info(["a", "ab", "abc", ">"]))
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        #expect(approx(matcher.temperature, 0.7))
        #expect(allowed(&matcher) == [0, 1, 3])
        let ab = matcher.acceptToken(1)
        #expect(ab && matcher.temperature == nil)
        #expect(allowed(&matcher) == [3])
        let close = matcher.acceptToken(3)
        #expect(close && matcher.isTerminated)
    }

    @Test func maxCharsSuffixCanCloseInsideToken() throws {
        let compiled = try compile(lark: "start: reasoning \"!\"\nreasoning[max_chars=2, suffix=\">\"]: TEXT\n" + Self.text, info(["aa!", "a>!", "aa>!"]))
        #expect(acceptsTokens(compiled, [0]))
        #expect(acceptsTokens(compiled, [1]))
        #expect(!acceptsTokens(compiled, [2]))
        let regex = try compile(lark: "start: reasoning \"!\"\nreasoning[max_chars=2, suffix=\">\"]: /[a-z]*/", info(["a", "!"]))
        var matcher = GrammarMatcher(regex, terminateWithoutStopToken: true)
        let a = matcher.acceptToken(0), b = matcher.acceptToken(0)
        #expect(a && b && allowed(&matcher) == [1])
        let close = matcher.acceptToken(1)
        #expect(close && matcher.isTerminated)
    }

    @Test func maxCharsRollbackResetAndFork() throws {
        let compiled = try compile(lark: Self.reasoning, info(["a", "b", ">"]))
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let a = matcher.acceptToken(0)
        var forked = matcher
        let b = matcher.acceptToken(1)
        #expect(a && b && allowed(&matcher) == [2])
        matcher.rollback(1)
        #expect(allowed(&matcher).contains(0))
        let forkB = forked.acceptToken(1)
        #expect(forkB && allowed(&forked) == [2])
        matcher.reset()
        #expect(allowed(&matcher).contains(0))
    }

    /// The upstream stderr warnings have no Swift counterpart (no diagnostic channel); the
    /// observable effect, dropping both budgets, is checked.
    @Test func maxCharsIsIgnoredOnDynamicDispatchRules() throws {
        let grammar = try Grammar(lark: """
            start[max_chars=5]: tool* tail
            tail: TEXT
            tool_head[lazy]: TEXT "<tool>"
            tool[max_chars=3]: tool_head /[0-9]+/ "</tool>"
            TEXT: /(\\n|.)*/
            """)
        #expect(!grammar.description.contains("max_chars="), "\(grammar.description)")
    }

    @Test func maxCharsCompilerCacheAndSerialization() throws {
        let info = try info(["ab>", "abc"])
        let grammar = try Grammar(ebnf: "root ::= value \">\"\nvalue[max_chars=2] ::= [^]*")
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: true).compile(grammar)
        let recoveredInfo = try TokenizerInfo(serializedJSON: info.serializedJSON)
        let recovered = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: recoveredInfo)
        for candidate in [compiled, recovered] {
            var matcher = GrammarMatcher(candidate, terminateWithoutStopToken: true)
            #expect(allowed(&matcher) == [0])
            let accepted = matcher.acceptToken(0)
            #expect(accepted && matcher.isTerminated)
        }
    }

    @Test func unbudgetedRuleMasksMatchBudgetFreeGrammar() throws {
        let info = try info(["<s>", "</s>", "a", "b", "ab", "abcd", "<", ">", "<|x|>", "|", "\"", ","], stop: [1])
        let compiler = GrammarCompiler(tokenizerInfo: info, cacheEnabled: false)
        let budgeted = try compiler.compile(ebnf: "root ::= \"\\\"\" t \"\\\"\" \",\" b \"|\"\nb[max_chars=3] ::= s\nt ::= [a-z]*\ns ::= [a-z]*")
        let plain = try compiler.compile(ebnf: "root ::= \"\\\"\" t \"\\\"\" \",\" b \"|\"\nb ::= s\nt ::= [a-z]*\ns ::= [a-z]*")
        for prefix in ["\"", "\"ab", "\"" + String(repeating: "a", count: 3000)] {
            let lhs = allowed(budgeted, after: prefix)
            #expect(lhs != nil && lhs == allowed(plain, after: prefix))
        }
        let long = "\"" + String(repeating: "a", count: 3000) + "\","
        #expect(allowed(budgeted, after: long + "ab") == [2, 3, 9])
        #expect(allowed(plain, after: long + "ab") == [2, 3, 4, 5, 9])
        #expect(allowed(budgeted, after: long + "abc") == [9])
        #expect(allowed(plain, after: long + "abc") == [2, 3, 4, 5, 9])
    }

    // MARK: test_temperature.py

    private static let temperatureVocab = ["a", "b", "x", "z", " "]

    @Test func ebnfTemperatureEntersAndLeavesRule() throws {
        let compiled = try GrammarCompiler(tokenizerInfo: info(Self.temperatureVocab))
            .compile(ebnf: "root ::= \"a\" value \"z\"\nvalue[temperature=0.6] ::= \"x\"+")
        var matcher = GrammarMatcher(compiled, defaultTemperature: 0.1)
        #expect(approx(matcher.temperature, 0.1))
        let a = matcher.acceptString("a")
        #expect(a && approx(matcher.temperature, 0.6))
        let x = matcher.acceptString("xx")
        #expect(x && approx(matcher.temperature, 0.6))
        let z = matcher.acceptString("z")
        #expect(z && approx(matcher.temperature, 0.1))
    }

    @Test func ebnfLazyRulePreservesTemperature() throws {
        let compiled = try GrammarCompiler(tokenizerInfo: info(Self.temperatureVocab))
            .compile(ebnf: "root ::= \"a\" value \"z\"\nvalue[lazy, temperature=0.6] ::= \"x\"+")
        var matcher = GrammarMatcher(compiled, defaultTemperature: 0.1)
        let a = matcher.acceptString("a")
        #expect(a && approx(matcher.temperature, 0.6))
        let rest = matcher.acceptString("xz")
        #expect(rest && approx(matcher.temperature, 0.1))
    }

    @Test(arguments: [
        ("start[temperature=-0.1]: \"a\"", "temperature must be a finite non-negative number", nil),
        ("start[temperature=1e999]: \"a\"", "temperature must be a finite non-negative number", nil),
        ("start[temperature=0.1, temperature=0.2]: \"a\"", "temperature attribute is specified more than once", nil),
        ("start[temperature=abc]: \"a\"", "expected number after temperature=", nil),
        ("start: complex\ncomplex[temperature=0.5]: \"a\" child\nchild: \"b\"", "temperature is only supported on terminals and subgrammars", nil),
    ] as [(String, String, String?)])
    func invalidLarkTemperature(_ source: String, _ message: String, _ knownIssue: String?) throws {
        let info = try info(Self.temperatureVocab)
        func check() {
            #expect {
                _ = try Grammar(lark: source, tokenizerInfo: info)
            } throws: { error in
                String(describing: error).contains(message)
            }
        }
        if let knownIssue { withKnownIssue(Comment(rawValue: knownIssue)) { check() } } else { check() }
    }

    @Test(arguments: [("%json {\"type\": \"integer\"}", "1"), ("%lark { start: \"x\" }", "x")])
    func temperatureOnInlineSubgrammar(_ body: String, _ value: String) throws {
        let compiled = try compile(lark: "start: \"a\" value \"z\"\nvalue[temperature=0.6]: " + body, info(Self.temperatureVocab))
        var matcher = GrammarMatcher(compiled, defaultTemperature: 0.1)
        let a = matcher.acceptString("a")
        #expect(a && approx(matcher.temperature, 0.6))
        let rest = matcher.acceptString(value + "z")
        #expect(rest && approx(matcher.temperature, 0.1))
    }

    @Test func temperatureSurvivesSerializationAndCachedCompilation() throws {
        let info = try info(Self.temperatureVocab)
        let grammar = try Grammar(lark: "start[temperature=0.75]: \"a\"")
        let restored = try Grammar(serializedJSON: grammar.serializedJSON)
        #expect(restored.description.contains("[temperature=0.75]"))
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: true).compile(restored)
        let restoredCompiled = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: info)
        #expect(approx(GrammarMatcher(restoredCompiled).temperature, 0.75))
    }

    // MARK: test_recursion_depth.py

    /// test_recursion_exceed: the Earley matcher is iterative, so a long right-recursive string
    /// is matched without any depth limit (upstream only requires that it does not crash).
    @Test func recursionIsNotExceededByEarleyMatching() throws {
        let ebnf = #"""
            root ::= "\"" basic_string "\""
            basic_string ::= "" | [^"\\\r\n] basic_string | "\\" escape basic_string
            escape ::= ["\\/bfnrt] | "u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]
            """#
        #expect(try Upstream.accepts(ebnf: ebnf, "\"" + String(repeating: " ", count: 10000) + "\""))
    }

    // MARK: test_structural_tag_converter.py

    @Test func structuralTagMaxWhitespaceCountCompileCache() throws {
        func tag(_ limit: Int?) -> String {
            let bound = limit.map { ", \"max_whitespace_cnt\": \($0)" } ?? ""
            return #"{"type": "structural_tag", "format": {"type": "tag", "begin": "<call>", "content": {"type": "json_schema", "json_schema": {"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}, "style": "json""# + bound + #"}, "end": "</call>"}}"#
        }
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, cacheEnabled: true)
        let unbounded = try compiler.compile(structuralTagJSON: tag(nil)).grammar
        let bounded = try compiler.compile(structuralTagJSON: tag(2)).grammar
        let instance = "<call>{\"a\":" + String(repeating: " ", count: 5) + "1}</call>"
        #expect(try Upstream.accepts(unbounded, instance))
        #expect(try !Upstream.accepts(bounded, instance))
    }
}
