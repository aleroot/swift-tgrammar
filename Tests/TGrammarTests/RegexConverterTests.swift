// Port of xgrammar's tests/python/test_regex_converter.py (minus the HF-tokenizer mask tests).

import Testing

@testable import TGrammar

@Suite("Regex converter")
struct RegexConverterTests {
    private static let emptyTokenizer = try! TokenizerInfo(encodedVocab: [String]())

    private func ebnf(_ regex: String) throws -> String { try Grammar.ebnf(fromRegex: regex) }

    private func accepts(_ grammar: Grammar, _ input: String) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: Self.emptyTokenizer, cacheEnabled: false)
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isTerminated
    }

    private func accepts(_ ebnf: String, _ input: String) throws -> Bool { try accepts(try Grammar(ebnf: ebnf), input) }

    @Test func basic() throws {
        let grammar = try ebnf("123")
        #expect(grammar == "root ::= \"1\" \"2\" \"3\"\n")
        #expect(try accepts(grammar, "123"))
        #expect(try !accepts(grammar, "1234"))
    }

    @Test func unicode() throws {
        let grammar = try ebnf("ww我😁")
        #expect(grammar == "root ::= \"w\" \"w\" \"\\u6211\" \"\\U0001f601\"\n")
        #expect(try accepts(grammar, "ww我😁"))
    }

    @Test(arguments: [
        (#"\^\$\.\*\+\?\\\(\)\[\]\{\}\|\/"#, #"root ::= "^" "$" "." "*" "+" "\?" "\\" "(" ")" "[" "]" "{" "}" "|" "/""# + "\n", "^$.*+?\\()[]{}|/"),
        (#"\"\'\a\f\n\r\t\v\0\e"#, #"root ::= "\"" "\'" "\a" "\f" "\n" "\r" "\t" "\v" "\0" "\e""# + "\n", "\"'\u{07}\u{0C}\n\r\t\u{0B}\u{0}\u{1B}"),
        (#"\u{20BB7}\u0300\x1F\cJ"#, #"root ::= "\U00020bb7" "\u0300" "\x1f" "\n""# + "\n", "\u{20BB7}\u{0300}\u{1F}\n"),
        (#"[\r\n\$\u0010-\u006F\]\--]+"#, #"root ::= [\r\n$\x10-o\]\--]+"# + "\n", "\r\n$\u{20}-"),
    ])
    func escapes(_ regex: String, _ expected: String, _ instance: String) throws {
        let grammar = try ebnf(regex)
        #expect(grammar == expected)
        #expect(try accepts(grammar, instance))
    }

    @Test func escapedCharClass() throws {
        let grammar = try ebnf(#"\w\w\W\d\D\s\S"#)
        #expect(grammar == #"root ::= [a-zA-Z0-9_] [a-zA-Z0-9_] [^a-zA-Z0-9_] [0-9] [^0-9] [\f\n\r\t\v\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff] [^\f\n\r\t\v\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]"# + "\n")
        #expect(try accepts(grammar, "A_ 1b 0"))
    }

    @Test func nonWhitespaceAcceptsBracket() throws {
        let grammar = try ebnf(#"\S"#)
        #expect(try accepts(grammar, "["))
        #expect(try accepts(grammar, "a"))
        #expect(try !accepts(grammar, " "))
    }

    /// `\s` follows the ECMAScript dialect (WhiteSpace plus LineTerminator), not ASCII.
    static let ecmascriptWhitespace: [Character] = [
        "\t", "\n", "\u{0B}", "\u{0C}", "\r", " ", "\u{00A0}", "\u{1680}", "\u{2000}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]
    static let notECMAScriptWhitespace: [Character] = ["\u{00}", "\u{01}", "\u{85}", "\u{200B}", "\u{2060}", "a", "好"]

    /// Upstream `test_whitespace_class_accepts_ecmascript_whitespace` (#977).
    @Test(arguments: ecmascriptWhitespace)
    func whitespaceClassAcceptsECMAScriptWhitespace(_ char: Character) throws {
        #expect(try accepts(ebnf(#"a\sb"#), "a\(char)b"))
        #expect(try accepts(ebnf(#"a[\s]b"#), "a\(char)b"))
        #expect(try !accepts(ebnf(#"a\Sb"#), "a\(char)b"))
        #expect(try !accepts(ebnf(#"a[\S]b"#), "a\(char)b"))
    }

    /// Upstream `test_whitespace_class_rejects_other_characters` (#977).
    @Test(arguments: notECMAScriptWhitespace)
    func whitespaceClassRejectsOtherCharacters(_ char: Character) throws {
        #expect(try !accepts(ebnf(#"a\sb"#), "a\(char)b"))
        #expect(try !accepts(ebnf(#"a[\s]b"#), "a\(char)b"))
        #expect(try accepts(ebnf(#"a\Sb"#), "a\(char)b"))
        #expect(try accepts(ebnf(#"a[\S]b"#), "a\(char)b"))
    }

    @Test func charClass() throws {
        let grammar = try ebnf("[-a-zA-Z+--]+")
        #expect(grammar == "root ::= [-a-zA-Z+--]+\n")
        #expect(try accepts(grammar, "a-+"))
    }

    @Test func boundary() throws {
        let grammar = try ebnf("^abc$")
        #expect(grammar == "root ::= \"a\" \"b\" \"c\"\n")
        #expect(try accepts(grammar, "abc"))
    }

    @Test func disjunction() throws {
        let grammar = try ebnf("abc|de(f|g)")
        #expect(grammar == "root ::= \"a\" \"b\" \"c\" | \"d\" \"e\" ( \"f\" | \"g\" )\n")
        #expect(try accepts(grammar, "deg"))
    }

    @Test func space() throws {
        let grammar = try ebnf(" abc | df | g ")
        #expect(grammar == "root ::= \" \" \"a\" \"b\" \"c\" \" \" | \" \" \"d\" \"f\" \" \" | \" \" \"g\" \" \"\n")
        #expect(try accepts(grammar, " df "))
    }

    @Test func quantifier() throws {
        let grammar = try ebnf("(a|b)?[a-z]+(abc)*")
        #expect(grammar == "root ::= ( \"a\" | \"b\" )? [a-z]+ ( \"a\" \"b\" \"c\" )*\n")
        #expect(try accepts(grammar, "adddabcabc"))
        #expect(try accepts(grammar, "z"))
    }

    @Test(arguments: ["a{1,3}?{1,3}", "a???", "a++", "a+?{1,3}"])
    func consecutiveQuantifiers(_ regex: String) {
        #expect {
            try ebnf(regex)
        } throws: { error in
            "\(error)".contains("Two consecutive repetition modifiers are not allowed.")
        }
    }

    @Test func group() throws {
        let grammar = try ebnf("(a|b)(c|d)")
        #expect(grammar == "root ::= ( \"a\" | \"b\" ) ( \"c\" | \"d\" )\n")
        #expect(try accepts(grammar, "ac"))
    }

    @Test func any() throws {
        let grammar = try ebnf(".+a.+")
        #expect(grammar == #"root ::= [\u0000-\U0010FFFF]+ "a" [\u0000-\U0010FFFF]+"# + "\n")
        #expect(try accepts(grammar, "bbbabb"))
    }

    @Test func ipv4() throws {
        let grammar = try ebnf(#"((25[0-5]|2[0-4]\d|[01]?\d\d?).)((25[0-5]|2[0-4]\d|[01]?\d\d?).)((25[0-5]|2[0-4]\d|[01]?\d\d?).)(25[0-5]|2[0-4]\d|[01]?\d\d?)"#)
        let expected = #"root ::= ( ( "2" "5" [0-5] | "2" [0-4] [0-9] | [01]? [0-9] [0-9]? ) [\u0000-\U0010FFFF] ) ( ( "2" "5" [0-5] | "2" [0-4] [0-9] | [01]? [0-9] [0-9]? ) [\u0000-\U0010FFFF] ) ( ( "2" "5" [0-5] | "2" [0-4] [0-9] | [01]? [0-9] [0-9]? ) [\u0000-\U0010FFFF] ) ( "2" "5" [0-5] | "2" [0-4] [0-9] | [01]? [0-9] [0-9]? )"# + "\n"
        #expect(grammar == expected)
        #expect(try accepts(grammar, "123.45.67.89"))
    }

    @Test(arguments: [
        ("2024-05-19T14:23:45Z", true), ("2019-11-30T08:15:27+05:30", true), ("2030-02-01T22:59:59-07:00", true),
        ("2021-07-04T00:00:00.123456Z", true), ("2022-12-31T23:45:12-03:00", true),
        ("2024-13-15T14:30:00Z", false), ("2023-02-2010:59:59Z", false), ("2021-11-05T24:00:00+05:30", false), ("2022-08-20T12:61:10-03:00", false),
    ])
    func dateTime(_ instance: String, _ accepted: Bool) throws {
        let grammar = try ebnf(#"^\d\d\d\d-(0[1-9]|1[0-2])-([0-2]\d|3[01])T([01]\d|2[0123]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-]([01]\d|2[0123]):[0-5]\d)$"#)
        let expected = #"root ::= [0-9] [0-9] [0-9] [0-9] "-" ( "0" [1-9] | "1" [0-2] ) "-" ( [0-2] [0-9] | "3" [01] ) "T" ( [01] [0-9] | "2" [0123] ) ":" [0-5] [0-9] ":" [0-5] [0-9] ( "." [0-9]+ )? ( "Z" | [+-] ( [01] [0-9] | "2" [0123] ) ":" [0-5] [0-9] )"# + "\n"
        #expect(grammar == expected)
        #expect(try accepts(grammar, instance) == accepted)
    }

    @Test(arguments: [("0024-05-19", true), ("2019-11-30", true), ("2022-12-31", true), ("2024-13-15", false), ("2024-12-32", false)])
    func date(_ instance: String, _ accepted: Bool) throws {
        let grammar = try ebnf(#"^\d\d\d\d-(0[1-9]|1[0-2])-([0-2]\d|3[01])$"#)
        #expect(grammar == #"root ::= [0-9] [0-9] [0-9] [0-9] "-" ( "0" [1-9] | "1" [0-2] ) "-" ( [0-2] [0-9] | "3" [01] )"# + "\n")
        #expect(try accepts(grammar, instance) == accepted)
    }

    @Test(arguments: [
        ("14:23:45Z", true), ("08:15:27+05:30", true), ("22:59:59-07:00", true), ("00:00:00.123456Z", true),
        ("10:59:59ZA", false), ("24:00:00+05:30", false), ("12:15:10-03:60", false),
    ])
    func time(_ instance: String, _ accepted: Bool) throws {
        let grammar = try ebnf(#"^([01]\d|2[0123]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-]([01]\d|2[0123]):[0-5]\d)$"#)
        #expect(grammar == #"root ::= ( [01] [0-9] | "2" [0123] ) ":" [0-5] [0-9] ":" [0-5] [0-9] ( "." [0-9]+ )? ( "Z" | [+-] ( [01] [0-9] | "2" [0123] ) ":" [0-5] [0-9] )"# + "\n")
        #expect(try accepts(grammar, instance) == accepted)
    }

    @Test(arguments: [
        ("simple@example.com", true), ("very.common@example.com", true), ("user_name+123@example.co.uk", true),
        ("\"john.doe\"@example.org", true), ("mail-host@online-shop.biz", true), ("customer/department=shipping@example.com", true),
        ("$A12345@example.non-profit.org", true), ("\"!def!xyz%abc\"@example.com", true), ("support@192.168.1.1", true),
        ("plainaddress", false), ("@missingusername.com", false), ("user@.com.my", false), ("user@com", false), ("user@-example.com", false),
    ])
    func email(_ instance: String, _ accepted: Bool) throws {
        let regex = #"^([\w!#$%&'*+/=?^_`{|}~-]+(\.[\w!#$%&'*+/=?^_`{|}~-]+)*|"([\w!#$%&'*+/=?^_`{|}~\-(),:;<>@[\].]|\\")+")@(([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?)$"#
        #expect(try accepts(try ebnf(regex), instance) == accepted)
    }

    @Test func emptyCharacterClass() {
        #expect { try ebnf("[]") } throws: { "\($0)".contains("Empty character class is not allowed in regex.") }
    }

    @Test func groupModifiers() throws {
        var grammar = try ebnf("(?:abc)")
        #expect(grammar == "root ::= ( \"a\" \"b\" \"c\" )\n")
        #expect(try accepts(grammar, "abc"))
        grammar = try ebnf("(?<name>abc)")
        #expect(grammar == "root ::= ( \"a\" \"b\" \"c\" )\n")
        #expect(try accepts(grammar, "abc"))
        for regex in ["(?=abc)", "(?!abc)", "(?<=abc)", "(?<!abc)", "(?i)abc"] {
            #expect(throws: GrammarError.self) { try ebnf(regex) }
        }
    }

    @Test func unmatchedParentheses() {
        #expect { try ebnf("abc)") } throws: { "\($0)".contains("Unmatched ')'") }
        #expect { try ebnf("abc((a)") } throws: { "\($0)".contains("The parenthesis is not closed.") }
    }

    @Test func emptyParentheses() throws {
        var grammar = try ebnf("()")
        #expect(grammar == "root ::= ( )\n")
        #expect(try accepts(grammar, ""))
        grammar = try ebnf("a()b")
        #expect(grammar == "root ::= \"a\" ( ) \"b\"\n")
        #expect(try accepts(grammar, "ab"))
    }

    @Test func emptyAlternative() throws {
        var grammar = try ebnf("(a|)")
        #expect(grammar == "root ::= ( \"a\" | \"\" )\n")
        #expect(try accepts(grammar, "a"))
        #expect(try accepts(grammar, ""))
        #expect(try !accepts(grammar, "b"))
        grammar = try ebnf("ab(c|)")
        #expect(grammar == "root ::= \"a\" \"b\" ( \"c\" | \"\" )\n")
        #expect(try accepts(grammar, "abc"))
        #expect(try accepts(grammar, "ab"))
        #expect(try !accepts(grammar, "abd"))
    }

    @Test(arguments: [
        ("a|", "root ::= \"a\" | \"\"\n"), ("a||b", "root ::= \"a\" | \"\" | \"b\"\n"),
        ("(|a)", "root ::= ( \"\" | \"a\" )\n"), ("(a|$)", "root ::= ( \"a\" | \"\" )\n"),
    ])
    func emptyAlternativePositions(_ regex: String, _ expected: String) throws {
        #expect(try ebnf(regex) == expected)
    }

    @Test(arguments: ["", "^$", "(())", "()", "^", "$", "()|()"])
    func empty(_ regex: String) throws {
        let grammar = try Grammar(regex: regex)
        #expect(grammar.description == "root ::= (\"\")\n")
        #expect(try accepts(grammar, ""))
        #expect(try !accepts(grammar, "a"))
    }

    @Test(arguments: ["\u{0}", "\u{0}abc", "a\u{0}b", "[0-9]+\u{0}"])
    func nullCharacter(_ regex: String) {
        #expect { try Grammar(regex: regex) } throws: { "\($0)".contains("The regex must not contain null characters.") }
    }

    @Test(arguments: [
        ("(a{2,}){1,2}", ["aa", "aaa", "aaaa", "aaaaaa"], ["", "a"]),
        ("(a{2,}){2}", ["aaaa", "aaaaa"], ["", "a", "aa", "aaa"]),
        ("(a{1,}){1,2}", ["a", "aa", "aaa"], [""]),
        ("(a{2,}){1,2}b", ["aab", "aaab"], ["b", "ab"]),
    ])
    func boundedRepetitionOfUnboundedRepetition(_ regex: String, _ acceptedInputs: [String], _ rejectedInputs: [String]) throws {
        let grammar = try Grammar(regex: regex)
        for input in acceptedInputs { #expect(try accepts(grammar, input), "\(regex) \(input)") }
        for input in rejectedInputs { #expect(try !accepts(grammar, input), "\(regex) \(input)") }
        let ebnfGrammar = try Grammar(ebnf: "root ::= b{1,2}\nb ::= a{2,}\na ::= \"a\"")
        #expect(try accepts(ebnfGrammar, "aa"))
        #expect(try !accepts(ebnfGrammar, "a"))
    }
}
