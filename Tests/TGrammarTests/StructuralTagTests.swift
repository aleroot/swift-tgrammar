import Foundation
import Testing
@testable import TGrammar

private struct StructuralFixture: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let format: String
    let input: String
    let accepted: Bool
    var testDescription: String { id }
}
private struct StructuralFixtures: Decodable {
    let revision: String
    let cases: [StructuralFixture]
    static var upstream: [StructuralFixture] {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "StructuralTags", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).cases
        }
    }
}

@Suite("Structural tags (upstream)")
struct StructuralTagTests {
    private func accepts(_ format: StructuralFormat, _ input: String) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: format), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    @Test func unconstrainedAtomicTokensAndMalformedFlags() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "<symbol>", "b"])
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(structuralFormat: .anyTokens()))
        let initial = matcher.nextTokenBitmask()
        #expect(initial.allowedTokenIDs == [0, 1, 2])
        let accepted = matcher.acceptToken(1)
        #expect(accepted)
        for json in [#"{"type":"json_schema","json_schema":true,"any_order":"true"}"#,
                     #"{"type":"dispatch","rules":[],"loop":1}"#,
                     #"{"type":"triggered_tags","triggers":[],"tags":[],"at_least_one":"false"}"#] {
            #expect(throws: GrammarError.self) { try StructuralFormat(json: json) }
        }
    }
    @Test(arguments: try StructuralFixtures.upstream)
    fileprivate func upstream(_ fixture: StructuralFixture) throws {
        let format = try StructuralFormat(json: fixture.format)
        #expect(try accepts(format, fixture.input) == fixture.accepted)
    }

    @Test func constrainedToolCallingAcrossTokenBoundaries() throws {
        let tool = StructuralTag(begin: "<tool_call>", content: .jsonSchema(.object(properties: [
            .init("name", .constant("weather"), required: true),
            .init("arguments", .object(properties: [.init("city", .string(), required: true)]), required: true),
        ]), options: .xgrammar), end: "</tool_call>")
        let format = StructuralFormat.triggeredTags(triggers: ["<tool_"], tags: [tool])
        let vocab = ["<eos>", "Let me check. <tool_", "call>", #"{"name":"weather","arguments":{"city":"Dubai"}}"#, #"{"name":"delete","arguments":{}}"#, "</tool_call>", " Done."]
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [0]))
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: format))
        for token in [1, 2, 3, 5, 6] {
            let mask = matcher.nextTokenBitmask()
            #expect(mask.allows(Int32(token)))
            if token == 3 { #expect(!mask.allows(4)) }
            let accepted = matcher.acceptToken(Int32(token))
            #expect(accepted)
        }
        #expect(matcher.isCompleted)
    }

    @Test func reasoningAndAtomicToolDelimiters() throws {
        let format = StructuralFormat.sequence([
            .tag(.init(begin: .token("<think>"), content: .anyTokens(maxTokens: 2), end: .token("</think>"))),
            .tag(.init(begin: .token("<tool>"), content: .jsonSchema(.object(properties: [.init("city", .string(), required: true)]), options: .xgrammar), end: .token("</tool>"))),
        ])
        let vocab = ["<eos>", "<think>", "</think>", "reason", "<tool>", "</tool>", #"{"city":"Dubai"}"#]
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [0]))
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: format))
        for token: Int32 in [1, 3, 3, 2, 4, 6, 5, 0] {
            let mask = matcher.nextTokenBitmask()
            #expect(mask.allows(token))
            let accepted = matcher.acceptToken(token)
            #expect(accepted)
        }
        #expect(matcher.isTerminated)
    }

    @Test func inheritedEndStopsNestedFreeText() throws {
        let format = StructuralFormat.tag(.init(begin: "<think>", content: .sequence([.literal("Reason: "), .anyText()]), end: "</think>"))
        #expect(try accepts(format, "<think>Reason: hello</think>"))
        #expect(try !accepts(format, "<think>Reason: hello</think>extra</think>"))
    }

    /// Port of `test_lark_grammar_format_resolves_special_tokens_with_compiler_tokenizer` (#1015).
    @Test func larkGrammarFormatResolvesSpecialTokensWithCompilerTokenizer() throws {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: ["a", "<|tool|>", "b"]))
        let compiled = try compiler.compile(structuralTagJSON: #"""
            {"type": "structural_tag", "format": {"type": "grammar", "grammar": "start: <|tool|> \"a\"", "syntax": "lark"}}
            """#)
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let walked = matcher.acceptToken(1) && matcher.acceptToken(0) && matcher.isTerminated
        #expect(walked)
        var fresh = GrammarMatcher(compiled)
        let acceptedWithoutToken = fresh.acceptToken(0)
        #expect(!acceptedWithoutToken)
        // The typed form compiles the same way.
        #expect(try compiler.compile(structuralFormat: .lark(#"start: <|tool|> "a""#)).grammar.description == compiled.grammar.description)
    }
}
