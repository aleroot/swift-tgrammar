import Foundation
import Testing
@testable import TGrammar

/// An upstream test case: one schema converted with a model argument style, one instance.
private struct FunctionCallingFixture: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let schema: String
    let style: String
    let anyOrder: Bool
    let maxWhitespaceCount: Int?
    let excludes: [String]
    let strict: Bool
    let input: String
    let accepted: Bool
    var testDescription: String { id }

    var options: JSONSchemaOptions {
        get throws {
            let style = try #require(JSONSchemaOptions.Style(rawValue: style))
            return .init(anyWhitespace: true, strict: strict, anyOrder: anyOrder, maxWhitespaceCount: maxWhitespaceCount,
                         style: style, excludes: excludes)
        }
    }
}

private struct FunctionCallingError: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let schema: String
    let style: String
    let anyOrder: Bool
    let strict: Bool
    var testDescription: String { id }
}

private struct FunctionCallingFixtures: Decodable {
    let revision: String
    let cases: [FunctionCallingFixture]
    let errors: [FunctionCallingError]

    static var upstream: Self {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "FunctionCalling", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }
}

@Suite("Function calling argument styles (upstream)")
struct FunctionCallingStyleTests {
    private static func accepts(_ schema: String, options: JSONSchemaOptions, _ input: String) throws -> Bool {
        let grammar = try Grammar(jsonSchema: schema, options: options)
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    @Test(arguments: try FunctionCallingFixtures.upstream.cases)
    fileprivate func upstream(_ fixture: FunctionCallingFixture) throws {
        #expect(try Self.accepts(fixture.schema, options: fixture.options, fixture.input) == fixture.accepted)
    }

    @Test(arguments: try FunctionCallingFixtures.upstream.errors)
    fileprivate func upstreamRejects(_ fixture: FunctionCallingError) throws {
        let style = try #require(JSONSchemaOptions.Style(rawValue: fixture.style))
        #expect(throws: GrammarError.self) {
            try Grammar(jsonSchema: fixture.schema, options: .init(anyWhitespace: true, strict: fixture.strict, anyOrder: fixture.anyOrder, style: style))
        }
    }

    /// Upstream `test_glm_unconstrained_string_whitespace_has_bounded_parser_states`: the raw
    /// string is not padded with whitespace repetitions, so a long run of spaces inside it does
    /// not multiply parser states.
    @Test func glmUnconstrainedStringWhitespaceHasBoundedParserStates() throws {
        let schema = #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, style: .glmXML))), terminateWithoutStopToken: true)
        func states() -> Int { matcher.debugDescription.components(separatedBy: "ParserState(").count - 1 }
        let opened = matcher.acceptString("<arg_key>value</arg_key><arg_value>")
        #expect(opened)
        let before = states()
        let padded = matcher.acceptString(String(repeating: " ", count: 1024))
        #expect(padded)
        #expect(states() <= before + 1)
        let closed = matcher.acceptString("</arg_value>")
        #expect(closed)
        #expect(matcher.isTerminated)
    }

    /// Upstream `test_cohere_shared_parameter_references_have_linear_grammar_size`: doubling a
    /// shared reference graph must not expand its exponentially many paths.
    @Test func cohereSharedParameterReferencesHaveLinearGrammarSize() throws {
        var ruleCounts: [Int] = []
        for count in [12, 24] {
            var definitions = [#""V0":{"const":"fixed"}"#, #""V1":{"type":"integer","minimum":1}"#]
            for index in 2 ..< count {
                definitions.append("\"V\(index)\":{\"anyOf\":[{\"$ref\":\"#/$defs/V\(index - 1)\"},{\"$ref\":\"#/$defs/V\(index - 2)\"}]}")
            }
            let schema = "{\"type\":\"object\",\"$defs\":{" + definitions.joined(separator: ",") + "},\"properties\":{\"value\":{\"$ref\":\"#/$defs/V\(count - 1)\"}},\"required\":[\"value\"],\"additionalProperties\":false}"
            let options = JSONSchemaOptions(anyWhitespace: true, style: .cohereXML)
            ruleCounts.append(try Grammar(jsonSchema: schema, options: options).ruleCount)
            #expect(try Self.accepts(schema, options: options, #"<cofl:value name="value" type="raw">fixed</cofl:value>"#))
            #expect(try Self.accepts(schema, options: options, #"<cofl:value name="value" type="json">2</cofl:value>"#))
            #expect(try !Self.accepts(schema, options: options, #"<cofl:value name="value" type="json">fixed</cofl:value>"#))
        }
        #expect(ruleCounts[1] <= 2 * ruleCounts[0], "\(ruleCounts)")
    }
}
