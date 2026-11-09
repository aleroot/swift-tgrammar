// Port of xgrammar's tests/python/test_grammar_matcher_regex.py: `Grammar(regex:)` acceptance
// and mask generation. Vocabulary-dependent cases run on locally cached vocabularies.

import Foundation
import Testing

@testable import TGrammar

@Suite("Grammar matcher (regex)")
struct GrammarMatcherRegexTests {
    @Test func simple() throws {
        let grammar = try Grammar(regex: "abc")
        #expect(try Upstream.accepts(grammar, "abc"))
        #expect(try !Upstream.accepts(grammar, "ab"))
        #expect(try !Upstream.accepts(grammar, "abcd"))
    }

    @Test(arguments: [
        ("aaa", true), ("abcbc", true), ("bcbcbcbcbc", true), ("bcbcbcbcbcbcbcb", true), ("d", false), ("aaaa", false),
    ])
    func repetition(_ input: String, _ accepted: Bool) throws {
        let grammar = try Grammar(regex: "(a|[bc]{4,}){2,3}")
        #expect(try Upstream.accepts(grammar, input) == accepted)
    }

    @Test(arguments: [
        #"abc"#, #"[abc]+"#, #"[a-z0-9]+"#, #"[^abc]+"#, #"a*b+c?"#, #"(abc|def)+"#, #"a{2,4}"#, #"\d+"#, #"\w+"#,
        #"[A-Z][a-z]*"#, #"[0-9]{3}-[0-9]{3}-[0-9]{4}"#, #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
    ])
    func regexAccept(_ regex: String) throws {
        _ = try Grammar(regex: regex)
    }

    @Test(arguments: [
        #"a{,3}"#,  // Invalid range
        #"a{3,2}"#,  // Invalid range (max < min)
        #"[z-a]"#,  // Invalid range (max < min)
        #"a++"#,  // Invalid repetition
        #"(?=a)"#,  // Lookahead not supported
        #"(?!a)"#,  // Negative lookahead not supported
    ])
    func regexRefuse(_ regex: String) {
        #expect(throws: GrammarError.self) { try Grammar(regex: regex) }
    }

    @Test(arguments: [
        // Basic patterns
        (#"abc"#, "abc", true), (#"abc"#, "def", false),
        // Character classes
        (#"[abc]+"#, "aabbcc", true), (#"[abc]+"#, "abcd", false),
        (#"[a-z0-9]+"#, "abc123", true), (#"[a-z0-9]+"#, "ABC", false),
        (#"[^abc]+"#, "def", true), (#"[^abc]+"#, "aaa", false),
        // Lazy character class
        (#"[abc]+?abc"#, "aabc", true),
        // Quantifiers
        (#"a*b+c?"#, "b", true), (#"a*b+c?"#, "aaabbc", true), (#"a*b+c?"#, "c", false),
        // Alternation
        (#"(abc|def)+"#, "abcdef", true), (#"(abc|def)+"#, "abcabc", true), (#"(abc|def)+"#, "ab", false),
        // Repetition ranges
        (#"a{2,4}"#, "aa", true), (#"a{2,4}"#, "aaaa", true), (#"a{2,4}"#, "a", false), (#"a{2,4}"#, "aaaaa", false),
        // Common patterns
        (#"\d+"#, "123", true), (#"\d+"#, "abc", false),
        (#"\w+"#, "abc123", true), (#"\w+"#, "!@#", false),
        (#"[A-Z][a-z]*"#, "Hello", true), (#"[A-Z][a-z]*"#, "hello", false),
        // Complex patterns
        (#"[0-9]{3}-[0-9]{3}-[0-9]{4}"#, "123-456-7890", true), (#"[0-9]{3}-[0-9]{3}-[0-9]{4}"#, "12-34-567", false),
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}"#, "test@email.com", true),
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}"#, "invalid.email", false),
    ])
    func advanced(_ regex: String, _ instance: String, _ accepted: Bool) throws {
        #expect(try Upstream.accepts(try Grammar(regex: regex), instance) == accepted)
    }

    // MARK: Real vocabularies

    /// Upstream runs these on Llama 3; the assertions do not depend on the vocabulary, so the
    /// first locally cached vocabulary stands in.
    static let maskVocabularies = Array(LocalTokenizers.available([.llama3, .llama2, .qwen3]).prefix(1))

    @Test(arguments: maskVocabularies, [
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}"#, "test@email.com"),
        (#"[0-9]{3}-[0-9]{3}-[0-9]{4}"#, "123-456-7890"),
    ])
    func fillNextTokenBitmask(_ model: LocalTokenizers.Model, _ regexAndInput: (String, String)) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info)
        var matcher = GrammarMatcher(try compiler.compile(try Grammar(regex: regexAndInput.0)))
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for byte in regexAndInput.1.utf8 {
            let needsMask = matcher.fillNextTokenBitmask(&mask)
            #expect(needsMask)
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted)
        }
        matcher.fillNextTokenBitmask(&mask)
        #expect(mask.allows(tokenizer.eosTokenID))
    }

    @Test(.enabled(if: !maskVocabularies.isEmpty), .enabled(if: Upstream.runsPressureTests, Upstream.pressureTestsSkipReason))
    func regexWithLargeRangeCompilation() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(Self.maskVocabularies[0]))
        let start = ContinuousClock.now
        _ = try GrammarCompiler(tokenizerInfo: tokenizer.info).compile(try Grammar(regex: #"[a-z]{100,20000}"#))
        print("[upstream] regex [a-z]{100,20000} compiled against \(tokenizer.model.rawValue) in \(ContinuousClock.now - start)")
    }

    /// The token sequence is `tokenizer.encode("/*  */")`, as produced by the Qwen2.5 tokenizer
    /// into the fixture because the package has no encoder.
    @Test(.enabled(if: LocalTokenizers.has(.qwen25)))
    func regressionLookaheadAlreadyCompleted() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(.qwen25))
        let tokens = try #require(MatcherRuntimeFixtures.upstream.recordedTokens[LocalTokenizers.Model.qwen25.rawValue]?["/*  */"])
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info, maxThreads: 1)
        var matcher = GrammarMatcher(try compiler.compile(try Grammar(regex: #"\/\*(\*+[^*\/]|[^*])*\*+\/"#)))
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for token in tokens {
            matcher.fillNextTokenBitmask(&mask)
            #expect(mask.allows(token), "token \(token) (\(String(decoding: tokenizer.info.decodedVocab[Int(token)], as: UTF8.self))) is masked")
            let accepted = matcher.acceptToken(token)
            #expect(accepted)
        }
    }
}
