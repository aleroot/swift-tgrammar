// Ports of the remaining upstream xgrammar tests from tests/python/test_grammar_matcher_basic.py,
// test_grammar_matcher_ebnf.py, test_grammar_substring_macro.py, test_grammar_fsm_builder.py,
// test_json_schema_converter.py, test_token_bitmask_operations.py, test_tokenizer_info.py and
// test_serialization.py that had no Swift counterpart yet.

import Foundation
import Testing

@testable import TGrammar

@Suite("Matcher runtime (upstream leftovers)")
struct MatcherRuntimeUpstreamTests {
    // MARK: test_grammar_matcher_basic.py

    /// `test_override_stop_tokens_out_of_range_raises`: the id would be written into the bitmask.
    @Test func overrideStopTokensOutOfRangeTraps() async {
        await #expect(processExitsWith: .failure) {
            let info = try TokenizerInfo(encodedVocab: ["a", "b", "c"], vocabSize: 8)
            let compiled = try GrammarCompiler(tokenizerInfo: info).compile(try Grammar(regex: "a+"))
            _ = GrammarMatcher(compiled, stopTokenIDs: [1 << 28])
        }
    }

    /// `test_batch_fill_next_token_bitmask_terminated_matcher_raises`: upstream raises on the
    /// calling thread; `GrammarBatch` reports the terminated row instead (documented API shape),
    /// while the single-matcher call keeps upstream's precondition.
    @Test(arguments: [1, 2])
    func batchFillWithTerminatedMatcher(maxThreads: Int) throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "</s>"], stopTokenIDs: [2])
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(try Grammar(regex: "a"))
        var terminated = GrammarMatcher(compiled)
        let first = terminated.acceptToken(0), stop = terminated.acceptToken(2)
        #expect(first && stop && terminated.isTerminated)
        var batch = [GrammarMatcher(compiled), terminated]
        let result = GrammarBatch.fillNextTokenMasks(for: &batch, maxThreads: maxThreads)
        #expect(result.masks[0].allowedTokenIDs == [0])
        #expect(result.rows[1].isTerminated && !result.masks[1].allowsAny)
    }

    @Test func fillNextTokenBitmaskOnTerminatedMatcherTraps() async {
        await #expect(processExitsWith: .failure) {
            let info = try TokenizerInfo(encodedVocab: ["a", "b", "</s>"], stopTokenIDs: [2])
            var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(try Grammar(regex: "a")))
            _ = matcher.acceptToken(0)
            _ = matcher.acceptToken(2)
            _ = matcher.nextTokenBitmask()
        }
    }

    // MARK: test_grammar_matcher_ebnf.py

    /// `test_fill_next_token_bitmask_unicode_char_class` (Llama-2 vocabulary).
    @Test(.enabled(if: LocalTokenizers.has(.llama2)))
    func fillNextTokenBitmaskUnicodeCharClass() throws {
        let compiler = try #require(LocalTokenizers.compiler(.llama2))
        var matcher = GrammarMatcher(try compiler.compile(try Grammar(ebnf: "root ::= [a-zа-я一-龥]+")))
        let counts = Upstream.rejectedCounts(&matcher, bytes: "aбя中".utf8)
        // Upstream checks the mask before each of the 8 bytes.
        #expect(Array(counts.prefix(8)) == [22051, 22050, 31984, 22050, 31984, 22050, 31992, 31936])
    }

    // MARK: test_grammar_substring_macro.py

    /// `test_substring_macro_bitmask_matches_string_acceptance`.
    @Test func substringMacroBitmaskMatchesStringAcceptance() throws {
        let vocab = ["a", "b", "ab", "c", "d", "cd", "abcd", "<", ">", "b>", "ba", "ac"]
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: vocab), cacheEnabled: false)
        var matcher = GrammarMatcher(try compiler.compile(ebnf: #"root ::= "<" Substring("ab", "cd") ">""#), terminateWithoutStopToken: true)
        var consumed = "", remaining = Substring("<abcd>")
        while true {
            let mask = matcher.nextTokenBitmask()
            for (id, piece) in vocab.enumerated() {
                var fork = matcher.fork()
                let accepted = fork.acceptString(piece)
                #expect(accepted == mask[id], "piece \(piece) after \(consumed)")
            }
            guard let next = remaining.first else { break }
            let accepted = matcher.acceptString(String(next))
            #expect(accepted)
            consumed.append(next)
            remaining = remaining.dropFirst()
        }
        #expect(matcher.isTerminated)
    }

    // MARK: test_grammar_fsm_builder.py

    @Test func threeByteUpperTailRange() throws {
        #expect(try Upstream.accepts(ebnf: #"root ::= [\u0000-\u574e]"#, "候"))
        #expect(try !Upstream.accepts(ebnf: #"root ::= [\u0000-\u574e]"#, "坏"))
    }

    @Test func unicodeComplementRanges() throws {
        let grammar = try Grammar(ebnf: "root ::= [^😀-🙏é你A-C]")
        for value in ["D", "ê", "好", "😁", "🙏", "😀", "é", "你", "A", "C", "🚀"] {
            let scalar = value.unicodeScalars.first!.value
            let expected = !["é", "你", "A", "B", "C"].contains(value) && !(0x1F600 ... 0x1F64F).contains(scalar)
            #expect(try Upstream.accepts(grammar, value) == expected, "\(value)")
        }
    }

    // MARK: test_json_schema_converter.py

    private static func schemaAccepts(_ schema: String, _ instance: String, anyWhitespace: Bool = true, strict: Bool = true) throws -> Bool {
        try Upstream.accepts(try Grammar(jsonSchema: schema, options: .init(anyWhitespace: anyWhitespace, strict: strict)), instance)
    }

    static let allOptionalSchema = #"{"properties": {"size": {"default": 0, "title": "Size", "type": "integer"}, "state": {"default": false, "title": "State", "type": "boolean"}, "num": {"default": 0, "title": "Num", "type": "number"}}, "title": "MainModel", "type": "object"}"#

    @Test func allOptional() throws {
        for instance in [#"{"size": 42, "state": true, "num": 3.14}"#, #"{"state": false}"#, #"{"size": 1, "num": 1.5}"#] {
            #expect(try Self.schemaAccepts(Self.allOptionalSchema, instance, anyWhitespace: false), "\(instance)")
        }
    }

    @Test func allOptionalNonStrict() throws {
        for instance in [#"{"size": 1, "num": 1.5, "other": false}"#, #"{"other": false}"#] {
            #expect(try Self.schemaAccepts(Self.allOptionalSchema, instance, anyWhitespace: false, strict: false), "\(instance)")
        }
    }

    @Test func enumConst() throws {
        let schema = ##"{"$defs": {"Field": {"enum": ["foo", "bar"], "title": "Field", "type": "string"}}, "properties": {"bars": {"const": "a", "title": "Bars", "type": "string"}, "str_values": {"const": "a\n\r\"", "title": "Str Values", "type": "string"}, "foo": {"enum": ["a", "b", "c"], "title": "Foo", "type": "string"}, "values": {"enum": [1, "a", true], "title": "Values"}, "field": {"$ref": "#/$defs/Field"}}, "required": ["bars", "str_values", "foo", "values", "field"], "title": "MainModel", "type": "object"}"##
        #expect(try Self.schemaAccepts(schema, #"{"bars": "a", "str_values": "a\n\r\"", "foo": "a", "values": 1, "field": "foo"}"#, anyWhitespace: false))
    }

    /// `test_basic_rules_separators_in_qwen_xml` (upstream #948): object values inside Qwen XML
    /// parameters use the configured comma, not the default `", "`.
    @Test(arguments: [#"{"a":1,"b":2}"#, #"{"a":[1,2]}"#])
    func basicRulesSeparatorsInQwenXML(compact: String) throws {
        let schema = #"{"type": "object", "properties": {"value": {"type": "object"}}, "required": ["value"], "additionalProperties": false}"#
        let grammar = try Grammar(jsonSchema: schema, options: .init(anyWhitespace: false, itemSeparator: ",", keySeparator: ":", style: .qwenXML))
        #expect(try Upstream.accepts(grammar, "<parameter=value>" + compact + "</parameter>"))
        let spaced = compact.replacingOccurrences(of: ",", with: ", ")
        #expect(try !Upstream.accepts(grammar, "<parameter=value>" + spaced + "</parameter>"))
    }

    @Test(arguments: [
        (#"{"type": "array", "prefixItems": {"type": "string"}}"#, "prefixItems must be an array"),
        (#"{"type": "array", "prefixItems": ["not an object"]}"#, "prefixItems must be an array of objects or booleans"),
        (#"{"type": "array", "prefixItems": [false]}"#, "prefixItems contains false"),
        (#"{"type": "array", "items": "not an object"}"#, "items must be a boolean or an object"),
        (#"{"type": "array", "unevaluatedItems": "not an object"}"#, "unevaluatedItems must be a boolean or an object"),
        (#"{"type": "array", "minItems": "not an integer"}"#, "minItems must be an integer"),
        (#"{"type": "array", "maxItems": -1}"#, "maxItems must be a non-negative integer"),
        (#"{"type": "array", "minItems": 5, "maxItems": 3}"#, "minItems is greater than maxItems: 5 > 3"),
        (#"{"type": "array", "prefixItems": [{}, {}, {}], "maxItems": 2}"#, "maxItems is less than the number of prefixItems: 2 < 3"),
        (#"{"type": "array", "prefixItems": [{}, {}], "minItems": 3, "items": false}"#, "minItems is greater than the number of prefixItems, but additional items are not allowed: 3 > 2"),
    ])
    func arraySchemaErrorCases(_ schema: String, _ message: String) {
        #expect { try Grammar(jsonSchema: schema) } throws: { error in
            String(describing: error).contains(message)
        }
    }

    @Test func floatMinimumNoWildcardInGrammar() throws {
        for schema in [#"{"type":"number","minimum":0.5}"#, #"{"type":"number","maximum":9.5}"#, #"{"type":"number","minimum":0.5,"maximum":9.5}"#] {
            let printed = try Grammar(jsonSchema: schema).description
            for line in printed.split(separator: "\n") where line.hasPrefix("root") {
                #expect(!line.contains(#"[\0-\U0010ffff]"#), "\(line)")
            }
        }
    }

    @Test func typeArrayEmpty() {
        #expect(throws: Never.self) { _ = try Grammar(jsonSchema: #"{"type": []}"#, options: .init(anyWhitespace: true)) }
    }

    /// `test_multiple_of_unsupported_warns_and_ignores`; upstream's stderr warning has no Swift
    /// counterpart, the acceptance behaviour is checked.
    @Test(arguments: [
        (#"{"type": "number", "multipleOf": 2}"#, ["3", "5.5"], [String]()),
        (#"{"type": "integer", "multipleOf": 2.5}"#, ["2", "3"], ["1.5"]),
        (#"{"type": "integer", "multipleOf": 1025}"#, ["1025", "1026"], []),
        (#"{"type": "integer", "multipleOf": 1e30}"#, ["1", "2"], []),
        (#"{"type": "integer", "minimum": 0, "multipleOf": 2}"#, ["1", "3"], ["-1"]),
    ])
    func multipleOfUnsupportedIsIgnored(_ schema: String, _ accepted: [String], _ rejected: [String]) {
        for instance in accepted { #expect((try? Self.schemaAccepts(schema, instance)) == true, "\(instance)") }
        for instance in rejected { #expect((try? Self.schemaAccepts(schema, instance)) == false, "\(instance)") }
    }

    static let limitedWhitespaceSchema = #"{"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}"#
    static let limitedWhitespaceGrammar = #"""
        basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9])) (=(basic_string_sub))
        basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=(basic_string_sub_4 [,}\]:]))
        basic_string ::= (("\"" basic_string_sub)) (=(basic_string_sub_4 "}"))
        root ::= (("{" basic_string_sub_4 "\"key\"" basic_string_sub_4 ":" basic_string_sub_4 basic_string basic_string_sub_4 "}"))
        basic_string_sub_2 ::= ("" | ([ \n\r\t] basic_string_sub_3))
        basic_string_sub_3 ::= ("" | ([ \n\r\t]))
        basic_string_sub_4 ::= ((basic_string_sub_2))

        """#

    private static func checkLimitedWhitespace(_ grammar: Grammar) throws {
        for input in ["{  \"key\"  :  \"value\"  }", #"{"key":"value"}"#, "{\r\n\"key\"\r:\t\"value\"\n\r}"] {
            #expect(try Upstream.accepts(grammar, input), "\(input)")
        }
        for input in ["{   \"key\"  :  \"value\"   }", "{    \"key\"  :  \"value\"    }", "{\r\n\r\"key\":\"value\"}"] {
            #expect(try !Upstream.accepts(grammar, input), "\(input)")
        }
    }

    @Test func limitedWhitespaceCount() throws {
        let grammar = try GrammarTesting.optimize(try Grammar(jsonSchema: Self.limitedWhitespaceSchema, options: .init(anyWhitespace: true, maxWhitespaceCount: 2)))
        // Upstream also compares the printed grammar (`limitedWhitespaceGrammar`); this converter
        // lays schema rules out differently by design, so only the language is checked.
        try Self.checkLimitedWhitespace(grammar)
    }

    @Test func limitedWhitespaceCompile() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer)
        let compiled = try compiler.compile(try Grammar(jsonSchema: Self.limitedWhitespaceSchema, options: .init(anyWhitespace: true, maxWhitespaceCount: 2)))
        // Printed-layout comparison omitted as in `limitedWhitespaceCount`.
        try Self.checkLimitedWhitespace(compiled.grammar)
    }

    /// `test_generate_range_regex`: TGrammar generates its own range patterns, so each upstream
    /// regex is compared by language with the integer schema over probe values.
    @Test(arguments: [
        ("12", "16", #"^((1[2-6]))$"#), ("1", "10", #"^(([1-9]|10))$"#),
        ("2134", "3459", #"^((213[4-9]|21[4-8]\d|219\d|2[2-8]\d{2}|29\d{2}|30\d{2}|3[1-3]\d{2}|34[0-5]\d))$"#),
        ("-5", "10", #"^(-([1-5])|0|([1-9]|10))$"#), ("-15", "-10", #"^(-(1[0-5]))$"#),
        ("-1999", "-100", #"^(-([1-9]\d{2}|1\d{3}))$"#), ("1", "9999", #"^(([1-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}))$"#),
        ("", "", #"^-?\d+$"#), ("5", "", #"^([5-9]|[1-9]\d{1,})$"#), ("", "0", #"^(-[1-9]\d*|0)$"#),
        ("-5", "", #"^(-([1-5])|0|[1-9]\d*)$"#), ("", "-2", #"^(-[2-9]|-[1-9]\d{1,})$"#),
        ("78", "1278", #"^((7[8-9]|8\d|9\d|[1-9]\d{2}|10\d{2}|11\d{2}|120\d|12[1-6]\d|127[0-8]))$"#),
        ("-100", "100", #"^(-([1-9]|[1-9]\d|100)|0|([1-9]|[1-9]\d|100))$"#),
        ("", "-123", #"^(-12[3-9]|-1[3-8]\d|-19\d|-[2-8]\d{2}|-9\d{2}|-[1-9]\d{3,})$"#),
        ("5", "5", #"^((5))$"#), ("-10", "0", #"^(-([1-9]|10)|0)$"#), ("0", "10", #"^(0|([1-9]|10))$"#),
        ("100", "110", #"^((10\d|110))$"#), ("12345", "12347", #"^((1234[5-7]))$"#),
        ("", "-10", #"^(-[1-9]\d|-[1-9]\d{2,})$"#), ("", "-50", #"^(-[5-9]\d|-[1-9]\d{2,})$"#),
        ("100", "", #"^([1-9]\d{2}|[1-9]\d{3,})$"#), ("10000000000", "10000000002", #"^((1000000000[0-2]))$"#),
    ])
    func generateRangeRegex(_ minimum: String, _ maximum: String, _ regex: String) throws {
        var bounds: [String] = []
        if !minimum.isEmpty { bounds.append(#""minimum": \#(minimum)"#) }
        if !maximum.isEmpty { bounds.append(#""maximum": \#(maximum)"#) }
        let schema = try Upstream.matcher(try Grammar(jsonSchema: #"{"type": "integer"\#(bounds.map { ", " + $0 }.joined())}"#))
        let reference = try Upstream.matcher(try Grammar(regex: regex))
        var probes = Set((-1300 ... 1300).map(String.init))
        for bound in [minimum, maximum].compactMap(Int64.init) {
            for delta in Int64(-15) ... 15 { probes.insert(String(bound + delta)) }
        }
        for probe in probes.sorted() {
            var lhs = schema, rhs = reference
            let expected = rhs.acceptString(probe) && rhs.isTerminated
            let actual = lhs.acceptString(probe) && lhs.isTerminated
            #expect(actual == expected, "\(probe)")
        }
    }

    /// `test_generate_float_regex`, compared by language with the number schema over probes of at
    /// most six fractional digits (the precision of upstream's patterns).
    @Test(arguments: [
        ("1.0", "5.0", "", #"^(1\.[1-9]\d{0,5}|1\.0[1-9]\d{0,4}|1\.00[1-9]\d{0,3}|1\.000[1-9]\d{0,2}|1\.0000[1-9]\d{0,1}|1\.00000[1-9]|1\.0{1,6}|1|(([2-4]))(\.\d{1,6})?|5\.0{1,6}|5)$"#),
        ("1.5", "5.75", "", #"^(1\.[6-9]\d{0,5}|1\.5[1-9]\d{0,4}|1\.50[1-9]\d{0,3}|1\.500[1-9]\d{0,2}|1\.5000[1-9]\d{0,1}|1\.50000[1-9]|1\.50{0,5}|(([2-4]))(\.\d{1,6})?|5\.[0-6]\d{0,5}|5\.7[0-4]\d{0,4}|5\.0{1,6}|5\.70{0,5}|5\.750{0,4}|5)$"#),
        ("-3.14", "2.71828", "", #"^(-0\.[1-9]\d{0,5}|-0\.0[1-9]\d{0,4}|-0\.00[1-9]\d{0,3}|-0\.000[1-9]\d{0,2}|-0\.0000[1-9]\d{0,1}|-0\.00000[1-9]|-(([1-2]))(\.\d{1,6})?|-3\.0\d{0,5}|-3\.1[0-3]\d{0,4}|-3\.0{1,6}|-3\.10{0,5}|-3\.140{0,4}|-3|0(\.0{1,6})?|-0(\.0{1,6})|0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|((1))(\.\d{1,6})?|2\.[0-6]\d{0,5}|2\.70\d{0,4}|2\.71[0-7]\d{0,3}|2\.718[0-1]\d{0,2}|2\.7182[0-7]\d{0,1}|2\.0{1,6}|2\.70{0,5}|2\.710{0,4}|2\.7180{0,3}|2\.71820{0,2}|2\.718280{0,1}|2)$"#),
        ("0.5", "", "", #"^(0\.[6-9]\d{0,5}|0\.5[1-9]\d{0,4}|0\.50[1-9]\d{0,3}|0\.500[1-9]\d{0,2}|0\.5000[1-9]\d{0,1}|0\.50000[1-9]|0\.50{0,5}|([1-9]|[1-9]\d{1,})(\.\d{1,6})?)$"#),
        ("", "-1.5", "", #"^(-1\.[6-9]\d{0,5}|-1\.5[1-9]\d{0,4}|-1\.50[1-9]\d{0,3}|-1\.500[1-9]\d{0,2}|-1\.5000[1-9]\d{0,1}|-1\.50000[1-9]|-1\.50{0,5}|-([2-9]|[1-9]\d{1,})(\.\d{1,6})?)$"#),
        ("", "", "", #"^-?\d+(\.\d{1,6})?$"#),
        ("3.14159", "3.14159", "", #"^(3\.141590{0,1})$"#),
        ("10.5", "2.5", "", #"^()$"#),
        ("5.123456", "5.123457", "", #"^(5\.123456|5\.123457)$"#),
        ("-0.000001", "0.000001", "", #"^(-0\.000001|0(\.0{1,6})?|-0(\.0{1,6})|0\.000001)$"#),
        ("0", "", "start", #"^(0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|([1-9]|[1-9]\d{1,})(\.\d{1,6})?)$"#),
        ("0", "", "", #"^(0(\.0{1,6})?|0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|([1-9]|[1-9]\d{1,})(\.\d{1,6})?)$"#),
        ("2.5", "2.5", "end", #"^()$"#),
    ])
    func generateFloatRegex(_ minimum: String, _ maximum: String, _ exclusive: String, _ regex: String) throws {
        var bounds: [String] = []
        if !minimum.isEmpty { bounds.append(exclusive == "start" ? #""exclusiveMinimum": \#(minimum)"# : #""minimum": \#(minimum)"#) }
        if !maximum.isEmpty { bounds.append(exclusive == "end" ? #""exclusiveMaximum": \#(maximum)"# : #""maximum": \#(maximum)"#) }
        let source = #"{"type": "number"\#(bounds.map { ", " + $0 }.joined())}"#
        // An empty range (`^()$`) accepts no number; TGrammar may reject such a schema outright.
        let schema = try? Upstream.matcher(try Grammar(jsonSchema: source))
        let reference = try Upstream.matcher(try Grammar(regex: regex))
        let fractions = ["", ".0", ".00", ".000000", ".5", ".50", ".05", ".1", ".14", ".14159", ".141590", ".25",
                         ".5", ".6", ".71828", ".718281", ".71829", ".75", ".7500", ".751", ".123456", ".123457", ".123458",
                         ".000001", ".000002", ".999999", ".49", ".4999"]
        var probes = Set<String>()
        for integer in -12 ... 12 {
            for fraction in fractions {
                probes.insert(String(integer) + fraction)
                if integer == 0 { probes.insert("-0" + fraction) }
            }
        }
        for integer in ["10", "20", "99", "100", "123"] { for sign in ["", "-"] { probes.insert(sign + integer); probes.insert(sign + integer + ".5") } }
        for probe in probes.sorted() {
            var rhs = reference
            let expected = rhs.acceptString(probe) && rhs.isTerminated
            var actual = false
            if var lhs = schema { actual = lhs.acceptString(probe) && lhs.isTerminated }
            #expect(actual == expected, "\(source): \(probe)")
        }
    }

    /// `test_generate_float_regex_cross_zero_accepts_negative_zero_decimal`,
    /// `test_generate_float_regex_one_sided_integer_boundaries` and
    /// `test_generate_float_regex_fractional_upper_bound_includes_floor_integer`: their regex-level
    /// and schema-level assertions, checked on the number schema with the same bounds.
    @Test(arguments: [
        (#"{"type":"number","minimum":-4.0,"maximum":4.0}"#, ["-0.1", "-0.5", "-0.999999", "-0.0", "-0.000000"], ["-0", "-4.1", "4.1"]),
        (#"{"type":"number","minimum":-0.5,"maximum":0.5}"#, ["-0.1", "-0.5"], ["-0.9"]),
        (#"{"type":"number","minimum":4.0}"#, ["4.1", "4.999999"], ["3.999999", "3.9"]),
        (#"{"type":"number","maximum":-4.0}"#, ["-4.1", "-4.999999"], ["-3.999999", "-3.9"]),
        (#"{"type":"number","minimum":1.5,"maximum":5.75}"#, ["5", "5.75"], ["6"]),
        (#"{"type":"number","maximum":-1.5}"#, ["-2", "-2.0"], ["-1"]),
        (#"{"type":"number","minimum":-3.14,"maximum":2.71828}"#, ["2", "2.71828"], ["3"]),
    ])
    func floatRangeBoundaries(_ schema: String, _ accepted: [String], _ rejected: [String]) throws {
        let grammar = try Grammar(jsonSchema: schema, options: .xgrammar)
        for value in accepted + rejected {
            var matcher = try Upstream.matcher(grammar)
            #expect((matcher.acceptString(value) && matcher.isTerminated) == accepted.contains(value), "\(value)")
        }
    }

    /// `test_control_char_in_property_key`: a raw control byte cannot spell the key's `\x01`; the
    /// JSON escape can.
    @Test func controlCharInPropertyKey() throws {
        let info = try TokenizerInfo(encodedVocab: (0 ..< 128).map { String(UnicodeScalar(UInt8($0))) }, stopTokenIDs: [0])
        let schema = #"{"type":"object","properties":{"key\u0001ctrl":{"type":"string"}},"required":["key\u0001ctrl"]}"#
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(jsonSchema: schema, options: .xgrammar))
        var accepted = true
        for byte in #"{"key"#.utf8 { accepted = accepted && matcher.acceptToken(Int32(byte)) }
        #expect(accepted)
        let control = matcher.acceptToken(1)
        #expect(!control)
        for byte in #"\u0001ctrl":"v"}"#.utf8 { accepted = accepted && matcher.acceptToken(Int32(byte)) }
        let stop = matcher.acceptToken(0)
        #expect(accepted && stop && matcher.isTerminated)
    }

    // MARK: test_token_bitmask_operations.py

    @Test func applyTokenBitmaskInplaceCPUBFloat16() {
        let mask = TokenBitmask(vocabSize: 10, words: [0b10_1010_1010])
        let values: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        var logits = values.map { UInt16($0.bitPattern >> 16) }
        logits.withUnsafeMutableBufferPointer { mask.apply(toBFloat16: $0) }
        let expected = values.enumerated().map { $0.offset % 2 == 1 ? UInt16($0.element.bitPattern >> 16) : 0xFF80 }
        #expect(logits == expected)
    }

    @Test func bitmaskToBoolMask() {
        let mask = TokenBitmask(vocabSize: 64, words: [0xFFFF_0000, 0x0000_FFFF])
        let expected = Array(repeating: false, count: 16) + Array(repeating: true, count: 32) + Array(repeating: false, count: 16)
        #expect((0 ..< 64).map { mask[$0] } == expected)
        let mask50 = TokenBitmask(vocabSize: 50, words: [0xFFFF_0000, 0x0000_FFFF])
        #expect((0 ..< 50).map { mask50[$0] } == Array(expected.prefix(50)))
    }

    @Test(arguments: [(1, 4), (2, 1023), (4, 32000), (3, 32001)])
    func boolMaskBitmaskRoundtrip(batchSize: Int, vocabSize: Int) {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< batchSize {
            let bools = (0 ..< vocabSize).map { _ in Bool.random(using: &generator) }
            var words = [UInt32](repeating: 0, count: TokenBitmask.wordCount(vocabSize: vocabSize))
            for (token, allowed) in bools.enumerated() where allowed { words[token >> 5] |= 1 << UInt32(token & 31) }
            let mask = TokenBitmask(vocabSize: vocabSize, words: words)
            #expect((0 ..< vocabSize).map { mask[$0] } == bools)
        }
    }

    // MARK: test_tokenizer_info.py

    @Test func matcherAcceptPaddingTokenID() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b"], vocabSize: 1000, stopTokenIDs: [])
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(.builtinJSON))
        let accepted = matcher.acceptToken(500)
        #expect(!accepted)
    }

    @Test(arguments: LocalTokenizers.available(LocalTokenizers.Model.allCases))
    func buildTokenizerInfo(_ model: LocalTokenizers.Model) throws {
        let tokenizer = try #require(LocalTokenizers.tokenizer(model))
        #expect(tokenizer.info.decodedVocab.count == tokenizer.info.vocabSize)
    }

    /// `test_dump_metadata_load` rows whose vocabulary is cached locally (Phi-3 small is not).
    @Test(arguments: LocalTokenizers.available([.llama2, .llama3]))
    func dumpMetadataLoad(_ model: LocalTokenizers.Model) throws {
        let expected = [
            LocalTokenizers.Model.llama2: #"{"vocab_type":1,"vocab_size":32000,"add_prefix_space":true,"stop_token_ids":[2]}"#,
            .llama3: #"{"vocab_type":2,"vocab_size":128256,"add_prefix_space":false,"stop_token_ids":[128009]}"#,
        ]
        let info = try #require(LocalTokenizers.tokenizer(model)).info
        #expect(info.metadata.json == expected[model])
        let loaded = try TokenizerInfo(encodedVocab: Array(info.decodedVocab), vocabType: .raw)
        #expect(loaded.decodedVocab == info.decodedVocab)
    }

    // MARK: test_serialization.py

    private static func serializationGrammar() throws -> Grammar {
        try Grammar(ebnf: "rule1 ::= ([^0-9] rule1) | \"\"\nroot_rule ::= rule1 \"a\"\n", rootRule: "root_rule")
    }

    private static func serializationTokenizer() throws -> TokenizerInfo {
        try TokenizerInfo(encodedVocab: ["1", "212", "a", "A", "b", "一", "-", "aBc", "abc"], vocabType: .byteFallback,
                          vocabSize: 10, stopTokenIDs: [0, 1], addPrefixSpace: true)
    }

    @Test func deserializeDeeplyNestedJSONRejected() {
        #expect(throws: SerializationError.self) {
            try Grammar(serializedJSON: String(repeating: "[", count: 60) + String(repeating: "]", count: 60))
        }
        #expect(throws: SerializationError.self) {
            try Grammar(serializedJSON: String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000))
        }
    }

    @Test func deserializedTokenizerInfoCompilesTokenEdges() throws {
        let info = try Self.serializationTokenizer()
        let recovered = try TokenizerInfo(serializedJSON: info.serializedJSON)
        let grammar = try Grammar(ebnf: "root ::= Token(2, 3) \"a\"\n")
        var masks: [TokenBitmask] = []
        for tokenizer in [info, recovered] {
            var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: tokenizer).compile(grammar))
            masks.append(matcher.nextTokenBitmask())
            let accepted = matcher.acceptToken(2)
            #expect(accepted)
        }
        #expect(masks[0] == masks[1])
    }

    @Test func serializeGrammarFunctional() throws {
        let original = try Self.serializationGrammar()
        let recovered = try Grammar(serializedJSON: original.serializedJSON)
        #expect(original.description == recovered.description)
        let compiler = GrammarCompiler(tokenizerInfo: try Self.serializationTokenizer())
        var lhs = GrammarMatcher(try compiler.compile(original)), rhs = GrammarMatcher(try compiler.compile(recovered))
        let a = lhs.acceptString("aaa"), b = rhs.acceptString("aaa")
        #expect(a == b)
    }

    @Test func serializeGrammarUTF8() throws {
        let grammar = try Grammar(ebnf: #"root ::= "こんにちは" | "😊" | "你好" | "hello" | "\n""#)
        let recovered = try Grammar(serializedJSON: grammar.serializedJSON)
        for input in ["こんにちは", "😊", "你好", "hello", "\n"] { #expect(try Upstream.accepts(recovered, input), "\(input)") }
    }

    @Test func serializeTokenizerInfoFunctional() throws {
        let original = try Self.serializationTokenizer()
        let recovered = try TokenizerInfo(serializedJSON: original.serializedJSON)
        #expect(original.vocabType == recovered.vocabType && original.vocabSize == recovered.vocabSize)
        #expect(original.addPrefixSpace == recovered.addPrefixSpace && original.stopTokenIDs == recovered.stopTokenIDs)
        #expect(original.specialTokenIDs == recovered.specialTokenIDs && original.decodedVocab == recovered.decodedVocab)
        let grammar = try Self.serializationGrammar()
        var lhs = GrammarMatcher(try GrammarCompiler(tokenizerInfo: original).compile(grammar))
        var rhs = GrammarMatcher(try GrammarCompiler(tokenizerInfo: recovered).compile(grammar))
        let lmask = lhs.nextTokenBitmask(), rmask = rhs.nextTokenBitmask()
        #expect(lmask == rmask)
        let a = lhs.acceptString("aaa"), b = rhs.acceptString("aaa")
        #expect(a == b)
    }

    @Test func serializeCompiledGrammarFunctional() throws {
        let info = try Self.serializationTokenizer()
        let original = try GrammarCompiler(tokenizerInfo: info).compile(try Self.serializationGrammar())
        let recovered = try CompiledGrammar(serializedJSON: original.serializedJSON, tokenizerInfo: info)
        var lhs = GrammarMatcher(original), rhs = GrammarMatcher(recovered)
        var lmask = TokenBitmask(vocabSize: info.vocabSize), rmask = TokenBitmask(vocabSize: info.vocabSize)
        let lneeds = lhs.fillNextTokenBitmask(&lmask), rneeds = rhs.fillNextTokenBitmask(&rmask)
        #expect(lneeds == rneeds && lmask == rmask)
        let a = lhs.acceptString("aaa"), b = rhs.acceptString("aaa")
        #expect(a == b && lhs.isTerminated == rhs.isTerminated)
    }
}
