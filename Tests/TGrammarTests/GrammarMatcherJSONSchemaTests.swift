// Port of xgrammar's tests/python/test_grammar_matcher_json_schema.py: JSON Schema grammars over
// the matcher — pretty-printed instances, jump-forward strings, numeric ranges at the 64-bit
// boundary, string formats, and regressions on real vocabularies.
//
// Pydantic models are spelled as the JSON Schema `model_json_schema()` emits and instances as
// `model_dump_json()` prints them.

import Foundation
import Testing

@testable import TGrammar

@Suite("Grammar matcher (JSON Schema)")
struct GrammarMatcherJSONSchemaTests {
    /// `MainModel` with int, float, bool, untyped list, `List[str]`, `Tuple[str, int, List[str]]`,
    /// `Dict[str, int]` and `Dict[str, Dict[str, int]]` fields.
    static let mainModel = #"""
        {"properties": {"integer_field": {"title": "Integer Field", "type": "integer"}, "number_field": {"title": "Number Field", "type": "number"}, "boolean_field": {"title": "Boolean Field", "type": "boolean"}, "any_array_field": {"items": {}, "title": "Any Array Field", "type": "array"}, "array_field": {"items": {"type": "string"}, "title": "Array Field", "type": "array"}, "tuple_field": {"maxItems": 3, "minItems": 3, "prefixItems": [{"type": "string"}, {"type": "integer"}, {"items": {"type": "string"}, "type": "array"}], "title": "Tuple Field", "type": "array"}, "object_field": {"additionalProperties": {"type": "integer"}, "title": "Object Field", "type": "object"}, "nested_object_field": {"additionalProperties": {"additionalProperties": {"type": "integer"}, "type": "object"}, "title": "Nested Object Field", "type": "object"}}, "required": ["integer_field", "number_field", "boolean_field", "any_array_field", "array_field", "tuple_field", "object_field", "nested_object_field"], "title": "MainModel", "type": "object"}
        """#

    /// `instance.model_dump_json(indent=2, round_trip=True)`.
    static let instance = """
        {
          "integer_field": 42,
          "number_field": 314000.0,
          "boolean_field": true,
          "any_array_field": [
            3.14,
            "foo",
            null,
            true
          ],
          "array_field": [
            "foo",
            "bar"
          ],
          "tuple_field": [
            "foo",
            42,
            [
              "bar",
              "baz"
            ]
          ],
          "object_field": {
            "foo": 42,
            "bar": 43
          },
          "nested_object_field": {
            "foo": {
              "bar": 42
            }
          }
        }
        """

    /// `Grammar.from_json_schema(MainModel, indent=2)`: `any_whitespace` defaults to true and
    /// makes `indent` irrelevant.
    private static func mainModelGrammar() throws -> Grammar { try Grammar(jsonSchema: mainModel, options: .xgrammar) }

    /// Upstream parametrizes the vocabulary-dependent tests over Llama 2 and Llama 3.
    static let vocabularies = LocalTokenizers.available([.llama2, .llama3])

    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func jsonSchemaDebugAcceptString() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(.llama2))
        var matcher = try Upstream.matcher(try Self.mainModelGrammar(), tokenizer.info)
        for character in Self.instance {
            let accepted = matcher.acceptString(String(character))
            #expect(accepted, "\(character.debugDescription)")
        }
        let eosAccepted = matcher.acceptToken(2)
        #expect(eosAccepted)
        #expect(matcher.isTerminated)
    }

    @Test func jsonSchemaFindJumpForwardString() throws {
        var matcher = try Upstream.matcher(try Self.mainModelGrammar(), Upstream.emptyTokenizer)
        let instance = Array(Self.instance)
        for (index, character) in instance.enumerated() {
            let jump = matcher.findJumpForwardString()
            #expect(String(instance[index ..< min(instance.count, index + jump.count)]) == jump, "at \(index)")
            let accepted = matcher.acceptString(String(character))
            #expect(accepted)
        }
        #expect(matcher.findJumpForwardString() == "")
    }

    @Test(arguments: vocabularies)
    func fillNextTokenBitmask(_ model: LocalTokenizers.Model) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let compiler = try #require(LocalTokenizers.compiler(model))
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: Self.mainModel, options: .xgrammar))
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for byte in Self.instance.utf8 {
            matcher.fillNextTokenBitmask(&mask)
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted)
        }
        matcher.fillNextTokenBitmask(&mask)
        #expect(mask.allows(tokenizer.eosTokenID))
    }

    // MARK: Numeric ranges

    /// A pydantic model with one `value` field carrying `ge`/`le` bounds.
    struct RangeSchema: Sendable, CustomTestStringConvertible {
        let name: String
        let type: String
        let minimum: String
        let maximum: String
        var testDescription: String { name }
        var json: String {
            #"{"properties": {"value": {"maximum": \#(maximum), "minimum": \#(minimum), "title": "Value", "type": "\#(type)"}}, "required": ["value"], "title": "\#(name)", "type": "object"}"#
        }
        static func integer(_ name: String, _ minimum: String, _ maximum: String) -> Self { .init(name: name, type: "integer", minimum: minimum, maximum: maximum) }
        static func number(_ name: String, _ minimum: String, _ maximum: String) -> Self { .init(name: name, type: "number", minimum: minimum, maximum: maximum) }
    }

    static let rangeSchema = RangeSchema.integer("RangeSchema", "1", "100")
    static let extendedRangeSchema = RangeSchema.integer("ExtendedRangeSchema", "-128", "256")
    static let negativeRangeSchema = RangeSchema.integer("NegativeRangeSchema", "-1000", "-1")
    static let largeRangeSchema = RangeSchema.integer("LargeRangeSchema", "-99999", "99999")
    static let largeRangeSchemaStartZero = RangeSchema.integer("LargeRangeSchemaStartZero", "0", "20000000000")
    static let floatRangeSchema = RangeSchema.number("FloatRangeSchema", "0.0", "1.0")
    static let negativeFloatRangeSchema = RangeSchema.number("NegativeFloatRangeSchema", "-10.0", "-0.1")
    static let complexFloatRangeSchema = RangeSchema.number("ComplexFloatRangeSchema", "-12345.12345", "56789.56789")
    static let largeFloatRangeSchema = RangeSchema.number("LargeFloatRangeSchema", "-1000.0", "1000.0")
    /// `ge=-20_000_000_000.123123, le=20_000_000_000.456789`, as doubles print.
    static let veryLargeFloatRangeSchema = RangeSchema.number("VeryLargeFloatRangeSchema", "-20000000000.123123", "20000000000.456787")
    static let exceedsInt64MaxSchema = RangeSchema.integer("ExceedsInt64MaxSchema", "0", "18446744073709551615")
    static let exceedsInt64MinSchema = RangeSchema.integer("ExceedsInt64MinSchema", "-9223372036854775809", "100")
    static let exceedsInt64RangeSchema = RangeSchema.integer("ExceedsInt64RangeSchema", "-18446744073709551616", "18446744073709551616")
    static let validInt64MaxSchema = RangeSchema.integer("ValidInt64MaxSchema", "0", "9223372036854775807")
    static let validInt64MinSchema = RangeSchema.integer("ValidInt64MinSchema", "-9223372036854775808", "0")
    static let validLargeIntSchema = RangeSchema.integer("ValidLargeIntSchema", "0", "1000000000000000000")

    /// `(schema_class, test_value)` rows with the value as `model_dump_json()` prints it.
    static let rangeCases: [(RangeSchema, String)] = [
        // Integer test cases
        (rangeSchema, "42"),
        (extendedRangeSchema, "-128"), (extendedRangeSchema, "0"), (extendedRangeSchema, "256"), (extendedRangeSchema, "14"),
        (negativeRangeSchema, "-1000"), (negativeRangeSchema, "-500"), (negativeRangeSchema, "-1"),
        (largeRangeSchema, "-99999"), (largeRangeSchema, "-5678"), (largeRangeSchema, "0"), (largeRangeSchema, "5678"), (largeRangeSchema, "99999"),
        (largeRangeSchemaStartZero, "20000000000"), (largeRangeSchemaStartZero, "0"), (largeRangeSchemaStartZero, "10000000000"), (largeRangeSchemaStartZero, "19999999999"),
        // Float test cases
        (floatRangeSchema, "0.0"), (floatRangeSchema, "0.5"), (floatRangeSchema, "1.0"),
        (negativeFloatRangeSchema, "-10.0"), (negativeFloatRangeSchema, "-5.5"), (negativeFloatRangeSchema, "-0.1"),
        (largeFloatRangeSchema, "-1000.0"), (largeFloatRangeSchema, "-500.5"), (largeFloatRangeSchema, "0.0"), (largeFloatRangeSchema, "500.5"), (largeFloatRangeSchema, "1000.0"),
        (complexFloatRangeSchema, "-1234.1234"), (complexFloatRangeSchema, "0.0"), (complexFloatRangeSchema, "5671.123456"),
        (veryLargeFloatRangeSchema, "20000000000.456787"), (veryLargeFloatRangeSchema, "-19999999999.456787"),
        // Signed 64-bit boundary test cases (should succeed)
        (validInt64MaxSchema, "9223372036854775807"), (validInt64MaxSchema, "1000"),
        (validInt64MinSchema, "-9223372036854775808"), (validInt64MinSchema, "-1000"),
        (validLargeIntSchema, "1000000000000000000"), (validLargeIntSchema, "1000"),
    ]

    /// Fills masks and accepts `{"value":<value>}` byte by byte, then checks EOS is allowed.
    private static func acceptsInstance(_ schema: String, _ instance: String, _ tokenizer: LocalTokenizers.Tokenizer, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let compiler = try #require(LocalTokenizers.compiler(tokenizer.model))
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: schema, options: .xgrammar))
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for byte in instance.utf8 {
            matcher.fillNextTokenBitmask(&mask)
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted, "\(instance) byte \(UnicodeScalar(byte))", sourceLocation: sourceLocation)
        }
        matcher.fillNextTokenBitmask(&mask)
        #expect(mask.allows(tokenizer.eosTokenID), "\(instance)", sourceLocation: sourceLocation)
    }

    @Test(arguments: vocabularies, rangeCases)
    func fillNextTokenBitmaskIntFloatRange(_ model: LocalTokenizers.Model, _ row: (RangeSchema, String)) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        try Self.acceptsInstance(row.0.json, #"{"value":\#(row.1)}"#, tokenizer)
    }

    /// Schemas exceeding the signed 64-bit integer limits are rejected.
    @Test(arguments: [exceedsInt64MaxSchema, exceedsInt64MinSchema, exceedsInt64RangeSchema])
    func limit64BitValidation(_ schema: RangeSchema) throws {
        #expect { try Grammar(jsonSchema: schema.json) } throws: { error in
            (error as? GrammarError)?.message.lowercased().contains("exceeds") == true
        }
    }

    @Test(arguments: vocabularies, [
        (validInt64MaxSchema, "1000"), (validInt64MinSchema, "-1000"), (validLargeIntSchema, "1000"),
    ])
    func signed64BitBoundaryValuesWork(_ model: LocalTokenizers.Model, _ row: (RangeSchema, String)) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        try Self.acceptsInstance(row.0.json, #"{"value":\#(row.1)}"#, tokenizer)
    }

    @Test(arguments: vocabularies)
    func mixedTypeRangeSchema(_ model: LocalTokenizers.Model) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let schema = #"{"properties": {"int_value": {"maximum": 100, "minimum": -100, "title": "Int Value", "type": "integer"}, "float_value": {"maximum": 10.0, "minimum": -10.0, "title": "Float Value", "type": "number"}}, "required": ["int_value", "float_value"], "title": "MixedTypeRangeSchema", "type": "object"}"#
        for instance in [
            #"{"int_value":-100,"float_value":-10.0}"#, #"{"int_value":100,"float_value":10.0}"#,
            #"{"int_value":0,"float_value":0.0}"#, #"{"int_value":-50,"float_value":5.5}"#,
        ] {
            try Self.acceptsInstance(schema, instance, tokenizer)
        }
    }

    @Test(arguments: vocabularies)
    func multipleBoundariesSchema(_ model: LocalTokenizers.Model) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let schema = #"{"properties": {"small_value": {"maximum": 10, "minimum": -10, "title": "Small Value", "type": "integer"}, "medium_value": {"maximum": 100, "minimum": -100, "title": "Medium Value", "type": "integer"}, "large_value": {"maximum": 1000, "minimum": -1000, "title": "Large Value", "type": "integer"}}, "required": ["small_value", "medium_value", "large_value"], "title": "MultipleBoundariesSchema", "type": "object"}"#
        for instance in [
            #"{"small_value":-10,"medium_value":-100,"large_value":-1000}"#,  // All lower bounds
            #"{"small_value":10,"medium_value":100,"large_value":1000}"#,  // All upper bounds
            #"{"small_value":0,"medium_value":0,"large_value":0}"#,
            #"{"small_value":-5,"medium_value":50,"large_value":-500}"#,
        ] {
            try Self.acceptsInstance(schema, instance, tokenizer)
        }
    }

    // MARK: String formats

    static let stringFormatInstances: [(String, String)] = [
        (#"long.email-address-with-hyphens@and.subdomains.example.com"#, "email"),
        (#""very.(),:;<>[]\".VERY.\"very@\\ \"very\".unusual"@strange.example.com"#, "email"),
        (#"128.255.000.222"#, "ipv4"),
        (#"2001:db8:3:4::192.0.2.33"#, "ipv6"),
        (#"P1Y23M456DT9H87M654S"#, "duration"),
        (#"2025-01-01T12:34:56.7+08:09"#, "date-time"),
        (#"123--abc.efgh---789-xyz.rst-uvw"#, "hostname"),
        (#"01234567-89AB-CDEF-abcd-ef0123456789"#, "uuid"),
        (#"http://azAZ09-._~%Ff!$&'()*+,;=:@xyz:987/-/./+/*?aA0-._~%Ff!$&'()@#zZ9-._~%Aa!$&,;=:"#, "uri"),
    ]

    /// Upstream runs these on Llama 3.1; the assertions are vocabulary-independent, so the first
    /// cached vocabulary stands in.
    static let formatVocabularies = Array(LocalTokenizers.available([.llama31, .llama3, .llama2, .qwen3]).prefix(1))

    @Test(arguments: formatVocabularies, stringFormatInstances)
    func maskGenerationFormat(_ model: LocalTokenizers.Model, _ row: (String, String)) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let schema = #"{"properties": {"name": {"format": "\#(row.1)", "title": "Name", "type": "string"}}, "required": ["name"], "title": "MainModel", "type": "object"}"#
        let instance = #"{"name": \#(JSONValue.quote(row.0))}"#
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info, cacheEnabled: false)
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: schema, options: .xgrammar))
        var mask = TokenBitmask(vocabSize: tokenizer.info.vocabSize)
        for byte in instance.utf8 {
            matcher.fillNextTokenBitmask(&mask)
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted, "\(row.1): \(instance) byte \(UnicodeScalar(byte))")
        }
        matcher.fillNextTokenBitmask(&mask)
        let eosAccepted = matcher.acceptToken(tokenizer.eosTokenID)
        #expect(eosAccepted)
        #expect(matcher.isTerminated)
    }

    // MARK: Regressions

    @Test(.enabled(if: !formatVocabularies.isEmpty))
    func implicitLeftRecursionSchema() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(Self.formatVocabularies[0]))
        let schema = #"{"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "properties": {"url": {"type": "string", "pattern": "^(https?://)?([\\da-z\\.-]+)\\.([a-z\\.]{2,6})([/\\w \\.-]*)*/?"}}}"#
        _ = try GrammarCompiler(tokenizerInfo: tokenizer.info).compile(jsonSchema: schema, options: .xgrammar)
    }

    /// Qwen3-235B-A22B-Instruct-2507 shares the Qwen3 vocabulary; `vocab_size=151936`.
    @Test(.enabled(if: LocalTokenizers.has(.qwen3)))
    func regressionAcceptInvalidToken() throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(.qwen3))
        let info = try #require(LocalTokenizers.info(.qwen3, vocabSize: 151936, stopTokenIDs: [tokenizer.eosTokenID]))
        let schema = """
            {"type": "object", "properties": {"value": {"type": ["string", "null"], "maxLength": 10},
            "nested": {"type": "object", "properties": {"value": {"type": ["string", "null"]},
            "nested_nested": {"type": "array", "items": {"type": ["string", "null"]}}},
            "required": ["value", "nested_nested"], "maxItems": 10, "minItems": 1}},
            "required": ["value", "nested"], "additionalProperties": false}
            """
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(jsonSchema: schema, options: .xgrammar))
        var masks = [TokenBitmask](repeating: TokenBitmask(vocabSize: info.vocabSize), count: 7)
        for (index, token) in [4913, 957, 788, 330, 1072, 67212, 788].map(Int32.init).enumerated() {
            let expected = index == 0 || masks[index - 1].allows(token)
            #expect(matcher.acceptToken(token) == expected, "token \(index)")
            matcher.fillNextTokenBitmask(&masks[index])
        }
    }

    @Test func regressionEmptyPropertyKeyRegex() throws {
        let schema = #"{"type": "object", "properties": {"_links": {"type": "object", "patternProperties": {"": {"type": "object", "properties": {"href": {"type": "string"}}}}}}}"#
        _ = try Grammar(jsonSchema: schema, options: .xgrammar)
    }

    @Test func jsonSchemaNumberWithoutConstraint() throws {
        let grammar = try Grammar(jsonSchema: #"{"type": "object", "properties": {"value": {"type": "number"}}, "required": ["value"]}"#, options: .xgrammar)
        for input in [#"{"value": -0.5}"#, #"{"value": -1.5}"#, #"{"value": 0}"#, #"{"value": 1234567890}"#, #"{"value": 3.14159}"#,
                      #"{"value": 1e10}"#, #"{"value": -2.5E-3}"#, #"{"value": 0.0}"#, #"{"value": -0.0}"#] {
            #expect(try Upstream.accepts(grammar, input), "\(input)")
        }
        #expect(try !Upstream.accepts(grammar, #"{"value": "abc"}"#))
    }

    /// The rule-level cache must not change masks across grammars that share rules; exact
    /// upstream rejected counts on Llama 3.
    @Test(arguments: MatcherRuntimeFixtures.upstream.rejectedSizes.filter { $0.grammar == "json_schema" && $0.model.map(LocalTokenizers.has) == true })
    func ruleLevelCacheCrossGrammar(_ row: MatcherRuntimeFixtures.RejectedSizes) throws {
        let model = try #require(row.model)
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info, cacheEnabled: true)
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: try #require(row.schema), options: .xgrammar))
        let counts = Upstream.rejectedCounts(&matcher, bytes: row.input.utf8)
        #expect(counts == row.sizes)
    }
}
