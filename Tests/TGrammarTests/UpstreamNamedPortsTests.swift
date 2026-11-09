import Testing
@testable import TGrammar

// Ports of individual upstream tests (ca1acf2): test_temperature.py
// (defaults_to_none, ebnf_temperature_combines_with_other_attributes, inner_temperature_overrides_outer,
// ambiguous_paths_use_maximum_temperature, traverse_draft_tree_uses_minus_one...), test_max_chars.py
// (5 tests), test_json_schema_direct_converter.py (all 6), test_grammar_fsm_builder.py
// (negated_classes..., character_class_utf8_boundaries_and_mask, empty_sequence) and
// test_regex_converter.py test_non_greedy_quantifier.

@Suite("Temperature and max_chars (upstream, named ports)")
struct TemperatureMaxCharsNamedPortTests {
    static let vocab = ["a", "b", "x", "z", " "]
    func info(_ v: [String] = vocab, stop: [Int32] = []) throws -> TokenizerInfo {
        try TokenizerInfo(encodedVocab: v, stopTokenIDs: stop)
    }
    func lark(_ s: String, _ i: TokenizerInfo, named: [String: NamedGrammar] = [:]) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: i, cacheEnabled: false).compile(lark: s, namedGrammars: named)
    }
    func approx(_ v: Float?, _ e: Float) -> Bool { v.map { abs($0 - e) < 1e-6 } ?? false }
    func allowed(_ m: inout GrammarMatcher) -> [Int32] { m.nextTokenBitmask().allowedTokenIDs }
    func allowed(_ c: CompiledGrammar, after p: String) -> [Int32] {
        var m = GrammarMatcher(c); do { let ok = m.acceptString(p); #expect(ok) }; return m.nextTokenBitmask().allowedTokenIDs
    }

    @Test func temperatureDefaultsToNone() throws {
        var m = GrammarMatcher(try lark("start: \"a\"", info()))
        #expect(m.temperature == nil); do { let ok = m.acceptString("a"); #expect(ok) }; #expect(m.temperature == nil)
    }
    @Test func ebnfTemperatureCombines() throws {
        let g = try Grammar(ebnf: "root[max_tokens=3, temperature=0.5] ::= \"a\"*")
        #expect(g.description.contains("max_tokens=3")); #expect(g.description.contains("temperature=0.5"))
    }
    @Test func innerOverridesOuter() throws {
        let item = try Grammar(lark: "start[temperature=0.3]: \"x\"")
        let c = try lark("start: \"a\" value \"z\"\nvalue[temperature=0.6]: @item", info(), named: ["item": .grammar(item)])
        var m = GrammarMatcher(c, defaultTemperature: 0.1)
        do { let ok = m.acceptString("a"); #expect(ok) }; #expect(approx(m.temperature, 0.3))
        do { let ok = m.acceptString("x"); #expect(ok) }; #expect(approx(m.temperature, 0.1))
    }
    @Test func ambiguousUsesMaximum() throws {
        let c = try lark("start: left | right\nleft[temperature=0.2]: \"a\"+\nright[temperature=0.9]: \"a\" \"b\"", info())
        var m = GrammarMatcher(c, defaultTemperature: 0.1)
        #expect(approx(m.temperature, 0.9)); do { let ok = m.acceptString("a"); #expect(ok) }
        #expect(approx(m.temperature, 0.9)); do { let ok = m.acceptString("a"); #expect(ok) }; #expect(approx(m.temperature, 0.2))
    }
    @Test func draftTreeRejectedNodesHaveNoTemperature() throws {
        let m = GrammarMatcher(try lark("start: \"a\"", info()))
        let tree = try DraftTokenTree(nodes: [.init(1, firstChild: 1), .init(0)])
        let r = m.traverseDraftTree(tree)
        #expect(r.temperatures == [nil, nil])
    }
    @Test func maxCharsBoundaryWithAcceptedBitset() throws {
        let acc = (0..<1024).map { String(UnicodeScalar(0x1000 + $0)!) }
        let rej = (0..<1024).map { String(UnicodeScalar(0x2000 + $0)!) }
        let v = zip(acc, rej).flatMap { [$0, $1] } + [">"]
        let i = try TokenizerInfo(encodedVocab: v)
        let c = try lark("start: value \">\"\nvalue[max_chars=1]: /[\(acc[0])-\(acc.last!)]*/", i)
        var m = GrammarMatcher(c, terminateWithoutStopToken: true)
        do { let al = allowed(&m); #expect(al == Array(stride(from: Int32(0), to: 2048, by: 2)) + [2048]) }
    }
    @Test func maxCharsStopCapture() throws {
        let i = try TokenizerInfo(encodedVocab: ["aa!", "a>!"])
        let c = try lark("""
            start[capture="outer"]: reasoning "!"
            reasoning[max_chars=2, capture="inner", stop=">", stop_capture="marker"]: TEXT
            TEXT: /(\\\\n|.)*/
            """, i)
        var f = GrammarMatcher(c, terminateWithoutStopToken: true)
        do { let ok = f.acceptToken(0); #expect(ok) }; #expect(f.isTerminated)
        #expect(f.captures() == [.init(name: "inner", bytes: Array("aa".utf8)), .init(name: "outer", bytes: Array("aa!".utf8))])
        var mk = GrammarMatcher(c, terminateWithoutStopToken: true)
        do { let ok = mk.acceptToken(1); #expect(ok) }; #expect(mk.isTerminated)
        #expect(mk.captures() == [.init(name: "marker", bytes: Array(">".utf8)), .init(name: "inner", bytes: Array("a".utf8)), .init(name: "outer", bytes: Array("a!".utf8))])
        let si = try info(["a", "<eos>"], stop: [1])
        let sc = try lark("start: reasoning\nreasoning[max_chars=2, suffix=\">\"]: /[a-z]*/", si)
        var s = GrammarMatcher(sc)
        do { let ok = s.acceptToken(0); #expect(ok) }; do { let ok = s.acceptToken(0); #expect(ok) }; do { let al = allowed(&s); #expect(al == [1]) }
        do { let ok = s.acceptToken(1); #expect(ok) }; #expect(s.isTerminated)
        s.rollback(1); #expect(!s.isTerminated); do { let al = allowed(&s); #expect(al == [1]) }
    }
    @Test func maxCharsAtomicToken() throws {
        let i = try TokenizerInfo(encodedVocab: ["<|wide|>", "!"])
        let c = try lark("start: value \"!\"\nvalue[max_chars=1]: <|wide|>", i)
        var m = GrammarMatcher(c, terminateWithoutStopToken: true)
        do { let al = allowed(&m); #expect(al == [0]) }; do { let ok = m.acceptToken(0); #expect(ok) }; do { let ok = m.acceptToken(1); #expect(ok) }; #expect(m.isTerminated)
    }
    @Test func tokenEdgesRetriedUnderCharBudget() throws {
        let i = try info(["<s>", "</s>", "a", "b", "ab", "abcd", "<", ">", "<|x|>", "|", "\"", ","], stop: [1])
        let comp = GrammarCompiler(tokenizerInfo: i, cacheEnabled: false)
        let w = try comp.compile(Grammar(ebnf: "root ::= \"<\" body \">\"\nbody[max_chars=8] ::= (Token(8) | [a-z])*"))
        let wo = try comp.compile(Grammar(ebnf: "root ::= \"<\" body \">\"\nbody[max_chars=8] ::= [a-z]*"))
        #expect(allowed(w, after: "<") == [2, 3, 4, 5, 7, 8]); #expect(allowed(wo, after: "<") == [2, 3, 4, 5, 7])
        #expect(allowed(w, after: "<abcdab") == [2, 3, 4, 7, 8]); #expect(allowed(wo, after: "<abcdab") == [2, 3, 4, 7])
        #expect(allowed(w, after: "<abcdabcd") == [7]); #expect(allowed(wo, after: "<abcdabcd") == [7])
    }
    @Test func crossingIntoBudgetedSibling() throws {
        let v = ["<s>", "</s>", "a", "b", ",", "|", "a,bbb|", "a,bb|", ",bbb", "<"]
        let i = try info(v, stop: [1])
        let c = try GrammarCompiler(tokenizerInfo: i, cacheEnabled: false).compile(Grammar(ebnf: "root ::= \"<\" t \",\" b \"|\"\nt ::= [a-z]*\nb[max_chars=2] ::= [a-z]*"))
        for p in ["<", "<a"] {
            let a = allowed(c, after: p)
            #expect(a == ["a", "b", ",", "a,bb|"].map { Int32(v.firstIndex(of: $0)!) })
            for t in ["a,bbb|", "a,bb|", ",bbb"] {
                var m = GrammarMatcher(c); do { let ok = m.acceptString(p); #expect(ok) }
                let id = Int32(v.firstIndex(of: t)!)
                let ok = m.acceptToken(id); #expect(ok == a.contains(id))
            }
        }
    }
}


@Suite("JSON Schema direct converter (upstream)")
struct JSONSchemaDirectConverterUpstreamTests {
    func accepts(_ schema: String, _ text: String, _ o: JSONSchemaOptions = .xgrammar) throws -> Bool {
        try Upstream.accepts(Grammar(jsonSchema: schema, options: o), text)
    }
    static let basic = #"{"type":"object","properties":{"name":{"type":"string","minLength":2,"maxLength":4},"count":{"type":"integer","minimum":-2,"maximum":8},"choice":{"enum":["a","b",3]},"nullable":{"type":["string","null"]}},"required":["name","count"],"additionalProperties":false}"#
    @Test(arguments: [
        (#"{"name":"ab","count":0}"#, true), (#"{"name": "abcd", "count": -2, "choice": "a", "nullable": null}"#, true),
        (#"{"name":"a","count":0}"#, false), (#"{"count":0,"name":"ab"}"#, false), (#"{"name":"ab","count":9}"#, false),
        (#"{"name":"ab","count":0,"extra":true}"#, false)])
    func basicTypes(_ t: String, _ e: Bool) throws { #expect(try accepts(Self.basic, t) == e) }

    static let defRef = "#/$defs/entry"
    static let arrays = #"{"$defs":{"entry":{"type":"object","properties":{"id":{"type":"integer","multipleOf":3},"code":{"type":"string","pattern":"^[A-Z]{2}[0-9]+$"}},"required":["id","code"],"additionalProperties":false}},"type":"array","prefixItems":[{"const":"header"}],"items":{"$ref":"\#(Self.defRef)"},"minItems":2,"maxItems":3}"#
    @Test(arguments: [
        (#"["header",{"id":3,"code":"AB12"}]"#, true), (#"["header", {"id": 6, "code": "XY9"}, {"id": -3, "code": "AA0"}]"#, true),
        (#"["header"]"#, false), (#"["header",{"id":4,"code":"AB12"}]"#, false), (#"["header",{"id":3,"code":"ab12"}]"#, false)])
    func arraysRefsPatterns(_ t: String, _ e: Bool) throws { #expect(try accepts(Self.arrays, t) == e) }

    static let props = #"{"type":"object","properties":{"fixed":{"type":"boolean"},"optional":{"type":"number"}},"patternProperties":{"^x_[a-z]+$":{"type":"integer"}},"additionalProperties":{"type":"string"},"minProperties":1,"maxProperties":3}"#
    @Test(arguments: [
        (#"{"fixed":true}"#, true), (#"{"x_a":2}"#, true), (#"{"other":"value"}"#, true),
        (#"{"fixed":false,"x_test":3,"other":"value"}"#, true), ("{}", false), (#"{"fixed":true,"x_a":1,"one":"1","two":"2"}"#, false)])
    func propertyConstraints(_ t: String, _ e: Bool) throws { #expect(try accepts(Self.props, t) == e) }

    @Test func formattingAndAnyOrder() throws {
        let s = #"{"type":"object","properties":{"first":{"type":"string"},"second":{"type":"integer"}},"required":["first","second"],"additionalProperties":false}"#
        var o = JSONSchemaOptions(anyWhitespace: false); o.indent = 2; o.strict = true; o.anyOrder = true
        #expect(try accepts(s, "{\n  \"first\": \"x\",\n  \"second\": 1\n}", o))
        #expect(try accepts(s, "{\n  \"second\": 1,\n  \"first\": \"x\"\n}", o))
        #expect(try !accepts(s, #"{"first":"x","second":1}"#, o))
        var b = JSONSchemaOptions(anyWhitespace: true); b.maxWhitespaceCount = 3
        #expect(try accepts(s, #"{"first":"x","second":1}"#, b))
        #expect(try accepts(s, #"{"first": "x", "second": 1}"#, b))
        #expect(try !accepts(s, #"{    "first":"x","second":1}"#, b))
    }
    static let root = "#"
    static let rec = #"{"type":"object","properties":{"value":{"type":"integer"},"next":{"anyOf":[{"$ref":"\#(Self.root)"},{"type":"null"}]}},"required":["value","next"],"additionalProperties":false}"#
    @Test(arguments: [(#"{"value":1,"next":null}"#, true), (#"{"value":1,"next":{"value":2,"next":null}}"#, true),
        (#"{"value":1}"#, false), (#"{"value":1,"next":{"value":"bad","next":null}}"#, false)])
    func recursive(_ t: String, _ e: Bool) throws { #expect(try accepts(Self.rec, t) == e) }
    @Test(arguments: [(#""user@example.com""#, true), (#""first.last+tag@example.co.uk""#, true), (#""not-an-email""#, false), (#""@example.com""#, false)])
    func email(_ t: String, _ e: Bool) throws { #expect(try accepts(#"{"type":"string","format":"email"}"#, t) == e) }
}


@Suite("FSM builder and regex (upstream, named ports)")
struct FSMBuilderNamedPortTests {
    static let invalid: [[UInt8]] = [[0xc0, 0x80], [0xc1, 0xbf], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xc0], [0xc1]]
    static let valid = ["]", "\u{7f}", "\u{80}", "\u{7ff}", "\u{800}", "\u{ffff}", "\u{10000}", "\u{10ffff}"]
    @Test(arguments: [#"[^a]"#, #"[\u0000-\U0010ffff]"#, #"[\x5d-\U0010ffff]"#])
    func utf8Boundaries(_ expr: String) throws {
        let vocab = Self.invalid + Self.valid.map { Array($0.utf8) } + [Array("[EOS]".utf8)]
        let info = try TokenizerInfo(encodedVocab: vocab, stopTokenIDs: [Int32(vocab.count - 1)])
        let c = try GrammarCompiler(tokenizerInfo: info).compile(Grammar(ebnf: "root ::= " + expr))
        var m = GrammarMatcher(c)
        let mask = m.nextTokenBitmask()
        for i in vocab.indices {
            let expected = Self.invalid.count <= i && i < vocab.count - 1
            #expect(mask.allows(Int32(i)) == expected, "\(expr) token \(i)")
            m.reset(); let ok = m.acceptToken(Int32(i)); #expect(ok == expected, "\(expr) accept \(i)")
        }
        for b in Self.invalid { m.reset(); let ok = m.acceptBytes(b); #expect(!ok) }
    }
    @Test func negatedClassesUnicode() throws {
        let g = try Grammar(ebnf: #"root ::= "x" [^0-9] "y" [^a-z]* "z""#)
        for v in ["xéyz", "x你y😀z", "xAy你好éz"] { #expect(try Upstream.accepts(g, v)) }
        for v in ["x1yz", "xéyaz"] { #expect(try !Upstream.accepts(g, v)) }
        let c = try GrammarCompiler(tokenizerInfo: TokenizerInfo(encodedVocab: [String]())).compile(g)
        for b: [UInt8] in [[0x78, 0xc0, 0x80, 0x79, 0x7a], [0x78, 0xc1, 0xbf, 0x79, 0x7a], [0x78, 0xe0, 0x80, 0x80, 0x79, 0x7a], [0x78, 0x41, 0x79, 0xf0, 0x80, 0x80, 0x80, 0x7a], [0x78, 0x41, 0x79, 0xf4, 0x90, 0x80, 0x80, 0x7a]] {
            var m = GrammarMatcher(c, terminateWithoutStopToken: true); let ok = m.acceptBytes(b); #expect(!ok)
        }
    }
    @Test func emptySequence() throws {
        let g = try Grammar(ebnf: #"root ::= """#)
        #expect(try Upstream.accepts(g, "")); #expect(try !Upstream.accepts(g, "a"))
    }
    @Test func nonGreedy() throws {
        #expect(try Grammar.ebnf(fromRegex: "a{1,3}?") == "root ::= \"a\"{1,3}\n")
        #expect(try Grammar.ebnf(fromRegex: "a+?") == "root ::= \"a\"+\n")
        #expect(try Grammar.ebnf(fromRegex: "a*?") == "root ::= \"a\"*\n")
        #expect(try Grammar.ebnf(fromRegex: "a??") == "root ::= \"a\"?\n")
    }
}
