// Port of the optimizer-pass snapshot tests of xgrammar's tests/python/test_grammar_parser.py:
// each pass on its own (`GrammarFunctor`), compared with upstream's printed grammar. Cases live in
// Fixtures/OptimizerPasses.json.

import Foundation
import Testing

@testable import TGrammar

private struct OptimizerPassCase: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let parse: String
    let passes: [String]
    let before: String
    let expected: String
    var testDescription: String { id }

    static var upstream: [Self] {
        get throws {
            struct File: Decodable { let cases: [OptimizerPassCase] }
            let url = try #require(Bundle.module.url(forResource: "OptimizerPasses", withExtension: "json"))
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
        }
    }
}

@Suite("Optimizer passes (upstream)")
struct OptimizerPassTests {
    @Test(arguments: try OptimizerPassCase.upstream)
    fileprivate func upstream(_ fixture: OptimizerPassCase) throws {
        var grammar = fixture.parse == "raw" ? try GrammarTesting.parseWithoutNormalization(fixture.before) : try Grammar(ebnf: fixture.before)
        for pass in fixture.passes {
            switch pass {
            case "structure_normalizer": grammar = GrammarTesting.structureNormalizer(grammar)
            case "rule_inliner": grammar = GrammarTesting.ruleInliner(grammar)
            case "byte_string_fuser": grammar = GrammarTesting.byteStringFuser(grammar)
            case "dead_code_eliminator": grammar = GrammarTesting.deadCodeEliminator(grammar)
            case "lookahead_assertion_analyzer": grammar = GrammarTesting.lookaheadAssertionAnalyzer(grammar)
            case "grammar_optimizer": grammar = try GrammarTesting.optimize(grammar)
            default: Issue.record("Unknown pass \(pass)")
            }
        }
        #expect(grammar.description == fixture.expected)
    }

    @Test func byteStringFuserRemovesEmptyByteStrings() throws {
        let tag = #"{"type": "structural_tag", "format": {"type": "triggered_tags", "triggers": ["<t>"], "tags": [{"type": "tag", "begin": "<t>", "content": {"type": "const_string", "value": ""}, "end": ""}]}}"#
        let grammar = try Grammar(structuralTagJSON: tag)
        #expect(GrammarTesting.byteStringFuser(grammar).description.contains("triggered_tags_group ::= ((const_string))\n"))
        let compiled = try GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]())).compile(grammar)
        #expect(compiled.grammar.storage.allowEmptyRuleIDs == [0, 1, 2, 3])
    }

    @Test func passesDoNotMutateInput() throws {
        let fuserInput = try GrammarTesting.parseWithoutNormalization("root ::= \"a\" \"b\" rule1\nrule1 ::= \"c\" | \"d\"\n")
        let fuserBefore = fuserInput.description
        #expect(GrammarTesting.byteStringFuser(fuserInput).description != fuserBefore)
        #expect(fuserInput.description == fuserBefore)

        let inlinerInput = try GrammarTesting.parseWithoutNormalization("root ::= rule1 \"x\"\nrule1 ::= \"a\" | \"b\"\n")
        let inlinerBefore = inlinerInput.description
        #expect(GrammarTesting.ruleInliner(inlinerInput).description != inlinerBefore)
        #expect(inlinerInput.description == inlinerBefore)

        let grammar = try Grammar(ebnf: "root ::= rule1 \"x\" | \"y\"\nrule1 ::= \"a\" | \"b\"\n")
        let before = grammar.description
        #expect(try GrammarTesting.optimize(grammar).description == "root ::= ((\"a\" \"x\") | (\"b\" \"x\") | (\"y\"))\n")
        #expect(grammar.description == before)
        _ = try GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]())).compile(grammar)
        #expect(grammar.description == before)
    }
}
