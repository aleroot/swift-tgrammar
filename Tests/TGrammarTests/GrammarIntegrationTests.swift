import Dispatch
import Synchronization
import Testing
@testable import TGrammar

@Suite("Grammar integration")
struct GrammarIntegrationTests {
    private func matcher(_ grammar: Grammar, vocab: [String] = []) throws -> GrammarMatcher {
        let info = try TokenizerInfo(encodedVocab: vocab)
        return GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(grammar), terminateWithoutStopToken: true)
    }

    @Test func unionAndConcatenationUpstreamSemantics() throws {
        let nullable = try Grammar(ebnf: #"root ::= "a" | """#)
        let alternatives = try Grammar(ebnf: #"root ::= "bc" | "d""#)
        let repeated = try Grammar(ebnf: "root ::= [x-z]+")
        let union = try Grammar.union([nullable, alternatives, repeated])
        let concat = Grammar.concatenating([nullable, alternatives, repeated])
        for (grammar, accepted, rejected) in [
            (union, ["", "a", "bc", "d", "x", "xyz"], ["ab", "bd", "1", "ax"]),
            (concat, ["bcx", "dxyz", "abcx", "adxyz"], ["", "a", "bc", "x", "abdx", "abc"]),
        ] {
            for input in accepted + rejected {
                var matcher = try matcher(grammar)
                let result = matcher.acceptString(input) && matcher.isCompleted
                #expect(result == accepted.contains(input))
            }
        }
    }

    @Test func substringFactoriesPreserveScalarAndChunkBoundaries() throws {
        for (grammar, accepted, rejected) in [
            (Grammar.substring(of: "aé💥z"), ["", "é", "é💥", "aé💥z"], ["az", "💥é", "ae"]),
            (Grammar.substring(chunks: ["alpha ", "beta ", "gamma"]), ["", "beta ", "beta gamma"], ["beta", "eta ", "alpha gamma"]),
        ] {
            for input in accepted + rejected {
                var matcher = try matcher(grammar)
                let result = matcher.acceptString(input) && matcher.isCompleted
                #expect(result == accepted.contains(input))
            }
        }
    }

    // Language-equivalent translations of the upstream Lark capture tests; the native EBNF
    // attributes share their matcher implementation.
    @Test func captureCompletionAndDeduplication() throws {
        let grammar = try Grammar(ebnf: #"root ::= "a" v "b""# + "\nv[capture] ::= [0-9]+")
        var matcher = try matcher(grammar)
        let accepted = matcher.acceptString("a123b")
        #expect(accepted)
        #expect(matcher.captures().map(\.text) == ["123"])
        #expect(matcher.captures(deduplicate: false).map(\.text) == ["1", "12", "123"])
        #expect(matcher.captures().map(\.name) == ["v"])
    }

    @Test func captureForkRollbackAndRejectedInput() throws {
        let grammar = try Grammar(ebnf: "root ::= v\nv[capture] ::= [0-9]+")
        var original = try matcher(grammar, vocab: ["1", "2", "bad"])
        let first = original.acceptToken(0)
        #expect(first)
        var fork = original
        let second = fork.acceptToken(1)
        #expect(second)
        #expect(original.captures().map(\.text) == ["1"])
        #expect(fork.captures().map(\.text) == ["12"])
        let before = fork.captures(deduplicate: false)
        let rejected = fork.acceptToken(2)
        #expect(!rejected)
        #expect(fork.captures(deduplicate: false) == before)
        fork.rollback()
        #expect(fork.captures() == original.captures())
    }

    @Test func nestedCaptureCompletionOrder() throws {
        let grammar = try Grammar(ebnf: "root ::= outer\nouter[capture=\"o\"] ::= \"x\" inner \"!\"\ninner[capture=\"i\"] ::= [a-z]+")
        var matcher = try matcher(grammar)
        let accepted = matcher.acceptString("xabc!")
        #expect(accepted)
        #expect(matcher.captures().map(\.name) == ["i", "o"])
        #expect(matcher.captures().map(\.text) == ["abc", "xabc!"])
    }

    @Test func concurrentCompilationSharesOneResult() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "c"])
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let schema = JSONSchema.object(properties: [.init("value", .string(), required: true)])
        let results = Mutex<[CompiledGrammar]>([])
        let errors = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let value = try compiler.compile(jsonSchema: schema)
                results.withLock { $0.append(value) }
            } catch { errors.withLock { $0.append(String(describing: error)) } }
        }
        #expect(errors.withLock { $0.isEmpty })
        let values = results.withLock { $0 }
        #expect(values.count == 16)
        #expect(values.allSatisfy { $0 === values[0] })
        // The size covers the compiled grammar plus the rule masks shared with later grammars.
        #expect(compiler.cacheSizeBytes >= values[0].memorySize)
        #expect(compiler.cacheSizeBytes == values[0].memorySize + (compiler.ruleLevelCache?.totalBytes ?? 0))
        compiler.clearCache()
        #expect(compiler.cacheSizeBytes == 0)
    }

    @Test func cacheDoesNotRetainOversizedGrammars() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b"])
        let compiler = GrammarCompiler(tokenizerInfo: info, maxCacheBytes: 1)
        let compiled = try compiler.compile(ebnf: #"root ::= "a""#)
        #expect(compiled.memorySize > 1)
        #expect(compiler.cacheSizeBytes == 0)
    }

    @Test func speculativeSiblingsAndRejectedNodes() throws {
        let vocab = ["a", "b", "c", "{", "}", "\"", ":", ",", " ", "true", "false", "null"]
        var matcher = try matcher(.builtinJSON, vocab: vocab)
        let rootMask = matcher.nextTokenBitmask()
        let tree = try DraftTokenTree(nodes: [
            .init(3, firstChild: 1),
            .init(3, firstChild: 2),
            .init(100, nextSibling: 3),
            .init(5),
        ])
        let result = matcher.traverseDraftTree(tree)
        #expect(result.didFinish)
        #expect(result.masks[0] == rootMask)
        #expect(result.masks[1].allowsAny)
        #expect(!result.masks[2].allowsAny)
        #expect(result.masks[3].allowsAny)
        let after = matcher.nextTokenBitmask()
        #expect(after == rootMask)
    }

    @Test func draftTreeRejectsBadGraphs() {
        #expect(throws: GrammarError.self) { try DraftTokenTree(nodes: [.init(0, firstChild: 1000000)]) }
        #expect(throws: GrammarError.self) { try DraftTokenTree(nodes: [.init(0, firstChild: 1), .init(0, firstChild: 1)]) }
        #expect(throws: GrammarError.self) { try DraftTokenTree(nodes: [.init(0, nextSibling: 1), .init(0)]) }
    }

    @Test func deepDraftTraversalTimeoutPreservesRoot() throws {
        let matcher = try matcher(Grammar(ebnf: #"root ::= "a" root | "a""#), vocab: ["a"])
        let nodes = (0 ..< 10000).map { DraftTokenTree.Node(0, firstChild: $0 == 9999 ? nil : $0 + 1) }
        let tree = try DraftTokenTree(nodes: nodes)
        let result = matcher.traverseDraftTree(tree, timeLimit: .nanoseconds(1))
        #expect(!result.didFinish)
        #expect(result.masks[0].allows(0))
    }
}
