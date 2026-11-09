// Port of xgrammar's tests/python/test_speculative_decoding.py: next-token masks along a draft
// token tree.
//
// Upstream passes the tree as three tensors (`retrieve_next_token`, `retrieve_next_sibling`,
// `draft_tokens`); here they are `DraftTokenTree.Node(token, firstChild:, nextSibling:)` rows.
// Shape and dtype mismatches between the tensors are unrepresentable with typed nodes, so the
// shape-assertion test keeps only the graph checks (root with a sibling, out-of-bounds edge,
// cycle), which `DraftTokenTree.init` rejects before any traversal.

import Foundation
import Testing

@testable import TGrammar

@Suite("Speculative decoding")
struct SpeculativeDecodingTests {
    static let vocab = ["a", "b", "c", "{", "}", "\"", ":", ",", " ", "true", "false", "null"]

    /// `LINEAR_TREE`: 0 -> 1 -> 2 with draft tokens `{`, `:`, `}`.
    static let linearTree = try! DraftTokenTree(nodes: [.init(3, firstChild: 1), .init(6, firstChild: 2), .init(4)])

    /// `SIBLING_TREE`: 0 with children 1 and 2, draft tokens `{`, `"`, `}`.
    static let siblingTree = try! DraftTokenTree(nodes: [.init(3, firstChild: 1), .init(5, nextSibling: 2), .init(4)])

    /// `compiled_grammar`: the built-in JSON grammar over the small vocabulary, no stop tokens.
    static func compiledGrammar() throws -> CompiledGrammar {
        let tokenizer = try TokenizerInfo(encodedVocab: vocab, vocabSize: vocab.count, stopTokenIDs: [])
        return try GrammarCompiler(tokenizerInfo: tokenizer).compile(.builtinJSON)
    }

    /// `_run_traverse`.
    static func traverse(_ compiled: CompiledGrammar, _ tree: DraftTokenTree, timeLimit: Duration? = nil) -> DraftTraversalResult {
        GrammarMatcher(compiled).traverseDraftTree(tree, timeLimit: timeLimit)
    }

    // MARK: - Basic traversal

    @Test func traverseDraftTreeLinear() throws {
        let result = Self.traverse(try Self.compiledGrammar(), Self.linearTree)
        #expect(result.didFinish)
        #expect(result.masks[0].allowsAny, "First position bitmask should be non-zero")
    }

    @Test func traverseDraftTreeWithSiblings() throws {
        let result = Self.traverse(try Self.compiledGrammar(), Self.siblingTree)
        #expect(result.didFinish)
        #expect(result.masks[0].allowsAny, "Root position bitmask should be non-zero")
    }

    /// Rejected nodes should have zero bitmasks.
    @Test func traverseDraftTreeRejectedNode() throws {
        let rejectedTree = try DraftTokenTree(nodes: [.init(3, firstChild: 1), .init(0, firstChild: 2), .init(3)])
        let result = Self.traverse(try Self.compiledGrammar(), rejectedTree)
        #expect(result.didFinish)
        #expect(result.masks[0].allowsAny, "Root position bitmask should be non-zero")
        #expect(!result.masks[1].allowsAny, "Rejected node bitmask should be zero")
    }

    /// Invalid draft tokens should not break traversal of valid sibling branches.
    @Test func traverseDraftTreeInvalidTokenWithSibling() throws {
        let invalidTokenTree = try DraftTokenTree(nodes: [
            .init(3, firstChild: 1), .init(100, firstChild: 2, nextSibling: 3), .init(3), .init(3),
        ])
        let result = Self.traverse(try Self.compiledGrammar(), invalidTokenTree)
        #expect(result.didFinish)
        #expect(result.masks[0].allowsAny, "Root position bitmask should be non-zero")
        #expect(!result.masks[1].allowsAny, "Invalid token node bitmask should be zero")
        #expect(result.masks[3].allowsAny, "Valid sibling bitmask should be computed")
    }

    /// Terminated nodes should have zero bitmasks.
    @Test func traverseDraftTreeTerminatedNode() throws {
        let tokenizer = try TokenizerInfo(encodedVocab: ["a", "b"], vocabSize: 2, stopTokenIDs: [])
        let compiled = try GrammarCompiler(tokenizerInfo: tokenizer).compile(ebnf: #"root ::= "a""#)
        let matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let terminatedTree = try DraftTokenTree(nodes: [.init(0, firstChild: 1), .init(0, firstChild: 2), .init(1)])
        let result = matcher.traverseDraftTree(terminatedTree)
        #expect(result.didFinish)
        #expect(result.masks[0].allowsAny, "Root position bitmask should be non-zero")
        #expect(!result.masks[1].allowsAny, "Terminated node bitmask should be zero")
    }

    /// `test_old_traverse_draft_tree`: the traversal leaves the matcher itself untouched.
    @Test func traversalDoesNotMoveTheMatcher() throws {
        var matcher = GrammarMatcher(try Self.compiledGrammar())
        let before = matcher.nextTokenBitmask()
        let result = matcher.traverseDraftTree(Self.linearTree)
        #expect(result.didFinish)
        #expect(result.masks[0] == before, "First position bitmask is the matcher's own mask")
        #expect(matcher.nextTokenBitmask() == before)
    }

    // MARK: - Graph validation

    @Test func traverseDraftTreeShapeAssertion() {
        // Root should not have siblings.
        #expect(throws: GrammarError.self) {
            try DraftTokenTree(nodes: [.init(3, firstChild: 1, nextSibling: 1), .init(6, firstChild: 2), .init(4)])
        }
    }

    /// An edge index outside `[-1, num_nodes)` would make the traversal recurse into an
    /// out-of-bounds node; it must be rejected instead of crashing.
    @Test func traverseDraftTreeOutOfBoundsEdge() {
        #expect(throws: GrammarError.self) { try DraftTokenTree(nodes: [.init(3, firstChild: 1_000_000)]) }
    }

    /// Node 1 is its own child: the traversal would recurse forever, so the edges must be rejected.
    @Test func traverseDraftTreeCyclicEdge() {
        #expect(throws: GrammarError.self) {
            try DraftTokenTree(nodes: [.init(3, firstChild: 1), .init(6, firstChild: 1), .init(4)])
        }
    }

    // MARK: - Timeouts

    /// Results should be identical whether the time limit is omitted or set generously.
    @Test func traverseDraftTreeTimeoutNoChange() throws {
        let compiled = try Self.compiledGrammar()
        for tree in [Self.linearTree, Self.siblingTree] {
            // Baseline with the timeout explicitly disabled (`time_threshold=-1.0`).
            let baseline = Self.traverse(compiled, tree, timeLimit: .seconds(-1))
            let byDefault = Self.traverse(compiled, tree)
            #expect(byDefault.didFinish)
            #expect(byDefault.masks == baseline.masks)
            let generous = Self.traverse(compiled, tree, timeLimit: .seconds(100))
            #expect(generous.didFinish)
            #expect(generous.masks == baseline.masks)
        }
    }

    /// A near-zero time limit should cause the traversal to time out. The deadline is only
    /// checked for non-root nodes, so the root bitmask is always computed; a deep linear chain
    /// exercises the check.
    @Test func traverseDraftTreeTimeoutTriggers() throws {
        let tokenizer = try TokenizerInfo(encodedVocab: ["a"], vocabSize: 1, stopTokenIDs: [])
        let chainGrammar = try GrammarCompiler(tokenizerInfo: tokenizer).compile(ebnf: #"root ::= "a" root | "a""#)
        let nodeCount = 10_000
        let deepChain = try DraftTokenTree(nodes: (0 ..< nodeCount).map { .init(0, firstChild: $0 + 1 < nodeCount ? $0 + 1 : nil) })
        let result = GrammarMatcher(chainGrammar).traverseDraftTree(deepChain, timeLimit: .nanoseconds(100))
        #expect(!result.didFinish, "Traversal should time out with near-zero threshold")
        #expect(result.masks[0].allowsAny, "Root bitmask should still be computed even when timed out")
    }
}
