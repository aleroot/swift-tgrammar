// Port of xgrammar's tests/python/test_grammar_matcher_structural_tag.py: structural tags over
// the matcher — UTF-8 delimiters, printed-grammar snapshots, TagDispatch excludes, mask
// generation on real vocabularies, and AnyText/AnyTokens length budgets.

import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TGrammar

@Suite("Grammar matcher (structural tags)")
struct GrammarMatcherStructuralTagTests {
    /// Pydantic `Schema1 { arg1: str, arg2: int }`.
    private static let schema1 = try! JSONSchema(json: #"{"properties": {"arg1": {"title": "Arg1", "type": "string"}, "arg2": {"title": "Arg2", "type": "integer"}}, "required": ["arg1", "arg2"], "title": "Schema1", "type": "object"}"#)
    /// Pydantic `Schema2 { arg3: float, arg4: List[str] }`.
    private static let schema2 = try! JSONSchema(json: #"{"properties": {"arg3": {"title": "Arg3", "type": "number"}, "arg4": {"items": {"type": "string"}, "title": "Arg4", "type": "array"}}, "required": ["arg3", "arg4"], "title": "Schema2", "type": "object"}"#)

    /// `xgr.Grammar.from_structural_tag(tags, triggers)`.
    private static func legacyTags(_ tags: [StructuralTag], triggers: [String]) -> StructuralFormat {
        .triggeredTags(triggers: triggers, tags: tags)
    }

    @Test func utf8() throws {
        let tags = [
            StructuralTag(begin: "，，", content: .jsonSchema(Self.schema1), end: "。"),
            StructuralTag(begin: "，！", content: .jsonSchema(Self.schema1), end: "。。"),
            StructuralTag(begin: "，，？", content: .jsonSchema(Self.schema1), end: "。。。"),
            StructuralTag(begin: "｜｜？", content: .jsonSchema(Self.schema1), end: "｜？｜"),
        ]
        let grammar = try Grammar(structuralFormat: Self.legacyTags(tags, triggers: ["，", "｜｜"]))
        for input in [
            #"这是无用的内容，，{"arg1": "你好，世界！", "arg2": 0}。这是无用的内容"#,
            #"这是无用的内容，！{"arg1": "こんにちは！", "arg2": 1}。。这是无用的内容"#,
            #"这是无用的内容，，？{"arg1": "안녕하세요！", "arg2": 2}。。。这是无用的内容，！{"arg1": "안녕하세요！", "arg2": 3}。。"#,
            #"这是无用的内容｜｜？{"arg1": "။စ်န, ်ပြ！", "arg2": 0}｜？｜｜｜？{"arg1": "။စ်န, ်ပြ", "arg2": 0}｜？｜"#,
        ] {
            #expect(try Upstream.accepts(grammar, input), "\(input)")
        }
    }

    /// The tail of upstream's printed grammar, before and after optimization. The JSON-schema
    /// rules above it are not compared: this converter lays them out differently (regex string
    /// rules, `root_tail` chains) while accepting the same language. Identical schemas share
    /// `root_0`, as upstream.
    static let expectedTail = #"""
    triggered_tags_group ::= (("1>" root_0 "</function>") | ("2>" root_0 "</function>"))
    triggered_tags_group_1 ::= ((">" root_1 "</function>"))
    triggered_tags ::= TagDispatch(
      ("<function=f", triggered_tags_group),
      ("<function=g", triggered_tags_group_1),
      loop_after_dispatch=true,
      excludes=()
    )
    root ::= ((triggered_tags))

    """#

    /// The printed rules whose names start with `root_`, in order.
    private static func schemaRoots(_ grammar: Grammar) -> [String] {
        grammar.description.split(separator: "\n").filter { $0.hasPrefix("root_0 ::=") || $0.hasPrefix("root_1 ::=") }.map(String.init)
    }

    private static let functionTags = [
        StructuralTag(begin: "<function=f1>", content: .jsonSchema(schema1), end: "</function>"),
        StructuralTag(begin: "<function=f2>", content: .jsonSchema(schema1), end: "</function>"),
        StructuralTag(begin: "<function=g>", content: .jsonSchema(schema2), end: "</function>"),
    ]
    // In real cases one trigger "<function=" dispatches to every tag; two triggers test that path.
    private static let functionTriggers = ["<function=f", "<function=g"]

    @Test func structuralTag() throws {
        let grammar = try Grammar(structuralFormat: Self.legacyTags(Self.functionTags, triggers: Self.functionTriggers))
        #expect(grammar.description.contains(Self.expectedTail))
        let roots = Self.schemaRoots(grammar)
        #expect(roots.count == 2)
        #expect(roots.allSatisfy { !$0.contains("(=(") })
        for input in [
            #"<function=f1>{"arg1": "abc", "arg2": 1}</function>"#,
            #"<function=g>{"arg3": 1.23, "arg4": ["a", "b", "c"]}</function>"#,
            #"<function=f2>{"arg1": "abc", "arg2": 1}</function><function=g>{"arg3": 1.23, "arg4": ["a", "b", "c"]}</function>"#,
            #"hhhh<function=g>{"arg3": 1.23, "arg4": ["a", "b", "c"]}</function>haha<function=f1>{"arg1": "abc", "arg2": 1}</function>123"#,
        ] {
            #expect(try Upstream.accepts(grammar, input), "\(input)")
        }
    }

    @Test func structuralTagCompiler() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer)
        let compiled = try compiler.compile(structuralFormat: Self.legacyTags(Self.functionTags, triggers: Self.functionTriggers))
        #expect(compiled.grammar.description.contains(Self.expectedTail))
        // Optimization infers the tag end as the lookahead of the schema root that is referenced
        // once (`root_1`); the shared `root_0` has none, as in upstream's snapshot.
        let roots = Self.schemaRoots(compiled.grammar)
        #expect(roots.count == 2)
        #expect(roots[0].hasPrefix("root_0 ::=") && !roots[0].contains("(=("))
        #expect(roots[1].hasPrefix("root_1 ::=") && roots[1].hasSuffix(#"(=("</function>"))"#))
    }

    @Test(.enabled(if: LocalTokenizers.has(.llama31)))
    func structuralTagMaskGen() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(.llama31))
        let tags = [
            StructuralTag(begin: "<function=f>", content: .jsonSchema(Self.schema1), end: "</function>"),
            StructuralTag(begin: "<function=g>", content: .jsonSchema(Self.schema2), end: "</function>"),
        ]
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info)
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: Self.legacyTags(tags, triggers: ["<function=f", "<function=g"])))
        let input = #"hhhh<function=g>{"arg3": 1.23, "arg4": ["a", "b", "c"]}</function>haha<function=f>{"arg1": "abc", "arg2": 1}</function>123"#
        let dontApplyMaskIndices: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 119, 120, 121, 122]
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for (index, byte) in input.utf8.enumerated() {
            let needsApply = matcher.fillNextTokenBitmask(&mask)
            #expect(needsApply == !dontApplyMaskIndices.contains(index), "byte \(index)")
            // This check does not support non-ASCII characters.
            if let next = tokenizer.tokenID(String(UnicodeScalar(byte))) { #expect(mask.allows(next)) }
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted)
        }
        let needsApply = matcher.fillNextTokenBitmask(&mask)
        #expect(needsApply == !dontApplyMaskIndices.contains(input.utf8.count))
        #expect(mask.allows(tokenizer.eosTokenID))
    }

    @Test func emptyTagDispatch() throws {
        let grammar = try Grammar(ebnf: "root ::= TagDispatch(\n  loop_after_dispatch=true\n)\n")
        #expect(try Upstream.accepts(grammar, "any string"))
        #expect(try Upstream.accepts(grammar, ""))
        #expect(try Upstream.accepts(grammar, "好"))

        let withExcludes = try Grammar(ebnf: "root ::= TagDispatch(\n  excludes=(\"end\"),\n  loop_after_dispatch=true\n)\n")
        #expect(try Upstream.accepts(withExcludes, "any string"))
        #expect(try Upstream.accepts(withExcludes, "好"))
        #expect(try !Upstream.accepts(withExcludes, "any stringend"))
        #expect(try !Upstream.accepts(withExcludes, "endaaa"))
    }

    /// Dense accepting states and the post-dispatch final state.
    @Test(arguments: [false, true])
    func denseTagDispatchEndStates(_ loop: Bool) throws {
        let patterns = (0 ..< 32).map { index -> String in
            let digest = Insecure.SHA1.hash(data: Data("sparse-end-\(index)".utf8))
            return "@" + digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        }
        let rules = patterns.enumerated().map { index, pattern in
            StructuralFormat.TextDispatch(pattern, .literal(String(format: "X%02d", index)))
        }
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, cacheEnabled: false)
        let compiled = try compiler.compile(structuralFormat: .dispatch(rules, loop: loop))
        func accepts(_ input: String) -> Bool {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            return matcher.acceptString(input) && matcher.isTerminated
        }
        for index in [0, 15, 31] {
            #expect(accepts("free\(patterns[index])" + String(format: "X%02d", index)))
            #expect(!accepts("free\(patterns[index])WRONG"))
        }
        let repeated = "free\(patterns[0])X00tail\(patterns[31])X31"
        if loop {
            #expect(accepts(repeated))
        } else {
            #expect(!accepts(repeated))
            #expect(!accepts("free\(patterns[0])X00tail"))
        }
    }

    /// An excluded pattern must be found even when its start lies inside an already-followed trie
    /// branch of another excluded pattern: with excludes {"bcd", "abce"}, input "abcd" follows the
    /// "abce" branch for "abc"; on 'd' the Aho-Corasick failure link must resume at "bc".
    @Test func excludesOverlappingPrefixes() throws {
        let grammar = try Grammar(ebnf: "root ::= TagDispatch(\n  excludes=(\"bcd\", \"abce\"),\n  loop_after_dispatch=true\n)\n")
        #expect(try Upstream.accepts(grammar, "abc"))
        #expect(try Upstream.accepts(grammar, "hello"))
        #expect(try !Upstream.accepts(grammar, "abcd"))
        #expect(try !Upstream.accepts(grammar, "abcdX"))
        #expect(try !Upstream.accepts(grammar, "aabce"))
        #expect(try !Upstream.accepts(grammar, "abcbcd"))

        // The same defect through a structural tag's any_text excludes, with multi-byte UTF-8
        // patterns sharing an overlapping prefix.
        let tag = try Grammar(structuralFormat: .sequence([
            .tag(.init(begin: "<think>", content: .anyText(excluding: ["｜DSML｜", "<｜end▁of▁sentence｜>"]), end: "</think>")),
            .anyText(),
        ]))
        #expect(try Upstream.accepts(tag, "<think>clean</think>x"))
        #expect(try !Upstream.accepts(tag, "<think>a ｜DSML｜ b</think>x"))
        #expect(try !Upstream.accepts(tag, "<think>a <｜DSML｜tool_calls> b</think>x"))
    }

    /// A redundant longer pattern must not weaken an exclusion, in either entry point.
    @Test(arguments: [false, true], [
        (["abc", "xabcq"], ["xabc", "xabcr", "xabcq"], ["xab", "xabxr"]),
        (["bc", "abcq", "xabcde"], ["xabc", "xabcr"], ["xab", "xabr"]),
        (["好", "x好吗"], ["x好", "x好呀"], ["x你", "你"]),
        (["｜DSML｜", "<｜DSML｜ calls>"], ["<｜DSML｜", "<｜DSML｜ callsX>"], ["<｜DS", "hello"]),
    ])
    func excludesContainedPatterns(_ reverse: Bool, _ row: ([String], [String], [String])) throws {
        let excludes = reverse ? row.0.reversed() : row.0
        let ebnf = "root ::= TagDispatch(excludes=(" + excludes.map { JSONValue.quote($0) }.joined(separator: ", ") + "), loop_after_dispatch=false)"
        let grammars = [try Grammar(ebnf: ebnf), try Grammar(structuralFormat: .anyText(excluding: excludes))]
        for grammar in grammars {
            for text in row.1 { #expect(try !Upstream.accepts(grammar, text), "\(text)") }
            for text in row.2 { #expect(try Upstream.accepts(grammar, text), "\(text)") }
        }
    }

    @Test(arguments: [["abc", "xabcq"], ["｜DSML｜", "<｜DSML｜ calls>"]])
    func containedExcludesTokenMasks(_ excludes: [String]) throws {
        let vocab = ["<eos>", "x", "a", "b", "c", "q", "r", "abc", "xabc", "xabcr", "hello", "<", "｜", "DSML", "<｜DSML｜", "<｜DSML｜ callsX>"]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [0])
        let compiled = try GrammarCompiler(tokenizerInfo: info, maxThreads: 1).compile(structuralFormat: .anyText(excluding: excludes))
        var mask = TokenBitmask(vocabSize: vocab.count)
        for prefix in ["", "x", "xa", "xab", "<", "<｜", "<｜DSML", "hello"] {
            var matcher = GrammarMatcher(compiled)
            let prefixAccepted = matcher.acceptString(prefix)
            #expect(prefixAccepted)
            matcher.fillNextTokenBitmask(&mask)
            for (tokenID, token) in vocab.enumerated() {
                let expected = tokenID == 0 || !excludes.contains { (prefix + token).contains($0) }
                #expect(mask[tokenID] == expected, "\(prefix.debugDescription) \(token.debugDescription)")
                var fork = matcher
                #expect(fork.acceptToken(Int32(tokenID)) == expected, "\(prefix.debugDescription) \(token.debugDescription)")
            }
        }
    }

    @Test(arguments: ["abc", "abcq", "xabc", "xabcq"])
    func excludesTakePrecedenceOverTrigger(_ trigger: String) throws {
        let ebnf = "root ::= TagDispatch((\"\(trigger)\", body), excludes=(\"abc\"))\nbody ::= \"!\""
        // Exact/prefix conflicts are already rejected by the EBNF parser. A trigger containing a
        // forbidden suffix must not bypass the exclusion either.
        if trigger.hasPrefix("abc") {
            #expect { try Grammar(ebnf: ebnf) } throws: { error in
                (error as? GrammarError)?.message.contains("Exclude string must not be a prefix") == true
            }
            return
        }
        #expect(try !Upstream.accepts(ebnf: ebnf, trigger + "!"))
    }

    @Test(arguments: ["abc", "xabcq"])
    func containedExcludesPreserveDispatchBodyAndTagEnd(_ end: String) throws {
        let grammar = try Grammar(ebnf: "root ::= TagDispatch((\"<tool>\", body), excludes=(\"abc\", \"xabcq\"))\nbody ::= \"abc\"")
        // Excludes constrain free text, not the dispatched rule's body.
        #expect(try Upstream.accepts(grammar, "hello<tool>abc"))
        #expect(try !Upstream.accepts(grammar, "xabcr<tool>abc"))
        let tag = try Grammar(structuralFormat: .tag(.init(begin: "<think>", content: .anyText(excluding: ["abc", "xabcq"]), end: .text(end))))
        // The enclosing tag still consumes its delimiter outside the AnyText rule.
        #expect(try Upstream.accepts(tag, "<think>hello" + end))
        #expect(try !Upstream.accepts(tag, "<think>xabcr" + end))
    }

    // MARK: Real vocabularies

    /// Upstream compiles against DeepSeek-V3's (and, for the pressure test, Llama 3.1's)
    /// vocabulary; the assertion (compilation succeeds) does not depend on it, so the first cached
    /// vocabulary is used, smallest first.
    static let anyVocabulary = LocalTokenizers.available([.llama2, .llama3, .qwen3])

    @Test(.enabled(if: !anyVocabulary.isEmpty))
    func utf8StructuralTagBeginEnd() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(Self.anyVocabulary[0]))
        let structures = [StructuralTag(begin: "<｜tool▁calls▁begin｜>", content: .jsonSchema(.any), end: "<｜tool▁calls▁end｜>")]
        _ = try GrammarCompiler(tokenizerInfo: tokenizer.info).compile(structuralFormat: Self.legacyTags(structures, triggers: ["<｜tool▁calls▁begin｜>"]))
    }

    /// 128 concurrent compilations of growing concatenated grammars through one compiler.
    @Test(.enabled(if: !anyVocabulary.isEmpty), .enabled(if: Upstream.runsPressureTests, Upstream.pressureTestsSkipReason))
    func pressureStructuralTag() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(Self.anyVocabulary[0]))
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info, maxThreads: 1)
        let schema = try JSONSchema(json: #"{"type": "object", "properties": {"arg": {"type": "string"}}}"#)
        let tagGrammar = try Grammar(structuralFormat: Self.legacyTags([.init(begin: "start", content: .jsonSchema(schema), end: "end")], triggers: ["start"]))
        let startGrammar = try Grammar(ebnf: "root ::= [a-z] root | [a-z]")
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            var grammar = startGrammar
            for _ in 0 ..< index { grammar = Grammar.concatenating([grammar, startGrammar]) }
            let final = Grammar.concatenating([grammar, tagGrammar])
            if (try? compiler.compile(final)) == nil { failures.withLock { $0 += 1 } }
        }
        #expect(failures.withLock { $0 } == 0)
    }

    /// Upstream measures these TagDispatch scenarios on Llama 3.1 token streams; the token ids
    /// here come from the Qwen3 tokenizer and are stored in the fixture. Every token must be
    /// allowed and accepted.
    @Test(.enabled(if: LocalTokenizers.has(.qwen3) && MatcherRuntimeFixtures.upstream.recordedTokens[LocalTokenizers.Model.qwen3.rawValue] != nil),
          arguments: MatcherRuntimeFixtures.upstream.tagDispatchScenarios)
    func tagDispatchPerf(_ scenario: MatcherRuntimeFixtures.TagDispatchScenario) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(.qwen3))
        let recorded = try #require(MatcherRuntimeFixtures.upstream.recordedTokens[LocalTokenizers.Model.qwen3.rawValue])
        let tokens = try #require(recorded[scenario.input])
        let grammar = try Grammar(ebnf: scenario.ebnf)
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info, cacheEnabled: false)
        let compileStart = ContinuousClock.now
        let compiled = try compiler.compile(grammar)
        let compileTime = ContinuousClock.now - compileStart
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        var maskTime = Duration.zero, acceptTime = Duration.zero
        for token in tokens {
            var start = ContinuousClock.now
            matcher.fillNextTokenBitmask(&mask)
            maskTime += ContinuousClock.now - start
            #expect(mask.allows(token), "token \(token) (\(String(decoding: tokenizer.info.decodedVocab[Int(token)], as: UTF8.self).debugDescription)) is masked")
            start = ContinuousClock.now
            let accepted = matcher.acceptToken(token)
            acceptTime += ContinuousClock.now - start
            #expect(accepted, "token \(token) (\(String(decoding: tokenizer.info.decodedVocab[Int(token)], as: UTF8.self).debugDescription)) rejected")
        }
        print("[upstream] \(scenario.id): \(tokens.count) tokens, compile \(compileTime), mask \(maskTime / tokens.count)/token, accept \(acceptTime / tokens.count)/token")
    }

    // MARK: AnyText / AnyTokens length budgets

    private static let budgetVocab = ["<think>", "a", "b", "c", "de", "中", "a</", "</", "think>", "<eos>"]
    private static func budgetTokenID(_ token: String) -> Int32 { Int32(budgetVocab.firstIndex(of: token)!) }
    private static let budgetTokenizer = try! TokenizerInfo(encodedVocab: budgetVocab, stopTokenIDs: [budgetTokenID("<eos>")])

    private static func compileAnyTextBudget(maxTokens: Int? = nil, maxChars: Int? = nil, compiler: GrammarCompiler? = nil) throws -> CompiledGrammar {
        let compiler = compiler ?? GrammarCompiler(tokenizerInfo: budgetTokenizer, cacheEnabled: false)
        let content = StructuralFormat.anyText(excluding: ["</think>"], maxTokens: maxTokens, maxCharacters: maxChars)
        return try compiler.compile(structuralFormat: .tag(.init(begin: "<think>", content: content, end: "</think>")))
    }

    /// Every token must be allowed by the mask and accepted; the result is completion.
    private static func budgetAccepts(_ compiled: CompiledGrammar, _ tokens: String...) -> Bool {
        var matcher = GrammarMatcher(compiled)
        var mask = TokenBitmask(vocabSize: budgetVocab.count)
        for token in tokens {
            matcher.fillNextTokenBitmask(&mask)
            guard mask.allows(budgetTokenID(token)), matcher.acceptToken(budgetTokenID(token)) else { return false }
        }
        return matcher.isCompleted
    }

    private static func budgetMaskAllows(_ matcher: inout GrammarMatcher, _ token: String) -> Bool {
        matcher.nextTokenBitmask().allows(budgetTokenID(token))
    }

    private static func budgetMaskAllows(_ compiled: CompiledGrammar, _ prefix: [String], _ token: String) -> Bool {
        var matcher = GrammarMatcher(compiled)
        for prefixToken in prefix {
            let accepted = matcher.acceptToken(budgetTokenID(prefixToken))
            #expect(accepted)
        }
        return budgetMaskAllows(&matcher, token)
    }

    @Test func anyTextMaxTokensForcesMultitokenEnd() throws {
        let compiled = try Self.compileAnyTextBudget(maxTokens: 2)
        #expect(Self.budgetAccepts(compiled, "<think>", "a", "b", "</", "think>"))
        #expect(Self.budgetAccepts(compiled, "<think>", "a", "</", "think>"))
        #expect(Self.budgetAccepts(compiled, "<think>", "a", "a</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "a", "b", "c", "</", "think>"))
        #expect(Self.budgetMaskAllows(compiled, ["<think>", "a", "b"], "</"))
        #expect(!Self.budgetMaskAllows(compiled, ["<think>", "a", "b"], "a"))
        #expect(!Self.budgetMaskAllows(compiled, ["<think>", "a", "b"], "<eos>"))
    }

    @Test func anyTextZeroTokenBudgetForcesImmediateEnd() throws {
        let compiled = try Self.compileAnyTextBudget(maxTokens: 0)
        #expect(Self.budgetAccepts(compiled, "<think>", "</", "think>"))
        #expect(Self.budgetMaskAllows(compiled, ["<think>"], "</"))
        #expect(!Self.budgetMaskAllows(compiled, ["<think>"], "a"))

        let charCompiled = try Self.compileAnyTextBudget(maxChars: 0)
        #expect(Self.budgetAccepts(charCompiled, "<think>", "</", "think>"))
        #expect(!Self.budgetMaskAllows(charCompiled, ["<think>"], "a"))
    }

    @Test func anyTextMaxTokensRollbackAndFork() throws {
        let compiled = try Self.compileAnyTextBudget(maxTokens: 2)
        var matcher = GrammarMatcher(compiled)
        var accepted = matcher.acceptToken(Self.budgetTokenID("<think>"))
        #expect(accepted)
        accepted = matcher.acceptToken(Self.budgetTokenID("a"))
        #expect(accepted)
        var forked = matcher.fork()

        accepted = matcher.acceptToken(Self.budgetTokenID("b"))
        #expect(accepted)
        #expect(!Self.budgetMaskAllows(&matcher, "c"))
        matcher.rollback(1)
        #expect(Self.budgetMaskAllows(&matcher, "c"))
        accepted = matcher.acceptToken(Self.budgetTokenID("c"))
        #expect(accepted)

        accepted = forked.acceptToken(Self.budgetTokenID("c"))
        #expect(accepted)
        #expect(!Self.budgetMaskAllows(&forked, "b"))
    }

    @Test func anyTextMaxCharsCountsCodepoints() throws {
        let compiled = try Self.compileAnyTextBudget(maxChars: 3)
        #expect(Self.budgetAccepts(compiled, "<think>", "de", "a", "</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "de", "de", "</", "think>"))
        #expect(Self.budgetAccepts(compiled, "<think>", "中", "中", "中", "</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "中", "中", "中", "中", "</", "think>"))
        #expect(Self.budgetMaskAllows(compiled, ["<think>", "a", "b"], "a"))
        #expect(!Self.budgetMaskAllows(compiled, ["<think>", "a", "b"], "de"))

        let grammar = compiled.grammar
        #expect(try Upstream.accepts(grammar, "<think>中中中</think>"))
        #expect(try !Upstream.accepts(grammar, "<think>中中中中</think>"))
    }

    @Test func anyTextTokenAndCharacterBudgetsCombine() throws {
        let compiled = try Self.compileAnyTextBudget(maxTokens: 2, maxChars: 3)
        #expect(Self.budgetAccepts(compiled, "<think>", "de", "a", "</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "a", "b", "c", "</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "de", "de", "</", "think>"))
    }

    @Test func anyTextBudgetsAreIndependentPerFormat() throws {
        func thinkTag(maxTokens: Int) -> StructuralFormat {
            .tag(.init(begin: "<think>", content: .anyText(maxTokens: maxTokens), end: "</think>"))
        }
        let compiler = GrammarCompiler(tokenizerInfo: Self.budgetTokenizer, cacheEnabled: false)
        let compiled = try compiler.compile(structuralFormat: .sequence([thinkTag(maxTokens: 1), thinkTag(maxTokens: 2)]))
        #expect(Self.budgetAccepts(compiled, "<think>", "a", "</", "think>", "<think>", "a", "b", "</", "think>"))
        #expect(!Self.budgetAccepts(compiled, "<think>", "a", "b", "</", "think>", "<think>", "a", "</", "think>"))
    }

    @Test func anyTextMaxTokensInt32DoesNotOverflowAfterPrefix() throws {
        let info = try TokenizerInfo(encodedVocab: ["prefix", "<think>", "a", "</think>", "<eos>"], stopTokenIDs: [4])
        let format = StructuralFormat.sequence([
            .literal("prefix"),
            .tag(.init(begin: "<think>", content: .anyText(maxTokens: Int(Int32.max)), end: "</think>")),
        ])
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(structuralFormat: format)
        var matcher = GrammarMatcher(compiled)
        var accepted = matcher.acceptToken(0)
        #expect(accepted)
        accepted = matcher.acceptToken(1)
        #expect(accepted)
        #expect(matcher.debugDescription.contains("budget_deadline=2147483647"))
    }

    @Test func anyTokensMaxTokensForcesTokenEnd() throws {
        let vocab = ["<begin>", "x", "y", "<end>", "<eos>"]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [4])
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(structuralFormat:
            .tag(.init(begin: .token(0), content: .anyTokens(maxTokens: 2), end: .token(3))))
        var matcher = GrammarMatcher(compiled)
        for token: Int32 in [0, 1, 2] {
            let accepted = matcher.acceptToken(token)
            #expect(accepted)
        }
        var mask = matcher.nextTokenBitmask()
        #expect(mask.allows(3))
        #expect(!mask.allows(1) && !mask.allows(2) && !mask.allows(4))
        let endAccepted = matcher.acceptToken(3)
        #expect(endAccepted)
        #expect(matcher.isCompleted)

        let zeroCompiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(structuralFormat:
            .tag(.init(begin: .token(0), content: .anyTokens(maxTokens: 0), end: .token(3))))
        var zeroMatcher = GrammarMatcher(zeroCompiled)
        let beginAccepted = zeroMatcher.acceptToken(0)
        #expect(beginAccepted)
        mask = zeroMatcher.nextTokenBitmask()
        #expect(mask.allows(3))
        #expect(!mask.allows(1) && !mask.allows(2))
    }

    @Test func anyTextBudgetCacheAndSerializationRoundtrip() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Self.budgetTokenizer, cacheEnabled: true)
        let unbounded = try Self.compileAnyTextBudget(compiler: compiler)
        let bounded = try Self.compileAnyTextBudget(maxTokens: 2, compiler: compiler)
        #expect(Self.budgetAccepts(unbounded, "<think>", "a", "b", "c", "</", "think>"))
        #expect(!Self.budgetAccepts(bounded, "<think>", "a", "b", "c", "</", "think>"))

        let recovered = try CompiledGrammar(serializedJSON: bounded.serializedJSON, tokenizerInfo: Self.budgetTokenizer)
        #expect(Self.budgetAccepts(recovered, "<think>", "a", "b", "</", "think>"))
        #expect(!Self.budgetAccepts(recovered, "<think>", "a", "b", "c", "</", "think>"))
    }
}
