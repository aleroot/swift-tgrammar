// Port of xgrammar's tests/python/test_grammar_compiler.py: compiled grammars, the whole-grammar
// cache, its memory budget, concurrent compilation, and the rule-level cache that shares masks
// across grammars (and must not share them across automata that merely hash alike).
//
// Timing printouts are dropped. `cache_limit_bytes == -1` is `maxCacheBytes == nil`.

import Dispatch
import Foundation
import Synchronization
import Testing

@testable import TGrammar

@Suite("Grammar compiler")
struct GrammarCompilerTests {
    /// `check_matcher` of the JSON tests.
    private static func expectJSONMatcher(_ compiled: CompiledGrammar, sourceLocation: SourceLocation = #_sourceLocation) {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        #expect(!matcher.isTerminated, sourceLocation: sourceLocation)
        let rejected = matcher.acceptString("{ name: \"John\" }")
        #expect(!rejected, sourceLocation: sourceLocation)
        let accepted = matcher.acceptString("{\"name\": \"John\"}")
        #expect(accepted, sourceLocation: sourceLocation)
        #expect(matcher.isTerminated, sourceLocation: sourceLocation)
    }

    /// `_compiled_accepts`.
    private static func accepts(_ compiled: CompiledGrammar, _ input: String) -> Bool {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isTerminated
    }

    enum Step: Sendable { case text(String), token(Int32) }

    /// `_mask_trace`: the `(need_apply, bitmask)` pairs before each step of `input`.
    private static func maskTrace(_ compiled: CompiledGrammar, _ input: [Step], sourceLocation: SourceLocation = #_sourceLocation) -> [(apply: Bool, mask: TokenBitmask)] {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        var mask = TokenBitmask(vocabSize: compiled.tokenizerInfo.vocabSize)
        var trace: [(Bool, TokenBitmask)] = []
        for step in input {
            mask.clearAll()
            let apply = matcher.fillNextTokenBitmask(&mask)
            trace.append((apply, mask))
            let accepted = switch step {
            case .token(let id): matcher.acceptToken(id)
            case .text(let text): matcher.acceptString(text)
            }
            #expect(accepted, "\(step)", sourceLocation: sourceLocation)
        }
        #expect(matcher.isTerminated, sourceLocation: sourceLocation)
        return trace
    }

    private static func expectSameTrace(_ actual: [(apply: Bool, mask: TokenBitmask)], _ expected: [(apply: Bool, mask: TokenBitmask)], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (step, (a, e)) in zip(actual, expected).enumerated() {
            #expect(a.apply == e.apply, "step \(step)", sourceLocation: sourceLocation)
            #expect(a.mask == e.mask, "step \(step)", sourceLocation: sourceLocation)
        }
    }

    /// `test_grammar_compiler_cache_*` run on Llama 3.1 upstream; the first cached vocabulary
    /// stands in since the assertions do not depend on the vocabulary.
    static let anyVocabulary = Array(LocalTokenizers.available([.llama31, .llama3, .llama2, .qwen3]).prefix(1))

    // MARK: - Real vocabularies

    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func compiledGrammar() throws {
        let info = try #require(LocalTokenizers.info(.llama2))
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(.builtinJSON)
        Self.expectJSONMatcher(compiled)
        Self.expectJSONMatcher(compiled)
    }

    /// `max_threads=1` takes the serial path with no worker pool or mutex.
    @Test(.enabled(if: LocalTokenizers.has(.llama2)), arguments: [8, 1])
    func grammarCompilerJSON(maxThreads: Int) throws {
        let info = try #require(LocalTokenizers.info(.llama2))
        let compiler = GrammarCompiler(tokenizerInfo: info, maxThreads: maxThreads)
        Self.expectJSONMatcher(try compiler.compile(.builtinJSON))
        Self.expectJSONMatcher(try compiler.compile(.builtinJSON))
        compiler.clearCache()
        Self.expectJSONMatcher(try compiler.compile(.builtinJSON))
    }

    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func grammarCompilerJSONSchema() throws {
        let info = try #require(LocalTokenizers.info(.llama2))
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let compact = #"{"integer_field":42,"number_field":314000.0,"boolean_field":true,"any_array_field":[3.14,"foo",null,true],"array_field":["foo","bar"],"tuple_field":["foo",42,["bar","baz"]],"object_field":{"foo":42,"bar":43},"nested_object_field":{"foo":{"bar":42}}}"#
        let indented = GrammarMatcherJSONSchemaTests.instance

        func check(anyWhitespace: Bool, indent: Int?, separators: (String, String)?, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let options = JSONSchemaOptions(anyWhitespace: anyWhitespace, indent: indent, itemSeparator: separators?.0, keySeparator: separators?.1)
            let compiled = try compiler.compile(Grammar(jsonSchema: GrammarMatcherJSONSchemaTests.mainModel, options: options))
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            #expect(!matcher.isTerminated, sourceLocation: sourceLocation)
            let accepted = matcher.acceptString(indent == nil ? compact : indented)
            #expect(accepted, sourceLocation: sourceLocation)
            #expect(matcher.isTerminated, sourceLocation: sourceLocation)
        }

        try check(anyWhitespace: false, indent: nil, separators: (",", ":"))
        try check(anyWhitespace: false, indent: nil, separators: (",", ":"))
        try check(anyWhitespace: false, indent: 2, separators: nil)
        try check(anyWhitespace: false, indent: 2, separators: (",", ": "))

        try check(anyWhitespace: true, indent: nil, separators: (",", ":"))
        try check(anyWhitespace: true, indent: nil, separators: (",", ":"))
        try check(anyWhitespace: true, indent: 2, separators: nil)
        try check(anyWhitespace: true, indent: 2, separators: (",", ": "))

        compiler.clearCache()

        try check(anyWhitespace: false, indent: nil, separators: (",", ":"))
    }

    static let schemaInstances: [(schema: String, instance: String)] = [
        (#"{"type": "object","properties":{"username":{"type": "string"}},"required":["username"]}"#, #"{"username":"Alice"}"#),
        (#"{"type": "object","properties":{"age":{"type": "integer"}},"required":["age"]}"#, #"{"age":30}"#),
        (#"{"type": "object","properties":{"city":{"type": "string"}},"required":["city"]}"#, #"{"city":"Paris"}"#),
        (#"{"type": "object","properties":{"isActive":{"type": "boolean"}},"required":["isActive"]}"#, #"{"isActive":true}"#),
        (#"{"type": "object","properties":{"rating":{"type": "number"}},"required":["rating"]}"#, #"{"rating":4.5}"#),
        (#"{"type": "object","properties":{"name":{"type": "string"}},"required":["name"]}"#, #"{"name":"Bob"}"#),
        (#"{"type": "object","properties":{"quantity":{"type": "integer"}},"required":["quantity"]}"#, #"{"quantity":10}"#),
        (#"{"type": "object","properties":{"color":{"type": "string"}},"required":["color"]}"#, #"{"color":"blue"}"#),
        (#"{"type": "object","properties":{"temperature":{"type": "number"}},"required":["temperature"]}"#, #"{"temperature":22.5}"#),
        (#"{"type": "object","properties":{"isCompleted":{"type": "boolean"}},"required":["isCompleted"]}"#, #"{"isCompleted":false}"#),
    ]

    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func grammarCompilerJSONSchemaConcurrent() throws {
        let info = try #require(LocalTokenizers.info(.llama2))
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let threadCount = 100
        let outcomes = Mutex<[Int: Bool]>([:])
        DispatchQueue.concurrentPerform(iterations: threadCount) { index in
            let (schema, instance) = Self.schemaInstances[index % Self.schemaInstances.count]
            let options = JSONSchemaOptions(indent: nil, itemSeparator: ",", keySeparator: ":")
            guard let compiled = try? compiler.compile(Grammar(jsonSchema: schema, options: options)) else {
                outcomes.withLock { $0[index] = false }
                return
            }
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let passed = !matcher.isTerminated && matcher.acceptString(instance) && matcher.isTerminated
            outcomes.withLock { $0[index] = passed }
        }
        let results = outcomes.withLock { $0 }
        #expect(results.count == threadCount)
        #expect(results.values.allSatisfy { $0 })
    }

    private static func nameSchema(_ name: String) -> String {
        #"{"properties": {"\#(name)": {"type": "string"}}, "required": ["\#(name)"], "type": "object"}"#
    }

    @Test(arguments: anyVocabulary)
    func grammarCompilerCacheUnlimited(_ model: LocalTokenizers.Model) throws {
        let info = try #require(LocalTokenizers.info(model))
        // Upstream's default is unlimited; TGrammar's default is a device-scaled budget, so the
        // unlimited cache is requested explicitly.
        #expect(GrammarCompiler(tokenizerInfo: info).maxCacheBytes == GrammarCompiler.defaultMaxCacheBytes)
        let compiler = GrammarCompiler(tokenizerInfo: info, maxCacheBytes: nil)
        #expect(compiler.maxCacheBytes == nil)
        #expect(compiler.cacheSizeBytes == 0)
        var sumSingle = 0
        for index in 0 ..< 10 {
            let compiled = try compiler.compile(Grammar(jsonSchema: Self.nameSchema("name_\(index)")))
            sumSingle += compiled.memorySize
            #expect(compiler.cacheSizeBytes > 0)
        }
        #expect(sumSingle > 0)
        let oldSize = compiler.cacheSizeBytes
        _ = try compiler.compile(Grammar(jsonSchema: Self.nameSchema("name_0")))
        #expect(compiler.cacheSizeBytes == oldSize)
    }

    @Test(arguments: anyVocabulary)
    func grammarCompilerCacheLimited(_ model: LocalTokenizers.Model) throws {
        let info = try #require(LocalTokenizers.info(model))
        let limit = 2 * 1024 * 1024
        let compiler = GrammarCompiler(tokenizerInfo: info, maxCacheBytes: limit)
        #expect(compiler.maxCacheBytes == limit)
        #expect(compiler.cacheSizeBytes == 0)
        for index in 0 ..< 10 {
            _ = try compiler.compile(Grammar(jsonSchema: Self.nameSchema("name_\(index)")))
            #expect(compiler.cacheSizeBytes <= limit)
        }
        compiler.clearCache()
        #expect(compiler.cacheSizeBytes == 0)
    }

    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func grammarCompilerCrossingCacheSameGrammar() throws {
        let info = try #require(LocalTokenizers.info(.llama2))
        let a = try GrammarCompiler(tokenizerInfo: info).compile(.builtinJSON)
        let b = try GrammarCompiler(tokenizerInfo: info).compile(.builtinJSON)
        #expect(a.serializedJSON == b.serializedJSON)
    }

    /// Cached and non-cached compilations should yield the same result.
    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func grammarCompilerCrossingCacheDifferentGrammarWithSameFSM() throws {
        let grammarA = """
            root ::= "{" string "}"
            string ::= "\\"" [^"]* "\\"" | "'" [^']* "'"
            """
        let grammarB = """
            root ::= "[" string "]"
            string ::= "\\"" [^"]* "\\"" | "'" [^']* "'"
            """
        let info = try #require(LocalTokenizers.info(.llama2))
        let compiler = GrammarCompiler(tokenizerInfo: info)
        _ = try compiler.compile(ebnf: grammarA)
        let cached = try compiler.compile(ebnf: grammarB)
        compiler.clearCache()
        let fresh = try compiler.compile(ebnf: grammarB)
        #expect(cached.serializedJSON == fresh.serializedJSON)
    }

    // MARK: - Allow-empty analysis

    @Test(arguments: [
        ("root ::= rule1 rule2 | \"abc\"\nrule1 ::= \"abc\" | \"\"\nrule2 ::= \"def\" rule3 | \"\"\nrule3 ::= \"ghi\"\n", [0, 1, 2]),
        ("root ::= rule1 rule2 [a-z]*\nrule1 ::= \"abc\" | \"\"\nrule2 ::= \"def\" | \"\"\n", [0, 1, 2]),
        ("root ::= rule1 rule3\nrule1 ::= \"abc\" | \"\"\nrule2 ::= \"def\" | \"\"\nrule3 ::= rule1 rule2\n", [0, 1, 2, 3]),
        ("root ::= [a]* [b]* rule1\nrule1 ::= [abc]* [def]*\n", [0, 1]),
    ])
    func getAllowEmptyRuleIDs(grammar: String, expected: [Int32]) throws {
        let compiled = try GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer).compile(ebnf: grammar)
        #expect(compiled.grammar.storage.allowEmptyRuleIDs == expected)
    }

    // MARK: - Rule-level cache

    /// `HASHER_GRAPH_CASES`: the reference-graph corner cases of the automaton hasher.
    static let hasherGraphCases: [(grammar: String, accepted: [String], rejected: [String])] = [
        // chain
        ("root ::= first\nfirst ::= \"a\" second\nsecond ::= \"b\" third\nthird ::= \"c\"\n", ["abc"], ["", "ab", "abd"]),
        // diamond
        ("root ::= left | right\nleft ::= \"a\" leaf\nright ::= \"b\" leaf\nleaf ::= \"c\"\n", ["ac", "bc"], ["a", "b", "cc"]),
        // self-cycle
        ("root ::= node\nnode ::= \"a\" node | \"z\"\n", ["z", "az", "aaaz"], ["", "a", "za"]),
        // cycle-with-tail
        ("root ::= \"s\" outer\nouter ::= \"a\" middle | \"z\"\nmiddle ::= \"b\" inner\ninner ::= \"c\" outer | \"d\"\n", ["sz", "sabd", "sabcz", "sabcabd"], ["", "s", "sab", "sabc"]),
        // duplicate-referee
        ("root ::= pair\npair ::= leaf leaf | leaf\nleaf ::= \"x\" | \"y\"\n", ["x", "y", "xx", "xy", "yx", "yy"], ["", "xxx", "z"]),
        // repeat
        ("root ::= item {2, 3}\nitem ::= \"a\" | \"bc\"\n", ["aa", "abc", "bca", "bcbc", "aaa", "abca"], ["", "a", "bc", "aaaa"]),
    ]

    /// Compare cache and threading paths across the hasher's graph corner cases.
    @Test(arguments: hasherGraphCases.indices)
    func grammarFSMHasherWorklistGraphs(_ index: Int) throws {
        let (grammar, accepted, rejected) = Self.hasherGraphCases[index]
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c", "d", "s", "x", "y", "z", "ab", "bc", "abc"])
        let variants = [
            try GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: false).compile(ebnf: grammar),
            try GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: true).compile(ebnf: grammar),
            try GrammarCompiler(tokenizerInfo: info, maxThreads: 8, cacheEnabled: true).compile(ebnf: grammar),
        ]
        for compiled in variants {
            for input in accepted { #expect(Self.accepts(compiled, input), "\(input)") }
            for input in rejected { #expect(!Self.accepts(compiled, input), "\(input)") }
        }
        let expected = Self.maskTrace(variants[0], [.text(accepted[0])])
        for compiled in variants.dropFirst() {
            Self.expectSameTrace(Self.maskTrace(compiled, [.text(accepted[0])]), expected)
        }
    }

    /// `CROSSING_CACHE_DIFFERENT_FSM_CASES`: pairs of grammars whose rule automata must not
    /// share masks even though a weaker hash would have identified them.
    static let crossingCacheDifferentFSMCases: [(a: String, b: String, input: [Step])] = [
        // character-range
        ("root ::= \"(\" r \")\"\nr ::= [0-3] \"x\" | \"y\"", "root ::= \"(\" r \")\"\nr ::= [1-t] \"x\" | \"y\"", [.text("(ax)")]),
        // repeat-bounds
        ("root ::= \"(\" s \")\"\ns ::= \"\\\"\" [^\"\\\\\\r\\n]{0,64} \"\\\"\"", "root ::= \"(\" s \")\"\ns ::= \"\\\"\" [^\"\\\\\\r\\n]{1,129} \"\\\"\"", [.text("(\"a\")")]),
        // lookahead
        ("root ::= \"(\" r [0-9a-z] \")\" | \"(\" r \"y\" \")\"\nr ::= (\"x\" | \"yy\") (=[0-3])", "root ::= \"(\" r [0-9a-z] \")\" | \"(\" r \"y\" \")\"\nr ::= (\"x\" | \"yy\") (=[1-t])", [.text("(xa)")]),
        // rule-edge-source
        ("root ::= \"(\" r \")\"\nr ::= s | \"x\" s | \"x0y\"\ns ::= \"a\" | \"yy\" | \"a\" s", "root ::= \"(\" r \")\"\nr ::= s | \"x0\" s | \"x0y\"\ns ::= \"a\" | \"yy\" | \"a\" s", [.text("(x0a)")]),
        // token-edge
        ("root ::= \"(\" r \")\"\nr ::= \"a\" Token(4) | \"0\"", "root ::= \"(\" r \")\"\nr ::= \"a\" Token(5) | \"0\"", [.text("("), .text("a"), .token(5), .text(")")]),
        // lookahead-expr-boundary
        ("root ::= \"(\" r \"x\" [c-d] \")\"\nr ::= \"q\" (=\"x\" [c-d])", "root ::= \"(\" r \"x\\x01\\x00\\x63\\x64\" \")\"\nr ::= \"q\" (=\"x\\x01\\x00\\x63\\x64\")", [.text("("), .token(11), .text("\u{0}"), .text("c"), .text("d"), .text(")")]),
        // lookahead-rule-ref
        ("root ::= \"(\" r z \")\"\nr ::= \"q\" (=z)\nv ::= \"[\" w \"]\" | \"a\"\nw ::= v | \"{\" z \"}\"\nz ::= w | \"b\"", "root ::= \"(\" r z \")\"\nr ::= \"q\" (=z)\nv ::= \"[\" w \"]\" | \"0\"\nw ::= v | \"{\" z \"}\"\nz ::= w | \"b\"", [.text("(q0)")]),
        // lazy
        ("root ::= \"(\" r \")\"\nr ::= [a-x]* \"x\"", "root ::= \"(\" r \")\"\nr[lazy] ::= [a-x]* \"x\"", [.text("(ax)")]),
        // partial-hash-start-state
        ("root ::= \"(\" r \")\"\nr ::= z | \"qx\"\nv ::= \"q\" w \"]\" | \"a\"\nw ::= v | \"{\" z \"}\"\nz ::= w | \"b\"", "root ::= \"(\" r \")\"\nr ::= z | \"qx\"\nv ::= \"q\" w \"]\" | \"0\"\nw ::= v | \"{\" z \"}\"\nz ::= w | \"b\"", [.text("(q0])")]),
        // partial-hash-self-reference
        ("root ::= \"(\" r \")\"\nr ::= x \"b\" | \"aq\" r | \"az\"\nx ::= r \"c\" | y\ny ::= x \"d\" | \"a\"", "root ::= \"(\" r \")\"\nr ::= x \"b\" | \"aq\" r | \"az\"\nx ::= r \"c\" | y\ny ::= x \"d\" | \"0\"", [.text("(aq0b)")]),
    ]

    /// A grammar must not reuse the token masks of another grammar whose rule differs only in
    /// small integers (character ranges, repetition bounds), in the state a rule reference
    /// leaves, in the tokens of a token edge, or in where one lookahead element ends. Nor may it
    /// reuse them for a lookahead that references a rule with a partial hash, which leaves out
    /// a rule referenced at its start state, or for a rule that differs only in being lazy. The
    /// start state of a rule with a partial hash must not reuse them either: its mask includes
    /// the tokens of that left-out rule, and so do the masks of every state of such a rule that
    /// references itself.
    @Test(arguments: crossingCacheDifferentFSMCases.indices)
    func grammarCompilerCrossingCacheDifferentFSM(_ index: Int) throws {
        let (grammarA, grammarB, input) = Self.crossingCacheDifferentFSMCases[index]
        let info = try TokenizerInfo(encodedVocab: ["(", ")", "a", "0", "x", "y", "\"", "\"\"", "xa", "x0", "q", "qx\u{1}", "qa", "q0"])
        let compiler = GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: true)
        _ = try compiler.compile(ebnf: grammarA)
        let cached = try compiler.compile(ebnf: grammarB)
        let fresh = try GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: false).compile(ebnf: grammarB)
        Self.expectSameTrace(Self.maskTrace(cached, input), Self.maskTrace(fresh, input))
    }

    /// `test_grammar_compiler_cache_regex_large_repeat` (upstream #957): a large bounded
    /// repetition references the rule of its repeated element only through an automaton edge;
    /// that rule's hash must still feed the referrer's, so the two patterns get their own masks.
    @Test func grammarCompilerCacheRegexLargeRepeat() throws {
        let vocab = ["\"", "x", "xa", "x1", "a", "1"]
        let info = try TokenizerInfo(encodedVocab: vocab)
        let schemaA = try Grammar(jsonSchema: #"{"type": "string", "pattern": "^x[a-z]{129}$"}"#)
        let schemaB = try Grammar(jsonSchema: #"{"type": "string", "pattern": "^x[0-9]{129}$"}"#)
        let compiler = GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: true)
        _ = try compiler.compile(schemaA)
        let cached = try compiler.compile(schemaB)
        let fresh = try GrammarCompiler(tokenizerInfo: info, maxThreads: 1, cacheEnabled: false).compile(schemaB)
        let input = (["\"", "x1"] + Array(repeating: "1", count: 128) + ["\""]).map { Step.token(Int32(vocab.firstIndex(of: $0)!)) }
        Self.expectSameTrace(Self.maskTrace(cached, input), Self.maskTrace(fresh, input))
        // Swift addition: before the fix the hasher failed safe (no hash, so no cache reuse)
        // where upstream crashed; every rule must now get a complete hash.
        let hashes = GrammarFSMHasher.apply(try GrammarTesting.optimize(schemaB).storage)
        #expect(hashes.ruleHashes.allSatisfy { $0 != nil } && !hashes.isPartial.contains(true))
    }

    /// Propagate worker failures while exercising concurrent cache lookup and insertion.
    @Test func shardedRuleCacheConcurrentCompilation() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c", "d", "x", "y", "z", "ab", "bc"])
        let cacheLimit = 4 * 1024 * 1024
        let compiler = GrammarCompiler(tokenizerInfo: info, maxThreads: 4, cacheEnabled: true, maxCacheBytes: cacheLimit)
        let cases = Array(Self.hasherGraphCases.prefix(5))

        @Sendable func compileAndCheck(_ index: Int) throws {
            let (grammar, accepted, rejected) = cases[index % cases.count]
            let compiled = try compiler.compile(ebnf: grammar)
            #expect(Self.accepts(compiled, accepted[0]))
            #expect(!Self.accepts(compiled, rejected[0]))
        }

        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do { try compileAndCheck(index) } catch { failures.withLock { $0.append("\(index): \(error)") } }
        }
        #expect(failures.withLock { $0 }.isEmpty)

        let size = compiler.cacheSizeBytes
        #expect(size > 0 && size <= cacheLimit)
        for index in cases.indices { try compileAndCheck(index) }
        #expect(compiler.cacheSizeBytes == size)

        compiler.clearCache()
        #expect(compiler.cacheSizeBytes == 0)
    }

    // MARK: - Cross-grammar parity (original)

    /// A vocabulary with JSON punctuation, words, word fragments, whitespace runs and tag pieces,
    /// so that most mask classes (accepted / rejected / uncertain) are populated.
    static let richVocabulary: [String] = {
        var pieces = ["{", "}", "[", "]", ",", ":", "\"", "\":", "\",", "\"}", "\"]", " ", "  ", "\n", "\n  ", "\n    ", ", ", ": ", "true", "false", "null",
                      "0", "1", "42", "3.14", "-", ".", "e", "E+", "<", ">", "</", "/>", "=", "<tool_call>", "</tool_call>", "<function", "<parameter", "name", "arguments",
                      "city", "unit", "celsius", "fahrenheit", "Dubai", "weather", "get_", "_time", "foo", "bar", "baz", "a", "aa", "ab", "b", "x", "y", "z", "q", "中", "中文", "é",
                      "\\", "\\n", "\\\"", "\\u00", "<|im_end|>", "<|endoftext|>", "</s>",
                      "<|start|>", "<|message|>", "<|eom|>", "<|eot|>"]
        for word in ["the", "and", "of", "to", "in", "is", "for", "on", "with", "as"] {
            pieces.append(word)
            pieces.append(" " + word)
            pieces.append(word.uppercased())
        }
        return pieces
    }()

    enum ParityVocabulary: CustomStringConvertible, Sendable {
        case synthetic, model(LocalTokenizers.Model)
        var description: String { switch self { case .synthetic: "synthetic"; case .model(let model): model.rawValue } }
        func info() throws -> TokenizerInfo? {
            switch self {
            case .synthetic: try TokenizerInfo(encodedVocab: GrammarCompilerTests.richVocabulary)
            case .model(let model): LocalTokenizers.info(model)
            }
        }
    }

    static let parityVocabularies: [ParityVocabulary] = [.synthetic] + (Upstream.runsPressureTests ? anyVocabulary.map(ParityVocabulary.model) : [])

    /// Grammars that share many rules (JSON values, whitespace, tool-call wrappers) but differ in
    /// details, so that the rule-level cache is both hit and must not be hit.
    static func parityGrammars(_ info: TokenizerInfo) throws -> [(name: String, grammar: Grammar)] {
        var grammars: [(String, Grammar)] = [("builtin json", .builtinJSON)]
        grammars.append(("main model", try Grammar(jsonSchema: GrammarMatcherJSONSchemaTests.mainModel)))
        grammars.append(("main model indent", try Grammar(jsonSchema: GrammarMatcherJSONSchemaTests.mainModel, options: .init(anyWhitespace: false, indent: 2))))
        grammars.append(("main model compact", try Grammar(jsonSchema: GrammarMatcherJSONSchemaTests.mainModel, options: .init(anyWhitespace: false, itemSeparator: ",", keySeparator: ":"))))
        for (index, (schema, _)) in schemaInstances.enumerated() { grammars.append(("schema \(index)", try Grammar(jsonSchema: schema))) }
        for (index, schema) in [#"{"type": "string", "maxLength": 3}"#, #"{"type": "string", "minLength": 2, "maxLength": 3}"#,
                                #"{"type": "array", "items": {"type": "string", "maxLength": 3}}"#, #"{"type": "object", "properties": {"content": {"type": "string", "maxLength": 8}}, "required": ["content"]}"#].enumerated() {
            grammars.append(("bounded \(index)", try Grammar(jsonSchema: schema)))
        }
        let tools: [ToolDeclaration] = [
            .function(.init(name: "get_weather", parameters: .object(properties: [.init("city", .string(), required: true), .init("unit", .enumeration(["celsius", "fahrenheit"]))]))),
            .function(.init(name: "get_time", parameters: .object(properties: [.init("zone", .string())]))),
        ]
        for model in ToolCallDialect.allCases {
            for reasoning in [ReasoningMode.disabled, .optional] {
                guard let format = try? StructuralFormat.toolCalls(tools, model: model, reasoning: reasoning) else { continue }
                // Onyx frames need the model's control tokens.
                if model == .atem, info.tokenID(for: "<|message|>") == nil { continue }
                grammars.append(("\(model.rawValue) \(reasoning)", try Grammar(structuralFormat: format, tokenizerInfo: info)))
            }
        }
        for (index, ebnf) in [
            "root ::= \"(\" r [0-9a-z] \")\" | \"(\" r \"y\" \")\"\nr ::= (\"x\" | \"yy\") (=[0-3])",
            "root ::= \"(\" r \")\"\nr ::= [a-x]* \"x\"",
            "root ::= \"(\" r \")\"\nr[lazy] ::= [a-x]* \"x\"",
            "root ::= \"<\" s{1,2} \">\"\ns ::= [^<>]{2,3}",
            "root ::= a | b\na[max_tokens=1] ::= [^xy]{0,2} \"x\"\nb[max_tokens=2] ::= [^xy]{0,3} \"y\"",
            "root ::= \"\\\"\" [^\"\\\\]{0,3} \"\\\"\" | t\nt[max_chars=2] ::= [a-z]*",
        ].enumerated() {
            grammars.append(("ebnf \(index)", try Grammar(ebnf: ebnf)))
        }
        return grammars
    }

    /// The tokens a mask settles (sorted indices) and the ones it leaves to the parent.
    private static func classes(_ mask: AdaptiveTokenMask, _ info: TokenizerInfo) -> (accepted: Set<Int32>, uncertain: Set<Int32>) {
        let sortedCount = Int32(info.sortedTokens.count)
        let uncertain = Set(mask.uncertainIndices)
        var accepted: Set<Int32>
        switch mask.storeType {
        case .accepted: accepted = Set(mask.acceptedIndices)
        case .rejected:
            let blocked = Set(mask.rejectedIndices).union(uncertain)
            accepted = Set((0 ..< sortedCount).filter { !blocked.contains($0) })
        case .acceptedBitset: accepted = Set((0 ..< sortedCount).filter { mask.acceptedBitset[info.sortedTokenIDs[Int($0)]] })
        }
        return (accepted, uncertain)
    }

    /// Every grammar compiled through one shared compiler yields the masks a fresh compiler
    /// computes for it alone.
    @Test(arguments: parityVocabularies)
    func ruleLevelCacheMatchesFreshCompilation(_ vocabulary: ParityVocabulary) throws {
        let info = try #require(try vocabulary.info())
        let shared = GrammarCompiler(tokenizerInfo: info, cacheEnabled: true)
        // Masks computed independently for every state: no sharing across or within grammars.
        let fresh = GrammarCompiler(tokenizerInfo: info, maxThreads: nil, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: false)
        var hits = 0
        for (name, grammar) in try Self.parityGrammars(info) {
            let before = shared.ruleLevelCache?.totalBytes ?? 0
            let cached = try shared.compile(grammar)
            let reference = try fresh.compile(grammar)
            if (shared.ruleLevelCache?.totalBytes ?? 0) == before { hits += 1 }
            #expect(cached.grammar.description == reference.grammar.description, "\(name)")
            #expect(cached.masks.count == reference.masks.count, "\(name)")
            for (key, expected) in reference.masks {
                guard let actual = cached.masks[key] else {
                    Issue.record("\(name): missing mask for rule \(key.ruleID) state \(key.elementID)")
                    continue
                }
                let a = Self.classes(actual, info), e = Self.classes(expected, info)
                #expect(a.accepted == e.accepted, "\(name): accepted tokens of rule \(key.ruleID) state \(key.elementID)")
                #expect(a.uncertain == e.uncertain, "\(name): uncertain tokens of rule \(key.ruleID) state \(key.elementID)")
                #expect(actual.repeatInteriorCharCounts == expected.repeatInteriorCharCounts && actual.repeatInteriorBitsets == expected.repeatInteriorBitsets
                    && AdaptiveTokenMask.equal(actual.repeatInteriorTokens, expected.repeatInteriorTokens), "\(name): repetition fast path of rule \(key.ruleID)")
            }
        }
        // Several of the grammars reuse every mask of an earlier one.
        #expect(hits > 0)
    }

    /// Without a cache, rules of one grammar with identical automata share masks (threshold 0,
    /// so the small synthetic vocabulary shares too); the result matches independent compilation.
    @Test(arguments: parityVocabularies)
    func withinGrammarSharingMatchesFreshCompilation(_ vocabulary: ParityVocabulary) throws {
        let info = try #require(try vocabulary.info())
        let sharing = GrammarCompiler(tokenizerInfo: info, maxThreads: nil, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: true, minimumSharedScan: 0)
        let fresh = GrammarCompiler(tokenizerInfo: info, maxThreads: nil, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: false)
        for (name, grammar) in try Self.parityGrammars(info) {
            let shared = try sharing.compile(grammar)
            let reference = try fresh.compile(grammar)
            #expect(shared.masks.count == reference.masks.count, "\(name)")
            for (key, expected) in reference.masks {
                guard let actual = shared.masks[key] else {
                    Issue.record("\(name): missing mask for rule \(key.ruleID) state \(key.elementID)")
                    continue
                }
                let a = Self.classes(actual, info), e = Self.classes(expected, info)
                #expect(a.accepted == e.accepted, "\(name): accepted tokens of rule \(key.ruleID) state \(key.elementID)")
                #expect(a.uncertain == e.uncertain, "\(name): uncertain tokens of rule \(key.ruleID) state \(key.elementID)")
            }
        }
    }

    /// Dynamic compilation (upstream #1017) computes, mask by mask, what eager compilation
    /// computes up front, both through the rule-level cache and with sharing within a grammar.
    @Test(arguments: parityVocabularies)
    func dynamicCompilationMatchesFreshCompilation(_ vocabulary: ParityVocabulary) throws {
        let info = try #require(try vocabulary.info())
        let cached = GrammarCompiler(tokenizerInfo: info, cacheEnabled: true, dynamicCompilation: true)
        let sharing = GrammarCompiler(tokenizerInfo: info, maxThreads: nil, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: true,
                                      minimumSharedScan: 0, dynamicCompilation: true)
        let fresh = GrammarCompiler(tokenizerInfo: info, maxThreads: nil, cacheEnabled: false, maxCacheBytes: nil, sharesMasksWithinGrammar: false)
        for (name, grammar) in try Self.parityGrammars(info) {
            let reference = try fresh.compile(grammar).masks
            for dynamic in [try cached.compile(grammar), try sharing.compile(grammar)] {
                #expect(dynamic.isDynamicallyCompiled)
                let masks = dynamic.masks
                #expect(masks.count == reference.count, "\(name)")
                for (key, expected) in reference {
                    guard let actual = masks[key] else {
                        Issue.record("\(name): missing mask for rule \(key.ruleID) state \(key.elementID)")
                        continue
                    }
                    let a = Self.classes(actual, info), e = Self.classes(expected, info)
                    #expect(a.accepted == e.accepted, "\(name): accepted tokens of rule \(key.ruleID) state \(key.elementID)")
                    #expect(a.uncertain == e.uncertain, "\(name): uncertain tokens of rule \(key.ruleID) state \(key.elementID)")
                    #expect(actual.repeatInteriorCharCounts == expected.repeatInteriorCharCounts && actual.repeatInteriorBitsets == expected.repeatInteriorBitsets
                        && AdaptiveTokenMask.equal(actual.repeatInteriorTokens, expected.repeatInteriorTokens), "\(name): repetition fast path of rule \(key.ruleID)")
                }
            }
        }
    }

    /// The tag-dispatch "second slicing" scan (only bytes that start a needle are compared)
    /// agrees with a naive substring search on random tokens and needles.
    @Test func tagDispatchSlicingMatchesNaiveSearch() {
        var generator = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = Array("<>|ab\"".utf8) + [0xE4, 0xB8]
        func random(_ length: Int) -> [UInt8] { (0 ..< length).map { _ in alphabet.randomElement(using: &generator)! } }
        for round in 0 ..< 40 {
            let tokens = (0 ..< 400).map { _ in random(Int.random(in: 0 ... 9, using: &generator)) }
            var needles = (0 ..< Int.random(in: 1 ... 4, using: &generator)).map { _ in random(Int.random(in: 1 ... 4, using: &generator)) }
            if round == 0 { needles.append([]) }
            let actual = TagDispatchSlicing.compute(needles, ByteStringTable(tokens))
            for (index, token) in tokens.enumerated() {
                let tail = token.dropFirst()
                let containsNeedle = needles.contains { needle in
                    needle.isEmpty || (needle.count <= tail.count && (0 ... tail.count - needle.count).contains { tail.dropFirst($0).starts(with: needle) })
                }
                #expect(actual[index] == (token.isEmpty || !containsNeedle), "\(token) \(needles)")
            }
        }
    }
}
