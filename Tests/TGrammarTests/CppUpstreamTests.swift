// Port of xgrammar's C++ GoogleTest suites in tests/cpp that are not covered elsewhere:
// test_fsm_builder.cc, test_json.cc, test_regular_grammar_fsm.cc, test_repetition_range.cc,
// test_parser.cc, test_lark_converter.cc, test_serialization.cc, test_thread_pool.cc and
// test_thread_safe_cache.cc. test_fsm.cc lives in FSMTests.swift.

import Foundation
import Testing

@testable import TGrammar

// MARK: - test_fsm_builder.cc

@Suite("C++ upstream: FSM builders")
struct CppFSMBuilderTests {
    private func expr(_ kind: GrammarExprKind, _ data: [Int32]) -> GrammarExpr {
        GrammarExpr(kind: kind, data: data[...])
    }

    private func build(_ regex: String) throws -> FSMWithStartEnd { try RegexFSMBuilder.build(regex) }

    private func errorMessage(_ regex: String) -> String {
        do {
            _ = try RegexFSMBuilder.build(regex)
            return "<no error>"
        } catch {
            return error.message
        }
    }

    @Test func trieFSMBuilder() throws {
        let patterns = ["hello", "hi", "哈哈", "哈", "hili", "good"].map { Array($0.utf8) }
        let fsm = try #require(TrieFSMBuilder.build(patterns: patterns)).fsm
        func next(_ state: Int32, _ character: Character) -> Int32 {
            fsm.fsm.nextState(from: state, value: Int32(character.asciiValue!))
        }
        #expect(fsm.start == 0)
        #expect(next(fsm.start, "h") == 1)
        #expect(next(1, "e") == 2)
        #expect(next(2, "l") == 3)
        #expect(next(3, "l") == 4)
        #expect(next(4, "o") == 5)
        #expect(fsm.isEndState(5))

        #expect(next(fsm.start, "h") == 1)
        #expect(next(1, "i") == 6)
        #expect(next(6, "l") == 13)
        #expect(!fsm.isEndState(13))

        #expect(next(fsm.start, "g") == 15)
        #expect(next(15, "o") == 16)
        #expect(next(16, "e") == FSM.noNextState)
    }

    @Test(arguments: [["b", "abx"], ["abx", "b"], ["b", "abx", "xabxx"], ["ab", "ab", "abx"]])
    func trieExcludedSuffixes(_ excludes: [String]) throws {
        let result = try #require(TrieFSMBuilder.build(patterns: [], excludedPatterns: excludes.map { Array($0.utf8) }, allowOverlap: true, addBackEdges: true))
        var inputs = [""]
        for length in 0 ... 5 {
            var next: [String] = []
            for input in inputs {
                let expected = excludes.allSatisfy { !input.contains($0) }
                var state = result.fsm.start
                for byte in input.utf8 {
                    state = result.fsm.fsm.nextState(from: state, value: Int32(byte))
                    if state == FSM.noNextState { break }
                }
                #expect((state != FSM.noNextState) == expected, "\(excludes) \(input)")
                if length < 5 { next += ["a", "b", "x"].map { input + $0 } }
            }
            inputs = next
        }
    }

    private static let dispatchTags: [(tag: [UInt8], ruleID: Int32)] = [(Array("hel".utf8), 1), (Array("hi".utf8), 2), (Array("哈".utf8), 3)]

    @Test func tagDispatchFSMBuilderLoop() throws {
        let fsm = try #require(GrammarFSMBuilder.tagDispatch(TagDispatch(tagRulePairs: Self.dispatchTags, loopAfterDispatch: true)))
        #expect(fsm.description == #"""
            FSM(num_states=8, start=0, end=[0, 1, 2, 5, 6], edges=[
            0: [[\0-g]->0, 'h'->1, [i-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            1: [[\0-d]->0, 'e'->2, [f-g]->0, 'h'->1, 'i'->4, [j-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            2: [[\0-g]->0, 'h'->1, [i-k]->0, 'l'->3, [m-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            3: [Rule(1)->0]
            4: [Rule(2)->0]
            5: [[\0-g]->0, 'h'->1, [i-\x92]->0, '\x93'->6, [\x94-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            6: [[\0-g]->0, 'h'->1, [i-\x87]->0, '\x88'->7, [\x89-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            7: [Rule(3)->0]
            ])
            """#)
    }

    @Test func tagDispatchFSMBuilderNoLoop() throws {
        let fsm = try #require(GrammarFSMBuilder.tagDispatch(TagDispatch(tagRulePairs: Self.dispatchTags, loopAfterDispatch: false)))
        #expect(fsm.description == #"""
            FSM(num_states=11, start=0, end=[0, 1, 2, 5, 6, 8, 9, 10], edges=[
            0: [[\0-g]->0, 'h'->1, [i-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            1: [[\0-d]->0, 'e'->2, [f-g]->0, 'h'->1, 'i'->4, [j-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            2: [[\0-g]->0, 'h'->1, [i-k]->0, 'l'->3, [m-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            3: [Rule(1)->8]
            4: [Rule(2)->9]
            5: [[\0-g]->0, 'h'->1, [i-\x92]->0, '\x93'->6, [\x94-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            6: [[\0-g]->0, 'h'->1, [i-\x87]->0, '\x88'->7, [\x89-\xe4]->0, '\xe5'->5, [\xe6-\xff]->0]
            7: [Rule(3)->10]
            8: []
            9: []
            10: []
            ])
            """#)
    }

    @Test func tagDispatchFSMBuilderExcludes() throws {
        let dispatch = TagDispatch(tagRulePairs: Self.dispatchTags, loopAfterDispatch: true, excludes: [Array("hos".utf8), Array("eos".utf8)])
        let printed = try #require(GrammarFSMBuilder.tagDispatch(dispatch)).description
        for edge in ["Rule(1)->0", "Rule(2)->0", "Rule(3)->0"] { #expect(printed.contains(edge)) }
    }

    @Test func tokenTagDispatchFSMBuilder() {
        let printed = GrammarFSMBuilder.tokenTagDispatch(TokenTagDispatch(triggerRulePairs: [(3, 1), (5, 2)], loopAfterDispatch: false, excludes: [7])).description
        #expect(printed.contains("Token"))
        #expect(printed.contains("ExcludeToken"))
    }

    @Test func byteStringFSMBuilder() {
        #expect(GrammarFSMBuilder.byteString(expr(.byteString, "hello".utf8.map(Int32.init))).description == """
            FSM(num_states=6, start=0, end=[5], edges=[
            0: ['h'->1]
            1: ['e'->2]
            2: ['l'->3]
            3: ['l'->4]
            4: ['o'->5]
            5: []
            ])
            """)
        #expect(GrammarFSMBuilder.byteString(expr(.byteString, "你好".utf8.map(Int32.init))).description == #"""
            FSM(num_states=7, start=0, end=[6], edges=[
            0: ['\xe4'->1]
            1: ['\xbd'->2]
            2: ['\xa0'->3]
            3: ['\xe5'->4]
            4: ['\xa5'->5]
            5: ['\xbd'->6]
            6: []
            ])
            """#)
    }

    @Test func ruleRefFSMBuilder() {
        #expect(GrammarFSMBuilder.ruleRef(expr(.ruleRef, [1])).description == """
            FSM(num_states=2, start=0, end=[1], edges=[
            0: [Rule(1)->1]
            1: []
            ])
            """)
    }

    @Test func characterClassFSMBuilder() {
        let letters: [Int32] = [97, 122, 65, 90]
        #expect(GrammarFSMBuilder.characterClass(expr(.characterClass, [0] + letters)).description == """
            FSM(num_states=2, start=0, end=[1], edges=[
            0: [[a-z]->1, [A-Z]->1]
            1: []
            ])
            """)
        #expect(GrammarFSMBuilder.characterClass(expr(.characterClassStar, [0] + letters)).description == """
            FSM(num_states=1, start=0, end=[0], edges=[
            0: [[a-z]->0, [A-Z]->0]
            ])
            """)
        #expect(GrammarFSMBuilder.characterClass(expr(.characterClass, [1] + letters)).description == #"""
            FSM(num_states=16, start=0, end=[1], edges=[
            0: [[\0-@]->1, [[-`]->1, [{-\x7f]->1, [\xc2-\xdf]->2, '\xe0'->3, [\xe1-\xef]->5, '\xf0'->7, '\xf4'->10, [\xf1-\xf3]->13]
            1: []
            2: [[\x80-\xbf]->1]
            3: [[\xa0-\xbf]->4]
            4: [[\x80-\xbf]->1]
            5: [[\x80-\xbf]->6]
            6: [[\x80-\xbf]->1]
            7: [[\x90-\xbf]->8]
            8: [[\x80-\xbf]->9]
            9: [[\x80-\xbf]->1]
            10: [[\x80-\x8f]->11]
            11: [[\x80-\xbf]->12]
            12: [[\x80-\xbf]->1]
            13: [[\x80-\xbf]->14]
            14: [[\x80-\xbf]->15]
            15: [[\x80-\xbf]->1]
            ])
            """#)
        #expect(GrammarFSMBuilder.characterClass(expr(.characterClassStar, [1] + letters)).description == #"""
            FSM(num_states=15, start=0, end=[0], edges=[
            0: [[\0-@]->0, [[-`]->0, [{-\x7f]->0, [\xc2-\xdf]->1, '\xe0'->2, [\xe1-\xef]->4, '\xf0'->6, '\xf4'->9, [\xf1-\xf3]->12]
            1: [[\x80-\xbf]->0]
            2: [[\xa0-\xbf]->3]
            3: [[\x80-\xbf]->0]
            4: [[\x80-\xbf]->5]
            5: [[\x80-\xbf]->0]
            6: [[\x90-\xbf]->7]
            7: [[\x80-\xbf]->8]
            8: [[\x80-\xbf]->0]
            9: [[\x80-\x8f]->10]
            10: [[\x80-\xbf]->11]
            11: [[\x80-\xbf]->0]
            12: [[\x80-\xbf]->13]
            13: [[\x80-\xbf]->14]
            14: [[\x80-\xbf]->0]
            ])
            """#)
    }

    private func ruleFSMs(_ ebnf: String) throws -> [String] {
        let grammar = try Grammar(ebnf: ebnf)
        return try (0 ..< Int32(grammar.storage.rules.count)).map { id in
            try GrammarFSMBuilder.choices(grammar.expr(grammar.rule(id).bodyExprID), grammar.storage).description
        }
    }

    @Test func sequenceFSMBuilder() throws {
        let fsms = try ruleFSMs("""
            root ::= rule1 rule2 rule3
            rule1 ::= "a" [a-z]* rule3
            rule2 ::= "c" [A-Z] rule3
            rule3 ::= "a" rule3
            """)
        #expect(fsms == [
            "FSM(num_states=4, start=2, end=[3], edges=[\n0: [Rule(2)->1]\n1: [Rule(3)->3]\n2: [Rule(1)->0]\n3: []\n])",
            "FSM(num_states=3, start=1, end=[2], edges=[\n0: [Rule(3)->2, [a-z]->0]\n1: ['a'->0]\n2: []\n])",
            "FSM(num_states=4, start=2, end=[3], edges=[\n0: [[A-Z]->1]\n1: [Rule(3)->3]\n2: ['c'->0]\n3: []\n])",
            "FSM(num_states=3, start=1, end=[2], edges=[\n0: [Rule(3)->2]\n1: ['a'->0]\n2: []\n])",
        ])
    }

    @Test func choicesFSMBuilder() throws {
        let fsms = try ruleFSMs("""
            root ::= rule1 | rule2
            rule1 ::= "" | "hello" rule2
            rule2 ::= [a-z]* "A" | "B" rule2
            """)
        #expect(fsms == [
            "FSM(num_states=3, start=0, end=[1, 2], edges=[\n0: [Rule(1)->1, Rule(2)->2]\n1: []\n2: []\n])",
            "FSM(num_states=7, start=0, end=[0, 6], edges=[\n0: ['h'->2]\n1: [Rule(2)->6]\n2: ['e'->3]\n3: ['l'->4]\n4: ['l'->5]\n5: ['o'->1]\n6: []\n])",
            "FSM(num_states=4, start=1, end=[0], edges=[\n0: []\n1: [Eps->2, 'B'->3]\n2: ['A'->0, [a-z]->2]\n3: [Rule(2)->0]\n])",
        ])
    }

    @Test func regexBuildWithForbiddenChars() throws {
        let forbidden = GrammarFSMBuilder.jsonStringForbiddenBytes
        func build(_ regex: String) throws -> FSMWithStartEnd { try RegexFSMBuilder.build(Array(regex.utf8), forbidding: forbidden) }
        var fsm = try build(#"\S+"#)
        #expect(fsm.accepts("abc"))
        #expect(fsm.accepts("a!~z"))
        #expect(!fsm.accepts("a\"b"))
        #expect(!fsm.accepts("a\\b"))
        #expect(!fsm.accepts("a b"))

        fsm = try build("[ -~]+")
        #expect(fsm.accepts("A z!"))
        #expect(!fsm.accepts("\""))
        #expect(!fsm.accepts("\\"))

        fsm = try build(".")
        #expect(fsm.accepts("a"))
        #expect(!fsm.accepts("\t"))
        #expect(!fsm.accepts("\n"))
        #expect(!fsm.accepts("\""))

        fsm = try build("(ab)*")
        #expect(fsm.accepts(""))
        #expect(fsm.accepts("abab"))
        #expect(!fsm.accepts("a"))

        fsm = try build("a\"b")
        #expect(!fsm.accepts("a\"b"))
        #expect(!fsm.accepts("ab"))
        #expect(!fsm.accepts(""))

        fsm = try build(".+")
        #expect(fsm.accepts("你好"))
    }

    @Test func regexBuildWithForbiddenCharsPreservesRepeatAuxData() throws {
        let fsm = try RegexFSMBuilder.build(Array(#"[^\n\r]{1,129}"#.utf8), forbidding: GrammarFSMBuilder.jsonStringForbiddenBytes,
                                            makeRepeatRule: { _, _ in 1 }).fsm
        #expect(!fsm.auxData.isEmpty)
        var foundRepeatEdge = false
        for state in 0 ..< Int32(fsm.stateCount) {
            for edge in fsm.edges(of: state) where edge.isRepeatRef {
                foundRepeatEdge = true
                #expect(edge.auxIndex >= 0)
                #expect(edge.auxIndex + 2 < Int32(fsm.auxData.count))
                let info = fsm.repeatInfo(at: edge.auxIndex)
                #expect(info.lower == 1)
                #expect(info.upper == 129)
            }
        }
        #expect(foundRepeatEdge)
    }

    @Test func grammarFSMBuilderRegex() throws {
        var fsm = try GrammarFSMBuilder.regex(Array("(ab)+".utf8))
        #expect(!fsm.accepts(""))
        #expect(!fsm.accepts("a"))
        #expect(fsm.accepts("ab"))
        #expect(fsm.accepts("abab"))

        fsm = try GrammarFSMBuilder.regex(Array("[0-9]{5}$".utf8))
        #expect(fsm.accepts("12345"))
        #expect(!fsm.accepts("1234"))
        #expect(!fsm.accepts("123456"))

        fsm = try GrammarFSMBuilder.regex(Array(#"\S+"#.utf8), isJSONString: true)
        #expect(fsm.accepts("abc"))
        #expect(!fsm.accepts("a\"b"))
        #expect(!fsm.accepts("a\\b"))

        fsm = try GrammarFSMBuilder.regex(Array(#"\S+"#.utf8))
        #expect(fsm.accepts("a\"b"))

        #expect(throws: GrammarError.self) { try GrammarFSMBuilder.regex(Array("+a".utf8)) }
    }

    @Test func regexRepeatZero() throws {
        var fsm = try build("a{0}")
        #expect(fsm.accepts(""))
        #expect(!fsm.accepts("a"))
        fsm = try build("a{0,0}")
        #expect(fsm.accepts(""))
        #expect(!fsm.accepts("a"))
        fsm = try build("(ab){0}")
        #expect(fsm.accepts(""))
        #expect(!fsm.accepts("ab"))
        fsm = try build("ba{0}c")
        #expect(fsm.accepts("bc"))
        #expect(!fsm.accepts("bac"))
        fsm = try GrammarFSMBuilder.regex(Array("ba{0}c".utf8))
        #expect(fsm.accepts("bc"))
        #expect(!fsm.accepts("bac"))
        #expect(throws: GrammarError.self) { try build("a{3,1}") }
        #expect(throws: GrammarError.self) { try build("a{1,0}") }
    }

    @Test func regexCaseInsensitiveFlag() throws {
        var fsm = try build("(?i)abc")
        for input in ["abc", "ABC", "aBc"] { #expect(fsm.accepts(input)) }
        #expect(!fsm.accepts("abd"))
        fsm = try build("(?i)(ab|cd)+")
        #expect(fsm.accepts("aBcD"))
        #expect(!fsm.accepts("ac"))
        fsm = try build("(?i)[a-dx]")
        for input in ["b", "B", "X"] { #expect(fsm.accepts(input)) }
        for input in ["e", "E"] { #expect(!fsm.accepts(input)) }
        fsm = try build("(?i)[^k]")
        #expect(fsm.accepts("a"))
        #expect(!fsm.accepts("k"))
        #expect(!fsm.accepts("K"))
        fsm = try build("(?i)Σ")
        #expect(fsm.accepts("Σ"))
        #expect(!fsm.accepts("σ"))
        fsm = try build("abc")
        #expect(!fsm.accepts("ABC"))
    }

    @Test func regexEscapes() throws {
        var fsm = try build(#"\x41\u0042\u{43}"#)
        #expect(fsm.accepts("ABC"))
        fsm = try build(#"\u{1F600}"#)
        #expect(fsm.accepts("😀"))
        #expect(!fsm.accepts("😁"))
        fsm = try build(#"[\u0041-\u0043]+"#)
        #expect(fsm.accepts("ABC"))
        #expect(!fsm.accepts("D"))
        fsm = try build("好*")
        #expect(fsm.accepts(""))
        #expect(fsm.accepts("好好"))
        #expect(!fsm.accepts([UInt8(0xBD)]))
        fsm = try build(#"\s+"#)
        #expect(fsm.accepts(" \t\n\r\u{0C}\u{0B}"))
        #expect(!fsm.accepts([UInt8(0)]))
        #expect(!fsm.accepts([UInt8(1)]))
        fsm = try build(#"\S"#)
        #expect(fsm.accepts("好"))
        #expect(fsm.accepts([UInt8(0)]))
        #expect(!fsm.accepts(" "))
    }

    @Test func regexUnsupportedFeatures() throws {
        for regex in [#"a\b"#, #"a\B"#, #"\p{L}"#, #"(a)\1"#, #"(?<name>a)\k<name>"#, "(?<=a)b", "[]", "[^]"] {
            #expect(throws: GrammarError.self, "\(regex)") { try build(regex) }
        }
        #expect(try build("a(?=b)c").accepts("ac"))
        #expect(try build("a(?!b)c").accepts("ac"))
        #expect(try build("(?<name>ab)+").accepts("abab"))
        #expect(try build("(?P<name>ab)c").accepts("abc"))
        #expect(try build("a^b$c").accepts("abc"))
        var fsm = try build("a*?b+?c??(de){1,2}?")
        #expect(fsm.accepts("aabbcde"))
        #expect(fsm.accepts("bdede"))
        fsm = try build("(a|)b")
        #expect(fsm.accepts("ab"))
        #expect(fsm.accepts("b"))
        fsm = try build("a|")
        #expect(fsm.accepts("a"))
        #expect(fsm.accepts(""))
    }

    @Test func regexErrorMessages() {
        let cases: [(String, String)] = [
            ("+a", "Regex parsing error at position 1: There is nothing to repeat before '+'"),
            ("ab)", "Regex parsing error at position 3: Unmatched ')'"),
            ("a]", "Regex parsing error at position 2: Unmatched ']'"),
            ("a(bc", "Regex parsing error at position 2: The parenthesis is not closed"),
            ("a[bc", "Regex parsing error at position 2: Unclosed '['"),
            ("a[]", "Regex parsing error at position 2: Empty character class is not allowed in regex"),
            ("a{,2}", "Regex parsing error at position 2: Invalid repetition count: expected a number after '{'"),
            ("a{3,1}", "Regex parsing error at position 2: Invalid repetition count: the lower bound 3 is larger than the upper bound 1"),
            ("a{1,9999999999}", "Regex parsing error at position 2: Invalid repetition count: the count 9999999999 is too large"),
            (#"a\b"#, #"Regex parsing error at position 2: Word boundary assertion \b is not supported in regex"#),
            ("(?<name)a", "Regex parsing error at position 1: Invalid named capturing group"),
            ("(?i)+a", "Regex parsing error at position 5: There is nothing to repeat before '+'"),
        ]
        for (regex, expected) in cases { #expect(errorMessage(regex) == expected) }
    }

    @Test func regexMatchesEmpty() throws {
        func matchesEmpty(_ regex: String) throws -> Bool { try RegexFSMBuilder.matchesEmpty(Array(regex.utf8)) }
        for regex in ["a*", "(a|)", "a{0,10}", "(ab)?", "(abc){0,1000000}", "(?i)A*"] { #expect(try matchesEmpty(regex), "\(regex)") }
        for regex in ["a+", "a{1,10}", "ab|cd", "(abc){2,1000000}"] { #expect(try !matchesEmpty(regex), "\(regex)") }
        #expect(throws: GrammarError.self) { try matchesEmpty(#"\b"#) }
    }

    @Test func regexLargeRepeatWithoutBuilder() throws {
        let fsm = try build("a{2,300}")
        #expect(!fsm.accepts("a"))
        #expect(fsm.accepts("aa"))
        #expect(fsm.accepts(String(repeating: "a", count: 300)))
        #expect(!fsm.accepts(String(repeating: "a", count: 301)))
        #expect(throws: GrammarError.self) { try build("(abcdefghij){1,100000}") }
    }
}

// MARK: - test_json.cc, test_regular_grammar_fsm.cc, test_repetition_range.cc

@Suite("C++ upstream: JSON whitespace, regular grammars, repetition ranges")
struct CppGrammarTests {
    private static let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, maxThreads: 1, cacheEnabled: false)

    private func matchesEntireString(_ grammar: CompiledGrammar, _ input: String) -> Bool {
        var matcher = GrammarMatcher(grammar, terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isTerminated
    }

    @Test func builtinGrammarAcceptsAllRFCWhitespace() throws {
        let compiled = try Self.compiler.compile(.builtinJSON)
        for input in ["{\r\"value\"\r:\r3\r}", "{\r\n\"value\"\r\n:\r\n3\r\n}", "{ \t\r\n\"value\"\n\r\t :\r 3\t\n}"] {
            #expect(matchesEntireString(compiled, input))
        }
    }

    @Test func jsonSchemaCarriageReturnWhitespaceModes() throws {
        let schema = #"""
            {
                "type": "object",
                "properties": {"value": {"type": "integer"}},
                "required": ["value"],
                "additionalProperties": false
            }
            """#
        let flexible = try Self.compiler.compile(Grammar(jsonSchema: schema, options: .init(anyWhitespace: true)))
        for input in ["{\r\"value\"\r:\r3\r}", "{\r\n\"value\"\r\n:\r\n3\r\n}", "{ \t\r\n\"value\"\n\r\t :\r 3\t\n}"] {
            #expect(matchesEntireString(flexible, input))
        }
        let fixed = try Self.compiler.compile(Grammar(jsonSchema: schema, options: .init(anyWhitespace: false)))
        #expect(matchesEntireString(fixed, #"{"value": 3}"#))
        #expect(!matchesEntireString(fixed, "{\r\"value\"\r:\r3\r}"))
        let capped = try Self.compiler.compile(Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, strict: true, maxWhitespaceCount: 2)))
        #expect(matchesEntireString(capped, "{\r\n\"value\"\r:\t3\n\r}"))
        #expect(!matchesEntireString(capped, "{\r\n\r\"value\": 3}"))
    }

    // Upstream checks these languages on GrammarFSMBuilder::FromRegularGrammar, which TGrammar
    // does not have; the same expectations are checked on the grammar itself.
    @Test func regularGrammarRepeatedCallsHaveSeparateReturns() throws {
        let grammar = try Grammar(ebnf: "root ::= part \"x\" part \"y\"\npart ::= \"a\" part | \"b\"\n")
        for text in ["bxby", "abxby", "bxaaby", "aaabxaaaby"] { #expect(try Upstream.accepts(grammar, text), "\(text)") }
        for text in ["", "by", "bxy", "bxay", "abxay", "bybx", "bxbyy"] { #expect(try !Upstream.accepts(grammar, text), "\(text)") }
    }

    @Test func regularGrammarRecursiveCalleeCannotUseCallersOptionalExit() throws {
        let grammar = try Grammar(ebnf: "root ::= part? \"z\" part*\npart ::= \"a\" part | \"b\"\n")
        for text in ["z", "bz", "abz", "zb", "zaab", "bzab", "abzbaab"] { #expect(try Upstream.accepts(grammar, text), "\(text)") }
        for text in ["az", "za", "bza", "aaz", "zba"] { #expect(try !Upstream.accepts(grammar, text), "\(text)") }
    }

    @Test func unboundedRepetitionAboveThresholdDoesNotCrash() throws {
        let grammar = try Grammar(ebnf: "root ::= [a-z]{129,} [0-9]{129,}")
        _ = RepetitionRangeExpander.apply(grammar.storage)
        let input = String(repeating: "a", count: 129) + String(repeating: "7", count: 130)
        #expect(try Upstream.accepts(grammar, input))
        #expect(try !Upstream.accepts(grammar, String(repeating: "a", count: 129) + String(repeating: "7", count: 128)))
    }
}

// MARK: - test_parser.cc (EBNF lexer)

@Suite("C++ upstream: EBNF lexer")
struct CppEBNFLexerTests {
    private typealias K = EBNFToken.Kind

    private func string(_ token: EBNFToken) -> String? {
        if case let .string(bytes) = token.value { return String(decoding: bytes, as: UTF8.self) }
        return nil
    }

    private func codepoint(_ token: EBNFToken) -> Codepoint? {
        if case let .codepoint(value) = token.value { return value }
        return nil
    }

    private func bool(_ token: EBNFToken) -> Bool? {
        if case let .boolean(value) = token.value { return value }
        return nil
    }

    private func lexError(_ input: String) -> String {
        do {
            _ = try EBNFLexer.tokenize(input)
            return "<no error>"
        } catch {
            return error.description
        }
    }

    @Test func basicTokenization() throws {
        let tokens = try EBNFLexer.tokenize("rule1 ::= \"string\" | [a-z] | 123 | (expr) | {1,3} | * | + | ? | true | false")
        try #require(tokens.count == 32)
        let kinds: [K] = [.ruleName, .assign, .stringLiteral, .pipe, .lBracket, .charInCharClass, .dash, .charInCharClass, .rBracket,
                          .pipe, .integerLiteral, .pipe, .lParen, .identifier, .rParen, .pipe, .lBrace, .integerLiteral, .comma,
                          .integerLiteral, .rBrace, .pipe, .star, .pipe, .plus, .pipe, .question, .pipe, .booleanLiteral, .pipe,
                          .booleanLiteral, .endOfFile]
        #expect(tokens.map(\.kind) == kinds)
        #expect(tokens[0].lexeme == "rule1")
        #expect(tokens[1].lexeme == "::=")
        #expect(tokens[2].lexeme == "\"string\"")
        #expect(string(tokens[2]) == "string")
        #expect(tokens[5].lexeme == "a" && codepoint(tokens[5]) == 97)
        #expect(tokens[7].lexeme == "z" && codepoint(tokens[7]) == 122)
        #expect(tokens[10].lexeme == "123")
        if case let .integer(value) = tokens[10].value { #expect(value == 123) } else { Issue.record("not an integer") }
        #expect(tokens[28].lexeme == "true" && bool(tokens[28]) == true)
        #expect(tokens[30].lexeme == "false" && bool(tokens[30]) == false)
    }

    @Test func commentsAndWhitespace() throws {
        let tokens = try EBNFLexer.tokenize("rule1 ::= expr1 # This is a comment\n  | expr2 # Another comment")
        try #require(tokens.count == 6)
        #expect(tokens.map(\.kind) == [.ruleName, .assign, .identifier, .pipe, .identifier, .endOfFile])
        #expect(tokens[0].lexeme == "rule1")
        #expect(tokens[2].lexeme == "expr1")
        #expect(tokens[4].lexeme == "expr2")
    }

    @Test func stringLiterals() throws {
        let tokens = try EBNFLexer.tokenize(#"rule ::= "normal string" | "escaped \"quotes\"" | "\n\r\t\\""#)
        try #require(tokens.count == 8)
        for index in [2, 4, 6] { #expect(tokens[index].kind == .stringLiteral) }
        #expect(string(tokens[2]) == "normal string")
        #expect(string(tokens[4]) == "escaped \"quotes\"")
        #expect(string(tokens[6]) == "\n\r\t\\")
    }

    @Test func characterClasses() throws {
        let tokens = try EBNFLexer.tokenize(#"rule ::= [a-z] | [0-9] | [^a-z] | [\-\]\\] | [\u0041-\u005A] | [测试] | [\t\r\n] | [\b\f]"#)
        try #require(tokens.count == 49)
        let expected: [(Int, K, String?, Codepoint?)] = [
            (2, .lBracket, nil, nil), (3, .charInCharClass, "a", 97), (4, .dash, nil, nil), (5, .charInCharClass, "z", 122),
            (6, .rBracket, nil, nil), (7, .pipe, nil, nil),
            (8, .lBracket, nil, nil), (9, .charInCharClass, "0", 48), (10, .dash, nil, nil), (11, .charInCharClass, "9", 57),
            (12, .rBracket, nil, nil), (13, .pipe, nil, nil),
            (14, .lBracket, nil, nil), (15, .caret, nil, nil), (16, .charInCharClass, "a", 97), (17, .dash, nil, nil),
            (18, .charInCharClass, "z", 122), (19, .rBracket, nil, nil), (20, .pipe, nil, nil),
            (21, .lBracket, nil, nil), (22, .charInCharClass, #"\-"#, 45), (23, .charInCharClass, #"\]"#, 93),
            (24, .charInCharClass, #"\\"#, 92), (25, .rBracket, nil, nil), (26, .pipe, nil, nil),
            (27, .lBracket, nil, nil), (28, .charInCharClass, #"\u0041"#, 0x41), (29, .dash, nil, nil),
            (30, .charInCharClass, #"\u005A"#, 0x5A), (31, .rBracket, nil, nil), (32, .pipe, nil, nil),
            (33, .lBracket, nil, nil), (34, .charInCharClass, "测", 0x6D4B), (35, .charInCharClass, "试", 0x8BD5),
            (36, .rBracket, nil, nil), (37, .pipe, nil, nil),
            (38, .lBracket, nil, nil), (39, .charInCharClass, #"\t"#, 9), (40, .charInCharClass, #"\r"#, 13),
            (41, .charInCharClass, #"\n"#, 10), (42, .rBracket, nil, nil), (43, .pipe, nil, nil),
            (44, .lBracket, nil, nil), (45, .charInCharClass, #"\b"#, 8), (46, .charInCharClass, #"\f"#, 12), (47, .rBracket, nil, nil),
        ]
        for (index, kind, lexeme, value) in expected {
            #expect(tokens[index].kind == kind, "token \(index)")
            if let lexeme { #expect(tokens[index].lexeme == lexeme, "token \(index)") }
            if let value { #expect(codepoint(tokens[index]) == value, "token \(index)") }
        }
    }

    @Test func booleanValues() throws {
        let tokens = try EBNFLexer.tokenize("rule ::= true | false")
        try #require(tokens.count == 6)
        #expect(tokens[2].kind == .booleanLiteral && tokens[2].lexeme == "true" && bool(tokens[2]) == true)
        #expect(tokens[4].kind == .booleanLiteral && tokens[4].lexeme == "false" && bool(tokens[4]) == false)
    }

    @Test func lookaheadAssertion() throws {
        let tokens = try EBNFLexer.tokenize("rule ::= \"a\" (= lookahead)")
        try #require(tokens.count == 7)
        #expect(tokens[3].kind == .lookaheadLParen)
        #expect(tokens[3].lexeme == "(=")
        #expect(tokens[5].kind == .rParen)
    }

    @Test func lineAndColumnTracking() throws {
        let tokens = try EBNFLexer.tokenize("rule1 ::= expr1\nrule2 ::= expr2")
        try #require(tokens.count == 7)
        let positions = tokens.prefix(6).map { [$0.line, $0.column] }
        #expect(positions == [[1, 1], [1, 7], [1, 11], [2, 1], [2, 7], [2, 11]])
    }

    @Test func complexGrammar() throws {
        let tokens = try EBNFLexer.tokenize(#"""
            # JSON Grammar
            root ::= value
            value ::= object | array | string | number | "true" | "false" | "null"
            object ::= "{" (member ("," member)*)? "}"
            member ::= string ":" value
            array ::= "[" (value ("," value)*)? "]"
            string ::= "\"" char* "\""
            char ::= [^"\\] | "\\\""
            number ::= int frac? exp?
            int ::= "-"? ([1-9] [0-9]* | "0")
            frac ::= "." [0-9]+
            exp ::= [eE] [+\-]? [0-9]+
            """#)
        #expect(tokens.count > 50)
        #expect(tokens.last?.kind == .endOfFile)
    }

    @Test func edgeCases() throws {
        #expect(try EBNFLexer.tokenize("").map(\.kind) == [.endOfFile])
        #expect(try EBNFLexer.tokenize("  \t\n # Comment\n  # Another comment").map(\.kind) == [.endOfFile])
        #expect(try EBNFLexer.tokenize("rule1 ::= expr1\nrule2 ::= expr2\r\nrule3 ::= expr3\rrule4 ::= expr4").count == 13)
        var tokens = try EBNFLexer.tokenize("rule ::= 999999999999999")
        try #require(tokens.count == 4)
        #expect(tokens[2].kind == .integerLiteral && tokens[2].lexeme == "999999999999999")
        tokens = try EBNFLexer.tokenize("rule-name ::= _special.identifier-123")
        try #require(tokens.count == 4)
        #expect(tokens[0].kind == .ruleName && tokens[0].lexeme == "rule-name")
        #expect(tokens[2].kind == .identifier && tokens[2].lexeme == "_special.identifier-123")
    }

    @Test func quantifierTokens() throws {
        let tokens = try EBNFLexer.tokenize("rule ::= expr? | expr* | expr+ | expr{1} | expr{1,} | expr{1,5}")
        let expected: [(Int, K)] = [(3, .question), (6, .star), (9, .plus), (12, .lBrace), (13, .integerLiteral), (14, .rBrace),
                                    (17, .lBrace), (18, .integerLiteral), (19, .comma), (20, .rBrace)]
        for (index, kind) in expected { #expect(tokens[index].kind == kind, "token \(index)") }
    }

    @Test func utf8Handling() throws {
        let tokens = try EBNFLexer.tokenize(#"rule ::= "UTF-8: \u00A9 \u2603 \U0001F600""#)
        try #require(tokens.count == 4)
        #expect(tokens[2].kind == .stringLiteral)
        #expect(string(tokens[2]) == "UTF-8: © ☃ 😀")
    }

    // The two invalid-UTF-8 inputs ("\xC2\x20" in a string and in a class) cannot be expressed as
    // a Swift `String`, the lexer's input type, so they are not ported.
    @Test(arguments: [
        ("rule ::= \"unterminated string", "Expect \" in string literal"),
        ("rule ::= [a-z", "Unterminated character class"),
        (#"rule ::= [a-z\-\\\]"#, "Unterminated character class"),
        (#"rule ::= "\z""#, "Invalid escape sequence"),
        ("rule ::= [a-z\n]", "Character class should not contain newline"),
        (#"rule ::= [\z]"#, "Invalid escape sequence"),
        ("rule ::= expr{1000000000000000000}", "Integer is too large"),
        ("rule ::= @", "Unexpected character"),
        ("rule : expr", "Unexpected character: ':'"),
        ("\"string\" ::= expr", "Assign should be preceded by an identifier"),
        ("::= expr", "Assign should not be the first token"),
        ("token token ::= expr", "The rule name should be at the beginning of the line"),
    ])
    func lexerErrorCases(_ input: String, _ message: String) {
        let error = lexError(input)
        #expect(error.contains(message), "\(error)")
    }
}

// MARK: - test_lark_converter.cc

@Suite("C++ upstream: Lark converter")
struct CppLarkConverterTests {
    private func larkError(_ source: String, tokenizerInfo: TokenizerInfo? = nil, named: [String: NamedGrammar] = [:]) -> String {
        do {
            _ = try Grammar(lark: source, tokenizerInfo: tokenizerInfo, namedGrammars: named)
            return "<no error>"
        } catch {
            return error.description
        }
    }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func defaultArguments() throws {
        let source = #"start: "x""#
        let expected = try Grammar(lark: source, tokenizerInfo: nil, namedGrammars: [:]).description
        #expect(try Grammar(lark: source).description == expected)
        #expect(try Grammar(lark: source, tokenizerInfo: nil).description == expected)
    }

    @Test func coreSyntaxAndImports() throws {
        let printed = try Grammar(lark: """
            %import common.INT
            %import common (WS_INLINE, CNAME)
            %ignore WS_INLINE
            start: item{2,3}
            item: CNAME ":" INT | "none"
            """).description
        for part in ["root", "lark_ignore", "{2, 3}"] { #expect(printed.contains(part), "\(part)\n\(printed)") }
    }

    @Test func inlineAndNestedGrammar() throws {
        let printed = try Grammar(lark: """
            start: "payload=" %json {
              "type": "object",
              "properties": {"x": {"type": "integer"}},
              "required": ["x"],
              "additionalProperties": false
            } ";" %lark {
              start: "yes" | "no"
            }
            """).description
        for part in ["payload=", "yes"] { #expect(printed.contains(part), "\(part)\n\(printed)") }
        withKnownIssue("Swift's JSON Schema converter names the integer rule per property (root_x), not upstream's basic_integer") {
            #expect(printed.contains("basic_integer"))
        }
    }

    @Test func namedGrammars() throws {
        let word = try Grammar(regex: "[a-z]+")
        let number = try Grammar(lark: "start: /[0-9]+/")
        let printed = try Grammar(lark: """
            start: "<" @word ":" @number ">" %lark {
              start: "/" @word
            }
            """, namedGrammars: ["word": .grammar(word), "number": .grammar(number)]).description
        #expect(printed.contains("[a-z]"))
        #expect(printed.contains("[0-9]"))
    }

    @Test func namedGrammarSources() throws {
        let printed = try Grammar(lark: "start: @pair", namedGrammars: ["pair": .lark(#"start: @item ":" @item"#), "item": .lark("start: /[a-z]+/")]).description
        #expect(printed.contains("[a-z]"))
        #expect(printed.contains("\":\""))
        let error = larkError("start: @left", named: ["left": .lark("start: @right"), "right": .lark("start: @left")])
        #expect(error.contains("circular named grammar reference: @left -> @right -> @left"), "\(error)")
    }

    @Test func grammarCompilerCachesLarkSources() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, maxThreads: 1, cacheEnabled: true)
        #expect(try compiler.compile(lark: #"start: "a""#) === compiler.compile(lark: #"start: "a""#))
        // Named grammars are a dictionary in Swift, so the reordering case is the same lookup.
        let named: [String: NamedGrammar] = ["left": .lark(#"start: "a""#), "right": .lark(#"start: "b""#)]
        let withNamed = try compiler.compile(lark: "start: @left @right", namedGrammars: named)
        #expect(try withNamed === compiler.compile(lark: "start: @left @right", namedGrammars: ["right": .lark(#"start: "b""#), "left": .lark(#"start: "a""#)]))
        #expect(try withNamed !== compiler.compile(lark: "start: @left @right", namedGrammars: ["left": .lark(#"start: "a""#), "right": .lark(#"start: "c""#)]))
        #expect(try compiler.compile(lark: "start: @item", namedGrammars: ["item": .grammar(Grammar(lark: #"start: "item""#))])
            === compiler.compile(lark: "start: @item", namedGrammars: ["item": .grammar(Grammar(lark: #"start: "item""#))]))
        let uncached = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, maxThreads: 1, cacheEnabled: false)
        #expect(try uncached.compile(lark: #"start: "a""#) !== uncached.compile(lark: #"start: "a""#))
    }

    @Test func dynamicToolCallLowersToTagDispatch() throws {
        let printed = try Grammar(lark: #"""
            start: (foo | bar)* tail
            tail: TEXT

            foo_head[lazy]: TEXT "<function"
            foo: foo_head "=foo>" /[a-z]+/ "</function>"

            bar_head[lazy]: TEXT "<function"
            bar: bar_head "=bar>" /[A-Z]+/ "</function>"

            TEXT: /(\n|.)*/
            """#).description
        for part in ["TagDispatch", "\"<function\"", "loop_after_dispatch=true"] { #expect(printed.contains(part), "\(part)\n\(printed)") }
    }

    @Test func numericAndNamedSpecialTokens() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "<|tool|>", "b"], vocabType: .raw, vocabSize: 3, stopTokenIDs: [])
        let printed = try Grammar(lark: "start: <[0,2]> | <|tool|>", tokenizerInfo: info).description
        #expect(printed.contains("Token(0, 2)"), "\(printed)")
        #expect(printed.contains("Token(1)"), "\(printed)")
    }

    @Test func stringAndRegexFlags() throws {
        #expect(try Grammar(lark: "start: \"Case\"i /Σ[^k].x/isu").description.contains("root"))
        let error = larkError("start: \"Żółw\"i")
        #expect(error.contains("case-insensitive string literals currently support ASCII characters only"), "\(error)")
    }

    @Test func dynamicRegexSuffixAndSuffixAttribute() throws {
        let printed = try Grammar(lark: #"""
            start: (foo | bar)* tail
            tail: TEXT

            foo_head[lazy]: /(\n|.)*<foo>/
            foo: foo_head /[a-z]+/ "</foo>"

            bar_head[suffix="<bar>"]: TEXT
            bar: bar_head /[0-9]+/ "</bar>"

            TEXT: /.*/s
            """#).description
        for part in ["TagDispatch", "\"<foo>\"", "\"<bar>\""] { #expect(printed.contains(part), "\(part)\n\(printed)") }
    }

    // Duplicate named grammars ("Duplicate named grammar 'item'") cannot be expressed: Swift
    // passes named grammars as a dictionary.
    @Test(arguments: [
        ("item: \"a\"", "line 1, column 1.*no start rule"),
        ("start: FOO\nFOO: BAR\nBAR: FOO", "circular reference in terminal"),
    ])
    func errorsContainSourceLocations(_ source: String, _ pattern: String) {
        let error = larkError(source)
        #expect(matches(error, pattern), "\(error)")
    }

    @Test(arguments: [
        ("start: missing", "line 1, column 8.*unknown name"),
        ("start[budget=10]: \"a\"", "attribute 'budget' is not supported"),
        ("start[capture=\"a b\"]: \"a\"", "capture name must only contain letters, digits"),
        ("start: A & B\nA: \"a\"\nB: \"b\"", "intersection '&' is not supported"),
        ("start: /abc/m", "regular-expression flag 'm' is not supported"),
        ("start: TOKEN\nTOKEN: %json {}", "%json cannot be used in terminals"),
        ("start: TOKEN\nTOKEN: %lark { start: \"a\" }", "nested %lark cannot be used in terminals"),
        ("start: <[1-2-3]>", "invalid numeric special-token range"),
        ("start: @missing", "line 1, column 8.*unknown named grammar '@missing'"),
    ])
    func errorsContainSourceLocationsDivergent(_ source: String, _ pattern: String) {
        let error = larkError(source)
        #expect(matches(error, pattern), "\(error)")
    }
}

// MARK: - test_serialization.cc, test_thread_pool.cc

@Suite("C++ upstream: serialization and parallel compilation")
struct CppSerializationTests {
    @Test func tokenizerInfoRoundtripPreservesDerivedData() throws {
        let original = try TokenizerInfo(encodedVocab: ["\0", "a", "</s>"], vocabType: .raw, vocabSize: 4, stopTokenIDs: [2])
        let recovered = try TokenizerInfo(serializedJSON: original.serializeJSON())
        #expect((0 ..< recovered.decodedVocab.count).map { Array(recovered.decodedVocab[$0]) } == (0 ..< original.decodedVocab.count).map { Array(original.decodedVocab[$0]) })
        #expect(recovered.sortedIndexByTokenID == original.sortedIndexByTokenID)
        #expect(recovered.sortedIndexByTokenID == [0, 1, -1, -1])
    }

    private static func simpleFSM() -> FSM {
        var fsm = FSM(stateCount: 3)
        fsm.addEdge(from: 0, to: 1, min: 97, max: 97)
        fsm.addEdge(from: 1, to: 2, min: 98, max: 98)
        fsm.addEpsilonEdge(from: 0, to: 2)
        return fsm
    }

    private static func ruleFSM() -> FSM {
        var fsm = FSM(stateCount: 3)
        fsm.addEdge(from: 0, to: 1, min: 97, max: 122)
        fsm.addRuleEdge(from: 1, to: 2, ruleID: 5)
        fsm.addEOSEdge(from: 2, to: 0)
        return fsm
    }

    @Test(arguments: [
        (simpleFSM(), #"{"edges":{"data_":[[-1,0,2],[97,97,1],[98,98,2]],"indptr_":[0,2,3,3]},"edge_aux_data":[],"edge_num":3}"#),
        (ruleFSM(), #"{"edges":{"data_":[[97,122,1],[-2,5,2],[-3,0,0]],"indptr_":[0,1,2,3]},"edge_aux_data":[],"edge_num":3}"#),
    ])
    func compactFSM(_ fsm: FSM, _ expected: String) throws {
        let compact = fsm.compacted()
        let json = compact.serializationValue.serialized()
        #expect(json == expected)
        let restored = try CompactFSM.restore(JSONValue.parse(json))
        #expect(restored.stateCount == compact.stateCount)
        #expect(restored.serializationValue.serialized() == json)
    }

    /// Upstream serializes `CompactFSMWithStartEnd` as `[fsm, start, ends, is_dfa, edge_count]`;
    /// TGrammar stores it inside the `[view, edge_count, node_count]` grammar-fragment record.
    @Test(arguments: [
        (simpleFSM(), #"[{"edges":{"data_":[[-1,0,2],[97,97,1],[98,98,2]],"indptr_":[0,2,3,3]},"edge_aux_data":[],"edge_num":3},0,[2],false,3]"#),
        (ruleFSM(), #"[{"edges":{"data_":[[97,122,1],[-2,5,2],[-3,0,0]],"indptr_":[0,1,2,3]},"edge_aux_data":[],"edge_num":3},0,[2],false,3]"#),
    ])
    func compactFSMWithStartEnd(_ fsm: FSM, _ expected: String) throws {
        let compact = CompactFSMWithStartEnd(fsm: fsm.compacted(), start: 0, ends: [2])
        let record = CompactFSMWithStartEndWithSize(fsm: compact, edgeCount: compact.fsm.edgeCount, nodeCount: compact.fsm.stateCount)
        let json = record.serializationValue().serialized()
        #expect(json == "[\(expected),3,3]")
        let restored = try CompactFSMWithStartEndWithSize.restore(JSONValue.parse(json), sharing: nil)
        #expect(restored.fsm.fsm.stateCount == compact.fsm.stateCount)
        #expect(restored.fsm.start == 0)
        #expect(restored.fsm.ends == [2])
        #expect(restored.serializationValue().serialized() == json)
    }

    /// test_thread_pool.cc FunctionalTest runs a batch of tasks on the pool; the Swift pool is the
    /// compiler's parallel mask computation, whose results must not depend on the thread count.
    @Test func parallelCompilationMatchesSerial() throws {
        let info = try TokenizerInfo(encodedVocab: ["{", "}", "\"", "a", "1", ",", ":", " ", "[", "]", "true", "null", "\"a\":", "12", "</s>"],
                                     stopTokenIDs: [14])
        let serial = GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: false)
        let parallel = GrammarCompiler(tokenizerInfo: info, maxThreads: 8, cacheEnabled: false)
        #expect(try serial.compile(.builtinJSON).serializedJSON == parallel.compile(.builtinJSON).serializedJSON)
    }
}
