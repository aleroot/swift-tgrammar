// Port of upstream `tests/python/test_dynamic_compilation.py` and
// `tests/cpp/test_dynamic_compilation.cc` (XGrammar #1017, opt-in dynamic compilation): masks
// computed on demand must equal eagerly compiled ones, and both must agree with a token oracle
// (a fresh matcher trying every token). Test names follow the upstream functions.

import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TGrammar

@Suite("Dynamic compilation (upstream)")
struct DynamicCompilationUpstreamTests {
    typealias Piece = [UInt8]
    typealias Trace = [(apply: Bool, mask: TokenBitmask)]

    static func b(_ text: String) -> Piece { Array(text.utf8) }
    static func pieces(_ texts: [String]) -> [Piece] { texts.map(b) }

    static func info(_ vocab: [Piece], stops: [Int32]? = []) throws -> TokenizerInfo {
        try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: stops)
    }

    /// Upstream's compiler defaults: unlimited cache budget.
    static func compiler(_ info: TokenizerInfo, dynamic: Bool, cache: Bool = true, threads: Int = 1,
                         maxCacheBytes: Int? = nil) -> GrammarCompiler {
        GrammarCompiler(tokenizerInfo: info, maxThreads: threads, cacheEnabled: cache, maxCacheBytes: maxCacheBytes, dynamicCompilation: dynamic)
    }

    static func eagerAndDynamic(_ info: TokenizerInfo, cache: Bool = true,
                                _ build: (GrammarCompiler) throws -> CompiledGrammar) throws -> (eager: CompiledGrammar, dynamic: CompiledGrammar) {
        let eager = try build(compiler(info, dynamic: false, cache: cache))
        let dynamic = try build(compiler(info, dynamic: true, cache: cache))
        #expect(!eager.isDynamicallyCompiled && dynamic.isDynamicallyCompiled)
        return (eager, dynamic)
    }

    static let strictCompact = JSONSchemaOptions(anyWhitespace: false, strict: true)

    /// `_mask_trace`: the mask before every code point of `input`, then the input is complete.
    static func trace(_ compiled: CompiledGrammar, _ input: String, sourceLocation: SourceLocation = #_sourceLocation) -> Trace {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        var result: Trace = []
        for scalar in input.unicodeScalars {
            var mask = TokenBitmask(vocabSize: compiled.tokenizerInfo.vocabSize)
            let apply = matcher.fillNextTokenBitmask(&mask)
            result.append((apply, mask))
            let accepted = matcher.acceptString(String(scalar))
            #expect(accepted, sourceLocation: sourceLocation)
        }
        #expect(matcher.isTerminated, sourceLocation: sourceLocation)
        return result
    }

    /// `#expect` for conditions that mutate a matcher (the macro cannot capture those).
    static func check(_ condition: Bool, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, comment, sourceLocation: sourceLocation)
    }

    static func expectSameTrace(_ actual: Trace, _ expected: Trace, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(a.apply == e.apply, sourceLocation: sourceLocation)
            #expect(a.mask == e.mask, sourceLocation: sourceLocation)
        }
    }

    /// A matcher (completion terminates) after `prefix`, and its next mask.
    static func fill(_ compiled: CompiledGrammar, _ prefix: Piece, expectApply: Bool = true,
                     sourceLocation: SourceLocation = #_sourceLocation) -> (matcher: GrammarMatcher, mask: TokenBitmask) {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let accepted = prefix.isEmpty || matcher.acceptBytes(prefix)
        #expect(accepted, sourceLocation: sourceLocation)
        var mask = TokenBitmask(vocabSize: compiled.tokenizerInfo.vocabSize)
        let apply = matcher.fillNextTokenBitmask(&mask)
        if expectApply { #expect(apply, sourceLocation: sourceLocation) }
        return (matcher, mask)
    }

    /// Every token `ids` is allowed by `mask` exactly when a fork of `matcher` accepts it.
    static func expectOracle(_ matcher: GrammarMatcher, _ mask: TokenBitmask, ids: some Sequence<Int>,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        for id in ids {
            var fork = matcher
            let accepted = fork.acceptToken(Int32(id))
            #expect(mask[id] == accepted, "token \(id)", sourceLocation: sourceLocation)
        }
    }

    static func expectOracle(_ matcher: GrammarMatcher, _ mask: TokenBitmask, sourceLocation: SourceLocation = #_sourceLocation) {
        expectOracle(matcher, mask, ids: 0 ..< mask.vocabSize, sourceLocation: sourceLocation)
    }

    /// Eager and dynamic masks after `prefix` agree, and the dynamic one passes the oracle.
    static func expectParityAndOracle(_ grammars: (eager: CompiledGrammar, dynamic: CompiledGrammar), _ prefix: Piece,
                                      oracleIDs: [Int]? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let eager = fill(grammars.eager, prefix, sourceLocation: sourceLocation)
        let dynamic = fill(grammars.dynamic, prefix, sourceLocation: sourceLocation)
        #expect(dynamic.mask == eager.mask, sourceLocation: sourceLocation)
        expectOracle(dynamic.matcher, dynamic.mask, ids: oracleIDs ?? Array(0 ..< dynamic.mask.vocabSize), sourceLocation: sourceLocation)
    }

    static func accepts(_ compiled: CompiledGrammar, _ input: String) -> Bool {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isTerminated
    }

    static func restored(_ compiled: CompiledGrammar) throws -> CompiledGrammar {
        try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: compiled.tokenizerInfo)
    }

    static func concurrently(_ iterations: Int, _ body: @Sendable (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
    }

    // MARK: Byte vocabulary

    static let byteVocab: [Piece] = (0 ... 255).map { [UInt8($0)] }
        + [b("hello"), b("ab"), b("abc"), b("a>"), b("ab>"), b("\":"), b("\"}"), b("12"), b("</s>"), b("中"), b("中文>")]
    static let stop = Int32(byteVocab.firstIndex(of: b("</s>"))!)

    static let byteGrammarCases: [(String, String)] = [
        (#"start: "hello" ("!" | "?")"#, "hello!"),
        (#"start: "(" start ")" | "ab""#, "((ab))"),
        (#"start: /[a-z]{2,4}/ "!""#, "abc!"),
        (#"start: "中" "!""#, "中!"),
        ("start: value \">\"\nvalue[max_chars=2]: /[a-z]*/", "ab>"),
    ]

    @Test(arguments: byteGrammarCases, [false, true])
    func masksMatchEagerAndTokenAcceptance(_ testCase: (String, String), _ cacheEnabled: Bool) throws {
        let (source, text) = testCase
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        let grammar = try Grammar(lark: source, tokenizerInfo: info)
        let eager = try Self.compiler(info, dynamic: false, cache: cacheEnabled).compile(grammar)
        // The compiled grammar must own everything required after the compiler dies.
        let dynamic: CompiledGrammar = try {
            let compiler = Self.compiler(info, dynamic: true, cache: cacheEnabled)
            defer { compiler.clearCache() }
            return try compiler.compile(grammar)
        }()
        var matchers = [GrammarMatcher(eager), GrammarMatcher(dynamic)]
        let bytes = Self.b(text)
        for offset in 0 ... bytes.count {
            let actual = matchers[1].nextTokenBitmask()
            Self.check(actual == matchers[0].nextTokenBitmask())
            // Independent of mask construction: replay the prefix and try every token.
            var oracle = GrammarMatcher(eager)
            for byte in bytes[..<offset] { Self.check(oracle.acceptToken(Int32(byte))) }
            Self.expectOracle(oracle, actual)
            if offset < bytes.count {
                for index in matchers.indices { Self.check(matchers[index].acceptToken(Int32(bytes[offset]))) }
            }
        }
        for index in matchers.indices {
            Self.check(matchers[index].acceptToken(Self.stop))
            #expect(matchers[index].isTerminated)
        }
    }

    @Test(arguments: [false, true])
    func rollbackResetAndRepeatedMasks(_ dynamic: Bool) throws {
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        let compiled = try Self.compiler(info, dynamic: dynamic).compile(regex: "ab|ac")
        var matcher = GrammarMatcher(compiled)
        let initial = matcher.nextTokenBitmask()
        Self.check(matcher.acceptToken(Int32(UInt8(ascii: "a"))))
        let afterA = matcher.nextTokenBitmask()
        let size = compiled.memorySize
        for _ in 0 ..< 5 {
            Self.check(matcher.nextTokenBitmask() == afterA)
            #expect(compiled.memorySize == size)
        }
        Self.check(matcher.acceptToken(Int32(UInt8(ascii: "b"))))
        _ = matcher.nextTokenBitmask()
        matcher.rollback(1)
        Self.check(matcher.nextTokenBitmask() == afterA)
        Self.check(matcher.acceptToken(Int32(UInt8(ascii: "c"))))
        Self.check(matcher.acceptToken(Self.stop))
        matcher.reset()
        Self.check(matcher.nextTokenBitmask() == initial)
    }

    @Test(arguments: [false, true])
    func serializationAndMemoryDuringLazyGeneration(_ warm: Bool) throws {
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        let compiled = try Self.compiler(info, dynamic: true).compile(regex: "ab|ac")
        var reference = GrammarMatcher(try Self.compiler(info, dynamic: false).compile(regex: "ab|ac"))
        let expected = reference.nextTokenBitmask()
        if warm {
            var matcher = GrammarMatcher(compiled)
            _ = matcher.nextTokenBitmask()
        }
        let results = Mutex<[TokenBitmask?]>(Array(repeating: nil, count: 32))
        Self.concurrently(32) { index in
            var matcher: GrammarMatcher
            if index % 3 == 0 {
                guard let restored = try? Self.restored(compiled) else { return }
                matcher = GrammarMatcher(restored)
            } else {
                #expect(compiled.memorySize > 0)
                matcher = GrammarMatcher(compiled)
            }
            let mask = matcher.nextTokenBitmask()
            results.withLock { $0[index] = mask }
        }
        for mask in results.withLock({ $0 }) { #expect(mask == expected) }
    }

    @Test func defaultIsEagerAndEmptyVocabSerializes() throws {
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        let implicit = try GrammarCompiler(tokenizerInfo: info, maxCacheBytes: nil).compile(regex: "hello|world")
        let explicit = try Self.compiler(info, dynamic: false).compile(regex: "hello|world")
        #expect(!GrammarCompiler(tokenizerInfo: info).isDynamicCompilationEnabled)
        #expect(implicit.memorySize == explicit.memorySize)
        let size = implicit.memorySize
        var matcher = GrammarMatcher(implicit)
        _ = matcher.nextTokenBitmask()
        #expect(implicit.memorySize == size)
        let emptyInfo = try TokenizerInfo(encodedVocab: [String]())
        let empty = try Self.compiler(emptyInfo, dynamic: true).compile(regex: "a")
        let restored = try CompiledGrammar(serializedJSON: empty.serializedJSON, tokenizerInfo: emptyInfo)
        #expect(restored.grammar.serializedJSON == empty.grammar.serializedJSON)
    }

    @Test(arguments: [false, true])
    func tokenBudgetEnforcedByMasks(_ dynamic: Bool) throws {
        // max_tokens enforcement is committed by fillNextTokenBitmask. Bare token acceptance may
        // relax the budget, so it is not an oracle for this feature.
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        let grammar = try Grammar(lark: "start: value \">\"\nvalue[max_tokens=2]: /[a-z]+/", tokenizerInfo: info)
        var matcher = GrammarMatcher(try Self.compiler(info, dynamic: dynamic).compile(grammar))
        for byte in Self.b("ab") {
            Self.check(matcher.nextTokenBitmask()[Int(byte)])
            Self.check(matcher.acceptToken(Int32(byte)))
        }
        Self.check(matcher.nextTokenBitmask().allowedTokenIDs == [Int32(UInt8(ascii: ">"))])
        Self.check(matcher.acceptToken(Int32(UInt8(ascii: ">"))))
        Self.check(matcher.acceptToken(Self.stop))
    }

    @Test(arguments: ["Token(97, 98)", "ExcludeToken(120, 121)"], [false, true])
    func tokenEdgesPreserveMasks(_ edge: String, _ cacheEnabled: Bool) throws {
        let info = try Self.info(Self.byteVocab, stops: [Self.stop])
        var matchers = try [false, true].map { dynamic in
            GrammarMatcher(try Self.compiler(info, dynamic: dynamic, cache: cacheEnabled).compile(ebnf: "root ::= \(edge) \"!\""))
        }
        for token in [97, 33, Self.stop] as [Int32] {
            Self.check(matchers[0].nextTokenBitmask() == matchers[1].nextTokenBitmask())
            for index in matchers.indices { Self.check(matchers[index].acceptToken(token)) }
        }
    }

    @Test func dynamicTokenIDValidationIsNotDeferred() throws {
        let compiler = Self.compiler(try Self.info(Self.pieces(["a"])), dynamic: true)
        #expect { try compiler.compile(ebnf: "root ::= Token(10)") } throws: { "\($0)".contains("out of the vocabulary range") }
    }

    // MARK: Printable vocabulary

    static let printable: [Piece] = (32 ..< 127).map { [UInt8($0)] } + pieces(["Ada", "hello", "42", "<call>"])

    static let compilationCases: [(String, String)] = [
        ("ebnf", "hello!"), ("json-schema", #"{"name":"Ada","scores":[1,2]}"#), ("regex", "Ada42"),
        ("builtin-json", #"{"name":"Ada"}"#), ("structural-tag", "prefix<call>X"),
    ]

    static func compileCase(_ name: String, _ compiler: GrammarCompiler) throws -> CompiledGrammar {
        switch name {
        case "ebnf": try compiler.compile(ebnf: "root ::= greeting punctuation\ngreeting ::= \"hello\" | \"hi\"\npunctuation ::= \"!\" | \"?\"\n")
        case "json-schema":
            try compiler.compile(jsonSchema: #"{"type": "object", "properties": {"name": {"type": "string"}, "scores": {"type": "array", "items": {"type": "integer"}}}, "required": ["name", "scores"], "additionalProperties": false}"#,
                                 options: JSONSchemaOptions(anyWhitespace: true))
        case "regex": try compiler.compile(regex: "[A-Z][a-z]{2}[0-9]+")
        case "builtin-json": try compiler.compile(.builtinJSON)
        default:
            try compiler.compile(structuralTagJSON: #"{"type": "structural_tag", "format": {"type": "dispatch", "rules": [["<call>", {"type": "const_string", "value": "X"}]], "loop": false, "excludes": []}}"#)
        }
    }

    @Test(arguments: compilationCases)
    func dynamicCompilationMatchesEagerMasks(_ testCase: (String, String)) throws {
        let info = try Self.info(Self.printable)
        let (eager, dynamic) = try Self.eagerAndDynamic(info) { try Self.compileCase(testCase.0, $0) }
        Self.expectSameTrace(Self.trace(dynamic, testCase.1), Self.trace(eager, testCase.1))
    }

    @Test(arguments: ["{3,}", "{3,5}"])
    func rightRecursiveRuleInsideRepetitionMatchesEagerMasks(_ repeatRange: String) throws {
        let grammar = "root ::= \"[\" item tail \"]\"\ntail ::= unit\(repeatRange)\nunit ::= \", \" item\nitem ::= [0-9]+"
        let (eager, dynamic) = try Self.eagerAndDynamic(try Self.info(Self.printable)) { try $0.compile(ebnf: grammar) }
        Self.expectSameTrace(Self.trace(dynamic, "[1, 2, 3, 4]"), Self.trace(eager, "[1, 2, 3, 4]"))
    }

    @Test(arguments: [false, true])
    func recursiveJSONStringCharacterClassSummaryMatchesEager(_ cacheEnabled: Bool) throws {
        let shared = String(repeating: "a", count: 64)
        let vocab = Self.printable.prefix(95) + Self.pieces(["plainascii", shared, shared + "!", shared + "\"", shared + "\"}", shared + "\"}suffix",
                                                             "中文", "中文\"", "中文\"}", "\\n"]) + [[0xE4], [0xE4, 0xB8], [0xFF]]
        let schema = #"{"type": "object", "properties": {"value": {"type": "string"}}, "required": ["value"], "additionalProperties": false}"#
        let grammars = try Self.eagerAndDynamic(try Self.info(Array(vocab)), cache: cacheEnabled) { try $0.compile(jsonSchema: schema, options: Self.strictCompact) }
        let input = #"{"value": "中文\nA"}"#
        Self.expectSameTrace(Self.trace(grammars.dynamic, input), Self.trace(grammars.eager, input))
        let dynamic = Self.fill(grammars.dynamic, Self.b(#"{"value": ""#))
        Self.expectOracle(dynamic.matcher, dynamic.mask)
    }

    @Test func jsonStringShapeFastPathRequiresStandardEscapeRule() throws {
        let info = try Self.info(Self.pieces(["a", #"\n"#, #"\q"#, "\"", "a\"", #"\\"#]))
        let compiled = try Self.compiler(info, dynamic: true).compile(ebnf: #"""
            root ::= "\"" string_sub
            string_sub ::= "\"" | [^\x00-\x1f"\\] string_sub | "\\" weird_escape string_sub
            weird_escape ::= [q]
            """#)
        let (matcher, mask) = Self.fill(compiled, Self.b("\""))
        Self.expectOracle(matcher, mask)
    }

    @Test func jsonStringMinLengthMasksTrackDecodedCountAcrossPositions() throws {
        let crossing = (0 ..< 17000).map { String(repeating: "x", count: $0 % 60 + 1) + "\"" + String($0) }
        let vocab = (32 ..< 127).filter { $0 != 35 }.map { [UInt8($0)] } + Self.pieces(["#\"", "abcd", "efg", "h"] + crossing)
        let info = try Self.info(vocab)
        let compiled = try Self.compiler(info, dynamic: true, cache: false).compile(jsonSchema: #"{"type": "string", "minLength": 8}"#, options: .xgrammar)
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let sampled = Array(0 ..< 98) + Array(stride(from: 98, to: info.vocabSize, by: 127))
        for chunk in ["\"", "abcd", "efg", "h", "#\""] {
            var mask = TokenBitmask(vocabSize: info.vocabSize)
            if matcher.fillNextTokenBitmask(&mask) { Self.expectOracle(matcher, mask, ids: sampled) }
            Self.check(matcher.acceptString(chunk))
        }
        #expect(matcher.isTerminated)
    }

    static let boundedValueSchema = #"{"type": "object", "properties": {"value": {"type": "string", "minLength": 2, "maxLength": 3}}, "required": ["value"], "additionalProperties": false}"#

    @Test(arguments: [false, true])
    func plainJSONStringLengthMasksMatchEagerAndTokenOracle(_ cacheEnabled: Bool) throws {
        let vocab = Self.pieces(["\"", "\"}", "a", "ab", "abc", "abcd", "a\"", "ab\"", "abc\"", "abcd\"", "é", "é\"", "中", "中\"",
                                 #"\u0061"#, #"\u0061""#, #"\ud83d\ude00"#, #"\ud83d\ude00""#, #"\""#, #"\\"#])
            + [[0xE4], [0xE4, 0xB8], [0xFF]]
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: cacheEnabled) { try $0.compile(jsonSchema: Self.boundedValueSchema, options: Self.strictCompact) }
        for prefix in [#"{"value": ""#, #"{"value": "a"#, #"{"value": "ab"#, #"{"value": "abc"#] {
            Self.expectParityAndOracle(grammars, Self.b(prefix))
        }
    }

    @Test func jsonStringLengthQuoteSuffixIndexMatchesEagerAndTokenOracle() throws {
        let safe = (1 ... 1100).map { String(repeating: "q", count: $0) }
        let crossing = ["a\"}", "aa\"}", "aaa\"}", "aaaa\"}", #"\u0061a"}"#, #"\ud83d\ude00a"}"#, #"a\"b"}"#, "aa\"", "aa\"}x", "aa\"},"]
            + (0 ..< 256).map { "aa\"}invalid" + String(format: "%03d", $0) }
        let vocab = Self.pieces(safe + crossing) + [[0xFF]]
        let info = try Self.info(vocab)
        let grammars = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(jsonSchema: Self.boundedValueSchema, options: Self.strictCompact) }
        let prefix = Self.b(#"{"value": ""#)
        let eager = Self.fill(grammars.eager, prefix)
        let dynamic = Self.fill(grammars.dynamic, prefix)
        #expect(dynamic.mask == eager.mask)
        Self.expectOracle(dynamic.matcher, dynamic.mask, ids: crossing.map { safe.count + crossing.firstIndex(of: $0)! })
        #expect(Self.fill(try Self.restored(grammars.dynamic), prefix).mask == dynamic.mask)
    }

    struct LengthBoundaryCase: Sendable, CustomTestStringConvertible {
        let minimum: Int?, maximum: Int?, prefixLength: Int
        var testDescription: String { "min \(minimum.map(String.init) ?? "-") max \(maximum.map(String.init) ?? "-") seq \(prefixLength)" }
    }

    /// `_json_string_length_boundary_cases`; prefixes past 129 bytes run in release only.
    static var lengthBoundaryCases: [LengthBoundaryCase] {
        var cases: [LengthBoundaryCase] = []
        for boundary in [0, 1, 2, 3, 31, 32, 33, 63, 64, 65, 127, 128, 129, 200, 255, 256, 257, 4095, 4096, 4097, 16383, 16384, 16385, 32768, 65536] {
            for prefix in boundary == 0 ? [0, 1] : [boundary - 1, boundary, boundary + 1] {
                cases += [.init(minimum: boundary, maximum: nil, prefixLength: prefix), .init(minimum: nil, maximum: boundary, prefixLength: prefix)]
            }
        }
        for exact in [0, 1, 32, 64, 128, 256, 4096, 16384, 65536] {
            for prefix in Set([max(0, exact - 1), exact, exact + 1]).sorted() { cases.append(.init(minimum: exact, maximum: exact, prefixLength: prefix)) }
        }
        for (minimum, maximum) in [(0, 1), (31, 33), (63, 65), (127, 129), (4095, 4097)] {
            for prefix in max(0, minimum - 1) ..< maximum + 2 { cases.append(.init(minimum: minimum, maximum: maximum, prefixLength: prefix)) }
        }
        cases = cases.filter { ($0.minimum ?? 0) <= 128 } + [.init(minimum: 129, maximum: nil, prefixLength: 128)]
        return Upstream.runsPressureTests ? cases : cases.filter { $0.prefixLength <= 129 }
    }

    static let lengthBoundaryFixtures = Mutex<[String: (TokenizerInfo, CompiledGrammar, CompiledGrammar)]>([:])

    static func lengthBoundaryFixture(_ minimum: Int?, _ maximum: Int?) throws -> (TokenizerInfo, CompiledGrammar, CompiledGrammar) {
        let key = "\(minimum ?? -1),\(maximum ?? -1)"
        if let hit = lengthBoundaryFixtures.withLock({ $0[key] }) { return hit }
        let lengths = [1, 2, 3, 31, 32, 33, 63, 64, 65, 126, 127, 128, 129, 255, 256, 257, 4095, 4096, 4097, 16383, 16384, 16385]
        let crossing = lengths.flatMap { length in ["\"", "\"}", "\"}x", "\"]", "\":", "\"   "].map { String(repeating: "a", count: length) + $0 } }
            + [#"\u0061"}"#, #"\ud83d\ude00"}"#, #"a\"b"}"#]
        let info = try Self.info(Self.pieces(["a", "\"", "}", "]", ":", " "] + crossing) + [[0xFF]])
        var string = #"{"type": "string""#
        if let minimum { string += #", "minLength": \#(minimum)"# }
        if let maximum { string += #", "maxLength": \#(maximum)"# }
        let schema = #"{"type": "object", "properties": {"value": \#(string)}}, "required": ["value"], "additionalProperties": false}"#
        let (eager, dynamic) = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(jsonSchema: schema, options: Self.strictCompact) }
        let fixture = (info, eager, dynamic)
        lengthBoundaryFixtures.withLock { $0[key] = fixture }
        return fixture
    }

    @Test(arguments: lengthBoundaryCases)
    func jsonStringLengthQuoteSuffixIndexBoundaries(_ testCase: LengthBoundaryCase) throws {
        let (info, eager, dynamic) = try Self.lengthBoundaryFixture(testCase.minimum, testCase.maximum)
        let prefix = Self.b(#"{"value": ""# + String(repeating: "a", count: testCase.prefixLength))
        if let maximum = testCase.maximum, testCase.prefixLength > maximum {
            for compiled in [eager, dynamic] {
                var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
                Self.check(!matcher.acceptBytes(prefix))
            }
            return
        }
        let last = info.vocabSize - 1
        let ids = testCase.prefixLength <= 4097 ? Array(0 ... last)
            : Array(Set([0, 1, 2, 3, 4, 5, 6, 7, 8, info.vocabSize / 4, info.vocabSize / 2, 3 * info.vocabSize / 4, last - 1, last])).sorted()
        Self.expectParityAndOracle((eager, dynamic), prefix, oracleIDs: ids)
    }

    @Test(arguments: [false, true])
    func unboundedJSONStringQuoteSuffixIndexMatchesEagerAndTokenOracle(_ withOtherLengthRule: Bool) throws {
        let safe = (1 ... 1100).map { String(repeating: "q", count: $0) }
        let crossing = [1, 2, 63, 64, 127, 128, 129, 255, 256, 4095, 4096, 4097].flatMap { length in
            ["\"", "\"}", "\"}x", "\"]", "\":", "\"   "].map { String(repeating: "a", count: length) + $0 }
        } + (0 ..< 256).map { "aa\"}invalid" + String(format: "%03d", $0) } + [#"\u0061"}"#, #"\ud83d\ude00"}"#, #"a\"b"}"#]
        let info = try Self.info(Self.pieces(safe + crossing + ["a", "\"", "}", "]", ":", " "]))
        let other = withOtherLengthRule ? #", "optional_bounded": {"type": "string", "minLength": 1, "maxLength": 2}"# : ""
        let schema = #"{"type": "object", "properties": {"value": {"type": "string"}\#(other)}, "required": ["value"], "additionalProperties": false}"#
        let grammars = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(jsonSchema: schema, options: Self.strictCompact) }
        for prefixLength in Upstream.runsPressureTests ? [0, 16384] : [0, 300] {
            let prefix = Self.b(#"{"value": ""# + String(repeating: "a", count: prefixLength))
            Self.expectParityAndOracle(grammars, prefix)
            var (matcher, mask) = Self.fill(grammars.dynamic, prefix)
            var repeated = TokenBitmask(vocabSize: info.vocabSize)
            Self.check(matcher.fillNextTokenBitmask(&repeated))
            #expect(repeated == mask)
            Self.check(matcher.acceptString("a"))
            mask = repeated
        }
    }

    @Test func genericLocalCompletionMaskMatchesOracleAndSurvivesSerialization() throws {
        let safe = (1 ... 1100).map { String(repeating: "q", count: $0) }
        let crossing = (0 ..< 384).map { String(repeating: "a", count: 1 + $0 % 257) + ";" + ($0 % 3 == 0 ? ">" : "x" + String(format: "%03d", $0)) }
        let info = try Self.info(Self.pieces(safe + crossing + ["a", "q", ";", ">", #"\1;>"#]) + [[0xFF]])
        let grammar = try Grammar(ebnf: #"""
            root ::= "<" body ">"
            body ::= (";" | [a-z] body | "\\" escape body)
            escape ::= [0-9]
            """#)
        let grammars = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(grammar) }
        Self.expectParityAndOracle(grammars, Self.b("<"))
        let restored = Self.fill(try Self.restored(grammars.dynamic), Self.b("<"))
        #expect(restored.mask == Self.fill(grammars.dynamic, Self.b("<")).mask)
        Self.expectOracle(restored.matcher, restored.mask)
    }

    @Test func jsonShapedRuleWithNonJSONEscapeUsesActualLanguage() throws {
        let vocab = Self.pieces([#"\q"}"#, #"\q"x"#, #"\n"}"#, "a\"}", "\"}", "a", #"\q"#]) + [[0xFF]]
        let grammar = try Grammar(ebnf: #"""
            root ::= "\"" basic_string_sub "}"
            basic_string_sub ::= ("\"" | [^\0-\x1f\"\\\r\n] basic_string_sub | "\\" fake_escape basic_string_sub)
            fake_escape ::= "q"
            """#)
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) { try $0.compile(grammar) }
        Self.expectParityAndOracle(grammars, Self.b("\""))
        let mask = Self.fill(grammars.dynamic, Self.b("\"")).mask
        #expect(mask[0] && !mask[2])
    }

    @Test func localCompletionFallsBackForNestedNonredundantLookahead() throws {
        let vocab = Self.pieces(["a", ";", "ax", "ax;", "a;>", ";>", ">", "z"]) + [[0xFF]]
        let grammar = try Grammar(ebnf: "root ::= \"<\" body \">\"\nbody ::= (\";\" | \"a\" guarded body)\nguarded ::= \"x\" (= \"z\")")
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) { try $0.compile(grammar) }
        Self.expectParityAndOracle(grammars, Self.b("<"))
    }

    @Test func localCompletionAllAcceptedSuffixesMatchEagerAndOracle() throws {
        let vocab = Self.pieces((1 ..< 40).map { String(repeating: "q", count: $0) } + (1 ..< 40).map { String(repeating: "a", count: $0) + ";>" }
            + [";>", ";", "a", "q", ">"]) + [[0xFF]]
        let grammar = try Grammar(ebnf: "root ::= \"<\" body \">\"\nbody ::= (\";\" | [a-z] body)")
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) { try $0.compile(grammar) }
        Self.expectParityAndOracle(grammars, Self.b("<"))
        let mask = Self.fill(grammars.dynamic, Self.b("<")).mask
        #expect(mask[vocab.firstIndex(of: Self.b(";>"))!] && mask[vocab.firstIndex(of: Self.b("a;>"))!])
    }

    @Test(arguments: [false, true])
    func localCompletionRespectsRuleOwnLookahead(_ dynamic: Bool) throws {
        let vocab = Self.pieces(["a;!", "aa;!", "a;>", "a", ";", "!", ">"]) + [[0xFF]]
        let info = try Self.info(vocab)
        for source in ["root ::= \"<\" body \"!\"\nbody ::= (\";\" | [a-z] body) (= \">\")",
                       "root ::= \"<\" body \"!\"\nbody ::= (\";\" | \":\" | [a-z] body) (= \">\")"] {
            let compiled = try Self.compiler(info, dynamic: dynamic, cache: false).compile(ebnf: source)
            let mask = Self.fill(compiled, Self.b("<")).mask
            #expect(!mask[0] && !mask[1] && !mask[2])
            #expect(mask[3] && mask[4])
        }
    }

    @Test(arguments: [false, true])
    func emailFormatRegexFSMMasksMatchEagerAndTokenOracle(_ cacheEnabled: Bool) throws {
        let shared = String(repeating: "a", count: 64)
        let vocab = Self.pieces(["a", "abc", shared + "@example.com", shared + "@example.com-", shared + ".doe@example.com\"}", ".doe", ".doe@example",
                                 "@example", "@example.com", ".com", ".com\"", ".com\"}", "-", "..", ".-", "@", "\"", "\\\"", "\\\\", "\",", "é", "中", "a中"])
            + [[0xE4], [0xE4, 0xB8], [0xFF]]
        let schema = #"{"type": "object", "properties": {"email": {"type": "string", "format": "email"}}, "required": ["email"], "additionalProperties": false}"#
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: cacheEnabled) { try $0.compile(jsonSchema: schema, options: Self.strictCompact) }
        for email in ["john.doe@example-domain.com", #"\"john..doe\"@example.org"#] {
            let scalars = Array(email.unicodeScalars)
            for length in 0 ... scalars.count {
                var prefix = #"{"email": ""#
                prefix.unicodeScalars.append(contentsOf: scalars[..<length])
                Self.expectParityAndOracle(grammars, Self.b(prefix))
            }
        }
    }

    @Test func dynamicMasksAreCached() throws {
        let info = try Self.info(Self.printable)
        let dynamic = try Self.compiler(info, dynamic: true).compile(.builtinJSON)
        let eager = try Self.compiler(info, dynamic: false).compile(.builtinJSON)
        let initial = dynamic.memorySize
        #expect(initial < eager.memorySize)
        _ = Self.trace(dynamic, #"{"name":"Ada"}"#)
        let populated = dynamic.memorySize
        #expect(populated > initial)
        _ = Self.trace(dynamic, #"{"name":"Ada"}"#)
        #expect(dynamic.memorySize == populated)
    }

    @Test func serializationMaterializesDynamicMasks() throws {
        let info = try Self.info(Self.printable)
        let dynamic = try Self.compileCase("ebnf", Self.compiler(info, dynamic: true))
        let initial = dynamic.memorySize
        let restored = try Self.restored(dynamic)
        #expect(dynamic.memorySize > initial)
        #expect(!restored.isDynamicallyCompiled)
        for input in ["hello!", "hi?"] { Self.expectSameTrace(Self.trace(restored, input), Self.trace(dynamic, input)) }
    }

    @Test func concurrentDynamicMaskGeneration() throws {
        let dynamic = try Self.compileCase("json-schema", Self.compiler(try Self.info(Self.printable), dynamic: true))
        let input = #"{"name":"Ada","scores":[1,2]}"#
        let traces = Mutex<[[TokenBitmask]]>([])
        Self.concurrently(32) { _ in
            let trace = Self.trace(dynamic, input).map(\.mask)
            traces.withLock { $0.append(trace) }
        }
        let all = traces.withLock { $0 }
        #expect(all.count == 32)
        for trace in all { #expect(trace == all[0]) }
    }

    @Test func sharedCharacterClassRepeatMasksSurviveCompilerCacheClear() throws {
        let info = try Self.info(Self.pieces([">", "<", "[", "]", "a", "b", "ab", "ab<", "ab]"]) + [[0xFF]])
        let compiler = Self.compiler(info, dynamic: true)
        let first = try compiler.compile(ebnf: "root ::= \">\" value \"<\"\nvalue ::= [a-z]{2,4}")
        let expectedFirst = Self.trace(first, ">ab<").map(\.mask)
        compiler.clearCache()
        let second = try compiler.compile(ebnf: "root ::= \"[\" value \"]\"\nvalue ::= [a-z]{2,4}")
        let expectedSecond = Self.trace(second, "[ab]").map(\.mask)
        Self.concurrently(16) { index in
            let actual = index % 2 == 0 ? Self.trace(first, ">ab<").map(\.mask) : Self.trace(second, "[ab]").map(\.mask)
            #expect(actual == (index % 2 == 0 ? expectedFirst : expectedSecond))
        }
    }

    @Test func cacheDisabledBoundedCharacterClassMasksMatchEager() throws {
        let info = try Self.info((32 ..< 127).map { [UInt8($0)] } + Self.pieces(["ab", "abc", "abcd", "ab>", ">"]))
        let (eager, dynamic) = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(ebnf: "root ::= value \">\"\nvalue ::= [a-z]{2,4}") }
        _ = GrammarMatcher(dynamic, terminateWithoutStopToken: true)
        Self.expectSameTrace(Self.trace(dynamic, "ab>"), Self.trace(eager, "ab>"))
    }

    static let deterministicBytePathCases: [(String, [Piece], [Piece])] = [
        ("root ::= literal \"x\"\nliteral[capture=\"literal\"] ::= \"abc\"", pieces(["", "a", "ab", "abc"]),
         pieces(["a", "ab", "abc", "abc", "abcx", "abcy", "x", "xy", "bad"])),
        ("root ::= left \"!\" | right \"?\"\nleft[capture=\"left\"] ::= \"abc\"\nright[capture=\"right\"] ::= \"abd\"", pieces(["", "a", "ab", "abc"]),
         pieces(["a", "ab", "abc", "abc!", "abc?", "abd", "abd!", "abd?", "abe", "!", "?"])),
        ("root ::= literal \"x\"\nliteral[capture=\"literal\"] ::= \"abc\" | \"abd\"", pieces(["", "a", "ab", "abc"]),
         pieces(["a", "ab", "abc", "abcx", "abc?", "abd", "abdx", "abd?", "abe", "x"])),
        ("root ::= property\nproperty[capture=\"property\"] ::= \"\\\"name\\\":\" value\nvalue ::= [0-9]", pieces(["", "\"", "\"name", "\"name\":"]),
         pieces(["\"", "\"name", "\"name\":", "\"name\":1", "\"name\":x", "1", "x"])),
        ("root ::= property\nproperty[capture=\"property\"] ::= \"\\\"name\\\":\" value | \"\\\"address\\\":\" value\nvalue ::= [0-9]",
         pieces(["", "\"", "\"name", "\"name\":", "\"address", "\"address\":"]),
         pieces(["\"", "\"name", "\"name\":", "\"name\":1", "\"address", "\"address\":", "\"address\":1", "\"other\":1", "1"])),
        ("root ::= literal \"x\"\nliteral[capture=\"literal\"] ::= \"é\"", [[], [0xC3], b("é")], [[0xC3], b("é"), b("éx"), b("éy"), b("x"), [0xFF]]),
    ]

    @Test(arguments: deterministicBytePathCases)
    func cacheDisabledDeterministicBytePathMasksMatchTokenOracle(_ testCase: (String, [Piece], [Piece])) throws {
        let (grammar, prefixes, vocab) = testCase
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) { try $0.compile(ebnf: grammar) }
        for prefix in prefixes {
            let eager = Self.fill(grammars.eager, prefix, expectApply: false)
            let dynamic = Self.fill(grammars.dynamic, prefix, expectApply: false)
            #expect(dynamic.mask == eager.mask)
            Self.expectOracle(dynamic.matcher, dynamic.mask)
        }
    }

    @Test func additionalPropertyExclusionSinkMasksMatchTokenOracle() throws {
        let vocab = Self.pieces(["\"", "n", "na", "name", "name\"", "name\":", "name\":1", "p", "profile", "profile\":", "x", "xname", "xname\"",
                                 "xname\":", "x中", "x🙂"])
            + [Self.b("x") + [0xE4], Self.b("x") + [0xE4, 0xB8], Self.b("x") + [0xE4, 0xB8, 0xAD, 0x22], Self.b("x") + [0xFF], Self.b("x") + [0xC0, 0x80]]
            + Self.pieces(["x\\u0061", "x\\", "x\\u", "x\\u0", "x\\u00", "x\\u006", "x\\u0061\"", "x\\q", "x\\u0g", "x\\\"", "x\n", " other",
                           "\\\"", "\\u0061", "\\n"])
            + [[0xFF]] + Self.pieces([":", "1", "}"])
        let schema = #"{"type": "object", "properties": {"name": {"type": "integer"}, "profile": {"type": "integer"}}, "additionalProperties": {"type": "integer"}}"#
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) {
            try $0.compile(jsonSchema: schema, options: JSONSchemaOptions(anyWhitespace: false, strict: false))
        }
        for prefix in [#"{""#, #"{"n"#, #"{"na"#, #"{"name"#, #"{"p"#, #"{"x"#, #"{"xname"#] {
            Self.expectParityAndOracle(grammars, Self.b(prefix))
        }
    }

    @Test func limitedCompilerCacheDoesNotRetainGrowingGrammar() throws {
        let limit = 64 * 1024
        let compiler = Self.compiler(try Self.info(Self.printable), dynamic: true, maxCacheBytes: limit)
        let dynamic = try compiler.compile(.builtinJSON)
        #expect(compiler.cacheSizeBytes == 0)
        Self.concurrently(9) { index in
            if index == 8 {
                for _ in 0 ..< 100 { #expect((0 ... limit).contains(compiler.cacheSizeBytes)) }
            } else {
                _ = Self.trace(dynamic, #"{"name":"Ada"}"#)
            }
        }
        #expect((0 ... limit).contains(compiler.cacheSizeBytes))
        #expect(try compiler.compile(.builtinJSON) !== dynamic)
    }

    @Test func ruleMaskSharingDoesNotCrossContextDependentRules() throws {
        let info = try Self.info(Self.printable)
        let dynamicCompiler = Self.compiler(info, dynamic: true)
        _ = Self.trace(try dynamicCompiler.compile(ebnf: "root ::= \"a\" shared \"z\"\nshared ::= [x]+"), "axxz")
        let bounded = "root ::= \"a\" shared \"z\"\nshared[max_tokens=1] ::= [x]+"
        let expected = Self.trace(try Self.compiler(info, dynamic: false).compile(ebnf: bounded), "axz")
        Self.expectSameTrace(Self.trace(try dynamicCompiler.compile(ebnf: bounded), "axz"), expected)
    }

    @Test(arguments: [("{0}", ""), ("{1}", "a"), ("{0,1}", ""), ("{1,3}", "ab"), ("{63,65}", String(repeating: "a", count: 64)),
                      ("{127,129}", String(repeating: "a", count: 128)), ("{255,257}", String(repeating: "a", count: 256)), ("{2,}", "abc")])
    func preservedRepetitionRangesMatchEagerMasks(_ repeatRange: String, _ value: String) throws {
        let vocab = Self.pieces([">", "<", "a", "aa", "ab", "abc", "b", "ba", "c"]) + [[0xC3], [0xFF]]
        let (eager, dynamic) = try Self.eagerAndDynamic(try Self.info(vocab)) { try $0.compile(ebnf: "root ::= \">\" [a-z]\(repeatRange) \"<\"") }
        Self.expectSameTrace(Self.trace(dynamic, ">" + value + "<"), Self.trace(eager, ">" + value + "<"))
    }

    static let repeatBoundaryCases: [(String, String, [Piece])] = [
        ("root ::= unit{0,1} unit \"x\"\nunit ::= \"a\"", "aax", pieces(["a", "x", "aa", "ax", "aaa", "aax"]) + [[0xC3], [0xFF]]),
        ("root ::= unit unit{0,1} \"x\"\nunit[capture=\"u\"] ::= \"a\"", "aax", pieces(["a", "x", "aa", "ax", "aaa", "aax"]) + [[0xC3], [0xFF]]),
        ("root ::= unit{2,3} unit \"x\"\nunit ::= \"a\"", "aaaax", pieces(["a", "x", "aa", "ax", "aaa", "aax", "aaaa", "aaax", "aaaax"]) + [[0xC3], [0xFF]]),
        ("root ::= unit{0,1} unit \"x\"\nunit ::= \"é\"", "ééx", pieces(["é", "x", "éé", "éx", "ééx"]) + [[0xC3], [0xA9], [0xFF]]),
    ]

    @Test(arguments: [false, true], repeatBoundaryCases)
    func preservedRepetitionRangesMatchMultitokensAcrossRepeatBoundaries(_ cacheEnabled: Bool, _ testCase: (String, String, [Piece])) throws {
        let (grammar, value, vocab) = testCase
        let (eager, dynamic) = try Self.eagerAndDynamic(try Self.info(vocab), cache: cacheEnabled) { try $0.compile(ebnf: grammar) }
        Self.expectSameTrace(Self.trace(dynamic, value), Self.trace(eager, value))
        guard value == "aax" else { return }
        let aa = Int32(vocab.firstIndex(of: Self.b("aa"))!), x = Int32(vocab.firstIndex(of: Self.b("x"))!), aax = Int32(vocab.firstIndex(of: Self.b("aax"))!)
        for compiled in [eager, dynamic] {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            Self.check(matcher.acceptToken(aa) && !matcher.isTerminated)
            Self.check(matcher.acceptToken(x) && matcher.isTerminated)
            var whole = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            Self.check(whole.acceptToken(aax) && whole.isTerminated)
        }
    }

    @Test(arguments: [("[a-z]", "a"), ("[^b]", "é"), ("[a-zа-я一-龥]", "中")])
    func dynamicSingleCharacterClassMasksMatchEager(_ characterClass: String, _ value: String) throws {
        let vocab = Self.pieces([">", "<", "a", "ab", "a<", "b", "é", "中"]) + [[0xE4], [0xE4, 0xB8], [0xFF]]
        let (eager, dynamic) = try Self.eagerAndDynamic(try Self.info(vocab)) { try $0.compile(ebnf: "root ::= \">\" value \"<\"\nvalue ::= \(characterClass)") }
        Self.expectSameTrace(Self.trace(dynamic, ">" + value + "<"), Self.trace(eager, ">" + value + "<"))
    }

    @Test(arguments: [("[a-z]", "abc"), ("[a-zа-я一-龥]", "a中я"), ("[^b]", "aé中")])
    func recursiveCharacterClassMasksMatchEagerAndTokenOracle(_ characterClass: String, _ value: String) throws {
        let shared = String(repeating: "a", count: 64)
        let vocab = Self.pieces([">", "<", "a", "abc", "abc<", "b", "é", "中", "я", "a中", "a中<", shared, shared + "x", shared + "!", shared + "<"])
            + [[0xC3], [0xE4], [0xE4, 0xB8], [0xFF]]
        let grammar = "root ::= \">\" run \"<\"\nrun ::= (\(characterClass) run | \(characterClass)) (=(\"<\"))"
        let grammars = try Self.eagerAndDynamic(try Self.info(vocab), cache: false) { try $0.compile(ebnf: grammar) }
        Self.expectSameTrace(Self.trace(grammars.dynamic, ">" + value + "<"), Self.trace(grammars.eager, ">" + value + "<"))
        for prefix in [">", ">" + String(value.unicodeScalars.first!)] { Self.expectParityAndOracle(grammars, Self.b(prefix)) }
    }

    static func letterPairs(_ letters: ClosedRange<Character>) -> [String] {
        let range = letters.lowerBound.asciiValue! ... letters.upperBound.asciiValue!
        return range.flatMap { first in range.map { String(UnicodeScalar(first)) + String(UnicodeScalar($0)) } }
    }

    @Test func continuationTransitionCacheIsolatedBetweenParserStates() throws {
        let vocab = Self.pieces(Self.letterPairs("a" ... "m").map { $0 + "!" } + Self.letterPairs("n" ... "z").map { $0 + "?" } + ["a", "n", "!", "?", "x"]) + [[0xFF]]
        let compiled = try Self.compiler(try Self.info(vocab), dynamic: true).compile(ebnf: "root ::= left \"!\" | right \"?\"\nleft ::= [a-m] left | \"\"\nright ::= [n-z] right | \"\"")
        let (matcher, mask) = Self.fill(compiled, [])
        Self.expectOracle(matcher, mask)
    }

    @Test func continuationMaskCacheClassifiesTokensIndependentlyOfOtherStates() throws {
        let vocab = Self.pieces(["\"x"] + Self.letterPairs("a" ... "z").map { "\"x" + $0 } + ["a", "x", "Q"])
        let compiled = try Self.compiler(try Self.info(vocab), dynamic: true, cache: false)
            .compile(ebnf: "root ::= value \"x\" | branch\nvalue[temperature=0.7] ::= [a-z]* \"\\\"\"\nbranch ::= \"aQ\" | \"\\\"xaa\"")
        let shared = vocab.firstIndex(of: Self.b("\"xaa"))!
        var (matcher, initial) = Self.fill(compiled, [])
        #expect(initial[shared])
        Self.check(matcher.acceptToken(Int32(vocab.firstIndex(of: Self.b("a"))!)))
        var cached = TokenBitmask(vocabSize: vocab.count)
        Self.check(matcher.fillNextTokenBitmask(&cached))
        #expect(!cached[shared])
        Self.expectOracle(matcher, cached)
        initial = cached
    }

    @Test func continuationMaskCacheIsClearedBeforeRollbackRowReuse() throws {
        let suffixes = Self.letterPairs("a" ... "l")
        let vocab = Self.pieces(["L\"", "R\"", "\"x", "\"y"] + suffixes.map { "\"x" + $0 } + suffixes.map { "\"y" + $0 } + ["a", "x", "y"])
        let compiled = try Self.compiler(try Self.info(vocab), dynamic: true, cache: false)
            .compile(ebnf: "root ::= \"L\\\"\" wrapper \"x\" | \"R\\\"\" wrapper \"y\"\nwrapper ::= value\nvalue[temperature=0.7] ::= [a-z]* \"\\\"\"")
        func id(_ text: String) -> Int32 { Int32(vocab.firstIndex(of: Self.b(text))!) }
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        func fill() -> TokenBitmask {
            var mask = TokenBitmask(vocabSize: vocab.count)
            Self.check(matcher.fillNextTokenBitmask(&mask))
            return mask
        }
        Self.check(matcher.acceptToken(id("L\"")))
        let left = fill()
        #expect(left[Int(id("\"x"))] && !left[Int(id("\"y"))])
        Self.check(matcher.acceptToken(id("a")))
        #expect(fill() == left)
        matcher.rollback(2)
        Self.check(matcher.acceptToken(id("R\"")))
        let right = fill()
        #expect(!right[Int(id("\"x"))] && right[Int(id("\"y"))])
        Self.expectOracle(matcher, right)
    }

    @Test(arguments: [false, true])
    func sharedParserFeaturesPreserveBudgetAndCaptureBehavior(_ dynamic: Bool) throws {
        let info = try TokenizerInfo(encodedVocab: ["ab ", "cd", " ", "</t>", "1", "<t>", "x"])
        let grammar = try Grammar(lark: "start: r \"<t>\"\nr[max_tokens=3, capture]: TEXT\nTEXT: /(\\n|.)*/", tokenizerInfo: info)
        let compiled = try Self.compiler(info, dynamic: dynamic).compile(grammar)
        for _ in 0 ..< 4 {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            Self.check([0, 1, 2].allSatisfy { matcher.acceptToken($0) })
            var mask = TokenBitmask(vocabSize: info.vocabSize)
            Self.check(matcher.fillNextTokenBitmask(&mask))
            #expect(mask.allowedTokenIDs == [5])
            Self.check(matcher.acceptToken(5) && matcher.isTerminated)
            #expect(matcher.captures() == [GrammarCapture(name: "r", bytes: Self.b("ab cd "))])
        }
        let nested = try Self.compiler(try TokenizerInfo(encodedVocab: [String]()), dynamic: dynamic)
            .compile(try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[max_chars=2, capture=\"inner\", suffix=\"!\"]: /[a-z]*/"))
        for _ in 0 ..< 4 {
            for (value, expected) in [("a!z", [("inner", "a"), ("outer", "a!z")]), ("abz", [("inner", "ab"), ("outer", "abz")])] {
                var matcher = GrammarMatcher(nested, terminateWithoutStopToken: true)
                Self.check(matcher.acceptString(value) && matcher.isTerminated)
                #expect(matcher.captures() == expected.map { GrammarCapture(name: $0.0, bytes: Self.b($0.1)) })
            }
        }
    }

    @Test(arguments: [false, true], ["Token", "ExcludeToken"])
    func ruleMaskSharingDistinguishesTokenEdgePayloads(_ dynamic: Bool, _ edge: String) throws {
        let info = try Self.info(Self.pieces(["a", "b", "c"]))
        let cached = Self.compiler(info, dynamic: dynamic, cache: true)
        let uncached = Self.compiler(info, dynamic: dynamic, cache: false)
        func initialMask(_ compiled: CompiledGrammar) -> TokenBitmask { Self.fill(compiled, []).mask }
        let first = initialMask(try cached.compile(ebnf: "root ::= \(edge)(0)"))
        let actual = initialMask(try cached.compile(ebnf: "root ::= \(edge)(1)"))
        let expected = initialMask(try uncached.compile(ebnf: "root ::= \(edge)(1)"))
        #expect(first != expected)
        #expect(actual == expected)
    }

    @Test(arguments: [false, true])
    func ruleMaskSharingDistinguishesLookaheadExpressionBoundaries(_ dynamic: Bool) throws {
        let info = try Self.info(Self.pieces(["p", "qac", "qa\u{01}\u{01}aabb", "q"] + (0 ..< 28).map { "invalid-\($0)" }))
        let cached = Self.compiler(info, dynamic: dynamic, cache: true)
        let uncached = Self.compiler(info, dynamic: dynamic, cache: false)
        func grammar(_ suffix: String) -> String { "root ::= \"p\" target \(suffix)\ntarget ::= [q] (= \(suffix))" }
        func maskAfterPrefix(_ compiler: GrammarCompiler, _ source: String) throws -> TokenBitmask {
            var matcher = GrammarMatcher(try compiler.compile(ebnf: source), terminateWithoutStopToken: true)
            Self.check(matcher.acceptToken(0))
            var mask = TokenBitmask(vocabSize: info.vocabSize)
            Self.check(matcher.fillNextTokenBitmask(&mask))
            return mask
        }
        let byteString = #""a\u0001\u0001aabb""#, characterClass = "\"a\" [^ab]"
        let first = try maskAfterPrefix(cached, grammar(byteString))
        let actual = try maskAfterPrefix(cached, grammar(characterClass))
        let expected = try maskAfterPrefix(uncached, grammar(characterClass))
        #expect(first != expected)
        #expect(actual == expected)
    }

    @Test(arguments: [false, true], [("root ::= (\"b\"{0,1}){2,2}", ["", "b", "bb"], ["bbb"]),
                                     ("root ::= unit{63,64} \"x\"\nunit ::= inner{0,2}\ninner ::= \"c\"", ["x", "cx", String(repeating: "c", count: 128) + "x"],
                                      ["c", String(repeating: "c", count: 129) + "x"])])
    func preservedRepetitionRangesCompleteIndirectlyNullableChildren(_ cacheEnabled: Bool, _ testCase: (String, [String], [String])) throws {
        let (grammar, acceptedValues, rejectedValues) = testCase
        let info = try Self.info(Self.pieces(["b", "c", "x", "bb", "cx"]) + [[0xFF]])
        let (eager, dynamic) = try Self.eagerAndDynamic(info, cache: cacheEnabled) { try $0.compile(ebnf: grammar) }
        let restored = try Self.restored(dynamic)
        for value in acceptedValues {
            Self.check(Self.accepts(eager, value))
            for candidate in [dynamic, restored] {
                Self.check(Self.accepts(candidate, value))
                Self.expectSameTrace(Self.trace(candidate, value), Self.trace(eager, value))
            }
        }
        for value in rejectedValues {
            for candidate in [eager, dynamic, restored] { Self.check(!Self.accepts(candidate, value)) }
        }
    }

    @Test func nestedNullableRepetitionPreservesCapturesInDynamicMode() throws {
        let info = try Self.info(Self.pieces(["b", "x", "bx", "bbx"]))
        let grammar = try Grammar(lark: "start: (item{2,3}){2,2} \"x\"\nitem[capture=\"item\"]: \"\" | \"b\"", tokenizerInfo: info)
        let (eager, dynamic) = try Self.eagerAndDynamic(info, cache: false) { try $0.compile(grammar) }
        let restored = try Self.restored(dynamic)
        for value in ["x", "bx", "bbx", "bbbx", "bbbbx"] {
            var expected = GrammarMatcher(eager, terminateWithoutStopToken: true)
            Self.check(expected.acceptString(value) && expected.isTerminated)
            for candidate in [dynamic, restored] {
                var matcher = GrammarMatcher(candidate, terminateWithoutStopToken: true)
                Self.check(matcher.acceptString(value) && matcher.isTerminated)
                #expect(matcher.captures() == expected.captures())
            }
        }
    }

    @Test func getAllowEmptyRuleIDsWithPreservedZeroLowerRepeat() throws {
        let compiled = try Self.compiler(try TokenizerInfo(encodedVocab: [String]()), dynamic: true)
            .compile(ebnf: "root ::= unit\nunit ::= inner{0,2}\ninner ::= \"a\"")
        // Repetition expansion can introduce additional nullable helper rules.
        let storage = compiled.grammar.storage
        #expect(storage.allowsEmpty(storage.rootRuleID))
        Self.check(Self.accepts(compiled, ""))
    }

    @Test func repeatedRegexFSMReusePreservesNullableRules() throws {
        let info = try Self.info(Self.pieces(["!", "a", "aa", "b"]))
        let grammar = try Grammar(lark: "start: left \"!\" right\nleft: /a*/\nright: /a*/")
        for dynamic in [false, true] {
            let compiled = try Self.compiler(info, dynamic: dynamic).compile(grammar)
            for value in ["!", "a!", "!a", "aa!aa"] { Self.check(Self.accepts(compiled, value)) }
            for value in ["", "aa", "!!", "b!"] { Self.check(!Self.accepts(compiled, value)) }
        }
    }

    @Test func limitedCompilerCacheEvictsValueThatCrossesLimit() throws {
        let limit = 64 * 1024
        let compiler = Self.compiler(try Self.info((32 ..< 127).map { [UInt8($0)] }), dynamic: false, threads: 4, maxCacheBytes: limit)
        let compiled = try compiler.compile(.builtinJSON)
        #expect(compiler.cacheSizeBytes <= limit)
        Self.check(Self.accepts(compiled, #"{"a": 1}"#))
    }

    @Test(arguments: [false, true])
    func boundedWordPatternPropertyRejectsInvalidNestedValueToken(_ dynamic: Bool) throws {
        let schema = #"{"type": "object", "patternProperties": {"\\w{1,15}": {"type": "object", "properties": {"x": {"type": "integer"}}, "required": ["x"]}}}"#
        let info = try Self.info(Self.pieces([#"{"q": {}}"#, #"{"q": {"x": 1}}"#]))
        let compiled = try Self.compiler(info, dynamic: dynamic, cache: false).compile(jsonSchema: schema, options: Self.strictCompact)
        var invalid = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        var valid = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        Self.check(!invalid.acceptToken(0))
        Self.check(valid.acceptToken(1) && valid.isTerminated)
    }

    @Test(arguments: [false, true])
    func patternLengthFiltersNarrowCachedAcceptSet(_ dynamic: Bool) throws {
        let info = try Self.info(Self.pieces(["\"", "1", "1234567890", "12345678901", "1234567890\""] + (0 ..< 1200).map { "x\($0)" }))
        let compiled = try Self.compiler(info, dynamic: dynamic, cache: false)
            .compile(jsonSchema: #"{"type": "string", "pattern": "^[0-9]{10,10}$", "minLength": 10, "maxLength": 10}"#, options: JSONSchemaOptions(anyWhitespace: false))
        for candidate in [compiled, try Self.restored(compiled)] {
            let mask = Self.fill(candidate, Self.b("\"")).mask
            #expect(mask[1] && mask[2] && !mask[3] && mask[4] && !mask[5])
        }
    }

    @Test func regexFSMCacheDistinguishesJSONStringMode() throws {
        let grammar = try Grammar(ebnf: "root ::= plain \"!\" plain json \"!\" json\nplain ::= Regex(\".\")\njson ::= Regex(\".\", json_string=true)")
        for dynamic in [false, true] {
            let compiled = try Self.compiler(try TokenizerInfo(encodedVocab: [String]()), dynamic: dynamic).compile(grammar)
            for value in ["\"!ab!c", "\\!ab!c", "a!bc!d"] { Self.check(Self.accepts(compiled, value), "\(value)") }
            for value in ["a!a\"!b", "a!a\\!b", "a!ab!\n"] { Self.check(!Self.accepts(compiled, value), "\(value)") }
        }
    }

    @Test func largeUnicodeCharacterClassMatchesEagerAndTokenOracle() throws {
        let codepoints = Array(stride(from: 0x0100, to: 0x0300, by: 2)) + Array(stride(from: 0x4E00, to: 0x5000, by: 2))
        let characterClass = codepoints.map { String(format: "\\\\u%04X", $0) }.joined()
        let vocab = Self.pieces(["Ā", "一", "Ā一", "一Ā一", "Ā一Ā一", "Ā一Ā一Ā", "ā", "丁", "Ā>", "一>", ">", "\"", "Ā\"", "Ā\">"]) + [[0xFF]]
            + codepoints.filter { $0 != 0x0100 && $0 != 0x4E00 }.map { Self.b(String(UnicodeScalar($0)!)) }
        let info = try Self.info(vocab)
        let schema = #"{"type": "string", "pattern": "^[\#(characterClass)]{1,4}$"}"#
        let compiled = try [false, true].map { dynamic in
            try Self.compiler(info, dynamic: dynamic, cache: false).compile(jsonSchema: schema, options: Self.strictCompact)
        }
        let text = Array("Ā一Ā一".unicodeScalars)
        for length in 0 ..< 5 {
            var prefix = "\""
            prefix.unicodeScalars.append(contentsOf: text[..<length])
            var masks: [TokenBitmask] = []
            for grammar in compiled {
                let (matcher, mask) = Self.fill(grammar, Self.b(prefix))
                Self.expectOracle(matcher, mask)
                // Check the intended language as well as agreement between implementations.
                #expect(mask[0] == (length < 4))
                #expect(mask[2] == (length + 2 <= 4))
                #expect(mask[11] == (length >= 1))
                for id in 15 ..< info.vocabSize { #expect(mask[id] == (length < 4)) }
                for id in [5, 6, 7, 8, 9, 10, 13, 14] { #expect(!mask[id], "\(prefix) \(id)") }
                masks.append(mask)
            }
            #expect(masks[0] == masks[1])
        }
    }

    // MARK: test_grammar_compiler.py additions

    @Test(arguments: [false, true])
    func grammarCompilerBindingConstructor(_ dynamic: Bool) throws {
        let info = try Self.info(Self.pieces(["a", "b", "ab"]))
        let compiled = try Self.compiler(info, dynamic: dynamic).compile(regex: "ab")
        var matcher = GrammarMatcher(compiled)
        let initial = compiled.memorySize
        _ = matcher.nextTokenBitmask()
        #expect((compiled.memorySize > initial) == dynamic)
    }

    // MARK: test_dynamic_compilation.cc

    @Test func ruleCacheSharedAcrossGrammarsOutlivesCompiler() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c", "ab", "ac", "x"])
        // A finite limit disables whole-grammar reuse, but rule-level reuse remains enabled.
        var compiler: GrammarCompiler? = Self.compiler(info, dynamic: true, maxCacheBytes: 65536)
        let first = try compiler!.compile(regex: "ab|ac")
        let second = try compiler!.compile(regex: "ab|ac")
        #expect(first !== second)
        compiler = nil
        var expected = GrammarMatcher(try Self.compiler(info, dynamic: false, cache: false).compile(regex: "ab|ac"))
        let initial = expected.nextTokenBitmask()
        var firstMatcher = GrammarMatcher(first), secondMatcher = GrammarMatcher(second)
        Self.check(firstMatcher.nextTokenBitmask() == initial)
        Self.check(secondMatcher.nextTokenBitmask() == initial)
    }

    @Test func concurrentMasksSerializationAndAccounting() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c", "ab", "ac", "x"])
        let compiler = Self.compiler(info, dynamic: true, maxCacheBytes: 65536)
        let dynamic = try compiler.compile(regex: "ab|ac")
        var reference = GrammarMatcher(try Self.compiler(info, dynamic: false, cache: false).compile(regex: "ab|ac"))
        let expected = reference.nextTokenBitmask()
        Self.check(reference.acceptToken(0))
        let expectedAfterA = reference.nextTokenBitmask()
        Self.concurrently(8) { worker in
            for _ in 0 ..< 20 {
                switch worker {
                case 0:
                    guard let restored = try? Self.restored(dynamic) else { Issue.record("restore failed"); return }
                    var matcher = GrammarMatcher(restored)
                    Self.check(matcher.nextTokenBitmask() == expected)
                case 1:
                    #expect(dynamic.memorySize > 0)
                    #expect(compiler.cacheSizeBytes <= 65536)
                    compiler.clearCache()
                default:
                    var matcher = GrammarMatcher(dynamic)
                    Self.check(matcher.nextTokenBitmask() == expected)
                    Self.check(matcher.acceptToken(0))
                    Self.check(matcher.nextTokenBitmask() == expectedAfterA)
                }
            }
        }
    }

    /// Memory inspection must remain safe while missing masks are generated.
    @Test func memorySizeIsSafeDuringMaskGeneration() throws {
        var grammar = "root ::= r0\n"
        for index in 0 ..< 512 { grammar += "r\(index) ::= [ab]" + (index + 1 < 512 ? " r\(index + 1)" : "") + " | \"\"\n" }
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "ab", "ba"])
        let compiled = try Self.compiler(info, dynamic: true, cache: false).compile(ebnf: grammar)
        let initial = compiled.memorySize
        let state = Mutex((started: false, done: false, sawZero: false, observations: 0))
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            while true {
                let size = compiled.memorySize
                let stop = state.withLock { state in
                    if size == 0 { state.sawZero = true }
                    state.observations += 1
                    return state.done
                }
                if stop { break }
            }
            finished.signal()
        }
        reader.start()
        while state.withLock({ $0.observations }) == 0 { Thread.sleep(forTimeInterval: 0.0001) }
        // Generate missing masks while the reader measures the compiled grammar.
        var matcher = GrammarMatcher(compiled)
        let mask = matcher.nextTokenBitmask()
        state.withLock { $0.done = true }
        finished.wait()
        let sawZero = state.withLock { $0.sawZero }
        #expect(!sawZero)
        #expect(compiled.memorySize > initial)
        #expect(mask[0] && mask[1] && mask[2] && mask[3])
    }
}
