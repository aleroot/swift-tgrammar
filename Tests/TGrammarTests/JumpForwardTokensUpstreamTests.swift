import Testing
@testable import TGrammar

/// Port of upstream `tests/python/test_jump_forward_tokens.py` and
/// `tests/cpp/test_jump_forward_tokens.cc` (xgrammar #980): token jump-forward keeps accepted
/// boundaries and withholds only a prefix tail token.
@Suite("Jump-forward tokens (upstream)")
struct JumpForwardTokensUpstreamTests {
    private static func matcher(
        _ vocab: [[UInt8]], _ ebnf: String, vocabType: VocabType = .raw, stopTokenIDs: [Int32]? = nil,
        overrideStopTokens: [Int32]? = nil, terminateWithoutStopToken: Bool = false
    ) throws -> (GrammarMatcher, TokenizerInfo) {
        let info = try TokenizerInfo(encodedVocab: vocab, vocabType: vocabType, stopTokenIDs: stopTokenIDs)
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(ebnf: ebnf)
        let matcher = GrammarMatcher(compiled, stopTokenIDs: overrideStopTokens, terminateWithoutStopToken: terminateWithoutStopToken)
        return (matcher, info)
    }

    private static func bytes(_ pieces: [String]) -> [[UInt8]] { pieces.map { Array($0.utf8) } }

    struct TailCase: Sendable, CustomTestStringConvertible {
        let vocab: [[UInt8]]
        let grammar: String
        let expected: [Int32]
        init(_ vocab: [String], _ grammar: String, _ expected: [Int32]) {
            self.init(bytes: vocab.map { Array($0.utf8) }, grammar, expected)
        }
        init(bytes vocab: [[UInt8]], _ grammar: String, _ expected: [Int32]) {
            self.vocab = vocab
            self.grammar = grammar
            self.expected = expected
        }
        var testDescription: String { "\(vocab) \(grammar) -> \(expected)" }
    }

    static let tailCases: [TailCase] = [
        TailCase(["ab", "c"], #"root ::= "abc" [xy]"#, [0, 1]),
        // The prefix test is vocabulary-wide, even when "cd" is not grammar-valid.
        TailCase(["ab", "c", "cd"], #"root ::= "abc" [xy]"#, [0]),
        TailCase(["abc", "abcd"], #"root ::= "abc""#, []),
        TailCase(["abc", "abc"], #"root ::= "abc""#, [0]),
        TailCase(["abc", "abc", "abcd"], #"root ::= "abc""#, []),
        TailCase(["a", "ab", "abc", "d"], #"root ::= "abcd""#, [2, 3]),
        TailCase(["a", "ab", "c", "cd"], #"root ::= "ac""#, [0]),
        TailCase(["ab", "c", "bcx"], #"root ::= "abc" [xy]"#, [0, 1]),
        TailCase(["abc", "zabcq"], #"root ::= "abc""#, [0]),
        // Missing bytes stop tokenization; they must never be skipped.
        TailCase(["ab", "d"], #"root ::= "abcd""#, [0]),
        TailCase(["ab", "abcd", "e"], #"root ::= "abce""#, []),
        TailCase(["ab", "abc", "cd"], #"root ::= "abcd""#, [1]),
        TailCase(["b"], #"root ::= "ab""#, []),
        TailCase([], #"root ::= "a""#, []),
        TailCase(["", "a"], #"root ::= "a""#, [1]),
        TailCase(["a", "b"], "root ::= [ab]", []),
        TailCase(["a"], #"root ::= """#, []),
        TailCase(["a"], #"root ::= "a"*"#, []),
        TailCase(["ab", "c"], #"root ::= "ab" | "abc""#, [0]),
        TailCase(["a", "b"], #"root ::= Token(0) | "b""#, []),
        TailCase(["a", "b"], #"root ::= ExcludeToken(0) | "a""#, []),
        TailCase(["ab", "c", "d"], #"root ::= "ab" (Token(2) | "c")"#, [0]),
        TailCase(bytes: [[0xE4, 0xBD, 0xA0], [0xE5, 0xA5, 0xBD]], #"root ::= "你好""#, [0, 1]),
        TailCase(bytes: [[0xE4], [0xBD], [0xA0]], #"root ::= "你""#, [0, 1, 2]),
        // A forced byte prefix need not itself be valid UTF-8.
        TailCase(bytes: [[0xE4], [0xBD]], #"root ::= "你" | "佡""#, [0, 1]),
        TailCase(bytes: [[0xE4], [0xBD], [0xBD, 0xA0]], #"root ::= "你" | "佡""#, [0]),
        TailCase(bytes: [[0x00], [0x61]], #"root ::= "a""#, [1]),
        TailCase(bytes: [[0x61], [0x61, 0x00]], #"root ::= "a""#, []),
    ]

    /// Upstream `test_tail_rule`.
    @Test(arguments: tailCases)
    func tailRule(_ test: TailCase) throws {
        var (matcher, info) = try Self.matcher(test.vocab, test.grammar)
        let before = matcher.debugDescription
        #expect(matcher.findJumpForwardTokens() == test.expected)
        #expect(matcher.findJumpForwardTokens() == test.expected)
        #expect(matcher.debugDescription == before)
        for tokenID in test.expected {
            #expect(matcher.acceptToken(tokenID) == true)
            #expect(!info.decodedVocab[Int(tokenID)].isEmpty)
        }
    }

    /// Upstream `test_decoded_vocabulary`.
    @Test(arguments: [
        (["Ġhello", "!"], VocabType.byteLevel, [Int32(0), 1]),
        (["▁hello", "!"], VocabType.byteFallback, [0, 1]),
        (["<0x20>", "hello", "!"], VocabType.byteFallback, [0, 1, 2]),
    ])
    func decodedVocabulary(_ vocab: [String], _ vocabType: VocabType, _ expected: [Int32]) throws {
        let (matcher, _) = try Self.matcher(Self.bytes(vocab), #"root ::= " hello!""#, vocabType: vocabType)
        #expect(matcher.findJumpForwardTokens() == expected)
    }

    /// Upstream `test_preserves_accepted_boundary` and the C++
    /// `JumpForwardTokens.ConstQueryPreservesAcceptedBoundary`.
    @Test func preservesAcceptedBoundary() throws {
        var (matcher, _) = try Self.matcher(Self.bytes(["a", "bc", "abc", "x", "y"]), #"root ::= "abc" [xy]"#)
        #expect(matcher.acceptToken(0) == true)
        #expect(matcher.findJumpForwardTokens() == [1])
        #expect(matcher.acceptToken(1) == true)
        #expect(matcher.findJumpForwardTokens() == [])
        matcher.rollback()
        #expect(matcher.findJumpForwardTokens() == [1])
        matcher.rollback()
        #expect(matcher.findJumpForwardTokens() == [2])

        var (query, _) = try Self.matcher(Self.bytes(["a", "bc", "abc"]), #"root ::= "abc""#)
        #expect(query.acceptToken(0) == true)
        #expect(query.findJumpForwardTokens() == [1])
        #expect(query.findJumpForwardTokens() == [1])
        #expect(query.acceptToken(1) == true)
        #expect(query.isCompleted)
        #expect(query.findJumpForwardTokens().isEmpty)
        query.rollback(2)
        #expect(query.findJumpForwardTokens() == [2])
    }

    /// Upstream `test_completion_stop_tokens_and_reset`.
    @Test(arguments: [false, true])
    func completionStopTokensAndReset(_ terminateWithoutStopToken: Bool) throws {
        var (matcher, _) = try Self.matcher(
            Self.bytes(["a", "ab", ""]), #"root ::= "a""#, stopTokenIDs: [1], terminateWithoutStopToken: terminateWithoutStopToken)
        // A stop token's spelling is not an ordinary extension of "a".
        #expect(matcher.findJumpForwardTokens() == [0])
        #expect(matcher.acceptToken(0) == true)
        #expect(matcher.isCompleted)
        #expect(matcher.findJumpForwardTokens() == [])
        if !terminateWithoutStopToken {
            #expect(!matcher.isTerminated)
            #expect(matcher.acceptToken(1) == true)
        }
        #expect(matcher.isTerminated)
        #expect(matcher.findJumpForwardTokens() == [])
        matcher.reset()
        #expect(matcher.findJumpForwardTokens() == [0])
    }

    /// Upstream `test_override_stop_and_duplicate_tokens`.
    @Test func overrideStopAndDuplicateTokens() throws {
        var (matcher, _) = try Self.matcher(Self.bytes(["a", "a", "b"]), #"root ::= "ab""#, overrideStopTokens: [0])
        #expect(matcher.findJumpForwardTokens() == [1, 2])
        for tokenID: Int32 in [1, 2] { #expect(matcher.acceptToken(tokenID) == true) }
        #expect(matcher.acceptToken(0) == true)
        #expect(matcher.findJumpForwardTokens() == [])
    }

    /// Upstream `test_override_stop_is_not_a_text_extension`.
    @Test func overrideStopIsNotATextExtension() throws {
        let (matcher, _) = try Self.matcher(Self.bytes(["a", "ab"]), #"root ::= "a""#, overrideStopTokens: [1])
        #expect(matcher.findJumpForwardTokens() == [0])
    }

    /// Upstream `test_captures_masks_fork_and_serialization`.
    @Test(arguments: [false, true])
    func capturesMasksForkAndSerialization(_ roundtrip: Bool) throws {
        var info = try TokenizerInfo(encodedVocab: Self.bytes(["a", "b", "c", "cd", "x", "y", ""]), vocabSize: 32)
        var compiled = try GrammarCompiler(tokenizerInfo: info).compile(ebnf: "root ::= item [xy]\nitem[capture=\"value\"] ::= \"abc\"")
        if roundtrip {
            info = try TokenizerInfo(serializedJSON: info.serializedJSON)
            compiled = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: info)
        }
        var matcher = GrammarMatcher(compiled)
        var control = matcher.fork()
        let before = control.nextTokenBitmask()
        #expect(matcher.findJumpForwardTokens() == [0, 1])
        #expect(matcher.captures() == [])
        #expect(matcher.nextTokenBitmask() == before)
        for tokenID: Int32 in [0, 1, 2] {
            #expect(matcher.acceptToken(tokenID) == true)
            #expect(control.acceptToken(tokenID) == true)
        }
        let expected = [GrammarCapture(name: "value", bytes: Array("abc".utf8))]
        #expect(matcher.captures() == expected)
        #expect(control.captures() == expected)
        matcher.rollback(3)
        #expect(matcher.captures() == [])
        #expect(matcher.findJumpForwardTokens() == [0, 1])
    }

    /// Upstream `test_budget_enforcement_state_is_preserved`.
    @Test func budgetEnforcementStateIsPreserved() throws {
        var (matcher, _) = try Self.matcher(Self.bytes(["a", "x", "!"]), "root ::= body \"!\"\nbody[max_tokens=1] ::= [ax]*")
        #expect(matcher.acceptToken(0) == true)
        _ = matcher.nextTokenBitmask()
        var control = matcher.fork()
        #expect(matcher.findJumpForwardTokens() == [2])
        #expect(matcher.findJumpForwardTokens() == [2])
        #expect(matcher.acceptToken(1) == false)
        #expect(control.acceptToken(1) == false)
        #expect(matcher.acceptToken(2) == true)
        #expect(control.acceptToken(2) == true)
        #expect(matcher.isCompleted && control.isCompleted)
    }

    /// Upstream `test_token_edges_do_not_force_a_byte_alternative`.
    @Test func tokenEdgesDoNotForceAByteAlternative() throws {
        var (matcher, _) = try Self.matcher(Self.bytes(["a", "b"]), #"root ::= Token(0) | "b""#)
        #expect(matcher.findJumpForwardString() == "")
        #expect(matcher.findJumpForwardTokens() == [])
        #expect(matcher.acceptToken(0) == true)
    }

    /// Upstream `test_sequences_remain_grammar_valid`: many overlapping vocabularies against
    /// finite grammar languages (a seeded generator stands in for Python's `random.Random(0)`).
    @Test func sequencesRemainGrammarValid() throws {
        var rng = SplitMix64(seed: 0)
        var words: [String] = []
        for length in 1 ... 4 {
            for index in 0 ..< (1 << length) {
                words.append(String((0 ..< length).map { (index >> (length - 1 - $0)) & 1 == 0 ? "a" : "b" }))
            }
        }
        func sample(_ count: Int) -> [String] { Array(words.shuffled(using: &rng).prefix(count)) }
        for _ in 0 ..< 100 {
            let vocab = ["a", "b"] + sample(10)
            let prefix = words.randomElement(using: &rng)!
            let alternatives = sample(5).map { prefix + $0 }
            let grammar = "root ::= " + alternatives.map { "\"\($0)\"" }.joined(separator: " | ")
            var (matcher, info) = try Self.matcher(Self.bytes(vocab), grammar)
            let encoded = alternatives.map { Array($0.utf8) }
            var accepted: [UInt8] = []
            func viable(_ bytes: [UInt8]) -> Bool { encoded.contains { $0.starts(with: bytes) } }
            while !matcher.isCompleted {
                for tokenID in matcher.findJumpForwardTokens() {
                    let piece = Array(info.decodedVocab[Int(tokenID)])
                    #expect(encoded.filter { $0.starts(with: accepted) }.allSatisfy { $0.starts(with: accepted + piece) })
                    #expect(matcher.acceptToken(tokenID) == true)
                    accepted += piece
                    #expect(viable(accepted))
                }
                if matcher.isCompleted { break }
                // Choose a legal single-byte continuation when there are no more forced tokens.
                let tokenID = try #require([Int32(0), 1].first { viable(accepted + Array(info.decodedVocab[Int($0)])) })
                #expect(matcher.acceptToken(tokenID) == true)
                accepted += Array(info.decodedVocab[Int(tokenID)])
            }
            #expect(alternatives.contains(String(decoding: accepted, as: UTF8.self)))
        }
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
