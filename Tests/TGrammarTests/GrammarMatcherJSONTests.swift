// Port of xgrammar's tests/python/test_grammar_matcher_json.py: the optimized builtin JSON
// grammar over documents of increasing size, plus exact rejected-token counts on real
// vocabularies.

import Foundation
import Testing

@testable import TGrammar

@Suite("Grammar matcher (builtin JSON)")
struct GrammarMatcherJSONTests {
    private static let fixtures = MatcherRuntimeFixtures.upstream

    @Test(arguments: fixtures.json.accepted)
    func jsonAccept(_ input: String) throws {
        #expect(try Upstream.accepts(.builtinJSON, input))
    }

    @Test(arguments: fixtures.json.refused)
    func jsonRefuse(_ input: String) throws {
        #expect(try !Upstream.accepts(.builtinJSON, input))
    }

    @Test(arguments: fixtures.json.pressure)
    func jsonPressure(_ input: String) throws {
        #expect(try Upstream.accepts(.builtinJSON, input))
    }

    /// Exact upstream rejected counts for the builtin JSON grammar; needs the named vocabulary.
    @Test(arguments: fixtures.rejectedSizes.filter { $0.grammar == "builtin_json" && $0.model.map(LocalTokenizers.has) == true })
    func fillNextTokenBitmask(_ row: MatcherRuntimeFixtures.RejectedSizes) throws {
        let model = try #require(row.model)
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: tokenizer.info).compile(.builtinJSON))
        let counts = Upstream.rejectedCounts(&matcher, bytes: row.input.utf8)
        #expect(counts == row.sizes)
    }
}
