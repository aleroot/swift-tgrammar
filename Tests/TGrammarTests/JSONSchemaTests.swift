import Foundation
import Testing
@testable import TGrammar

private struct SchemaFixture: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let schema: String
    let input: String
    let accepted: Bool
    let strict: Bool
    var testDescription: String { id }
}

private struct SchemaFixtures: Decodable {
    let revision: String
    let cases: [SchemaFixture]

    static var upstream: [SchemaFixture] {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "JSONSchema", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).cases
        }
    }
}

@Suite("JSON Schema (upstream)")
struct JSONSchemaTests {
    private func accepts(_ schema: String, _ input: String, strict: Bool = true) throws -> Bool {
        let grammar = try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, strict: strict))
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    @Test(arguments: try SchemaFixtures.upstream)
    fileprivate func upstream(_ fixture: SchemaFixture) throws {
        #expect(try accepts(fixture.schema, fixture.input, strict: fixture.strict) == fixture.accepted)
    }

    @Test func orderedPropertiesAndOptionalFields() throws {
        let schema = #"{"type":"object","properties":{"num":{"type":"integer"},"size":{"type":["number","null"]},"name":{"type":"string"}},"required":["size"]}"#
        for input in [#"{"size":null}"#, #"{"num":1,"size":3.14,"name":"foo"}"#] {
            #expect(try accepts(schema, input))
        }
        for input in [#"{}"#, #"{"name":"foo","size":null}"#, #"{"size":null,"extra":true}"#] {
            #expect(try !accepts(schema, input))
        }
    }

    @Test func recursiveReferences() throws {
        let schema = ##"{"$defs":{"node":{"type":"object","properties":{"value":{"type":"integer"},"next":{"anyOf":[{"$ref":"#/$defs/node"},{"type":"null"}]}},"required":["value","next"]}},"$ref":"#/$defs/node"}"##
        #expect(try accepts(schema, #"{"value":1,"next":{"value":2,"next":null}}"#))
        #expect(try !accepts(schema, #"{"value":1,"next":{"value":"bad","next":null}}"#))
    }

    @Test func masksRejectInvalidToolArguments() throws {
        let schema = JSONSchema.object(properties: [
            .init("city", .string(), required: true),
            .init("unit", .enumeration(["celsius", "fahrenheit"]), required: true),
        ])
        let info = try TokenizerInfo(encodedVocab: ["<eos>", #"{"city":"Dubai","unit":""#, "celsius", "kelvin", #""}"#], stopTokenIDs: [0])
        let compiler = GrammarCompiler(tokenizerInfo: info)
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: schema, options: .xgrammar))
        let prefixAccepted = matcher.acceptToken(1)
        #expect(prefixAccepted)
        let mask = matcher.nextTokenBitmask()
        #expect(mask.allows(2))
        #expect(!mask.allows(3))
        let unitAccepted = matcher.acceptToken(2)
        let closeAccepted = matcher.acceptToken(4)
        #expect(unitAccepted)
        #expect(closeAccepted)
        #expect(matcher.isCompleted)
        let stopAccepted = matcher.acceptToken(0)
        #expect(stopAccepted)
        #expect(matcher.isTerminated)
    }

    /// The default layout is canonical, so a model cannot spend its budget on whitespace.
    @Test func defaultOptionsGenerateCanonicalLayout() throws {
        let schema = JSONSchema.object(properties: [
            .init("city", .string(), required: true),
            .init("days", .array(items: .integer()), required: true),
            .init("extra", .any),
        ])
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        let compiled = try compiler.compile(jsonSchema: schema)
        func accepts(_ input: String) -> Bool {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            return matcher.acceptString(input) && matcher.isCompleted
        }
        for input in [#"{"city": "Rome", "days": [1, 2]}"#, #"{"city": "Rome", "days": [], "extra": {"a": [1, null]}}"#] {
            #expect(accepts(input), "\(input)")
        }
        for input in [#"{"city":"Rome","days":[1,2]}"#, #"{"city": "Rome", "days": [1, 2] }"#, "{\"city\": \"Rome\",\n\"days\": [1]}",
                      #" {"city": "Rome", "days": [1]}"#, #"{"city": "Rome", "days": [1]} "#] {
            #expect(!accepts(input), "\(input)")
        }
    }

    @Test func defaultOptionsAllowNoWhitespaceTokens() throws {
        let info = try TokenizerInfo(encodedVocab: ["<eos>", #"{"city": "Rome""#, " ", "\n", "  ", "}", " }", "\n}"], stopTokenIDs: [0])
        let schema = JSONSchema.object(properties: [.init("city", .string(), required: true)])
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(jsonSchema: schema))
        let accepted = matcher.acceptToken(1)
        #expect(accepted)
        let mask = matcher.nextTokenBitmask()
        #expect((0 ..< 8).filter { mask.allows($0) } == [5])
    }

    @Test func additionalKeysCannotBypassKnownPropertyConstraints() throws {
        for name in ["name", "\"", "\\", "\n", "😀"] {
            let schema = JSONSchema.object(properties: [.init(name, .integer())], additionalProperties: .any)
            let escaped = name.unicodeScalars.map { scalar -> String in
                if scalar.value <= 0xFFFF { return String(format: "\\u%04x", scalar.value) }
                let offset = scalar.value - 0x10000
                return String(format: "\\u%04x\\u%04x", 0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
            }.joined()
            #expect(try !accepts(schema.description, "{\"" + escaped + "\":\"wrong type\"}"))
            #expect(try accepts(schema.description, #"{"unrelated":"allowed"}"#))
            let grammar = try Grammar(jsonSchema: schema, options: .xgrammar)
            // Generated names must survive the compiler's printed-grammar cache key.
            let reparsed = try Grammar(ebnf: grammar.description)
            #expect(reparsed.ruleCount == grammar.ruleCount)
        }
    }

    @Test func stringLengthCountsUnicodeScalarsAndPairedEscapes() throws {
        let schema = JSONSchema.string(minLength: 1, maxLength: 1).description
        for input in [#""a""#, #""😀""#, #""\uD83D\uDE00""#, #""\u0061""#] { #expect(try accepts(schema, input)) }
        for input in [#""""#, #""ab""#, #""\uD83D""#, #""\uDE00""#] { #expect(try !accepts(schema, input)) }
    }
}
