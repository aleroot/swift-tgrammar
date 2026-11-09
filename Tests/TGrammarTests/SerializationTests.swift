import Foundation
import Testing
@testable import TGrammar

@Suite("Serialization (upstream v18)")
struct SerializationTests {
    @Test func serializationVersionIsUpstreams() {
        #expect(serializationVersion == "v18")
        #expect(Grammar.builtinJSON.serializedJSON.contains("\"__VERSION__\":\"v18\""))
    }

    private var fixtures: JSONValue {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "Serialization", withExtension: "json"))
            return try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        }
    }
    private func grammar() throws -> Grammar {
        try Grammar(ebnf: "rule1 ::= ([^0-9] rule1) | \"\"\nroot_rule ::= rule1 \"a\"\n", rootRule: "root_rule")
    }
    private func tokenizer() throws -> TokenizerInfo {
        try TokenizerInfo(encodedVocab: ["1", "212", "a", "A", "b", "一", "-", "aBc", "abc"], vocabType: .byteFallback,
                          vocabSize: 10, stopTokenIDs: [0, 1], addPrefixSpace: true)
    }
    private func replacing(_ object: JSONValue, path: [JSONValue], with new: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return new }
        if let key = head.string, let child = object[key] {
            return try object.replacing(key, with: replacing(child, path: Array(path.dropFirst()), with: new))
        }
        var values = try #require(object.array)
        let index = try #require(head.integer).description
        let position = try #require(Int(index))
        values[position] = try replacing(values[position], path: Array(path.dropFirst()), with: new)
        return .array(values)
    }
    private func sameJSON(_ a: JSONValue, _ b: JSONValue) -> Bool {
        // Object key order has no meaning in the upstream snapshots; arena/array order does.
        switch (a, b) {
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { member in b[member.key].map { sameJSON(member.value, $0) } ?? false }
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy(sameJSON)
        default: return a == b
        }
    }

    @Test func grammarSnapshotAndRoundTrip() throws {
        let original = try grammar()
        let snapshot = try JSONValue.parse(original.serializedJSON)
        #expect(sameJSON(snapshot, try #require(fixtures["grammar"])))
        let restored = try Grammar(serializedJSON: original.serializedJSON)
        #expect(restored.serializedJSON == original.serializedJSON)
        #expect(restored.description == original.description)
    }

    @Test func tokenizerSnapshotAndRoundTrip() throws {
        let original = try tokenizer()
        #expect(sameJSON(try JSONValue.parse(original.serializeJSON(preservingEncodedVocabulary: false)), try #require(fixtures["tokenizer"])))
        let restored = try TokenizerInfo(serializedJSON: original.serializedJSON)
        #expect(restored.serializedJSON == original.serializedJSON)
        #expect(restored.metadata == original.metadata)
        #expect(restored.tokenID(for: "一") == original.tokenID(for: "一"))
        let upstream = try TokenizerInfo(serializedJSON: #require(fixtures["tokenizer"]).serialized())
        #expect(upstream.decodedVocab[5].elementsEqual(original.decodedVocab[5]))
    }

    @Test func compiledSnapshotAndRoundTrip() throws {
        let info = try tokenizer()
        let original = try GrammarCompiler(tokenizerInfo: info).compile(grammar())
        let snapshot = try JSONValue.parse(original.serializedJSON)
        let expected = try #require(fixtures["compiled"])
        for member in try #require(expected.members) { #expect(sameJSON(try #require(snapshot[member.key]), member.value)) }
        let restored = try CompiledGrammar(serializedJSON: original.serializedJSON, tokenizerInfo: info)
        #expect(restored.serializedJSON == original.serializedJSON)
        var a = GrammarMatcher(original), b = GrammarMatcher(restored)
        for token: Int32 in [2, 3, 7, 2, 0] {
            let maskA = a.nextTokenBitmask(), maskB = b.nextTokenBitmask()
            #expect(maskA == maskB)
            let acceptedA = a.acceptToken(token), acceptedB = b.acceptToken(token)
            #expect(acceptedA == acceptedB)
        }
    }

    @Test func rejectsCorruptedArenasAutomataAndMasks() throws {
        let info = try tokenizer()
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(grammar())
        let grammarValue = try JSONValue.parse(grammar().serializedJSON)
        let compiledValue = try JSONValue.parse(compiled.serializedJSON)
        let tokenizerValue = try JSONValue.parse(info.serializedJSON)
        for (group, original) in [("grammarCorruptions", grammarValue), ("fsmCorruptions", compiledValue), ("tokenizerCorruptions", tokenizerValue)] {
            for raw in try #require(fixtures[group]?.array) {
                let pair = try #require(raw.array)
                let corrupted = try replacing(original, path: #require(pair[0].array), with: pair[1]).serialized()
                if group == "grammarCorruptions" { #expect(throws: SerializationError.self) { try Grammar(serializedJSON: corrupted) } }
                else if group == "fsmCorruptions" { #expect(throws: SerializationError.self) { try CompiledGrammar(serializedJSON: corrupted, tokenizerInfo: info) } }
                else { #expect(throws: SerializationError.self) { try TokenizerInfo(serializedJSON: corrupted) } }
            }
        }
        for fields in try #require(fixtures["maskCorruptions"]?.array) {
            var corrupted = compiledValue
            for member in try #require(fields.members) {
                corrupted = try replacing(corrupted, path: [.string("adaptive_token_mask_cache"), .number("0"), .number("1"), .string(member.key)], with: member.value)
            }
            #expect(throws: SerializationError.self) { try CompiledGrammar(serializedJSON: corrupted.serialized(), tokenizerInfo: info) }
        }
    }

    @Test func binaryVocabularyAndAtomicTokens() throws {
        let original = try TokenizerInfo(encodedVocab: [[UInt8(0)], [97], Array("</s>".utf8)], vocabSize: 4, stopTokenIDs: [2])
        let info = try TokenizerInfo(serializedJSON: original.serializedJSON)
        #expect(info.decodedVocab[0] == original.decodedVocab[0])
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(ebnf: "root ::= Token(1)")
        let restored = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: info)
        var matcher = GrammarMatcher(restored)
        let mask = matcher.nextTokenBitmask()
        #expect(mask.allowedTokenIDs == [1])
    }

    @Test func malformedVersionMissingFieldsAndCycles() throws {
        let original = try JSONValue.parse(grammar().serializedJSON)
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: "invalid") }
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: original.replacing("__VERSION__", with: .string("v1")).serialized()) }
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: "{\"__VERSION__\":\"v18\"}") }
        let cyclic = original.replacing("grammar_expr_data", with: .array([.number("6"), .number("1"), .number("0")]))
            .replacing("grammar_expr_indptr", with: .array([.number("0")]))
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: cyclic.serialized()) }
    }

    @Test func rejectsUnnormalizedRuleBodiesAndEmptyAtomicSets() throws {
        let original = try JSONValue.parse(Grammar(ebnf: "root ::= \"a\"").serializedJSON)
        let data = try #require(original["grammar_expr_data"]?.array), offsets = try #require(original["grammar_expr_indptr"]?.array)
        let literal = try #require(offsets.indices.first { data[Int(offsets[$0].integer!)] == .number("0") })
        let invalidBody = try replacing(original, path: [.string("rules"), .number("0"), .number("1")], with: .number(String(literal)))
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: invalidBody.serialized()) }
        var empty = JSONValue.array([.number("9"), .number("0")])
        // token has kind 9, and a zero-length token payload is not a legal FSM edge.
        empty = original.replacing("grammar_expr_data", with: empty).replacing("grammar_expr_indptr", with: .array([.number("0")]))
        #expect(throws: SerializationError.self) { try Grammar(serializedJSON: empty.serialized()) }
    }
}
