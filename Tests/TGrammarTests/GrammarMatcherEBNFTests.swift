// Port of xgrammar's tests/python/test_grammar_matcher_ebnf.py (the parts that do not need a
// gated Hugging Face tokenizer): string acceptance over unoptimized, hand-written EBNF.

import Testing

@testable import TGrammar

@Suite("Grammar matcher (EBNF)")
struct GrammarMatcherEBNFTests {
    private static let emptyTokenizer = try! TokenizerInfo(encodedVocab: [String]())

    /// `_is_grammar_accept_string`: whether the whole string is accepted and the grammar is complete.
    private func accepts(_ grammar: Grammar, _ input: String) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: Self.emptyTokenizer, cacheEnabled: false)
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isTerminated
    }

    private func accepts(_ ebnf: String, _ input: String) throws -> Bool {
        try accepts(try Grammar(ebnf: ebnf), input)
    }

    private func hasRepeatEdges(_ grammar: Grammar) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: Self.emptyTokenizer, cacheEnabled: false)
        return GrammarTesting.printGrammarFSMs(try compiler.compile(grammar).grammar).contains("Repeat(")
    }

    static let jsonEBNF = #"""
    root ::= basic_array | basic_object
    basic_any ::= basic_number | basic_string | basic_boolean | basic_null | basic_array | basic_object
    basic_integer ::= ("0" | "-"? [1-9] [0-9]*) ".0"?
    basic_number ::= ("0" | "-"? [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?
    basic_string ::= (([\"] basic_string_1 [\"]))
    basic_string_1 ::= "" | [^"\\\x00-\x1F] basic_string_1 | "\\" escape basic_string_1
    escape ::= ["\\/bfnrt] | "u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]
    basic_boolean ::= "true" | "false"
    basic_null ::= "null"
    basic_array ::= "[" ("" | ws basic_any (ws "," ws basic_any)*) ws "]"
    basic_object ::= "{" ("" | ws basic_string ws ":" ws basic_any ( ws "," ws basic_string ws ":" ws basic_any)*) ws "}"
    ws ::= [ \n\t]*

    """#

    @Test func simple() throws {
        let grammar = try Grammar(ebnf: "root ::= rule1 rule2\nrule1 ::= (rule2 | rule3) \"a\"\nrule2 ::= \"b\"\nrule3 ::= \"c\"\n")
        #expect(try accepts(grammar, "bab"))
        #expect(try !accepts(grammar, "abb"))
        #expect(try accepts(grammar, "cab"))
    }

    @Test(arguments: [("aaa", true), ("abcbc", true), ("bcbcbcbcbc", true), ("bcbcbcbcbcbcbcb", true), ("d", false), ("aaaa", false)])
    func repetition(_ input: String, _ expected: Bool) throws {
        #expect(try accepts("root ::= rule {2, 3}\nrule ::= (\"a\" | [bc] {4,})\n", input) == expected)
    }

    @Test(arguments: [("aaa", true), ("abcbc", true), ("bcbcbcbcbc", true), ("bcbcbcbcbcbcbcb", true), ("aaaa", false), ("", true), ("a", true), ("d", true)])
    func repetitionWithEmpty(_ input: String, _ expected: Bool) throws {
        #expect(try accepts("root ::= rule {2, 3} \"d\"?\nrule ::= (\"a\" | [bc] {4,}) | \"\"\n", input) == expected)
    }

    @Test func utf8() throws {
        for input in ["，", "，，，", String(repeating: "，", count: 22)] {
            #expect(try accepts("root ::= [，]+", input))
        }
    }

    @Test func customRootRule() throws {
        let ebnf = #"""
        root ::= basic_object
        basic_any ::= basic_string | basic_object
        basic_string ::= (([\"] basic_string_1 [\"]))
        basic_string_1 ::= "" | [^"\\\r\n] basic_string_1 | "\\" escape basic_string_1
        escape ::= ["\\/bfnrt] | "u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]
        basic_object ::= "{" ("" | ws basic_string ws ":" ws basic_any ( ws "," ws basic_string ws ":" ws basic_any)*) ws "}"
        ws ::= [ \n\t]*

        """#
        let grammar = try Grammar(ebnf: ebnf, rootRule: "basic_string")
        #expect(try accepts(grammar, #""abc\r\n""#))
        #expect(try !accepts(grammar, #"{"name": "John" }"#))
    }

    @Test(arguments: [
        #"{"name": "John"}"#,
        #"{ "name" : "John" }"#,
        "{}",
        "[]",
        #"{"name": "Alice", "age": 30, "city": "New York"}"#,
        #"{"name": "Mike", "hobbies": ["reading", "cycling", "hiking"]}"#,
        #"{"name": "Emma", "address": {"street": "Maple Street", "city": "Boston"}}"#,
        #"[{"name": "David"}, {"name": "Sophia"}]"#,
        #"{"name": "William", "age": null, "married": true, "children": ["Liam", "Olivia"], "hasPets": false}"#,
        #"{"name": "Olivia", "contact": {"email": "olivia@example.com", "address": {"city": "Chicago", "zipcode": "60601"}}}"#,
        #"{"name": "Liam", "skills": ["Java", "Python"], "experience": [{"company": "CompanyA", "years": 5}, {"company": "CompanyB", "years": 3}]}"#,
        #"{"person": {"name": "Ethan", "age": 40}, "education": {"degree": "Masters", "university": "XYZ University"}, "work": [{"company": "ABC Corp", "position": "Manager"}, {"company": "DEF Corp", "position": "Senior Manager"}]}"#,
        #"{"name": "Charlotte", "details": {"personal": {"age": 35, "hobbies": ["gardening", "painting"]}, "professional": {"occupation": "Engineer", "skills": ["CAD", "Project Management"], "projects": [{"name": "Project A", "status": "Completed"}, {"name": "Project B", "status": "In Progress"}]}}}"#,
    ])
    func jsonAccept(_ input: String) throws {
        #expect(try accepts(Self.jsonEBNF, input))
    }

    @Test(arguments: [
        #"{ name: "John" }"#,
        #"{ "name": "John" } "#,
        #"{ "name": "John", "age": 30, }"#,
        #"{ "name": "John", "address": { "street": "123 Main St", "city": "New York" }"#,
        #"{ "name": "John", "age": 30, "hobbies": ["reading", "traveling",], }"#,
        #"{ "name": "John", "age": 30.5.7 }"#,
        #"{ "name": "John, "age": 30, "hobbies": ["reading", "traveling"] }"#,
        #"{ "name": "John", "age": 30, "hobbies": ["reading", { "type": "outdoor", "list": ["hiking", "swimming",]}] }"#,
        #"{ "name": "John", "age": 30, "status": "\P\J" }"#,
        #"{ "name": "John", "age": 30, "hobbies": ["reading", "traveling"], "address": { "street": "123 Main St", "city": "New York", "coordinates": { "latitude": 40.7128, "longitude": -74.0060 }}}, "work": { "company": "Acme", "position": "developer" }}"#,
    ])
    func jsonRefuse(_ input: String) throws {
        #expect(try !accepts(Self.jsonEBNF, input))
    }

    @Test func jsonPressure() throws {
        let longString = "[\"" + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 20) + "\"]"
        #expect(try accepts(Self.jsonEBNF, longString))
        var nested = ""
        for _ in 0 ..< 60 { nested += "[" }
        for _ in 0 ..< 60 { nested += "]" }
        #expect(try accepts(Self.jsonEBNF, nested))
        let document = #"""
        {"web-app": {"servlet": [{"servlet-name": "cofaxCDS", "servlet-class": "org.cofax.cds.CDSServlet", "init-param": {"configGlossary:installationAt": "Philadelphia, PA", "cachePackageTagsTrack": 200, "useDataStore": true, "dataStoreTestQuery": "SET NOCOUNT ON;select test='test';", "maxUrlLength": 500}}, {"servlet-name": "cofaxEmail", "init-param": {"mailHost": "mail1", "mailHostOverride": "mail2"}}], "servlet-mapping": {"cofaxCDS": "/", "cofaxEmail": "/cofaxutil/aemail/*"}, "taglib": {"taglib-uri": "cofax.tld", "taglib-location": "/WEB-INF/tlds/cofax.tld"}}}
        """#
        #expect(try accepts(Self.jsonEBNF, document))
    }

    @Test func nullableGrammar() throws {
        let ebnf = "root ::= rule1 | (rule1 rule1 rule1 rule3)+\nrule1 ::= rule2\nrule2 ::= [0-9]*\nrule3 ::= [a-z]\n"
        for input in ["abc12312398014a", ""] { #expect(try accepts(ebnf, input)) }
    }

    @Test func predictComplete() throws {
        let mixed = """
            root ::= rule1 [0-9]?
            rule1 ::= rule2 [0-9]? | rule4 [0-9]?
            rule2 ::= rule3 [0-9]? | rule2 [0-9]? | rule1 [0-9]?
            rule3 ::= rule4 [0-9]? | rule5 [0-9]?
            rule4 ::= rule5 [0-9]? | rule6 [0-9]?
            rule5 ::= rule6 [0-9]? | rule7 [0-9]? | rule8 [0-9]?
            rule6 ::= rule7 [0-9]? | rule1 [0-9]?
            rule7 ::= rule8 [0-9]? | rule9 [0-9]?
            rule8 ::= rule9 [0-9]? | rule7 [0-9]?
            rule9 ::= [0-9]?

            """
        let grammar = try Grammar(ebnf: mixed)
        var input = ""
        for _ in 0 ..< 10 {
            #expect(try accepts(grammar, input))
            input += "0"
        }
        #expect(try accepts(grammar, input))

        let rightRecursion = "root ::= [a-z] root | [a-z]"
        for input in ["a", "ab", "abc", "abcd", "abcde"] { #expect(try accepts(rightRecursion, input)) }
        for input in ["", "1", "a1", "ab1", "abc1"] { #expect(try !accepts(rightRecursion, input)) }

        let braces = "root ::= rule1\nrule1 ::= \"{\" rule2 | \"\"\nrule2 ::= root \"}\"\n"
        for input in ["", "{}", "{{}}", "{{{}}}", "{{{{}}}}", "{{{{{}}}}}"] { #expect(try accepts(braces, input)) }
        for input in ["{", "{}{}", "{{{{}", "{{}}}", "{{{{{}}}}}}"] { #expect(try !accepts(braces, input)) }
    }

    @Test func advance() throws {
        let grammar = try Grammar(ebnf: "root ::= rule1\nrule1 ::= [a] | [a-b] | [a-c]* | \"a\" | \"aaaaaaaaaaaaaaaaaaa\"\n")
        for count in 0 ..< 10 { #expect(try accepts(grammar, String(repeating: "a", count: count))) }
    }

    @Test func characterClassStarUTF8() throws {
        #expect(try accepts("root ::= [^0-9]*", "worldせかい世界"))
    }

    @Test func cyrillic() throws {
        let lower = try Grammar(ebnf: "root ::= [а-я]+")
        for input in ["а", "я", "п", "привет", "абвгд"] { #expect(try accepts(lower, input)) }
        for input in ["hello", "123", ""] { #expect(try !accepts(lower, input)) }
        let upper = try Grammar(ebnf: "root ::= [А-Я]+")
        for input in ["А", "Я", "ПРИВЕТ"] { #expect(try accepts(upper, input)) }
        #expect(try !accepts(upper, "привет"))
        let mixed = try Grammar(ebnf: "root ::= [а-яА-ЯёЁ]+")
        for input in ["Привет", "ёлка", "ЁЖИК"] { #expect(try accepts(mixed, input)) }
    }

    @Test func cjk() throws {
        let grammar = try Grammar(ebnf: "root ::= [一-龥]+")
        for input in ["一", "中", "龥", "你好", "世界", "中文测试"] { #expect(try accepts(grammar, input)) }
        for input in ["hello", "привет", ""] { #expect(try !accepts(grammar, input)) }
        let hiragana = try Grammar(ebnf: "root ::= [あ-ん]+")
        for input in ["あ", "ん", "こんにちは"] { #expect(try accepts(hiragana, input)) }
        #expect(try !accepts(hiragana, "漢字"))
    }

    @Test func emoji() throws {
        let grammar = try Grammar(ebnf: "root ::= [😀-😿]+")
        for input in ["😀", "😃", "😿", "😀😃😄"] { #expect(try accepts(grammar, input)) }
        for input in ["hello", "🌍", ""] { #expect(try !accepts(grammar, input)) }
    }

    @Test func mixedRanges() throws {
        let grammar = try Grammar(ebnf: "root ::= [a-zа-я一-龥]+")
        for input in ["hello", "привет", "你好", "helloпривет你好"] { #expect(try accepts(grammar, input)) }
        for input in ["HELLO", "123"] { #expect(try !accepts(grammar, input)) }
    }

    @Test func singleUTF8Char() throws {
        let cyrillic = try Grammar(ebnf: "root ::= [а]+")
        #expect(try accepts(cyrillic, "а"))
        #expect(try accepts(cyrillic, "ааа"))
        #expect(try !accepts(cyrillic, "б"))
        #expect(try !accepts(cyrillic, "a"))
        let cjk = try Grammar(ebnf: "root ::= [中]+")
        #expect(try accepts(cjk, "中"))
        #expect(try accepts(cjk, "中中中"))
        #expect(try !accepts(cjk, "国"))
    }

    @Test func nfa() throws {
        let grammar = try Grammar(ebnf: "root ::= rule1 | rule2 | rule3\nrule1 ::= \"abc\" | \"\"\nrule2 ::= \"abd\" | \"\"\nrule3 ::= [a-n] [b-c] \"x\" | \"\"\n")
        for input in ["abc", "abx", "ccx"] { #expect(try accepts(grammar, input)) }
        for input in ["abb", "ad"] { #expect(try !accepts(grammar, input)) }
    }

    @Test func utf8ClassWithQuantifier() throws {
        let grammar = try Grammar(ebnf: "root ::= [a-zа-я一-龥]{0,2048}")
        for input in ["", "hello", "привет", "你好世界", "helloпривет你好", "abc中文def",
                      String(repeating: "a", count: 100), String(repeating: "я", count: 100), String(repeating: "中", count: 100)] {
            #expect(try accepts(grammar, input))
        }
        for input in ["HELLO", "123", "hello!"] { #expect(try !accepts(grammar, input)) }
    }

    // MARK: Counted repetitions (repeat edges)

    @Test func repeatRefExact() throws {
        let grammar = try Grammar(ebnf: "root ::= \"a\"{200}")
        #expect(try hasRepeatEdges(grammar))
        #expect(try accepts(grammar, String(repeating: "a", count: 200)))
        #expect(try !accepts(grammar, String(repeating: "a", count: 199)))
        #expect(try !accepts(grammar, String(repeating: "a", count: 201)))
        #expect(try !accepts(grammar, ""))
    }

    @Test func repeatRefUnbounded() throws {
        let grammar = try Grammar(ebnf: "root ::= \"a\"{200,}")
        #expect(try hasRepeatEdges(grammar))
        for count in [200, 300, 1000] { #expect(try accepts(grammar, String(repeating: "a", count: count))) }
        #expect(try !accepts(grammar, String(repeating: "a", count: 199)))
        #expect(try !accepts(grammar, ""))
    }

    @Test func repeatRefRange() throws {
        let grammar = try Grammar(ebnf: "root ::= \"a\"{100,200}")
        #expect(try hasRepeatEdges(grammar))
        for count in [100, 150, 200] { #expect(try accepts(grammar, String(repeating: "a", count: count))) }
        for count in [99, 201] { #expect(try !accepts(grammar, String(repeating: "a", count: count))) }
    }

    @Test func repeatRefBoundary() throws {
        let g128 = try Grammar(ebnf: "root ::= \"a\"{128}")
        #expect(try !hasRepeatEdges(g128))
        #expect(try accepts(g128, String(repeating: "a", count: 128)))
        #expect(try !accepts(g128, String(repeating: "a", count: 127)))
        #expect(try !accepts(g128, String(repeating: "a", count: 129)))
        let g129 = try Grammar(ebnf: "root ::= \"a\"{129}")
        #expect(try hasRepeatEdges(g129))
        #expect(try accepts(g129, String(repeating: "a", count: 129)))
        #expect(try !accepts(g129, String(repeating: "a", count: 128)))
        #expect(try !accepts(g129, String(repeating: "a", count: 130)))
    }

    @Test func repeatRefMultiCharRule() throws {
        let grammar = try Grammar(ebnf: "root ::= item{200}\nitem ::= \"ab\"\n")
        #expect(try hasRepeatEdges(grammar))
        #expect(try accepts(grammar, String(repeating: "ab", count: 200)))
        #expect(try !accepts(grammar, String(repeating: "ab", count: 199)))
        #expect(try !accepts(grammar, String(repeating: "ab", count: 201)))
        #expect(try !accepts(grammar, String(repeating: "a", count: 400)))
    }

    @Test func repeatRefRangeFromZero() throws {
        let grammar = try Grammar(ebnf: "root ::= \"a\"{0,200}")
        #expect(try hasRepeatEdges(grammar))
        for count in [0, 1, 128, 200] { #expect(try accepts(grammar, String(repeating: "a", count: count))) }
        #expect(try !accepts(grammar, String(repeating: "a", count: 201)))
    }

    @Test func repeatRefNestedInner() throws {
        let grammar = try Grammar(ebnf: "root ::= item{200}\nitem ::= \"a\" | \"b\"\n")
        #expect(try hasRepeatEdges(grammar))
        for input in [String(repeating: "a", count: 200), String(repeating: "b", count: 200), String(repeating: "ab", count: 100),
                      String(repeating: "a", count: 100) + String(repeating: "b", count: 100)] {
            #expect(try accepts(grammar, input))
        }
        for input in [String(repeating: "a", count: 199), String(repeating: "a", count: 201), String(repeating: "c", count: 200)] {
            #expect(try !accepts(grammar, input))
        }
    }

    @Test func repeatRefNestedOuter() throws {
        let grammar = try Grammar(ebnf: "root ::= \"start-\" body \"-end\"\nbody ::= [a-z]{200}\n")
        #expect(try hasRepeatEdges(grammar))
        #expect(try accepts(grammar, "start-" + String(repeating: "a", count: 200) + "-end"))
        #expect(try accepts(grammar, "start-" + String(repeating: "xyz", count: 66) + "xy-end"))
        #expect(try !accepts(grammar, "start-" + String(repeating: "a", count: 199) + "-end"))
        #expect(try !accepts(grammar, "start-" + String(repeating: "a", count: 201) + "-end"))
        #expect(try !accepts(grammar, String(repeating: "a", count: 200)))
    }

    @Test func repeatRefSequenceWithRepeat() throws {
        let grammar = try Grammar(ebnf: "root ::= prefix middle suffix\nprefix ::= \"x\"{129}\nmiddle ::= [0-9]{200}\nsuffix ::= \"y\"{129}\n")
        #expect(try hasRepeatEdges(grammar))
        let x129 = String(repeating: "x", count: 129), y129 = String(repeating: "y", count: 129)
        #expect(try accepts(grammar, x129 + String(repeating: "0", count: 200) + y129))
        #expect(try accepts(grammar, x129 + String(repeating: "1234567890", count: 20) + y129))
        #expect(try !accepts(grammar, String(repeating: "x", count: 128) + String(repeating: "0", count: 200) + y129))
        #expect(try !accepts(grammar, x129 + String(repeating: "0", count: 199) + y129))
        #expect(try !accepts(grammar, x129 + String(repeating: "0", count: 200) + String(repeating: "y", count: 128)))
    }

    @Test func repeatRefComplexNested() throws {
        let grammar = try Grammar(ebnf: "root ::= \"[\" row{150} \"]\"\nrow ::= \"(\" cell{130} \")\" sep\ncell ::= [a-c]\nsep ::= \",\" | \"\"\n")
        #expect(try hasRepeatEdges(grammar))
        let row = "(" + String(repeating: "a", count: 130) + ")"
        #expect(try accepts(grammar, "[" + String(repeating: row + ",", count: 149) + row + "]"))
        let mixedRow = "(" + String(repeating: "abc", count: 43) + "a)"
        #expect(try accepts(grammar, "[" + String(repeating: mixedRow + ",", count: 149) + mixedRow + "]"))
        let shortRow = "(" + String(repeating: "a", count: 129) + ")"
        #expect(try !accepts(grammar, "[" + String(repeating: shortRow + ",", count: 149) + shortRow + "]"))
        #expect(try !accepts(grammar, "[" + String(repeating: row + ",", count: 148) + row + "]"))
    }

    @Test(arguments: [
        ("root ::= (\"a\" | \"bc\")? \"z\"", ["z", "az", "bcz"], ["", "a", "bc", "bz", "abcz"]),
        ("root ::= (\"a\" | \"bc\")*", ["", "a", "bc", "abc", "bca", "bcbca"], ["b", "c", "ac", "ab"]),
        ("root ::= (\"a\" | \"bc\")+", ["a", "bc", "abc", "bca", "bcbc"], ["", "b", "c", "ac"]),
        ("root ::= [^a-cx-z]+", ["d", "w", "dw"], ["a", "x", "da", "wy"]),
        ("root ::= (\"ab\" | \"ac\" | \"db\" | \"dc\") (\"x\" | \"yz\")", ["abx", "abyz", "acx", "dbyz", "dcx"], ["ab", "x", "adx", "dcy", "abxyz"]),
    ])
    func sparseEndStateFSMOperations(_ ebnf: String, _ acceptedInputs: [String], _ rejectedInputs: [String]) throws {
        let grammar = try Grammar(ebnf: ebnf)
        for input in acceptedInputs { #expect(try accepts(grammar, input), "\(input)") }
        for input in rejectedInputs { #expect(try !accepts(grammar, input), "\(input)") }
    }

    @Test func characterClassStarFollowedBySameClass() throws {
        let grammar = try Grammar(ebnf: "root ::= [a-z]* [a-z] \"c\" \"d\"")
        #expect(try !accepts(grammar, "cd"))
        #expect(try !accepts(grammar, "d"))
        #expect(try accepts(grammar, "acd"))
        #expect(try accepts(grammar, "xyzcd"))
    }
}
