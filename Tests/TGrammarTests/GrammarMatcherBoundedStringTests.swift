// Port of xgrammar's tests/python/test_grammar_matcher_bounded_string.py: JSON strings with
// `minLength`/`maxLength` (upstream issue #852).
//
// A length-bounded string compiles into a counted repetition of the string body. The remaining
// repetition budget lives in the parser state while the compiled token mask is shared by every
// repeat count, so the matcher has to keep rejecting a token that would push the string past its
// bound even when the token only contains characters the body accepts. These tests pin that
// behaviour and check that the mask agrees with a fresh replay of the same prefix, including
// exactly at the bound.

import Foundation
import Testing

@testable import TGrammar

@Suite("Grammar matcher (bounded strings)")
struct GrammarMatcherBoundedStringTests {
    /// Tokens that only contain characters accepted by the string body, tokens that close the
    /// string or the object, and multi-byte characters so that the bound is checked in code
    /// points rather than bytes.
    static let vocab = ["{", "}", "\"", "\"}", "\"content\": \"", "content", ":", " ", "a", "aa", "aaa", "aaaa", "b", "bb", "中", "中文", "\n"]
    static let stringStart = "{\"content\": \""

    /// Tokens that end the repetition on their last byte, tokens that end inside a code point,
    /// and tokens that run past the repetition into what follows it.
    static let exitVocab: [[UInt8]] = ["a", "aa", "aaa", "aaaa", "\"", "a\"", "aa\"", "aaa\"", "aa\",", ",", "[", "]", " ", "\n", "a\n"].map { Array($0.utf8) }
        + [[0xE4], [0x61, 0xE4], [0x61, 0x61, 0xE4], [0xE4, 0xB8, 0xAD], [0xB8, 0xAD]]

    static func tokenID(_ token: String) -> Int32 { Int32(vocab.firstIndex(of: token)!) }

    static func tokenizer() throws -> TokenizerInfo { try TokenizerInfo(encodedVocab: vocab) }
    static func exitTokenizer() throws -> TokenizerInfo { try TokenizerInfo(encodedVocab: exitVocab) }

    /// `_compile`: an object whose required `content` property is a bounded string.
    static func compile(maxLength: Int?, minLength: Int? = nil) throws -> CompiledGrammar {
        var content = "{\"type\": \"string\""
        if let maxLength { content += ", \"maxLength\": \(maxLength)" }
        if let minLength { content += ", \"minLength\": \(minLength)" }
        content += "}"
        let schema = "{\"type\": \"object\", \"properties\": {\"content\": \(content)}, \"required\": [\"content\"]}"
        return try GrammarCompiler(tokenizerInfo: tokenizer()).compile(Grammar(jsonSchema: schema))
    }

    static func compile(_ tokenizer: TokenizerInfo, schema: String) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: tokenizer).compile(Grammar(jsonSchema: schema))
    }

    static func compile(_ tokenizer: TokenizerInfo, ebnf: String) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: tokenizer).compile(ebnf: ebnf)
    }

    /// `_matcher_after`.
    static func matcher(after text: String, _ compiled: CompiledGrammar, sourceLocation: SourceLocation = #_sourceLocation) throws -> GrammarMatcher {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let accepted = matcher.acceptString(text)
        try #require(accepted, "grammar rejected the prefix \(text.debugDescription)", sourceLocation: sourceLocation)
        return matcher
    }

    /// `_allowed_token_ids`.
    static func allowedTokenIDs(_ matcher: inout GrammarMatcher) -> Set<Int32> {
        Set(matcher.nextTokenBitmask().allowedTokenIDs)
    }

    static func allowedTokenIDs(after text: String, _ compiled: CompiledGrammar, sourceLocation: SourceLocation = #_sourceLocation) throws -> Set<Int32> {
        var matcher = try matcher(after: text, compiled, sourceLocation: sourceLocation)
        return allowedTokenIDs(&matcher)
    }

    /// `_assert_mask_matches_replay`: every mask bit must match what a fresh matcher does with
    /// that token.
    static func expectMaskMatchesReplay(_ compiled: CompiledGrammar, after text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let allowed = try allowedTokenIDs(after: text, compiled, sourceLocation: sourceLocation)
        let tokenizer = compiled.tokenizerInfo
        for tokenID in 0 ..< Int32(tokenizer.vocabSize) {
            var replay = try matcher(after: text, compiled, sourceLocation: sourceLocation)
            let accepted = replay.acceptToken(tokenID)
            let piece = String(decoding: tokenizer.decodedVocab[Int(tokenID)], as: UTF8.self)
            #expect(allowed.contains(tokenID) == accepted,
                    "prefix=\(text.debugDescription) token=\(piece.debugDescription): mask=\(allowed.contains(tokenID)) accept=\(accepted)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Bounds over the synthetic object vocabulary

    /// At the bound the string may close, but no token may extend it.
    @Test(arguments: [0, 1, 2, 3, 8])
    func boundedStringRejectsTokensPastTheBound(maxLength: Int) throws {
        let compiled = try Self.compile(maxLength: maxLength)
        let allowed = try Self.allowedTokenIDs(after: Self.stringStart + String(repeating: "a", count: maxLength), compiled)
        #expect(allowed.contains(Self.tokenID("\"")), "the string must still be closable at the bound")
        for token in ["a", "aa", "aaa", "aaaa", "b", "bb"] {
            #expect(!allowed.contains(Self.tokenID(token)), "maxLength=\(maxLength) allowed \(token.debugDescription) after the bound")
        }
    }

    @Test(arguments: [
        (8, 0, "aaaa", true),
        (8, 4, "aaaa", true),
        (8, 7, "a", true),
        (8, 7, "aa", false),
        (8, 7, "aaaa", false),
        (4, 1, "aaa", true),
        (4, 1, "aaaa", false),
        (1, 0, "a", true),
        (1, 0, "aa", false),
        (2, 0, "中文", true),
        (2, 1, "中文", false),
        (2, 2, "中", false),
    ])
    func boundedStringBudgetIsCheckedInCharacters(maxLength: Int, consumed: Int, token: String, expected: Bool) throws {
        let compiled = try Self.compile(maxLength: maxLength)
        let allowed = try Self.allowedTokenIDs(after: Self.stringStart + String(repeating: "a", count: consumed), compiled)
        #expect(allowed.contains(Self.tokenID(token)) == expected)
    }

    /// `minLength` constrains when the string may close, not how many characters fit.
    @Test func minLengthDelaysTheExitButNotTheRepetition() throws {
        let compiled = try Self.compile(maxLength: 4, minLength: 2)
        var allowed = try Self.allowedTokenIDs(after: Self.stringStart, compiled)
        #expect(!allowed.contains(Self.tokenID("\"")), "the string is shorter than minLength")
        #expect(allowed.contains(Self.tokenID("aa")), "repetition must not be blocked by minLength")

        allowed = try Self.allowedTokenIDs(after: Self.stringStart + "aa", compiled)
        #expect(allowed.contains(Self.tokenID("\"")), "the string reached minLength and may close")
        #expect(allowed.contains(Self.tokenID("aa")), "the string may still grow up to maxLength")
        #expect(!allowed.contains(Self.tokenID("aaa")), "that token would exceed maxLength")
    }

    @Test(arguments: [0, 1, 2, 8])
    func maskAgreesWithAFreshReplayAtTheBound(maxLength: Int) throws {
        let compiled = try Self.compile(maxLength: maxLength)
        var prefixes = [0, 1, 2, maxLength].map { Self.stringStart + String(repeating: "a", count: min($0, maxLength)) }
        prefixes.append(Self.stringStart + String(repeating: "a", count: maxLength) + "\"")
        for text in prefixes {
            try Self.expectMaskMatchesReplay(compiled, after: text)
        }
    }

    /// Away from the bound the bound must not change which tokens are allowed. The bound is
    /// large enough that no vocabulary token can reach it from these prefixes; a shorter bound
    /// legitimately forbids the long tokens.
    @Test func unboundedAndBoundedMasksAgreeAwayFromTheBound() throws {
        let unbounded = try Self.compile(maxLength: nil)
        let bounded = try Self.compile(maxLength: 32)
        for text in [Self.stringStart, Self.stringStart + "a", Self.stringStart + "aaa"] {
            #expect(try Self.allowedTokenIDs(after: text, unbounded) == Self.allowedTokenIDs(after: text, bounded), "\(text)")
        }
    }

    @Test func stringAtTheBoundStillCompletesTheObject() throws {
        let compiled = try Self.compile(maxLength: 4)
        var matcher = try Self.matcher(after: Self.stringStart + "aaaa", compiled)
        let closed = matcher.acceptToken(Self.tokenID("\""))
        #expect(closed)
        let ended = matcher.acceptToken(Self.tokenID("}"))
        #expect(ended)
        #expect(matcher.isTerminated)
    }

    /// A 2-code-point token counts as two repetitions, not as its byte length.
    @Test func boundIsEnforcedInCodepointsForMultibyteTokens() throws {
        let compiled = try Self.compile(maxLength: 2)
        var matcher = try Self.matcher(after: Self.stringStart, compiled)
        var allowed = Self.allowedTokenIDs(&matcher)
        #expect(allowed.contains(Self.tokenID("中文")))
        #expect(allowed.contains(Self.tokenID("中")))
        let accepted = matcher.acceptToken(Self.tokenID("中文"))
        #expect(accepted)
        allowed = Self.allowedTokenIDs(&matcher)
        #expect(allowed.contains(Self.tokenID("\"")))
        #expect(!allowed.contains(Self.tokenID("中")))
        #expect(!allowed.contains(Self.tokenID("中文")))
    }

    // MARK: - Tokens that leave the repetition

    /// A token that closes the string, or ends inside a code point, consumes budget too.
    @Test(arguments: [
        #"{"type": "string", "maxLength": 3}"#,
        #"{"type": "array", "items": {"type": "string", "maxLength": 3}}"#,
        #"{"anyOf": [{"type": "string", "maxLength": 1}, {"type": "string", "maxLength": 3}]}"#,
        #"{"anyOf": [{"type": "string", "maxLength": 1}, {"type": "string"}]}"#,
        #"{"type": "string", "minLength": 2, "maxLength": 3}"#,
        #"{"type": "string", "minLength": 2}"#,
        #"{"anyOf": [{"type": "string", "minLength": 3}, {"type": "string", "minLength": 1}]}"#,
    ])
    func tokensThatLeaveTheStringRespectTheBound(schema: String) throws {
        let compiled = try Self.compile(Self.exitTokenizer(), schema: schema)
        let isArray = schema.contains(#""type": "array""#)
        let start = isArray ? "[\"" : "\""
        for consumed in 0 ..< 4 {
            try Self.expectMaskMatchesReplay(compiled, after: start + String(repeating: "a", count: consumed))
        }
        if isArray {
            try Self.expectMaskMatchesReplay(compiled, after: "[\"aaa\", \"a")
        }
    }

    @Test(arguments: [
        // What follows the repetition starts with characters of the class.
        (#"root ::= [^x]{0,3} "ab""#, ["", "a", "aa", "aaa"]),
        (#"root ::= "(" [^()]{0,3} ")" | "[" [^()]{0,3} "]""#, ["(", "(a", "[aa"]),
        // A rule that is one character class but is not only used as a repetition body.
        ("root ::= d d \"x\" | d \"y\"\nd ::= [0-9]", ["", "1"]),
        // The repetition ends its rule, so what follows it is decided by the parent.
        ("root ::= a \"!\"\na ::= \"<\" [^!]{0,3}", ["<", "<a", "<aaa"]),
        (#"root ::= "<" [^>]{0,3} ">" [a-z]*"#, ["<", "<aa", "<aaa"]),
        // Two parents of one repetition body that have done different numbers of repetitions.
        ("root ::= r | \"a\" r\nr ::= [^()]{2,4} \")\"", ["a", "aa", "aaa"]),
        ("root ::= r | \"aa\" r\nr ::= [^()]{3,} \")\"", ["a", "aa", "aab", "aaaa"]),
        // A repetition nested in a repetition.
        ("root ::= \"<\" s{1,2} \">\"\ns ::= [^<>]{2,3}", ["<", "<a", "<aa", "<aaaa"]),
        // Repetitions of one class followed by different bytes.
        (#"root ::= "(" [^()]{2,} ")" | "<" [^()]{0,3} "(""#, ["(", "(aa", "<", "<a"]),
    ])
    func countedRepetitionsInEBNFMatchTheReplay(grammar: String, prefixes: [String]) throws {
        let vocab = ["a", "aa", "aaa", "aaaa", "ab", "aab", "abab", "b", "x", "(", ")", "[", "]", "a)",
                     "a]", "aa]", "<", ">", "a>", "a>b", "!", "a!", "1", "12", "1x", "y", "1y", "d"]
        let compiled = try Self.compile(TokenizerInfo(encodedVocab: vocab), ebnf: grammar)
        for text in prefixes {
            try Self.expectMaskMatchesReplay(compiled, after: text)
        }
    }

    enum SiblingSource: Sendable { case schema(String), ebnf(String) }

    /// After a repetition the parser returns to the repeat edge, which is not a branch point.
    @Test(arguments: [
        (SiblingSource.schema(#"{"anyOf": [{"const": "aaa"}, {"type": "string", "maxLength": 2}]}"#),
         ["\"aaa\"", "\"ab\"", "\"b\""], ["\"baaa\"", "\"baa\""]),
        (SiblingSource.ebnf(#"root ::= "<" ("ab" | [^"x]{0,2} "\"")"#),
         ["<ab", "<aa\""], ["<aab", "<Zab"]),
    ])
    func countedRepetitionDoesNotContinueIntoASiblingAlternative(source: SiblingSource, accepted: [String], rejected: [String]) throws {
        let tokenizer = try TokenizerInfo(encodedVocab: ["a", "b", "Z", "\"", "<"])
        let compiled: CompiledGrammar
        let prefixes: [String]
        switch source {
        case .schema(let schema):
            compiled = try Self.compile(tokenizer, schema: schema)
            prefixes = ["\"", "\"b", "\"ba"]
        case .ebnf(let ebnf):
            compiled = try Self.compile(tokenizer, ebnf: ebnf)
            prefixes = ["<", "<a", "<aa"]
        }
        for text in accepted + rejected {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let completes = matcher.acceptString(text) && matcher.isTerminated
            #expect(completes == accepted.contains(text), "\(text)")
        }
        for text in prefixes {
            try Self.expectMaskMatchesReplay(compiled, after: text)
        }
    }

    /// Once the budget is enforced, only the repetitions of a live parent count.
    @Test(arguments: [
        ("root ::= a | b\na[max_tokens=1] ::= \"p\" [^x]{0,3} \"x\"\nb[max_tokens=2] ::= [^x]{0,3} \"x\"", "pp"),
        // Budgeted parents with different bounds or different following bytes.
        ("root ::= a | b\na[max_tokens=1] ::= [^xy]{0,2} \"x\"\nb[max_tokens=2] ::= [^xy]{0,3} \"y\"", "a"),
        ("root ::= a | b\na[max_tokens=1] ::= [^xy]{1,2} \"x\"\nb[max_tokens=2] ::= [^xy]{1,3} \"y\"", "a"),
        ("root ::= a | b\na[max_tokens=1] ::= [^xy]{0,2} \"x\" \"!\"\nb[max_tokens=2] ::= [^xy]{0,3} \"x\" \"?\"", "a"),
        // One body with the same bounds and following byte, entered from an expired and a live
        // parent: replaying from the live one must not complete into the expired one.
        ("root ::= a | b\na[max_tokens=1] ::= [^x]{2,} \"x!\"\nb ::= \"a\" [^x]{2,} \"x?\"", "a"),
        ("root ::= a | b\na[max_tokens=1] ::= [^x]{0,5} \"x!\"\nb ::= \"a\" [^x]{0,5} \"x?\"", "a"),
        // The same with a plain rule shared by two budgeted parents.
        ("root ::= a | b\na[max_tokens=1] ::= c \"x\"\nb[max_tokens=2] ::= c \"y\"\nc ::= [^xy] [^xy]?", "a"),
    ])
    func expiredParentDoesNotLendItsRepetitions(grammar: String, firstToken: String) throws {
        let vocab = ["a", "aa", "b", "ba", "\"", "a\"", "p", "pp", "x", "ax", "y", "ay", "ax!", "ax?"]
        let compiled = try Self.compile(TokenizerInfo(encodedVocab: vocab), ebnf: grammar)
        let first = Int32(try #require(vocab.firstIndex(of: firstToken)))
        for tokenID in 0 ..< Int32(vocab.count) {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let started = matcher.acceptToken(first)
            #expect(started)
            // The budget is enforced by the accept that follows a fill.
            let allowed = Self.allowedTokenIDs(&matcher).contains(tokenID)
            let accepted = matcher.acceptToken(tokenID)
            #expect(allowed == accepted, "\(vocab[Int(tokenID)])")
        }
    }

    // MARK: - Serialization

    @Test(arguments: [0, 2])
    func deserializedBoundedStringMasksMatch(minLength: Int) throws {
        let tokenizer = try Self.exitTokenizer()
        let compiled = try Self.compile(tokenizer, schema: #"{"type": "string", "minLength": \#(minLength), "maxLength": 3}"#)
        let restored = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: tokenizer)
        for consumed in 0 ..< 4 {
            let text = "\"" + String(repeating: "a", count: consumed)
            #expect(try Self.allowedTokenIDs(after: text, restored) == Self.allowedTokenIDs(after: text, compiled), "\(text)")
            try Self.expectMaskMatchesReplay(restored, after: text)
        }
    }

    @Test func deserializeRejectsAMaskForAnUnknownRule() throws {
        let tokenizer = try Self.exitTokenizer()
        let compiled = try Self.compile(tokenizer, schema: #"{"type": "string", "maxLength": 3}"#)
        let serialized = try JSONValue.parse(compiled.serializedJSON)
        // serialized["adaptive_token_mask_cache"][0][0][0] = 2**31 - 1
        var entries = try #require(serialized["adaptive_token_mask_cache"]?.array)
        var entry = try #require(entries[0].array)
        var state = try #require(entry[0].array)
        state[0] = .number(String(Int32.max))
        entry[0] = .array(state)
        entries[0] = .array(entry)
        let corrupted = serialized.replacing("adaptive_token_mask_cache", with: .array(entries)).serialized()
        #expect(throws: SerializationError.self) { try CompiledGrammar(serializedJSON: corrupted, tokenizerInfo: tokenizer) }
    }

    // MARK: - Checkpoint bitsets and listed tokens

    /// A repetition keeps a bitset only at counts where at least `repeatCheckpointTokens` (64
    /// here) tokens accumulated, and lists the rest: count 1 (26 tokens) is listed, count 2 (64)
    /// is a checkpoint, count 3 (10) listed, count 4 (70) a checkpoint, counts 6 and 9 listed.
    /// Every remaining budget, including those between checkpoints, must agree with a replay.
    @Test func checkpointBitsetsAndListedTokensMatchTheReplay() throws {
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let eight = letters.prefix(8), five = letters.prefix(5)
        var vocab = ["\"", "\"}", "{", "}", "\"content\": \"", " "]
        vocab += letters
        vocab += eight.flatMap { a in eight.map { a + $0 } }
        vocab += ["abc", "bcd", "cde", "def", "efg", "fgh", "ghi", "hij", "ijk", "jkl"]
        vocab += Array(five.flatMap { a in five.flatMap { b in five.map { "z" + a + b + $0 } } }.prefix(70))
        vocab += ["abcdef", "bcdefg", "cdefgh", "defghi", "efghij", "abcdefghi", "bcdefghij", "cdefghijk"]
        let tokenizer = try TokenizerInfo(encodedVocab: vocab)
        let schema = #"{"type": "object", "properties": {"content": {"type": "string", "maxLength": 12}}, "required": ["content"]}"#
        let compiled = try Self.compile(tokenizer, schema: schema)

        var checkpoints: [Int32] = [], listedCounts = Set<Int32>()
        compiled.maskTable.forEachMask { mask in
            guard !mask.repeatInteriorBitsets.isEmpty else { return }
            checkpoints = mask.repeatInteriorCharCounts
            listedCounts = Set(mask.repeatInteriorTokens.map(\.repetitions))
        }
        #expect(checkpoints == [2, 4])
        #expect(listedCounts == [1, 3, 6, 9])

        for consumed in [0, 3, 6, 7, 8, 9, 10, 11, 12] {
            try Self.expectMaskMatchesReplay(compiled, after: Self.stringStart + String(repeating: "a", count: consumed))
        }
    }

    /// Large vocabularies are classified against the repetition in parallel chunks; the result
    /// must not depend on the split.
    @Test func parallelRepetitionClassificationMatchesSerial() throws {
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        var vocab = ["\"", "\"}", "{", "}", "\"content\": \"", " ", "\\", "\\n"]
        vocab += letters + letters.flatMap { a in letters.map { a + $0 } }
        vocab += letters.flatMap { a in letters.flatMap { b in letters.map { a + b + $0 } } }
        vocab += letters.map { "\"" + $0 } + letters.map { $0 + "\"}" }
        // Exit tokens and small count groups (listed, not checkpointed) in both chunks.
        vocab += letters.map { $0 + "\"" } + letters.map { $0 + "bcd" } + letters.map { $0 + "cdef" }
        let tokenizer = try TokenizerInfo(encodedVocab: vocab)
        #expect(tokenizer.sortedTokens.count >= 2 * 8192)
        let schema = #"{"type": "object", "properties": {"content": {"type": "string", "maxLength": 40}}, "required": ["content"]}"#
        func repetitionData(threads: Int) throws -> [AdaptiveTokenMask] {
            let compiled = try GrammarCompiler(tokenizerInfo: tokenizer, maxThreads: threads, cacheEnabled: false).compile(Grammar(jsonSchema: schema))
            var masks: [AdaptiveTokenMask] = []
            compiled.maskTable.forEachMask { mask in if mask.hasRepeatInterior { masks.append(copy mask) } }
            return masks
        }
        let serial = try repetitionData(threads: 1), parallel = try repetitionData(threads: 8)
        #expect(serial.count == 1)
        #expect(serial.first.map { !$0.repeatExitTokens.isEmpty && !$0.repeatInteriorTokens.isEmpty } == true)
        #expect(serial == parallel)
    }

    // MARK: - Which repetitions stay counted

    /// The byte after the outer repetition does not follow the inner one, so the inner one is
    /// not turned into a counted edge that the matcher cannot take the fast path for.
    @Test func nestedRepetitionKeepsTheExpandedRepetition() throws {
        let compiled = try Self.compile(Self.exitTokenizer(), ebnf: "root ::= \"<\" s{0,2} \"\\\"\"\ns ::= [^\"]{2,3}")
        #expect(!compiled.grammar.description.contains("{2, 3}"))
    }

    /// A lazy body is flattened, which a counted edge would prevent, so it keeps the expansion.
    @Test(arguments: [
        "root ::= s \",\"\ns[lazy] ::= \"\\\"\" [^\"]{2} \"\\\"\"",
        "root ::= s \",\"\ns[lazy] ::= \"\\\"\" [^\"]{3,} \"\\\"\"",
        "root ::= s \",\"\ns[lazy] ::= \"\\\"\" [^\"]{0,} \"\\\"\"",
        "root ::= s \",\"\ns[lazy] ::= \"\\\"\" t\nt ::= [^\"]{3,} \"\\\"\"",
    ])
    func lazyRuleKeepsTheExpandedRepetition(grammar: String) throws {
        let compiled = try Self.compile(Self.exitTokenizer(), ebnf: grammar)
        for consumed in 0 ..< 3 {
            try Self.expectMaskMatchesReplay(compiled, after: "\"" + String(repeating: "a", count: consumed))
        }
    }

    /// A repetition with `lower == 0` and an upper bound stays counted next to a lazy rule.
    @Test func lazyRuleElsewhereKeepsTheCountedRepetition() throws {
        let compiled = try Self.compile(Self.exitTokenizer(), ebnf: "root ::= \"\\\"\" [^\"]{0,3} \"\\\"\" t\nt[lazy] ::= \",\"")
        #expect(compiled.grammar.description.contains("{0, 3}"))
        for consumed in 0 ..< 4 {
            try Self.expectMaskMatchesReplay(compiled, after: "\"" + String(repeating: "a", count: consumed))
        }
    }

    /// With a character budget anywhere the matcher never uses the counted fast path, so the
    /// repetition is expanded as before instead of becoming a counted edge on the slow path.
    @Test func characterBudgetGrammarKeepsTheExpandedRepetition() throws {
        let compiled = try Self.compile(Self.exitTokenizer(), ebnf: "root ::= \"\\\"\" [^\"\\\\]{0,3} \"\\\"\" | t\nt[max_chars=2] ::= [a-z]*")
        #expect(!compiled.grammar.description.contains("{0, 3}"))
        for consumed in 0 ..< 4 {
            try Self.expectMaskMatchesReplay(compiled, after: "\"" + String(repeating: "a", count: consumed))
        }
    }
}
