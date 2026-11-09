// Port of xgrammar's tests/python/test_grammar_matcher_basic.py (the parts that do not need a
// gated Hugging Face tokenizer) plus the matcher-level tests of test_grammar_fsm_builder.py.

import Testing

@testable import TGrammar


/// Reference wrapper so `#expect` can call the matcher's mutating methods directly.
final class MatcherBox {
    var matcher: GrammarMatcher
    init(_ matcher: GrammarMatcher) { self.matcher = matcher }
    var isCompleted: Bool { matcher.isCompleted }
    var isTerminated: Bool { matcher.isTerminated }
    var stopTokenIDs: [Int32] { matcher.stopTokenIDs }
    var debugDescription: String { matcher.debugDescription }
    func acceptToken(_ id: Int32) -> Bool { matcher.acceptToken(id) }
    func acceptString(_ string: String) -> Bool { matcher.acceptString(string) }
    func acceptBytes(_ bytes: [UInt8]) -> Bool { matcher.acceptBytes(bytes) }
    func rollback(_ count: Int) { matcher.rollback(count) }
    func reset() { matcher.reset() }
    func fork() -> MatcherBox { MatcherBox(matcher) }
    func nextTokenBitmask() -> TokenBitmask { matcher.nextTokenBitmask() }
    func findJumpForwardString() -> String { matcher.findJumpForwardString() }
    /// Whether a fresh fork accepts `input` and terminates.
    func accepts(_ input: String) -> Bool {
        var copy = matcher
        return copy.acceptString(input) && copy.isTerminated
    }
}

@Suite("Grammar matcher")
struct GrammarMatcherTests {
    private static let jsonVocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", ":\"", "{", "}", ", ", "6", ":", "\n", " ", "\"a\":true"]

    /// A matcher over a tokenizer-less grammar, for string acceptance.
    private func stringMatcher(_ ebnf: String) throws -> MatcherBox {
        let tokenizerInfo = try TokenizerInfo(encodedVocab: [String]())
        let compiler = GrammarCompiler(tokenizerInfo: tokenizerInfo, cacheEnabled: false)
        return MatcherBox(GrammarMatcher(try compiler.compile(ebnf: ebnf), terminateWithoutStopToken: true))
    }

    private func matcher(_ grammar: Grammar, vocab: [String], vocabSize: Int? = nil, stopTokenIDs: [Int32]? = nil, overrideStopTokens: [Int32]? = nil, terminateWithoutStopToken: Bool = false) throws -> MatcherBox {
        let tokenizerInfo = try TokenizerInfo(encodedVocab: vocab, vocabSize: vocabSize, stopTokenIDs: stopTokenIDs)
        let compiler = GrammarCompiler(tokenizerInfo: tokenizerInfo, cacheEnabled: false)
        return MatcherBox(GrammarMatcher(try compiler.compile(grammar), stopTokenIDs: overrideStopTokens, terminateWithoutStopToken: terminateWithoutStopToken))
    }

    private func allowed(_ matcher: MatcherBox, _ vocab: [String]) -> [String] {
        let mask = matcher.nextTokenBitmask()
        return mask.allowedTokenIDs.map { vocab[Int($0)] }
    }

    // MARK: Strings

    @Test(arguments: [
        ("root ::= [^a]+", Array("bbb".utf8), true),
        ("root ::= [^a]+", Array("bba".utf8), false),
        ("root ::= [^a]+", Array("©".utf8), true),
        ("root ::= [^a]+", [0xE2, 0xA1, 0xA1], true),
        ("root ::= [^a]+", [0xE2, 0xA1, 0xA1, 0xA1], false),
        ("root ::= [^a]+", [0xE2, 0xA1, 0xE2, 0xA1], false),
    ] as [(String, [UInt8], Bool)])
    func acceptString(_ ebnf: String, _ input: [UInt8], _ accepted: Bool) throws {
        let matcher = try stringMatcher(ebnf)
        #expect(matcher.acceptBytes(input) == accepted)
    }

    @Test(arguments: ["{\"name\": \"John\"}", "{ \"name\" : \"John\" }"])
    func jsonAccepts(_ input: String) throws {
        let matcher = try stringMatcher(Grammar.builtinJSONSource)
        #expect(matcher.acceptString(input))
        #expect(matcher.isCompleted)
    }

    @Test(arguments: ["{ name: \"John\" }", "{ \"name\": \"John\" } "])
    func jsonRefuses(_ input: String) throws {
        let matcher = try stringMatcher(Grammar.builtinJSONSource)
        #expect(!(matcher.acceptString(input) && matcher.isCompleted))
    }

    @Test func debugDescription() throws {
        let matcher = try stringMatcher(Grammar.builtinJSONSource)
        for character in "{\"name\": \"John\"}" {
            #expect(matcher.acceptString(String(character)))
            #expect(!matcher.debugDescription.isEmpty)
        }
    }

    // MARK: Tokens

    @Test func tokenOperations() throws {
        let vocab = Self.jsonVocab
        let input = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\":true", "}"]
        let matcher = try matcher(.builtinJSON, vocab: vocab)
        let expected: [[String]] = [
            ["{"],
            ["\"", "}", "\n", " ", "\"a\":true"],
            ["<s>", "a", "abc", "b\"", "\"", ":\"", "{", "}", ", ", "6", ":", " "],
            ["<s>", "a", "abc", "b\"", "\"", ":\"", "{", "}", ", ", "6", ":", " "],
            [":", "\n", " ", ":\""],
            ["\"", "{", "6", "\n", " "],
            ["}", ", ", "6", "\n", " "],
            [" ", "\n", "\"", "\"a\":true"],
            [" ", "\n", "\"", "\"a\":true"],
            ["}", ", ", "\n", " "],
            ["</s>"],
        ]
        var result: [[String]] = []
        for piece in input {
            let id = Int32(vocab.firstIndex(of: piece)!)
            let tokens = allowed(matcher, vocab)
            result.append(tokens)
            #expect(tokens.contains(piece))
            #expect(matcher.acceptToken(id))
        }
        result.append(allowed(matcher, vocab))
        #expect(result.map(Set.init) == expected.map(Set.init))
    }

    @Test func rollback() throws {
        let vocab = Self.jsonVocab
        let input = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\":true", "}"].map { Int32(vocab.firstIndex(of: $0)!) }
        let matcher = try matcher(.builtinJSON, vocab: vocab)
        for pair in stride(from: 0, to: input.count, by: 2) {
            let first = input[pair], second = input[pair + 1]
            let mask1 = matcher.nextTokenBitmask()
            #expect(matcher.acceptToken(first))
            let mask2 = matcher.nextTokenBitmask()
            #expect(matcher.acceptToken(second))
            matcher.rollback(2)
            let again1 = matcher.nextTokenBitmask()
            #expect(matcher.acceptToken(first))
            let again2 = matcher.nextTokenBitmask()
            #expect(matcher.acceptToken(second))
            #expect(mask1 == again1)
            #expect(mask2 == again2)
        }
    }

    @Test func gracefulRollbackFailure() throws {
        let vocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", ":\"", "{", "}", ", ", "6", "6:", ":", "\n", " ", "\"a\":true"]
        let input = ["{", "\"", "abc", "\"", ":"].map { Int32(vocab.firstIndex(of: $0)!) }
        let matcher = try matcher(.builtinJSON, vocab: vocab)
        for id in input { #expect(matcher.acceptToken(id)) }
        // `6` is accepted but `:` is not: the partial progress must be rolled back.
        #expect(!matcher.acceptToken(Int32(vocab.firstIndex(of: "6:")!)))
        for piece in ["\"", "abc", "\"", " ", "}"] { #expect(matcher.acceptToken(Int32(vocab.firstIndex(of: piece)!))) }
    }

    @Test func reset() throws {
        let vocab = Self.jsonVocab
        let input = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\":true", "}"].map { Int32(vocab.firstIndex(of: $0)!) }
        let matcher = try matcher(.builtinJSON, vocab: vocab)
        var original: [TokenBitmask] = []
        for id in input {
            original.append(matcher.nextTokenBitmask())
            #expect(matcher.acceptToken(id))
        }
        matcher.reset()
        var afterReset: [TokenBitmask] = []
        for id in input {
            afterReset.append(matcher.nextTokenBitmask())
            #expect(matcher.acceptToken(id))
        }
        #expect(original == afterReset)
    }

    @Test func termination() throws {
        let vocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", ":\"", "{", " }", ", ", "6", ":", "\n", " ", "\"a\"", ":true"]
        let input = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\"", ":true", " }", "</s>"].map { Int32(vocab.firstIndex(of: $0)!) }
        let matcher = try matcher(.builtinJSON, vocab: vocab)
        for id in input {
            _ = matcher.nextTokenBitmask()
            #expect(matcher.acceptToken(id))
        }
        #expect(matcher.isTerminated)
        #expect(!matcher.acceptToken(0))
        matcher.rollback(2)
        #expect(!matcher.isTerminated)
        #expect(matcher.acceptToken(input[input.count - 2]))
    }

    @Test func isCompleted() throws {
        let vocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", ":\"", "{", " }", ", ", "6", ":", "\n", " ", "\"a\"", ":true"]
        let input = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\"", ":true", " }"].map { Int32(vocab.firstIndex(of: $0)!) }
        let stop = Int32(vocab.firstIndex(of: "</s>")!)

        let matcher = try matcher(.builtinJSON, vocab: vocab)
        #expect(!matcher.isCompleted)
        #expect(!matcher.isTerminated)
        for id in input { #expect(matcher.acceptToken(id)) }
        #expect(matcher.isCompleted)
        #expect(!matcher.isTerminated)
        #expect(matcher.acceptToken(stop))
        #expect(matcher.isCompleted)
        #expect(matcher.isTerminated)
        matcher.rollback(1)
        #expect(matcher.isCompleted)
        #expect(!matcher.isTerminated)
        matcher.rollback(2)
        #expect(!matcher.isCompleted)
        #expect(!matcher.isTerminated)

        let matcher2 = try self.matcher(.builtinJSON, vocab: vocab, terminateWithoutStopToken: true)
        #expect(!matcher2.isCompleted)
        #expect(!matcher2.isTerminated)
        for id in input { #expect(matcher2.acceptToken(id)) }
        #expect(matcher2.isCompleted)
        #expect(matcher2.isTerminated)
        // Completion is the termination here, so the stop token is no longer a signal (#710).
        #expect(!matcher2.nextTokenBitmask()[stop])
        #expect(!matcher2.acceptToken(stop))
    }

    // MARK: Fork

    @Test func forkInitialState() throws {
        let vocab = ["<s>", "</s>", "a", "b"]
        let original = try matcher(try Grammar(ebnf: "root ::= \"a\" \"b\""), vocab: vocab)
        let forked = original.fork()
        #expect(original.nextTokenBitmask() == forked.nextTokenBitmask())
        #expect(!original.isTerminated && !forked.isTerminated)
        #expect(original.stopTokenIDs == forked.stopTokenIDs)
    }

    @Test func forkAfterAcceptTokens() throws {
        let vocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", "{", "}", " ", ":"]
        let original = try matcher(.builtinJSON, vocab: vocab)
        for piece in ["{", "\"", "abc", "b\""] { #expect(original.acceptToken(Int32(vocab.firstIndex(of: piece)!))) }
        let forked = original.fork()
        #expect(original.nextTokenBitmask() == forked.nextTokenBitmask())
        let colon = Int32(vocab.firstIndex(of: ":")!)
        #expect(original.acceptToken(colon))
        #expect(forked.acceptToken(colon))
        original.rollback(1)
        forked.rollback(1)
        #expect(original.nextTokenBitmask() == forked.nextTokenBitmask())
    }

    @Test func forkAfterRollback() throws {
        let vocab = ["<s>", "</s>", "a", "b"]
        let original = try matcher(try Grammar(ebnf: "root ::= \"a\" \"b\""), vocab: vocab)
        #expect(original.acceptToken(2))
        #expect(original.acceptToken(3))
        original.rollback(1)
        let forked = original.fork()
        #expect(original.nextTokenBitmask() == forked.nextTokenBitmask())
        #expect(forked.nextTokenBitmask()[3])
    }

    @Test func forkWhenTerminated() throws {
        let vocab = ["<s>", "</s>", "a", "b"]
        let original = try matcher(try Grammar(ebnf: "root ::= \"a\" \"b\""), vocab: vocab)
        #expect(original.acceptToken(2))
        #expect(original.acceptToken(3))
        #expect(original.acceptToken(1))
        #expect(original.isTerminated)
        let forked = original.fork()
        #expect(forked.isTerminated)
        original.rollback(1)
        #expect(!original.isTerminated)
        #expect(forked.isTerminated)
        #expect(original.acceptToken(1))
    }

    @Test func forkIndependentState() throws {
        let vocab = ["<s>", "</s>", "a", "b", "c"]
        let original = try matcher(try Grammar(ebnf: "root ::= \"a\" (\"b\" | \"c\")"), vocab: vocab)
        #expect(original.acceptToken(2))
        let forked = original.fork()
        #expect(original.acceptToken(3))
        #expect(forked.acceptToken(4))
        #expect(forked.nextTokenBitmask().allowedTokenIDs == [1])
        #expect(original.acceptToken(1))
        #expect(forked.acceptToken(1))
        #expect(original.isTerminated)
        #expect(forked.isTerminated)
    }

    // MARK: Jump forward, vocab size, stop tokens

    @Test func jumpForwardString() throws {
        let grammar = try Grammar(ebnf: "root ::= \"abb\" | \"abbd\" | other_rule\nother_rule ::= \"a\" sub_rule \"b\"\nsub_rule ::= \"b\"\n")
        let matcher = try matcher(grammar, vocab: [])
        #expect(matcher.acceptString("a"))
        #expect(matcher.findJumpForwardString() == "bb")
    }

    /// Port of `test_get_jump_forward_string_partial_utf8` (upstream #1012).
    @Test(arguments: [
        ("root ::= \"é\" | \"è\"", ""),
        ("root ::= \"aé\" | \"aè\"", "a"),
        ("root ::= [é-ê]", ""),
        ("root ::= \"aé\"", "aé"),
    ])
    func jumpForwardStringPartialUTF8(_ ebnf: String, _ expected: String) throws {
        let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: ["é", "è", "a", "</s>"], stopTokenIDs: [3])
        #expect(matcher.findJumpForwardString() == expected)
    }

    /// Port of `test_get_jump_forward_string_after_split_character` (upstream #1012).
    @Test func jumpForwardStringAfterSplitCharacter() throws {
        let info = try TokenizerInfo(encodedVocab: [[0xC3], [0xA9], Array("a".utf8), Array("</s>".utf8)], vocabType: .raw, stopTokenIDs: [3])
        let box = MatcherBox(GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(ebnf: "root ::= \"éa\"")))
        #expect(box.findJumpForwardString() == "éa")
        #expect(box.acceptToken(0))
        // The forced bytes now start inside "é".
        #expect(box.findJumpForwardString() == "")
        #expect(box.matcher.findJumpForwardBytes() == [0xA9, 0x61])
        #expect(box.acceptToken(1))
        #expect(box.findJumpForwardString() == "a")
    }

    @Test func validUTF8PrefixLength() {
        let cases: [([UInt8], Int)] = [
            ([], 0), (Array("aé€😀".utf8), 10), ([0x61, 0xC3], 1), ([0xC0, 0x80], 0), ([0xE0, 0x80, 0x80], 0),
            ([0xED, 0xA0, 0x80], 0), ([0xF4, 0x90, 0x80, 0x80], 0), ([0xF5], 0), ([0x61, 0x80], 1),
            ([0xF0, 0x9F, 0x98], 0), ([0xEF, 0xBF, 0xBF, 0x62], 4),
        ]
        for (bytes, length) in cases { #expect(GrammarMatcher.validUTF8PrefixLength(bytes) == length, "\(bytes)") }
    }

    @Test func vocabSizePadding() throws {
        let matcher = try matcher(.builtinJSON, vocab: Self.jsonVocab, vocabSize: 64)
        let mask = matcher.nextTokenBitmask()
        #expect(mask.words.count == 2)
        #expect(mask.maskedTokenIDs == (0 ..< 64).filter { $0 != 7 }.map(Int32.init))
    }

    @Test(arguments: [[String](), ["\n", "\r", "\t", "\u{0}", "\u{1}", "\u{2}"]])
    func overrideStopTokensMaskUntilJSONComplete(_ extraVocab: [String]) throws {
        let vocab = ["</s>", "<stop>", "text", "\"}"] + extraVocab
        let matcher = try matcher(.builtinJSON, vocab: vocab, stopTokenIDs: [0], overrideStopTokens: [1])
        #expect(matcher.acceptString("{\"name\":\""))
        #expect(!matcher.isCompleted)
        var mask = matcher.nextTokenBitmask()
        #expect(!mask[1])
        #expect(mask[2])
        #expect(!matcher.acceptToken(1))
        #expect(matcher.acceptToken(2))
        #expect(matcher.acceptToken(3))
        #expect(matcher.isCompleted)
        mask = matcher.nextTokenBitmask()
        #expect(mask[1])
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
    }

    @Test func overrideStopTokensAllowedWhenGrammarComplete() throws {
        let matcher = try matcher(try Grammar(ebnf: "root ::= \"a\"*"), vocab: ["</s>", "<stop>", "a", "aa", "aaa"], stopTokenIDs: [0], overrideStopTokens: [1])
        #expect(matcher.acceptToken(2))
        #expect(matcher.isCompleted)
        #expect(matcher.nextTokenBitmask()[1])
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
    }

    // MARK: Stop tokens that are grammar terminals (upstream #710)

    /// Port of `test_stop_token_as_grammar_terminal`.
    @Test func stopTokenAsGrammarTerminal() throws {
        let matcher = try matcher(try Grammar(ebnf: #"root ::= "ok" "<|return|>""#), vocab: ["</s>", "<|return|>", "ok"],
                                  stopTokenIDs: [0], overrideStopTokens: [1])
        #expect(!matcher.nextTokenBitmask()[1])
        #expect(!matcher.acceptToken(1))
        #expect(matcher.acceptToken(2))
        #expect(matcher.nextTokenBitmask()[1])
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
        matcher.rollback(1)
        #expect(!matcher.isTerminated)
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)

        // Partial byte matches must be undone; empty tokens must not newly complete the grammar.
        for (stopText, suffix) in [("STOPx", "STOPz"), ("", "tail")] {
            let probe = try self.matcher(try Grammar(ebnf: "root ::= \"ok\" \"\(suffix)\""), vocab: ["</s>", stopText, "ok"], stopTokenIDs: [1])
            #expect(probe.acceptToken(2))
            #expect(!probe.nextTokenBitmask()[1])
            #expect(!probe.acceptToken(1))
            #expect(probe.acceptString(suffix))
            #expect(probe.isCompleted)
        }
    }

    /// The byte-alphabet shortcut of the stop-token trial must not hide terminals that only
    /// character classes (non-ASCII, negated, star) or byte strings consume.
    @Test(arguments: [
        ("root ::= \"ok\" [é-ê]", "é", true), ("root ::= \"ok\" [^a]", "z", true), ("root ::= \"ok\" [x-z]*", "zz", true),
        ("root ::= \"ok\" \"日本\"", "日本", true), ("root ::= \"ok\" [0-9]", "<s>", false), ("root ::= \"ok\" [a-c]+", "abz", false),
    ])
    func stopTokenTerminalThroughCharacterClasses(_ ebnf: String, _ stopText: String, _ expected: Bool) throws {
        let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: ["</s>", stopText, "ok"], stopTokenIDs: [1])
        #expect(matcher.acceptToken(2))
        #expect(matcher.nextTokenBitmask()[1] == expected)
        #expect(matcher.acceptToken(1) == expected)
        #expect(matcher.isTerminated == expected)
    }

    /// Port of `test_stop_token_terminal_matching_paths` (atomic-complete, atomic-then-bytes).
    @Test(arguments: [(#"root ::= "ok" Token(1)"#, true), (#"root ::= "ok" (Token(1) "tail" | "STOP")"#, false)])
    func stopTokenTerminalMatchingPaths(_ ebnf: String, _ withoutStop: Bool) throws {
        let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: ["</s>", "STOP", "ok"], stopTokenIDs: [1], terminateWithoutStopToken: withoutStop)
        #expect(matcher.acceptToken(2))
        #expect(matcher.nextTokenBitmask()[1])
        #expect(!matcher.isCompleted)
        #expect(matcher.acceptToken(1))
        #expect(matcher.isCompleted)
        #expect(matcher.isTerminated)
        #expect(!matcher.acceptToken(2))
        // Upstream's fill then raises "terminated"; here filling a terminated matcher traps.
        #expect(matcher.matcher.isStopTokenAccepted)
    }

    /// Port of `test_padded_stop_token_terminal_trial`.
    @Test func paddedStopTokenTerminalTrial() throws {
        let matcher = try matcher(try Grammar(ebnf: #"root ::= "ok""#), vocab: ["ok"], vocabSize: 2, stopTokenIDs: [], overrideStopTokens: [1])
        #expect(!matcher.nextTokenBitmask()[1])
        #expect(!matcher.acceptToken(1))
        #expect(matcher.acceptToken(0))
        #expect(matcher.nextTokenBitmask()[1])
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
    }

    /// Port of `test_stop_token_mid_token_exclude_probe`.
    @Test(arguments: [
        (#"root[capture="result"] ::= "<" (ExcludeToken(1) | "hello!")"#, "<hellX", true, true, false),
        (#"root ::= "<" ExcludeToken(1) "tail""#, "<hi", false, false, true),
        (#"root ::= "<hi" "tail""#, "<hi", false, false, true),
        ("root ::= \"<\" ExcludeToken(1) | limited \">\"\nlimited[max_chars=1] ::= \"x\"", "<hi", false, false, false),
    ])
    func stopTokenMidTokenExcludeProbe(_ ebnf: String, _ stopText: String, _ expected: Bool, _ overrideStop: Bool, _ withoutStop: Bool) throws {
        let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: [stopText, "<end>", "tail", "<eos>"], stopTokenIDs: overrideStop ? [3] : [0],
                                  overrideStopTokens: overrideStop ? [0] : nil, terminateWithoutStopToken: withoutStop)
        let initialState = matcher.debugDescription
        for _ in 0 ..< 3 {
            #expect(matcher.nextTokenBitmask()[0] == expected)
            #expect(matcher.debugDescription == initialState)
            #expect(matcher.matcher.captures().isEmpty)
        }
        #expect(matcher.acceptToken(0) == expected)
        if expected {
            #expect(matcher.isCompleted && matcher.isTerminated)
            let captures = ebnf.contains(#"capture="result""#) ? [GrammarCapture(name: "result", bytes: Array(stopText.utf8))] : []
            #expect(matcher.matcher.captures() == captures)
            matcher.rollback(1)
            #expect(matcher.debugDescription == initialState)
            #expect(matcher.matcher.captures().isEmpty)
            #expect(matcher.acceptToken(0))
            #expect(matcher.matcher.captures() == captures)
        } else {
            #expect(matcher.debugDescription == initialState)
        }
    }

    /// Port of `test_stop_token_atomic_success_blocks_mid_token_fallback`.
    @Test func stopTokenAtomicSuccessBlocksMidTokenFallback() throws {
        let matcher = try matcher(try Grammar(ebnf: #"root ::= Token(0) "tail" | "<" ExcludeToken(1)"#), vocab: ["<hi", "<end>", "tail"],
                                  stopTokenIDs: [0], terminateWithoutStopToken: true)
        let initialState = matcher.debugDescription
        #expect(!matcher.nextTokenBitmask()[0])
        #expect(!matcher.acceptToken(0))
        #expect(matcher.debugDescription == initialState)
    }

    /// Harmony's `<|call|>` ends a call and is listed among gpt-oss's stop tokens: with it as a
    /// stop token the call must still close on that token.
    @Test func harmonyCallTokenIsAlsoAStopToken() throws {
        let vocab = ["<|start|>", "<|end|>", "<|return|>", "<|call|>", "<|message|>", "<|channel|>", "<|constrain|>",
                     "commentary", " to=functions.weather", "json", "{\"city\":\"Dubai\"}", "<|endoftext|>"]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [2, 3, 11])
        let weather = ToolDefinition(name: "weather", parameters: .object(properties: [.init("city", .string(), required: true)]))
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(toolCalls: [weather], model: .harmony, choice: .required, reasoning: .disabled)
        let matcher = MatcherBox(GrammarMatcher(compiled))
        #expect(matcher.acceptString(#"<|channel|>commentary to=functions.weather<|constrain|>json<|message|>{"city":"Dubai"}"#))
        #expect(!matcher.isCompleted)
        #expect(matcher.nextTokenBitmask()[3])
        #expect(!matcher.nextTokenBitmask()[2])
        #expect(matcher.acceptToken(3))
        #expect(matcher.isTerminated)
    }

    @Test(arguments: [
        (["root ::= \"a\"", "root ::= [0-9]+", "root ::= \"ab\""], [2, 5, 2], [true, true, true]),
        (["root ::= \"a\"", "root ::= [0-9]+", "root ::= \"ab\""], [3, 2, 4], [false, false, false]),
        (["root ::= \"a\"", "root ::= [0-9]+", "root ::= \"ab\""], [2, 8, 9], [true, false, true]),
    ] as [([String], [Int32], [Bool])])
    func acceptTokenAcrossGrammars(_ grammars: [String], _ tokens: [Int32], _ expected: [Bool]) throws {
        let vocab = ["<s>", "</s>", "a", "b", "c", "1", "2", "3", "123a", "ab"]
        for (index, ebnf) in grammars.enumerated() {
            let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: vocab)
            #expect(matcher.acceptToken(tokens[index]) == expected[index], "\(ebnf) token \(tokens[index])")
        }
    }

    // MARK: From test_grammar_fsm_builder.py

    @Test(arguments: [
        ("root ::= \"a\" [0-9] \"b\"", "a[0-9]b", "a0b", 4),
        ("root ::= \"ab\" [xy] \"cd\"", "ab[xy]cd", "abxycd", 6),
        ("root ::= \"<\" [a-c]* \">\"", "<[a-c]*>", "<abc>", 5),
        ("root ::= \"<\" [^>] \">\"", "<[^>]>", "<ab>", 4),
        ("root ::= \"a\" mid \"c\"\nmid ::= \"b\" | \"x\" | \"\"", "a(b|x|)c", "abxc", 4),
        ("root ::= \"a\" [xy]{1, 3} \"z\"", "a[xy]{1,3}z", "axyz", 6),
        ("root ::= (\"a\" | \"bb\") [0-9] \"z\"", "(a|bb)[0-9]z", "ab09z", 5),
        ("root ::= \"abc\"", "abc", "abc", 4),
        ("root ::= [a-z]", "[a-z]", "az", 3),
        ("root ::= [a-b]*", "[a-b]*", "ab", 4),
    ])
    func sequenceMatchesReferenceRegex(_ ebnf: String, _ regex: String, _ alphabet: String, _ maxLength: Int) throws {
        let matcher = try stringMatcher(ebnf)
        let reference = try Regex("^(?:\(regex))$")
        let letters = Array(alphabet)
        var checked = 0
        func enumerate(_ prefix: String, _ remaining: Int) throws {
            let expected = (try? reference.wholeMatch(in: prefix)) != nil
            let actual = matcher.accepts(prefix)
            #expect(actual == expected, "\(ebnf) on \(prefix)")
            checked += 1
            if remaining == 0 { return }
            for letter in letters { try enumerate(prefix + String(letter), remaining - 1) }
        }
        try enumerate("", maxLength)
        #expect(checked > 1)
    }

    @Test func sequenceWithUTF8ByteStrings() throws {
        let matcher = try stringMatcher("root ::= \"你\" [好世] \"界\"")
        #expect(matcher.accepts("你好界"))
        #expect(matcher.accepts("你世界"))
        #expect(!matcher.accepts("你界"))
        #expect(!matcher.accepts("你好世界"))
        #expect(!matcher.accepts("好界"))
        #expect(!matcher.accepts("你好"))
    }

    @Test func nestedNegatedClassPreservesCallsAndUnicode() throws {
        let matcher = try stringMatcher("root ::= a b c\na ::= \"x\" [0-9]*\nb ::= a \"y\" | [^xyz]\nc ::= b{1,3} \"end\"")
        for value in ["xé你end", "x12x3y😀end", "xAé🙂好end", "xéx42yend"] {
            #expect(matcher.accepts(value), "\(value)")
        }
        for value in ["xéend", "xé你好😀Aend", "xéyend"] {
            #expect(!matcher.accepts(value), "\(value)")
        }
    }

    @Test(arguments: [("", [String]()), ("*", [""]), ("* \"end\"", ["end"]), (" | \"ok\"", ["ok"])])
    func emptyUnicodeComplement(_ suffix: String, _ valid: [String]) throws {
        let matcher = try stringMatcher("root ::= [^\\u0000-\\U0010FFFF]" + suffix)
        for value in valid + ["a", "\u{0}", "é", "你", "😀", "\u{10FFFF}", "你end"] {
            #expect(matcher.accepts(value) == valid.contains(value), "\(value)")
        }
    }

    @Test func longMixedSequence() throws {
        var elements: [String] = []
        var valid = ""
        for index in 0 ..< 64 {
            let literal = "s" + (index < 10 ? "0" : "") + String(index)
            elements.append("\"\(literal)\"")
            elements.append("[0-9]")
            valid += literal + String(index % 10)
        }
        let matcher = try stringMatcher("root ::= " + elements.joined(separator: " "))
        #expect(matcher.accepts(valid))
        #expect(!matcher.accepts(String(valid.dropLast())))
        #expect(!matcher.accepts(String(valid.prefix(valid.count / 2))))
        #expect(!matcher.accepts(valid + "0"))
        var characters = Array(valid)
        for position in stride(from: 0, to: characters.count, by: 17) {
            let original = characters[position]
            characters[position] = original == "x" ? "y" : "x"
            #expect(!matcher.accepts(String(characters)), "position \(position)")
            characters[position] = original
        }
    }

    @Test func recursiveRuleRefInSequence() throws {
        let matcher = try stringMatcher("root ::= \"(\" root \")\" | \"\"")
        for depth in [0, 1, 2, 8, 32] {
            #expect(matcher.accepts(String(repeating: "(", count: depth) + String(repeating: ")", count: depth)))
        }
        #expect(!matcher.accepts("("))
        #expect(!matcher.accepts("(()"))
        #expect(!matcher.accepts("())"))
    }

    @Test func largeRepetitionInSequence() throws {
        let matcher = try stringMatcher("root ::= \"a\" [xy]{2, 100} \"z\"")
        #expect(!matcher.accepts("axz"))
        #expect(matcher.accepts("axyz"))
        #expect(matcher.accepts("a" + String(repeating: "x", count: 100) + "z"))
        #expect(!matcher.accepts("a" + String(repeating: "x", count: 101) + "z"))
        #expect(!matcher.accepts("a" + String(repeating: "x", count: 50)))
    }

    @Test func tokenEdgeBetweenByteStrings() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc", "dd"]
        let matcher = try matcher(try Grammar(ebnf: "root ::= \"aa\" Token(3, 4) \"dd\"\n"), vocab: vocab)
        #expect(matcher.acceptToken(2))
        #expect(!matcher.acceptToken(5))
        #expect(matcher.acceptToken(3))
        #expect(matcher.acceptToken(5))
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
    }

    @Test func excludeTokenEdgeInSequence() throws {
        let vocab = ["<s>", "</s>", "aa", "bb", "cc", "dd"]
        let matcher = try matcher(try Grammar(ebnf: "root ::= \"aa\" ExcludeToken(3) \"dd\"\n"), vocab: vocab)
        #expect(matcher.acceptToken(2))
        #expect(!matcher.acceptToken(3))
        #expect(matcher.acceptToken(4))
        #expect(matcher.acceptToken(5))
        #expect(matcher.acceptToken(1))
        #expect(matcher.isTerminated)
    }

    @Test(arguments: [
        ("root ::= \"ab\" [0-9] \"cd\"", "ab5cd"),
        ("root ::= \"a\" mid \"c\"\nmid ::= \"b\" | \"x\" | \"\"", "axc"),
        ("root ::= \"<\" [a-c]* \">\"", "<abc>"),
        ("root ::= \"a\" [xy]{1, 3} \"z\"", "axyz"),
    ])
    func bitmaskMatchesStringAcceptance(_ ebnf: String, _ validInput: String) throws {
        let vocab = ["a", "b", "ab", "0", "5", "c", "d", "cd", "x", "y", "z", "<", ">", "bc"]
        let matcher = try matcher(try Grammar(ebnf: ebnf), vocab: vocab, terminateWithoutStopToken: true)
        var remaining = Substring(validInput)
        while true {
            let mask = matcher.nextTokenBitmask()
            for (id, piece) in vocab.enumerated() {
                let fork = matcher.fork()
                #expect(fork.acceptString(piece) == mask[id], "piece \(piece) after \(validInput.dropLast(remaining.count))")
            }
            if remaining.isEmpty { break }
            #expect(matcher.acceptString(String(remaining.removeFirst())))
        }
        #expect(matcher.isTerminated)
    }
}
