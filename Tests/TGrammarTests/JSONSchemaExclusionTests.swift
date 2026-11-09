import Foundation
import Testing
@testable import TGrammar

/// Language and stateful seams translated from upstream test_json_schema_excludes.py.
@Suite("JSON Schema string exclusions (upstream)")
struct JSONSchemaExclusionTests {
    private let controls = ["<|open|>", "<|close|>", "<|sep|>"]
    private let compiler = GrammarCompiler(tokenizerInfo: try! TokenizerInfo(encodedVocab: [String]()))

    private func accepts(_ grammar: Grammar, _ input: String) throws -> Bool {
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    @Test func stringsAndLiteralAlternatives() throws {
        for schema in [JSONSchema.string(), .string(minLength: 1, maxLength: 16), .enumeration(["safe", "你好🦋", "x<|open|>y"])] {
            let grammar = try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, excludes: controls))
            for value in ["safe", "你好🦋"] { #expect(try accepts(grammar, JSONValue.quote(value))) }
            for value in controls { #expect(try !accepts(grammar, JSONValue.quote("x" + value + "y"))) }
        }
        let blocked = try Grammar(jsonSchema: .constant("BAD"), options: .init(anyWhitespace: true, excludes: ["BAD"]))
        #expect(try !accepts(blocked, #""BAD""#))
    }

    @Test func patternsAndFormatsKeepTheirContract() throws {
        for (schema, accepted, rejected) in [(JSONSchema.string(pattern: "^a[abc]*z$"), ["aabz", "acbz"], ["aab"]),
                                             (.string(pattern: "^你好[abc]*$"), ["你好aa", "你好bc"], ["hello"]),
                                             (.string(format: "email"), ["aa@example.com", "bc@example.com"], ["aa"])] {
            let grammar = try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, excludes: ["bc", "cb"]))
            for value in accepted + rejected { #expect(try accepts(grammar, JSONValue.quote(value)) == accepted.contains(value)) }
        }
    }

    @Test func exclusionsDropLengthBoundsAndStayInStringContent() throws {
        let grammar = try Grammar(jsonSchema: .string(minLength: 2, maxLength: 3), options: .init(anyWhitespace: true, excludes: ["bc", "cb"]))
        for value in ["a", "abde", String(repeating: "ax", count: 10)] { #expect(try accepts(grammar, JSONValue.quote(value))) }
        for value in ["bc", "acbz", String(repeating: "a", count: 20) + "bc"] { #expect(try !accepts(grammar, JSONValue.quote(value))) }
        let any = try Grammar(jsonSchema: .any, options: .init(anyWhitespace: true, excludes: ["ab", ":", "12", "true"]))
        for value in [#"{"a":12}"#, "true", #"["a","b"]"#, #""\u0061b""#] { #expect(try accepts(any, value)) }
        for value in [#""ab""#, #"":""#, #""12""#, #""true""#] { #expect(try !accepts(any, value)) }
    }

    @Test func unicodeOverlapAndPersistence() throws {
        let grammar = try Grammar(jsonSchema: .string(), options: .init(anyWhitespace: true, excludes: ["aba", "bab", "你好", "坏", "aba"] + controls))
        for candidate in [grammar, try Grammar(serializedJSON: grammar.serializedJSON), try Grammar(ebnf: grammar.description)] {
            for value in ["aaba", "bbab", "x你好y", "x坏y"] { #expect(try !accepts(candidate, JSONValue.quote(value))) }
            for value in ["ab", "你x好", "🦋", "候", "好候"] { #expect(try accepts(candidate, JSONValue.quote(value))) }
            for codepoint: UInt32 in [0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF] {
                #expect(try accepts(candidate, JSONValue.quote(String(Unicode.Scalar(codepoint)!))))
            }
        }
    }

    @Test func recursiveObjectsAndKnownKeyAliases() throws {
        let source = ##"{"type":"object","properties":{"value":{"$ref":"#/$defs/payload"}},"required":["value"],"additionalProperties":false,"$defs":{"payload":{"type":"array","items":{"$ref":"#/$defs/node"}},"node":{"type":"object","properties":{"next":{"$ref":"#/$defs/node"}},"additionalProperties":true}}}"##
        let grammar = try Grammar(jsonSchema: source, options: .init(anyWhitespace: true, excludes: controls))
        #expect(try accepts(grammar, #"{"value":[{"next":{"text":"你好","n":42}}]}"#))
        for text in [#"{"value":[{"next":{"text":"a<|open|>b"}}]}"#, #"{"value":[{"next":{"a<|close|>b":"text"}}]}"#] {
            #expect(try !accepts(grammar, text))
        }
        let schema = JSONSchema.object(properties: [.init("city", .integer()), .init("💥", .integer())], additionalProperties: .any)
        let known = try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, excludes: controls))
        for key in ["city", #"\u0063ity"#, "💥", #"\ud83d\udca5"#] {
            #expect(try !accepts(known, "{\"" + key + "\":\"wrong\"}"))
        }
        #expect(try accepts(known, #"{"other":"safe"}"#))
    }

    @Test func maskKeepsClosingQuoteAndOuterDelimiter() throws {
        let end = "<|close|>response<|sep|>"
        let format = StructuralFormat.tag(.init(begin: "", content: .jsonSchema(.string(), options: .init(anyWhitespace: true, excludes: controls)), end: .text(end)))
        let info = try TokenizerInfo(encodedVocab: [#""hello"#, "<|open|>", "<|close|>", "<|sep|>", "\"", end, "\"" + end, "[EOS]"], stopTokenIDs: [7])
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(structuralFormat: format)
        for closing: [Int32] in [[4, 5], [6]] {
            var matcher = GrammarMatcher(compiled)
            let begin = matcher.acceptToken(0)
            #expect(begin)
            let mask = matcher.nextTokenBitmask()
            for index: Int32 in [1, 2, 3] { #expect(!mask.allows(index)) }
            for index: Int32 in [4, 6] { #expect(mask.allows(index)) }
            let accepted = (closing + [7]).allSatisfy { matcher.acceptToken($0) }
            #expect(accepted && matcher.isTerminated)
        }
    }

    @Test func rawXMLContentExcludesAndValidation() throws {
        let schema = JSONSchema.object(properties: [.init("value", .string(minLength: 3), required: true)])
        let grammar = try Grammar(jsonSchema: schema, options: .init(style: .qwenXML, excludes: controls))
        #expect(try accepts(grammar, "<parameter=value>a</parameter>"))
        #expect(try !accepts(grammar, "<parameter=value>BAD<|open|></parameter>"))
        #expect(throws: GrammarError.self) { try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, excludes: [""])) }
        #expect(throws: GrammarError.self) { try Grammar(jsonSchema: schema, options: .init(style: .qwenXML, excludes: [" bad"])) }
        let json = #"{"type":"json_schema","json_schema":{"type":"string"},"excludes":["BAD"]}"#
        let parsed = try Grammar(structuralTagJSON: json)
        #expect(try !accepts(parsed, #""BAD""#))
    }

    // MARK: Token-level and cache tests (the rest of the module is covered by
    // Fixtures/GrammarLanguage.json).

    private static let argumentBegin = #"<|open|>argument key="value" type="string"<|sep|>"#
    private static let argumentEnd = "<|close|>argument<|sep|>"

    /// Upstream `leaf_grammar`: a `json_schema` structural tag, wrapped in a one-argument object for K3.
    private func leafGrammar(_ schema: String, style: String, excludes: [String]) throws -> Grammar {
        let wrapped = style == "kimi_k3_xml"
            ? #"{"type":"object","properties":{"value":"# + schema + #"},"required":["value"],"additionalProperties":false}"#
            : schema
        let list = "[" + excludes.map(JSONValue.quote).joined(separator: ",") + "]"
        return try Grammar(structuralTagJSON: #"{"type":"structural_tag","format":{"type":"json_schema","json_schema":"# + wrapped
            + #","style":""# + style + #"","excludes":"# + list + "}}")
    }

    private func stringInstance(_ value: String, style: String) -> String {
        style == "kimi_k3_xml" ? Self.argumentBegin + value + Self.argumentEnd : JSONValue.quote(value)
    }

    private static func allowed(_ matcher: inout GrammarMatcher, _ token: Int32) -> Bool {
        matcher.nextTokenBitmask().allows(token)
    }

    private static func accept(_ matcher: inout GrammarMatcher, _ token: Int32) -> Bool {
        matcher.acceptToken(token)
    }

    /// Upstream `test_k3_excludes_token_mask_and_argument_end`.
    @Test func k3ExcludesTokenMaskAndArgumentEnd() throws {
        let grammar = try leafGrammar(#"{"type":"string"}"#, style: "kimi_k3_xml", excludes: controls)
        let vocab = [Self.argumentBegin, "hello", "<|open|>", "<|close|>", "argument", "response", "<|sep|>", "<|op", "en|>",
                     "hello" + Self.argumentEnd, "[EOS]"]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [Int32(vocab.count - 1)])
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(grammar)
        for candidate in [compiled, try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: info)] {
            var matcher = GrammarMatcher(candidate)
            #expect(Self.accept(&matcher, 0))
            #expect(Self.allowed(&matcher, 1))
            #expect(!Self.allowed(&matcher, 2))
            #expect(Self.allowed(&matcher, 3))  // CLOSE remains legal as the start of the argument terminator.
            #expect(Self.allowed(&matcher, 9))  // A token can cross the boundary from value into its wrapper.
            #expect(Self.accept(&matcher, 7))
            #expect(!Self.allowed(&matcher, 8))  // Exclusions also match text split across tokens.
            matcher.rollback(1)
            #expect(Self.accept(&matcher, 1))
            #expect(Self.accept(&matcher, 3))
            #expect(Self.allowed(&matcher, 4))
            #expect(!Self.allowed(&matcher, 5))
            #expect(Self.accept(&matcher, 4))
            #expect(Self.accept(&matcher, 6))
            #expect(Self.allowed(&matcher, 10))
            #expect(Self.accept(&matcher, 10))
            #expect(matcher.isTerminated)
        }
    }

    /// Upstream `test_excluded_branch_mask_rejects_unicode_and_stop_token`.
    @Test(arguments: [#"{"const":"BAD"}"#, #"{"enum":["BAD"]}"#], [false, true])
    func excludedBranchMaskRejectsUnicodeAndStopToken(schema: String, safeBranch: Bool) throws {
        let source = safeBranch ? #"{"anyOf":["# + schema + #",{"const":"safe"}]}"# : schema
        let grammar = try leafGrammar(source, style: "json", excludes: ["BAD"])
        let vocab = ["你", "🦋", #""你""#, #""BAD""#, #""safe""#, "[EOS]"]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [Int32(vocab.count - 1)])
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(grammar))
        let mask = matcher.nextTokenBitmask()
        for (index, text) in vocab.enumerated() {
            let expected = safeBranch && text == #""safe""#
            #expect(mask.allows(Int32(index)) == expected, "\(text)")
            matcher.reset()
            #expect(Self.accept(&matcher, Int32(index)) == expected, "\(text)")
            #expect(try accepts(grammar, text) == expected, "\(text)")
        }
        #expect(!matcher.isCompleted)
    }

    /// Upstream `test_nested_k3_three_controls_mask_and_argument_boundary`.
    @Test func nestedK3ThreeControlsMaskAndArgumentBoundary() throws {
        let payload = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
        let grammar = try leafGrammar(payload, style: "kimi_k3_xml", excludes: controls)
        let begin = Self.argumentBegin.replacingOccurrences(of: #"type="string""#, with: #"type="object""#)
        let vocab = [begin, #"{"text":""#, "hello"] + controls + ["<|op", "en|>", #""}"#, "argument", "response",
                     #"hello"}"# + Self.argumentEnd, "[EOS]"]
        let ids = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, Int32($0)) })
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [ids["[EOS]"]!])
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(grammar)
        for candidate in [compiled, try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: info)] {
            var matcher = GrammarMatcher(candidate)
            func allowed(_ text: String) -> Bool { Self.allowed(&matcher, ids[text]!) }
            func accept(_ text: String) -> Bool { Self.accept(&matcher, ids[text]!) }
            #expect(accept(begin))
            #expect(accept(#"{"text":""#))
            for control in controls {
                #expect(!allowed(control))
                #expect(!accept(control))
            }
            #expect(allowed(#"hello"}"# + Self.argumentEnd))  // One token may finish JSON and consume XML suffix.
            var crossing = GrammarMatcher(candidate)
            for text in [begin, #"{"text":""#, #"hello"}"# + Self.argumentEnd, "[EOS]"] { #expect(Self.accept(&crossing, ids[text]!)) }
            #expect(crossing.isTerminated)
            #expect(accept("<|op"))
            #expect(!allowed("en|>"))
            #expect(!accept("en|>"))
            matcher.rollback(1)
            #expect(accept("hello"))
            #expect(accept(#""}"#))
            #expect(allowed("<|close|>"))
            #expect(!allowed("<|open|>"))
            #expect(!allowed("<|sep|>"))
            #expect(accept("<|close|>"))
            #expect(allowed("argument"))
            #expect(!allowed("response"))
            #expect(accept("argument"))
            #expect(allowed("<|sep|>"))
            #expect(accept("<|sep|>"))
            #expect(allowed("[EOS]"))
            #expect(accept("[EOS]"))
            #expect(matcher.isTerminated)
        }
    }

    /// Upstream `test_excludes_default_and_cache_isolation`.
    @Test func excludesDefaultAndCacheIsolation() throws {
        let schema = #"{"type":"string"}"#
        let without = try Grammar(structuralTagJSON: #"{"type":"structural_tag","format":{"type":"json_schema","json_schema":"# + schema + "}}")
        #expect(without.description == (try leafGrammar(schema, style: "json", excludes: [])).description)
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()), cacheEnabled: true)
        for (excludes, allowed) in [([String](), true), (["bad"], false), (["other"], true), (["bad"], false)] {
            let list = "[" + excludes.map(JSONValue.quote).joined(separator: ",") + "]"
            let compiled = try compiler.compile(structuralTagJSON: #"{"type":"structural_tag","format":{"type":"json_schema","json_schema":"#
                + schema + #","excludes":"# + list + "}}")
            #expect(try accepts(compiled.grammar, #""bad""#) == allowed, "\(excludes)")
        }
        let sequence = try Grammar(structuralFormat: .sequence([
            .jsonSchema(.string(), options: .init(anyWhitespace: true, excludes: ["bad"])), .jsonSchema(.string()),
        ]))
        #expect(try accepts(sequence, #""safe""bad""#))
        #expect(try !accepts(sequence, #""bad""safe""#))
    }

    /// Upstream `test_excludes_drop_length_constraints`, without its warning-text assertions (Swift
    /// has no warning channel for dropped bounds yet).
    @Test(arguments: ["json", "kimi_k3_xml"], [#"{"type":"string","minLength":2}"#, #"{"type":"string","maxLength":3}"#,
                                                #"{"type":"string","minLength":2,"maxLength":3}"#])
    func excludesDropLengthConstraints(style: String, schema: String) throws {
        let bounded = try leafGrammar(schema, style: style, excludes: [])
        let unbounded = try leafGrammar(schema, style: style, excludes: ["bc", "cb"])
        let plain = try leafGrammar(#"{"type":"string"}"#, style: style, excludes: ["bc", "cb"])
        // Same rules as the unbounded string, not one rule per position and exclusion state.
        func ruleCount(_ grammar: Grammar) -> Int { grammar.description.components(separatedBy: "::=").count - 1 }
        #expect(ruleCount(unbounded) <= ruleCount(plain) + 1)
        let minimum = schema.contains("minLength") ? 2 : 0, maximum = schema.contains("maxLength") ? 3 : Int.max
        for value in ["a", "abde", String(repeating: "ax", count: 10)] {
            #expect(try accepts(unbounded, stringInstance(value, style: style)))
            #expect(try accepts(bounded, stringInstance(value, style: style)) == (minimum ... maximum).contains(value.count))
        }
        for value in ["bc", "acbz", String(repeating: "a", count: 20) + "bc"] {
            #expect(try !accepts(unbounded, stringInstance(value, style: style)))
        }
    }

    /// Declared keys stay excluded from additional properties in every JSON spelling (raw, short
    /// escapes, mixed-case `\u` escapes, surrogate pairs): a seeded sample of key spellings is
    /// decoded by `JSONSerialization`, and exactly the declared names must be rejected.
    @Test func additionalKeysExcludeEverySpellingOfDeclaredNames() throws {
        let names = ["city", "é", "日本", "a😀b", "x\"y", "tab\t", "c"]
        let declared = names.map { JSONValue.quote($0) + #":{"type":"integer"}"# }.joined(separator: ",")
        let schema = #"{"type":"object","properties":{"# + declared + #"},"additionalProperties":{"type":"string"}}"#
        let compiled = try compiler.compile(try Grammar(jsonSchema: schema, options: .init(anyWhitespace: true, excludes: ["<|open|>"])))
        var generator = SplitMix64(seed: 0x7A11_5EED)
        func spell(_ scalar: Unicode.Scalar) -> String {
            var options: [String] = []
            let value = scalar.value
            if value >= 0x20, value != 0x22, value != 0x5C { options.append(String(scalar)) }
            if let short = JSONStringPatterns.shortEscape(for: Int32(value)) { options.append("\\" + short) }
            func hex(_ unit: UInt32) -> String {
                let digits = String(unit, radix: 16)
                return (String(repeating: "0", count: 4 - digits.count) + digits).map { Bool.random(using: &generator) ? $0.uppercased() : String($0) }.joined()
            }
            if value <= 0xFFFF { options.append("\\u" + hex(value)) } else {
                let offset = value - 0x10000
                options.append("\\u" + hex(0xD800 + (offset >> 10)) + "\\u" + hex(0xDC00 + (offset & 0x3FF)))
            }
            return options.randomElement(using: &generator)!
        }
        let alphabet: [Unicode.Scalar] = ["c", "i", "t", "y", "é", "日", "本", "a", "😀", "b", "x", "\"", "\t", "/", "\\", "e", "😁"]
        for _ in 0 ..< 1500 {
            let key = Bool.random(using: &generator) ? names.randomElement(using: &generator)!
                : String(String.UnicodeScalarView((0 ..< Int.random(in: 0 ... 4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }))
            let document = "{\"" + key.unicodeScalars.map(spell).joined() + "\":\"v\"}"
            let decoded = try #require(try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
            let isDeclared = names.contains { $0.unicodeScalars.elementsEqual(decoded.keys.first!.unicodeScalars) }
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            #expect((matcher.acceptString(document) && matcher.isCompleted) == !isDeclared, "\(document)")
        }
    }
}

/// A seeded generator, so sampled test inputs are reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
