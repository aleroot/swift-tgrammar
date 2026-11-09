// Port of xgrammar's tests/python/test_token_edge.py: `Token(...)` / `ExcludeToken(...)` edges in
// EBNF parsing and printing, token-level acceptance and masks, `TokenTagDispatch` triggers and
// excludes, lookahead over token edges, nested dispatch end-to-end walks, rollback, and the
// structural-tag token formats (`token`, `exclude_token`, `any_tokens`, `token_triggered_tags`).

import Testing

@testable import TGrammar

@Suite("Token edges")
struct TokenEdgeTests {
    /// `"</s>"` in the test vocabularies.
    private static let stopToken: Int32 = 1

    private static func parsedWithoutNormalization(_ ebnf: String) throws -> String {
        try GrammarTesting.parseWithoutNormalization(ebnf).description
    }

    /// `_make_matcher`: a matcher over a custom vocabulary (stop tokens detected from the pieces).
    private static func matcher(_ vocab: [String], _ ebnf: String) throws -> MatcherBox {
        MatcherBox(try Upstream.matcher(try Grammar(ebnf: ebnf), try TokenizerInfo(encodedVocab: vocab)))
    }

    /// `_get_accepted`: fills the next mask and returns the allowed token ids.
    private static func accepted(_ matcher: MatcherBox) -> Set<Int32> {
        Set(matcher.nextTokenBitmask().allowedTokenIDs)
    }

    /// `_get_masked_tokens_from_bitmask` as a set.
    private static func rejected(_ matcher: MatcherBox) -> Set<Int32> {
        Set(matcher.nextTokenBitmask().maskedTokenIDs)
    }

    /// One step of upstream's `(token_id, expected)` path tables.
    private enum Step {
        /// `(None, set)`: the next mask allows exactly `set`.
        case mask(Set<Int32>)
        /// `(id, set)`: `id` is accepted and the following mask allows exactly `set`.
        case accept(Int32, Set<Int32>)
        /// `(id, False)`: `id` is rejected.
        case reject(Int32)
        /// `(id, None)`: `id` is accepted and the matcher terminates.
        case terminate(Int32)
    }

    private static func run(_ steps: [Step], on matcher: MatcherBox, sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, step) in steps.enumerated() {
            switch step {
            case .mask(let expected):
                #expect(accepted(matcher) == expected, "step \(index)", sourceLocation: sourceLocation)
            case .accept(let token, let expected):
                #expect(matcher.acceptToken(token), "step \(index): token \(token)", sourceLocation: sourceLocation)
                #expect(accepted(matcher) == expected, "step \(index): mask after \(token)", sourceLocation: sourceLocation)
            case .reject(let token):
                #expect(!matcher.acceptToken(token), "step \(index): token \(token)", sourceLocation: sourceLocation)
            case .terminate(let token):
                #expect(matcher.acceptToken(token), "step \(index): token \(token)", sourceLocation: sourceLocation)
                #expect(matcher.isTerminated, "step \(index)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: Parser / printer round trips

    @Test(arguments: [
        ("root ::= Token(1, 2, 3)\n", "root ::= ((Token(1, 2, 3)))\n"),
        ("root ::= Token(42)\n", "root ::= ((Token(42)))\n"),
        ("root ::= Token(3, 1, 2, 1, 3)\n", "root ::= ((Token(1, 2, 3)))\n"),
        ("root ::= Token(1, 2) \"hello\"\n", "root ::= ((Token(1, 2) \"hello\"))\n"),
        ("root ::= Token(1) | \"hello\"\n", "root ::= ((Token(1)) | (\"hello\"))\n"),
        ("root ::= ExcludeToken(1, 2, 3)\n", "root ::= ((ExcludeToken(1, 2, 3)))\n"),
        ("root ::= ExcludeToken(3, 1, 2, 1)\n", "root ::= ((ExcludeToken(1, 2, 3)))\n"),
    ])
    func parseAndPrint(before: String, expected: String) throws {
        #expect(try Self.parsedWithoutNormalization(before) == expected)
    }

    // MARK: accept_token

    @Test func acceptTokenBasic() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc", "dd"]
        let matcher = try Self.matcher(vocab, "root ::= Token(2, 4)\n")
        #expect(matcher.acceptToken(2))
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func acceptTokenReject() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc", "dd"]
        let matcher = try Self.matcher(vocab, "root ::= Token(2, 4)\n")
        #expect(!matcher.acceptToken(3))
        #expect(!matcher.acceptToken(5))
        #expect(matcher.acceptToken(4))
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func tokenThenString() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc"]
        let matcher = try Self.matcher(vocab, "root ::= Token(2) \"bb\"\n")
        #expect(matcher.acceptToken(2))
        #expect(matcher.acceptToken(3))
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func tokenOrString() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc"]
        let viaToken = try Self.matcher(vocab, "root ::= Token(2) | \"bb\"\n")
        #expect(viaToken.acceptToken(2))
        #expect(viaToken.acceptToken(Self.stopToken))
        #expect(viaToken.isTerminated)

        let viaString = try Self.matcher(vocab, "root ::= Token(2) | \"bb\"\n")
        #expect(viaString.acceptToken(3))
        #expect(viaString.acceptToken(Self.stopToken))
        #expect(viaString.isTerminated)
    }

    // MARK: Bitmasks

    @Test func bitmaskTokenOnly() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "aa", "bb", "cc", "dd"], "root ::= Token(2, 4)\n")
        #expect(Self.rejected(matcher) == [0, 1, 3, 5])
    }

    @Test func bitmaskTokenAndString() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "aa", "bb", "cc"], "root ::= Token(2) | \"bb\"\n")
        #expect(Self.rejected(matcher) == [0, 1, 4])
    }

    @Test func bitmaskAfterToken() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "aa", "bb", "cc"], "root ::= Token(2) \"bb\"\n")
        #expect(Self.rejected(matcher) == [0, 1, 3, 4])
        #expect(matcher.acceptToken(2))
        #expect(Self.rejected(matcher) == [0, 1, 2, 4])
    }

    @Test func tokenMultipleChoices() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "x", "y", "z", "w"], "root ::= Token(2, 3, 4) | \"w\"\n")
        #expect(Self.rejected(matcher) == [0, 1])
    }

    @Test func charThenTokenSequence() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "A", "B", "hello", "world"], "root ::= \"A\" Token(4, 5)\n")
        #expect(matcher.acceptToken(2))
        #expect(matcher.acceptToken(4))
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    // MARK: TokenTagDispatch excludes

    @Test func tokenTagDispatchExcludeNoTriggers() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "world", "blocked_1", "blocked_2"], """
            root ::= TokenTagDispatch(
              excludes=(4, 5)
            )
            """)
        for _ in 0 ..< 3 {
            #expect(Self.accepted(matcher) == [0, 1, 2, 3])
            #expect(matcher.acceptToken(2))
        }
    }

    @Test func tokenTagDispatchExcludeBasic() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "world", "bad"], """
            root ::= TokenTagDispatch(
              excludes=(4,)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3])
    }

    @Test func tokenTagDispatchRejectEnforcedByParser() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "world", "blocked"], """
            root ::= TokenTagDispatch(
              excludes=(4,)
            )
            """)
        #expect(!matcher.acceptToken(4), "parser must reject excluded token")
        #expect(matcher.acceptToken(2))
    }

    @Test func tokenTagDispatchTriggerAndExclude() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "A", "AB", "blocked"], """
            rule1 ::= "done"
            root ::= TokenTagDispatch(
              (3, rule1),
              excludes=(4,)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3])
    }

    // MARK: TokenTagDispatch triggers

    @Test func tokenTagDispatchTrigger() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "trigger_tok", "content"], """
            triggered_rule ::= Token(4)
            root ::= TokenTagDispatch(
              (3, triggered_rule)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3, 4])
        #expect(matcher.acceptToken(3))
        #expect(Self.accepted(matcher) == [4])
    }

    @Test func tokenTagDispatchMultipleTriggers() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "A", "B", "<tool>", "content"], """
            tool_body ::= Token(5)
            other_body ::= Token(5)
            root ::= TokenTagDispatch(
              (3, tool_body),
              (4, other_body)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3, 4, 5])
        #expect(matcher.acceptToken(3))
        #expect(Self.accepted(matcher) == [5])
    }

    @Test func tokenTagDispatchTriggerLoop() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "trigger", "content"], """
            body ::= Token(4)
            root ::= TokenTagDispatch(
              (3, body),
              loop_after_dispatch=true
            )
            """)
        #expect(matcher.acceptToken(3))
        #expect(matcher.acceptToken(4))
        #expect(Self.accepted(matcher) == [0, 1, 2, 3, 4])
    }

    @Test func tokenTagDispatchTriggerAndExcludeNoOverlap() {
        #expect(throws: GrammarError.self) {
            try Grammar(ebnf: """
                body ::= Token(2)
                root ::= TokenTagDispatch(
                  (3, body),
                  excludes=(3,)
                )
                """)
        }
    }

    @Test func tokenTagDispatchTriggerInBitmask() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "trigger", "content"], """
            body ::= Token(4)
            root ::= TokenTagDispatch(
              (3, body)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3, 4])
        #expect(matcher.acceptToken(3))
        #expect(Self.accepted(matcher) == [4])
    }

    @Test func tokenTagDispatchFullCombo() throws {
        let matcher = try Self.matcher(["<s>", "</s>", "hello", "B", "<tool>", "content", "blocked"], """
            tool_body ::= Token(5)
            other_body ::= Token(5)
            root ::= TokenTagDispatch(
              (3, tool_body),
              (4, other_body),
              excludes=(6,)
            )
            """)
        #expect(Self.accepted(matcher) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: Lookahead assertions over token edges

    private static func compiledRejected(_ vocab: [String], _ ebnf: String) throws -> Set<Int32> {
        let info = try TokenizerInfo(encodedVocab: vocab)
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(ebnf: ebnf)
        return rejected(MatcherBox(GrammarMatcher(compiled)))
    }

    @Test func lookaheadExactWithTokenSet() throws {
        let rejected = try Self.compiledRejected(["<s>", "</s>", "abc", "abcd", "X"], """
            rule_a ::= [a-z]+
            root ::= rule_a Token(4)
            """)
        #expect(rejected == [0, 1, 4])
    }

    @Test func lookaheadTokenSetSuffixNonemptyRejected() throws {
        let rejected = try Self.compiledRejected(["<s>", "</s>", "ab", "a", "X"], """
            rule_a ::= "a"
            root ::= rule_a Token(4)
            """)
        #expect(rejected == [0, 1, 2, 4])
    }

    @Test func lookaheadMixedCharAndToken() throws {
        let rejected = try Self.compiledRejected(["<s>", "</s>", "abc", "abc!", "X"], """
            rule_a ::= [a-z]+
            root ::= rule_a "!" Token(4)
            """)
        #expect(rejected == [0, 1, 4])
    }

    // MARK: End to end

    @Test func e2eComplex() throws {
        let vocab = [
            "<s>", "</s>", "<tool>", "<code>", "<blocked>", "hello", "he", "name", "val", "x", "y",
            "{", "}", ":", ",", "[", "]", ";", "42", "a:", "{a", "a}", "a;", "fn(", ")",
        ]
        let ebnf = """
            value ::= [a-z]+ | [0-9]+
            entry ::= [a-z]+ ":" value
            inner ::= entry (";" entry)*
            body ::= "{" inner "}" | "[" inner "]"
            tool_body ::= body ("," body)*
            arg ::= [a-z]+
            call ::= "fn(" Token(9, 10) "," arg ")"
            code_body ::= call (";" call)*
            root ::= TokenTagDispatch(
                (2, tool_body),
                (3, code_body),
                excludes=(4,)
            )
            """
        let all = Set<Int32>(0 ..< Int32(vocab.count)).subtracting([4])
        let az: Set<Int32> = [5, 6, 7, 8, 9, 10]
        let paths: [[Step]] = [
            [   // tool path: trigger -> nested char grammar with uncertainty tokens
                .mask(all),
                .accept(2, [11, 15, 20]),
                .accept(20, az.union([13, 19])),
                .accept(19, az.union([18, 21, 22])),
                .accept(18, [12, 17, 18]),
                .accept(17, az.union([19])),
                .accept(7, az.union([13, 19])),
                .accept(13, az.union([18, 21, 22])),
                .accept(8, az.union([12, 17, 21, 22])),
                .accept(12, all),
            ],
            [   // code path: trigger -> text-nested-Token grammar fn(Token,arg)
                .mask(all),
                .accept(3, [23]),
                .accept(23, [9, 10]),
                .accept(9, [14]),
                .accept(14, az),
                .accept(7, az.union([24])),
                .accept(24, all),
            ],
        ]
        for steps in paths {
            let matcher = try Self.matcher(vocab, ebnf)
            Self.run(steps, on: matcher)
            #expect(matcher.acceptToken(Self.stopToken))
            #expect(matcher.isTerminated)
        }
    }

    /// Nested TokenTagDispatch: outer excludes 4, inner excludes 5. Token 4 is rejected at the
    /// outer level but accepted inside the inner dispatch; token 5 the other way round.
    @Test func e2eNestedDispatch() throws {
        let vocab = ["<s>", "</s>", "<outer>", "<inner>", "<o_block>", "<i_block>", "hello", "world", "fn(", ")", "x", "y"]
        let ebnf = """
            leaf ::= Token(10, 11)
            inner ::= TokenTagDispatch((3, leaf), excludes=(5,))
            tool_fn ::= "fn(" inner ")"
            root ::= TokenTagDispatch((2, tool_fn), excludes=(4,))
            """
        let all = Set<Int32>(0 ..< Int32(vocab.count))
        let outer = all.subtracting([4])
        let inner = all.subtracting([1, 5])
        let paths: [[Step]] = [
            [.mask(outer), .accept(2, [8]), .accept(8, inner), .accept(6, inner), .accept(3, [10, 11]), .accept(10, inner), .accept(9, all), .terminate(1)],
            [.mask(outer), .accept(6, outer), .accept(5, outer), .reject(4), .terminate(1)],
            [.mask(outer), .reject(4)],
            [.accept(2, [8]), .accept(8, inner), .accept(4, inner), .accept(9, all), .terminate(1)],
        ]
        for steps in paths {
            Self.run(steps, on: try Self.matcher(vocab, ebnf))
        }
    }

    /// `[a-z]+ loop Token(5) [a-z]+`: token 4 is excluded from the loop and not `[a-z]+`, so it
    /// is always rejected; token 5 is excluded from the loop but accepted via `Token(5)` after it;
    /// token 0 is consumed by the loop.
    @Test func e2eNestedExcludeLoop() throws {
        let vocab = ["<s>", "</s>", "hello", "world", "###", "<END>", "foo", "done"]
        let ebnf = """
            loop ::= TokenTagDispatch(excludes=(4, 5))
            root ::= [a-z]+ loop Token(5) [a-z]+
            """
        let az: Set<Int32> = [2, 3, 6, 7]
        let loop: Set<Int32> = [0, 2, 3, 5, 6, 7]
        let steps: [Step] = [
            .mask(az), .reject(4), .accept(2, loop), .accept(0, loop), .accept(3, loop),
            .accept(5, az), .accept(7, az.union([1])), .terminate(1),
        ]
        Self.run(steps, on: try Self.matcher(vocab, ebnf))
    }

    /// Three layers: TagDispatch -> TokenTagDispatch -> TagDispatch. Token 6 (`<bad>`) is
    /// rejected by the string excludes of the outer and inner layers but accepted inside the
    /// token-based middle layer, which does not exclude it.
    @Test func e2eMixedTagAndTokenDispatch() throws {
        let vocab = ["<s>", "</s>", "<call>", "<mid>", "<skip>", "<end>", "<bad>", "hello", "world", "x", "y", "done"]
        let ebnf = """
            leaf ::= [a-z]+
            inner ::= TagDispatch(("<end>", leaf), excludes=("<bad>"))
            mid_body ::= Token(9, 10) inner
            mid ::= TokenTagDispatch((3, mid_body), excludes=(4,))
            root ::= TagDispatch(("<call>", mid), excludes=("<bad>"))
            """
        let all = Set<Int32>(0 ..< Int32(vocab.count))
        let outer = all.subtracting([6])
        let paths: [[Step]] = [
            [.mask(outer), .accept(7, outer), .accept(2, all), .accept(3, outer), .accept(9, outer), .accept(8, outer), .accept(5, outer), .accept(11, outer), .terminate(1)],
            [.mask(outer), .accept(7, outer), .accept(8, outer), .reject(6), .terminate(1)],
            [.mask(outer), .reject(6)],
            [.accept(2, all), .accept(6, all)],
            [.accept(2, all), .accept(3, outer), .accept(9, outer), .reject(6)],
            [.accept(4, outer)],
            [.accept(2, all), .accept(3, outer), .accept(9, outer), .accept(4, outer)],
        ]
        for steps in paths {
            Self.run(steps, on: try Self.matcher(vocab, ebnf))
        }
    }

    @Test func rollback() throws {
        let vocab = ["<s>", "</s>", "<tool>", "<code>", "hello", "world", "fn(", ")", "x", "y"]
        let matcher = try Self.matcher(vocab, """
            arg ::= [a-z]+
            call ::= "fn(" Token(8, 9) "," arg ")"
            root ::= TokenTagDispatch(
              (2, call),
              excludes=(3,)
            )
            """)
        let mask0 = Self.accepted(matcher)
        #expect(matcher.acceptToken(2))
        let mask1 = Self.accepted(matcher)
        #expect(matcher.acceptToken(6))
        let mask2 = Self.accepted(matcher)
        #expect(matcher.acceptToken(8))
        let mask3 = Self.accepted(matcher)

        matcher.rollback(3)
        #expect(Self.accepted(matcher) == mask0)

        #expect(matcher.acceptToken(2))
        #expect(Self.accepted(matcher) == mask1)
        #expect(matcher.acceptToken(6))
        #expect(Self.accepted(matcher) == mask2)
        #expect(matcher.acceptToken(8))
        #expect(Self.accepted(matcher) == mask3)

        // Rollback 2, then continue on a different path.
        matcher.rollback(2)
        #expect(Self.accepted(matcher) == mask1)
        #expect(matcher.acceptToken(6))
        #expect(matcher.acceptToken(9))
        #expect(Self.accepted(matcher) == mask3)

        // Rollback 1 past the token edge, re-accept.
        matcher.rollback(1)
        #expect(Self.accepted(matcher) == mask2)
        #expect(matcher.acceptToken(8))
        #expect(Self.accepted(matcher) == mask3)
    }

    // MARK: Structural tags with token formats

    private static let stagVocab = [
        "<s>", "</s>", "<tool>", "<code>", "<end>", "<think>", "<think_end>", "hello", "world",
        "{", "}", "fn(", ")", "x", "y", ",", "<bad>",
    ]

    /// `_stag_matcher`: compiles the upstream structural-tag JSON over `stagVocab`.
    private static func stagMatcher(_ json: String) throws -> MatcherBox {
        let info = try TokenizerInfo(encodedVocab: stagVocab)
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(structuralFormat: try StructuralFormat(json: json))
        return MatcherBox(GrammarMatcher(compiled))
    }

    /// `_accept_tokens`.
    private static func accept(_ matcher: MatcherBox, _ tokens: [Int32], sourceLocation: SourceLocation = #_sourceLocation) {
        for token in tokens {
            #expect(matcher.acceptToken(token), "Failed to accept token \(token) (\(stagVocab[Int(token)]))", sourceLocation: sourceLocation)
        }
    }

    /// `_accept_and_stop`.
    private static func acceptAndStop(_ matcher: MatcherBox, _ tokens: [Int32], sourceLocation: SourceLocation = #_sourceLocation) {
        accept(matcher, tokens, sourceLocation: sourceLocation)
        #expect(matcher.acceptToken(stopToken), "Failed to accept stop token", sourceLocation: sourceLocation)
        #expect(matcher.isTerminated, sourceLocation: sourceLocation)
    }

    @Test func stagTokenBeginEnd() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "const_string", "value": "hello"},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.acceptAndStop(matcher, [2, 7, 4])
    }

    @Test func stagExcludeTokenBasic() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "exclude_token", "exclude_tokens": [16]},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.accept(matcher, [2])
        #expect(!matcher.acceptToken(16))  // <bad> excluded
        #expect(!matcher.acceptToken(4))  // <end> auto-excluded
        #expect(matcher.acceptToken(7))
        Self.acceptAndStop(matcher, [4])
    }

    @Test func stagAnyTokensLoop() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<think>"},
                "content": {"type": "any_tokens", "exclude_tokens": [16]},
                "end": {"type": "token", "token": "<think_end>"}
            }}
            """#)
        Self.accept(matcher, [5])
        Self.accept(matcher, [7, 8, 13, 14, 9, 10])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [0, 3, 2])
        Self.acceptAndStop(matcher, [6])
    }

    @Test func stagAnyTokensEmpty() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "any_tokens"},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.acceptAndStop(matcher, [2, 4])
    }

    @Test func stagTokenTriggeredTagsBasic() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "hello"}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "const_string", "value": "world"}, "end": {"type": "token", "token": "<end>"}}
                ],
                "exclude_tokens": [16]
            }}
            """#)
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7, 8])
        Self.accept(matcher, [2, 7, 4])
        Self.accept(matcher, [13, 14])
        Self.accept(matcher, [3, 8, 4])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagTokenTriggeredStopAfterFirst() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "x"}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "const_string", "value": "y"}, "end": {"type": "token", "token": "<end>"}}
                ],
                "stop_after_first": true
            }}
            """#)
        Self.accept(matcher, [7])
        Self.acceptAndStop(matcher, [2, 13, 4])
    }

    @Test func stagTokenTriggeredAtLeastOne() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "x"}, "end": {"type": "token", "token": "<end>"}}
                ],
                "at_least_one": true,
                "stop_after_first": true
            }}
            """#)
        // Must start with the trigger; free tokens are not accepted.
        Self.acceptAndStop(matcher, [2, 13, 4])
    }

    @Test func stagNestedTokenTagsWithAnyTokens() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "any_tokens", "exclude_tokens": [16]}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "sequence", "elements": [
                        {"type": "exclude_token", "exclude_tokens": [16]},
                        {"type": "const_string", "value": "x"}
                    ]}, "end": {"type": "token", "token": "<end>"}}
                ],
                "exclude_tokens": [16]
            }}
            """#)
        Self.accept(matcher, [7, 8])
        Self.accept(matcher, [2, 9, 10, 13, 14, 7, 4])
        Self.accept(matcher, [14])
        Self.accept(matcher, [3, 7, 13, 4])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagSequenceOfTokenFormats() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "sequence",
                "elements": [
                    {"type": "token", "token": "<tool>"},
                    {"type": "const_string", "value": "fn("},
                    {"type": "exclude_token", "exclude_tokens": [16, 4]},
                    {"type": "const_string", "value": ")"},
                    {"type": "token", "token": "<end>"}
                ]
            }}
            """#)
        Self.accept(matcher, [2])
        Self.accept(matcher, [11])
        #expect(!matcher.acceptToken(16))
        #expect(!matcher.acceptToken(4))
        Self.accept(matcher, [7])
        Self.accept(matcher, [12])
        Self.acceptAndStop(matcher, [4])
    }

    @Test func stagOrTokenAndStringPaths() throws {
        let json = #"""
            {"type": "structural_tag", "format": {
                "type": "or",
                "elements": [
                    {"type": "sequence", "elements": [
                        {"type": "token", "token": "<tool>"},
                        {"type": "const_string", "value": "hello"}
                    ]},
                    {"type": "const_string", "value": "world"}
                ]
            }}
            """#
        Self.acceptAndStop(try Self.stagMatcher(json), [2, 7])
        Self.acceptAndStop(try Self.stagMatcher(json), [8])
    }

    @Test func stagComplexMultiDispatch() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "triggered_tags",
                "triggers": ["<tool>"],
                "tags": [
                    {"type": "tag", "begin": "<tool>", "content": {
                        "type": "token_triggered_tags",
                        "trigger_tokens": ["<code>", "<think>"],
                        "tags": [
                            {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "any_tokens"}, "end": {"type": "token", "token": "<end>"}},
                            {"type": "tag", "begin": {"type": "token", "token": "<think>"}, "content": {"type": "any_tokens", "exclude_tokens": [16]}, "end": {"type": "token", "token": "<think_end>"}}
                        ]
                    }, "end": "<end>"}
                ]
            }}
            """#)
        Self.accept(matcher, [7, 8])
        Self.accept(matcher, [2])
        Self.accept(matcher, [13, 14])
        Self.accept(matcher, [3, 7, 8, 9, 10, 4])
        Self.accept(matcher, [7])
        Self.accept(matcher, [5, 13, 14, 7])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [6])
        Self.accept(matcher, [4])
        Self.accept(matcher, [8])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagStarOfTokenSequence() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "star",
                "content": {"type": "sequence", "elements": [
                    {"type": "token", "token": "<tool>"},
                    {"type": "const_string", "value": "x"},
                    {"type": "token", "token": "<end>"}
                ]}
            }}
            """#)
        for _ in 0 ..< 3 {
            Self.accept(matcher, [2, 13, 4])
        }
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagStarOfTokenSequenceZero() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "star",
                "content": {"type": "sequence", "elements": [
                    {"type": "token", "token": "<tool>"},
                    {"type": "const_string", "value": "x"}
                ]}
            }}
            """#)
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagMultipleTriggeredTagsRounds() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>", "<think>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "hello"}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "exclude_token", "exclude_tokens": []}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<think>"}, "content": {"type": "any_tokens"}, "end": {"type": "token", "token": "<think_end>"}}
                ]
            }}
            """#)
        Self.accept(matcher, [2, 7, 4])
        Self.accept(matcher, [13, 14, 7])
        Self.accept(matcher, [3, 8, 4])
        Self.accept(matcher, [5, 7, 8, 13, 14, 9, 10, 6])
        Self.accept(matcher, [2, 7, 4])
        Self.accept(matcher, [8])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagExcludeTokenWithStringExcludes() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "exclude_token", "exclude_tokens": ["<bad>", "<end>", "<think>"]},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.accept(matcher, [2])
        #expect(!matcher.acceptToken(16))
        #expect(!matcher.acceptToken(4))
        #expect(!matcher.acceptToken(5))
        Self.accept(matcher, [7])
        Self.acceptAndStop(matcher, [4])
    }

    @Test func stagTokenTriggeredStringTokenRefs() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "any_tokens", "exclude_tokens": ["<bad>"]}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "const_string", "value": "y"}, "end": {"type": "token", "token": "<end>"}}
                ],
                "exclude_tokens": ["<bad>"]
            }}
            """#)
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7])
        Self.accept(matcher, [2])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [8, 13, 4])
        Self.accept(matcher, [3, 14, 4])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagTagWithSequenceContentMixed() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "sequence", "elements": [
                    {"type": "token", "token": "<code>"},
                    {"type": "exclude_token", "exclude_tokens": [16]},
                    {"type": "const_string", "value": "x"},
                    {"type": "any_tokens", "exclude_tokens": [16]}
                ]},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.accept(matcher, [2])
        Self.accept(matcher, [3])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7])
        Self.accept(matcher, [13])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [8, 14, 5])
        Self.acceptAndStop(matcher, [4])
    }

    @Test func stagOrBetweenTokenTriggeredAndStringTriggered() throws {
        let json = #"""
            {"type": "structural_tag", "format": {
                "type": "or",
                "elements": [
                    {
                        "type": "token_triggered_tags",
                        "trigger_tokens": ["<tool>"],
                        "tags": [
                            {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "hello"}, "end": {"type": "token", "token": "<end>"}}
                        ],
                        "stop_after_first": true,
                        "at_least_one": true
                    },
                    {
                        "type": "triggered_tags",
                        "triggers": ["fn("],
                        "tags": [
                            {"type": "tag", "begin": "fn(", "content": {"type": "any_text"}, "end": ")"}
                        ],
                        "stop_after_first": true,
                        "at_least_one": true
                    }
                ]
            }}
            """#
        let viaToken = try Self.stagMatcher(json)
        Self.acceptAndStop(viaToken, [2, 7, 4])

        let viaString = try Self.stagMatcher(json)
        Self.accept(viaString, [11])
        Self.accept(viaString, [7, 8])
        Self.acceptAndStop(viaString, [12])
    }

    @Test func stagDeeplyNestedThreeLayers() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "triggered_tags",
                "triggers": ["fn("],
                "tags": [
                    {"type": "tag", "begin": "fn(", "content": {
                        "type": "token_triggered_tags",
                        "trigger_tokens": ["<think>", "<code>"],
                        "tags": [
                            {"type": "tag", "begin": {"type": "token", "token": "<think>"}, "content": {"type": "any_tokens", "exclude_tokens": ["<bad>"]}, "end": {"type": "token", "token": "<think_end>"}},
                            {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "exclude_token", "exclude_tokens": ["<bad>"]}, "end": {"type": "token", "token": "<end>"}}
                        ],
                        "exclude_tokens": ["<bad>"]
                    }, "end": ")"}
                ]
            }}
            """#)
        Self.accept(matcher, [7, 8])
        Self.accept(matcher, [11])
        Self.accept(matcher, [13])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [5, 7, 8, 13, 14])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [6])
        Self.accept(matcher, [14])
        Self.accept(matcher, [3])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7])
        Self.accept(matcher, [4])
        Self.accept(matcher, [12])
        Self.accept(matcher, [8])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagAnyTokensAllExcludedExceptEnd() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "any_tokens", "exclude_tokens": [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#)
        Self.accept(matcher, [2])
        Self.acceptAndStop(matcher, [4])
    }

    @Test func stagTokenTagWithOrContent() throws {
        let json = #"""
            {"type": "structural_tag", "format": {
                "type": "tag",
                "begin": {"type": "token", "token": "<tool>"},
                "content": {"type": "or", "elements": [
                    {"type": "const_string", "value": "hello"},
                    {"type": "sequence", "elements": [
                        {"type": "exclude_token", "exclude_tokens": [16]},
                        {"type": "const_string", "value": "world"}
                    ]}
                ]},
                "end": {"type": "token", "token": "<end>"}
            }}
            """#
        Self.acceptAndStop(try Self.stagMatcher(json), [2, 7, 4])

        let viaExclude = try Self.stagMatcher(json)
        Self.accept(viaExclude, [2])
        Self.accept(viaExclude, [13])
        Self.accept(viaExclude, [8])
        Self.acceptAndStop(viaExclude, [4])
    }

    @Test func stagMixedBeginEndTypes() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>", "<think>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "hello"}, "end": "<end>"},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "exclude_token", "exclude_tokens": ["<bad>"]}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<think>"}, "content": {"type": "any_tokens", "exclude_tokens": ["<bad>"]}, "end": "<think_end>"}
                ]
            }}
            """#)
        // Tag 1: token begin, string end.
        Self.accept(matcher, [2])
        Self.accept(matcher, [7])
        Self.accept(matcher, [4])
        Self.accept(matcher, [13])
        // Tag 2: token begin, token end.
        Self.accept(matcher, [3])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7])
        Self.accept(matcher, [4])
        // Tag 3: token begin, string end.
        Self.accept(matcher, [5])
        #expect(!matcher.acceptToken(16))
        Self.accept(matcher, [7, 8, 13])
        Self.accept(matcher, [6])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagRepeatedTokenTriggeredTagsDifferentTags() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>", "<code>", "<think>"],
                "tags": [
                    {"type": "tag", "begin": {"type": "token", "token": "<tool>"}, "content": {"type": "const_string", "value": "x"}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<code>"}, "content": {"type": "const_string", "value": "y"}, "end": {"type": "token", "token": "<end>"}},
                    {"type": "tag", "begin": {"type": "token", "token": "<think>"}, "content": {"type": "const_string", "value": "hello"}, "end": {"type": "token", "token": "<think_end>"}}
                ]
            }}
            """#)
        for _ in 0 ..< 3 {
            Self.accept(matcher, [2, 13, 4])
            Self.accept(matcher, [7])
            Self.accept(matcher, [3, 14, 4])
            Self.accept(matcher, [5, 7, 6])
        }
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    /// Tags with `any_tokens` content and `end: ""`: the content stops when an excluded trigger
    /// token appears and the dispatch loop re-triggers.
    @Test func stagAnyTokensExcludesAllowEmptyEnd() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>"],
                "tags": [
                    {"begin": {"type": "token", "token": "<tool>"}, "content": {"type": "any_tokens", "exclude_tokens": ["<tool>", "<bad>"]}, "end": ""}
                ]
            }}
            """#)
        Self.accept(matcher, [2, 7, 8])
        Self.accept(matcher, [2, 13, 14])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    @Test func stagAnyTokensExcludeRedispatch() throws {
        let matcher = try Self.stagMatcher(#"""
            {"type": "structural_tag", "format": {
                "type": "token_triggered_tags",
                "trigger_tokens": ["<tool>"],
                "tags": [
                    {"begin": {"type": "token", "token": "<tool>"}, "content": {"type": "any_tokens", "exclude_tokens": ["<tool>"]}, "end": ""}
                ]
            }}
            """#)
        Self.accept(matcher, [2, 7])
        Self.accept(matcher, [2, 8])
        Self.accept(matcher, [2, 13])
        #expect(matcher.acceptToken(Self.stopToken))
        #expect(matcher.isTerminated)
    }

    // MARK: Free-text regions entered mid-token (upstream #942)

    private static let nn = #"{"type": "const_string", "value": "\n\n"}"#
    private static let anyExceptEnd = #"{"type": "any_tokens", "exclude_tokens": ["<end>"]}"#
    private static let endToken = #"{"type": "token", "token": "<end>"}"#
    private static func literal(_ value: String) -> String { #"{"type": "const_string", "value": "\#(value)"}"# }
    private static func or(_ elements: String...) -> String { #"{"type": "or", "elements": [\#(elements.joined(separator: ", "))]}"# }
    //                                       0      1       2         3        4         5           6     7     8      9
    private static let midTokenVocab = ["<s>", "</s>", "<tool>", "<end>", "\n\n", "\n\n\n", "hi", "<", "<hi", "\n\n\n\n"]

    /// `test_stag_free_text_region_entered_mid_token`: a token whose first bytes finish a literal
    /// is taken whole by the token-level free-text region after it.
    @Test(arguments: [
        // The region is in the same rule, which cannot end before it: decided by the mask cache.
        ([nn, anyExceptEnd, endToken], Int32(5), true),
        // The region follows the rule holding the literal: decided at runtime.
        ([or(nn, literal("x")), anyExceptEnd], 5, true),
        // The region still excludes its tokens.
        ([literal("<"), anyExceptEnd], 3, false),
        ([literal("<"), anyExceptEnd], 8, true),
        // A token under an excluded one is not rejected with it: at runtime, and in the mask cache.
        ([or(nn, literal("x")), #"{"type": "any_tokens", "exclude_tokens": ["\n\n\n"]}"#], 9, true),
        ([nn, #"{"type": "any_tokens", "exclude_tokens": ["\n\n\n"]}"#, endToken], 9, true),
        // The region is in the lookahead of the rule holding the literal.
        ([or(literal("<"), nn), anyExceptEnd, endToken], 8, true),
        // A Token edge is not a free-text region: a token begin or a trigger starts at a token boundary.
        ([literal("<"), #"{"type": "token", "token": "<hi"}"#], 8, false),
    ])
    func stagFreeTextRegionEnteredMidToken(elements: [String], token: Int32, expected: Bool) throws {
        let info = try TokenizerInfo(encodedVocab: Self.midTokenVocab)
        let json = #"{"type": "structural_tag", "format": {"type": "sequence", "elements": [\#(elements.joined(separator: ", "))]}}"#
        let matcher = MatcherBox(GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(structuralFormat: try StructuralFormat(json: json))))
        #expect(Self.accepted(matcher).contains(token) == expected)
        #expect(matcher.acceptToken(token) == expected)
    }

    /// `test_token_edge_in_lookahead_entered_mid_token`.
    @Test(arguments: [
        // The content rule's lookahead is the region itself: (=(ExcludeToken(2))) cannot be
        // scanned by bytes, so the mask cache leaves "<hi" to the parent instead of rejecting it.
        ("root ::= Token(3) x ExcludeToken(2)\nx ::= \"<\"\n", Int32(5), true),
        // A Token edge in the lookahead does not take a token from the middle.
        ("root ::= Token(3) x Token(2)\nx ::= \"<\"\n", 2, false),
    ])
    func tokenEdgeInLookaheadEnteredMidToken(grammar: String, token: Int32, expected: Bool) throws {
        let info = try TokenizerInfo(encodedVocab: ["<s>", "</s>", "<end>", "<tool>", "<", "<hi"])
        let matcher = MatcherBox(GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(ebnf: grammar)))
        #expect(matcher.acceptToken(3))
        #expect(Self.accepted(matcher).contains(token) == expected)
        #expect(matcher.acceptToken(token) == expected)
    }

    /// Token ids index per-token arrays during compilation, so an id outside the vocabulary must
    /// be rejected with an error instead of being read out of bounds.
    @Test func tokenEdgeIDOutOfVocabThrows() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c", "d"])
        let grammar = try Grammar(ebnf: "root ::= Token(2147483647) \"c\"\n")
        #expect(throws: GrammarError.self) {
            try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(grammar)
        }
    }
}
