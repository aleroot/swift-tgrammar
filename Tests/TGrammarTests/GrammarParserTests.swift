// Port of xgrammar's tests/python/test_grammar_parser.py. The printed grammar is compared
// character for character, which pins the parser, the builder, the printer and the
// normalization passes to upstream behaviour.

import Testing

@testable import TGrammar

@Suite("EBNF parser")
struct GrammarParserTests {
    /// Parses without normalization and prints.
    private func raw(_ ebnf: String) throws -> String {
        try GrammarTesting.parseWithoutNormalization(ebnf).description
    }

    /// Parses without normalization, applies the structure normalizer and prints.
    private func normalized(_ ebnf: String) throws -> String {
        GrammarTesting.structureNormalizer(try GrammarTesting.parseWithoutNormalization(ebnf)).description
    }

    /// Full `Grammar(ebnf:)` pipeline, printed.
    private func full(_ ebnf: String) throws -> String {
        try Grammar(ebnf: ebnf).description
    }

    // MARK: Elements

    @Test(arguments: [
        ("root ::= \"hello\"\n", "root ::= ((\"hello\"))\n"),
        ("root ::= \"\"\n", "root ::= ((\"\"))\n"),
        ("root ::= [a-z]\n", "root ::= (([a-z]))\n"),
        ("root ::= [^a-z]\n", "root ::= (([^a-z]))\n"),
        (#"root ::= [a-zA-Z0-9_-] [\r\n$\x10-o\]\--]"# + "\n", #"root ::= (([a-zA-Z0-9_\-] [\r\n$\x10-o\]\-\-]))"# + "\n"),
        ("root ::= \"a\" \"b\" \"c\"\n", "root ::= ((\"a\" \"b\" \"c\"))\n"),
        ("root ::= \"a\" | \"b\" | \"c\"\n", "root ::= ((\"a\") | (\"b\") | (\"c\"))\n"),
        ("root ::= (\"a\" \"b\") | (\"c\" \"d\")\n", "root ::= ((((\"a\" \"b\"))) | (((\"c\" \"d\"))))\n"),
        ("root ::= [a-z]*\n", "root ::= (([a-z]*))\n"),
        ("root ::= \"a\" (=\"b\")\n", "root ::= ((\"a\")) (=((\"b\")))\n"),
        ("root ::= \"a\" (=\"b\" \"c\" [0-9])\n", "root ::= ((\"a\")) (=((\"b\" \"c\" [0-9])))\n"),
        (#"root ::= "\n\t\r\"\\""# + "\n", #"root ::= (("\n\t\r\"\\"))"# + "\n"),
        (#"root ::= "\u0041\u0042\u0043\u00A9\u2603""# + "\n", #"root ::= (("ABC\xa9\u2603"))"# + "\n"),
        (#"root ::= "a\/b""# + "\n", #"root ::= (("a/b"))"# + "\n"),
    ])
    func elements(_ before: String, _ expected: String) throws {
        #expect(try raw(before) == expected)
    }

    // MARK: Quantifiers

    @Test(arguments: [
        ("root ::= \"a\"*\n", "root ::= ((root_1))\nroot_1 ::= (\"\" | (\"a\" root_1))\n"),
        ("root ::= \"a\"+\n", "root ::= ((root_1))\nroot_1 ::= ((\"a\" root_1) | \"a\")\n"),
        ("root ::= \"a\"?\n", "root ::= ((root_1))\nroot_1 ::= (\"\" | \"a\")\n"),
        ("root ::= \"a\"{3}\n", "root ::= ((root_1{3, 3}))\nroot_1 ::= \"a\"\n"),
        ("root ::= \"a\"{2,4}\n", "root ::= ((root_1{2, 4}))\nroot_1 ::= \"a\"\n"),
        ("root ::= \"a\"{2,}\n", "root ::= ((root_1{2, -1}))\nroot_1 ::= \"a\"\n"),
        ("root ::= (\"a\"*)+\n", "root ::= ((root_2))\nroot_1 ::= (\"\" | (\"a\" root_1))\nroot_2 ::= ((((root_1)) root_2) | ((root_1)))\n"),
    ])
    func quantifiers(_ before: String, _ expected: String) throws {
        #expect(try raw(before) == expected)
    }

    @Test func repetitionRangeUnboundedRoundtrip() throws {
        let first = try full("root ::= \"a\"{2,}\n")
        #expect(first.contains("{2, -1}"))
        #expect(try full(first) == first)
    }

    // MARK: Composite grammars

    @Test func complexGrammar() throws {
        let before = """
            root ::= expr
            expr ::= term ("+" term | "-" term)*
            term ::= factor ("*" factor | "/" factor)*
            factor ::= number | "(" expr ")"
            number ::= [0-9]+ ("." [0-9]+)?

            """
        let expected = """
            root ::= ((expr))
            expr ::= ((term expr_1))
            term ::= ((factor term_1))
            factor ::= ((number) | ("(" expr ")"))
            number ::= ((number_1 number_3))
            expr_1 ::= ("" | ((("+" term) | ("-" term)) expr_1))
            term_1 ::= ("" | ((("*" factor) | ("/" factor)) term_1))
            number_1 ::= (([0-9] number_1) | [0-9])
            number_2 ::= (([0-9] number_2) | [0-9])
            number_3 ::= ("" | (("." number_2)))

            """
        #expect(try raw(before) == expected)
    }

    @Test func combinedFeatures() throws {
        let before = """
            root ::= "start" (rule1 | rule2)+ "end"
            rule1 ::= [a-z]{1,3} (=":")
            rule2 ::= [0-9]+ "." [0-9]*

            """
        let expected = """
            root ::= (("start" root_1 "end"))
            rule1 ::= ((rule1_1{1, 3})) (=((":")))
            rule2 ::= ((rule2_1 "." [0-9]*))
            root_1 ::= ((((rule1) | (rule2)) root_1) | ((rule1) | (rule2)))
            rule1_1 ::= [a-z]
            rule2_1 ::= (([0-9] rule2_1) | [0-9])

            """
        #expect(try raw(before) == expected)
    }

    @Test func comments() throws {
        let before = """
            # top comment
            root ::= a b # inline comment
            a ::= "a"
            b ::= "b"
            # bottom comment

            """
        #expect(try raw(before) == "root ::= ((a b))\na ::= ((\"a\"))\nb ::= ((\"b\"))\n")
    }

    // MARK: Structure normalizer

    @Test func starQuantifierNormalized() throws {
        let before = """
            root ::= b c d
            b ::= [b]*
            c ::= "b"*
            d ::= ([b] [c] [d] | ([p] [q]))*
            e ::= [e]* [f]* | [g]*

            """
        let expected = """
            root ::= ((b c d))
            b ::= (([b]*))
            c ::= ((c_1))
            d ::= ((d_1))
            e ::= (([e]* [f]*) | ([g]*))
            c_1 ::= ("" | ("b" c_1))
            d_1 ::= ("" | (d_1_1 d_1))
            d_1_1 ::= (("b" "c" "d") | ("p" "q"))

            """
        #expect(try normalized(before) == expected)

        let nullable = """
            root ::= [a]* [b]* rule1
            rule1 ::= [abc]* [def]*

            """
        #expect(try normalized(nullable) == "root ::= (([a]* [b]* rule1))\nrule1 ::= (([abc]* [def]*))\n")
    }

    @Test func repetitionRangeNormalized() throws {
        let before = """
            root ::= a b c d e f g
            a ::= [a]{1,2}
            b ::= (a | "b"){1, 5}
            c ::= "c" {0 , 2}
            d ::= "d" {0,}
            e ::= "e" {2, }
            f ::= "f" {3}
            g ::= "g" {0}

            """
        let expected = """
            root ::= ((a b c d e f g))
            a ::= ((a_1{1, 2}))
            b ::= ((b_1{1, 5}))
            c ::= ((c_1{0, 2}))
            d ::= ((d_1{0, -1}))
            e ::= ((e_1{2, -1}))
            f ::= ((f_1{3, 3}))
            g ::= ((g_1{0, 0}))
            a_1 ::= (("a"))
            b_1 ::= ((a) | ("b"))
            c_1 ::= (("c"))
            d_1 ::= (("d"))
            e_1 ::= (("e"))
            f_1 ::= (("f"))
            g_1 ::= (("g"))

            """
        #expect(try normalized(before) == expected)
    }

    @Test func lookaheadAssertionNormalized() throws {
        let before = """
            root ::= ((b c d))
            b ::= (("abc" [a-z])) (=("abc"))
            c ::= (("a") | ("b")) (=[a-z] "b")
            d ::= (("ac") | ("b" d_choice)) (="abc")
            d_choice ::= (("e") | ("d"))

            """
        let expected = """
            root ::= ((b c d))
            b ::= (("abc" [a-z])) (=("abc"))
            c ::= (("a") | ("b")) (=([a-z] "b"))
            d ::= (("ac") | ("b" d_choice)) (=("abc"))
            d_choice ::= (("e") | ("d"))

            """
        #expect(try normalized(before) == expected)
    }

    @Test func characters() throws {
        let before = #"""
            root ::= [a-z] [A-z] "\u0234" "\U00000345\xff" [-A-Z] [--] [^a] rest
            rest ::= [a-zA-Z0-9-] [\u0234-\U00000345] [测-试] [\--\]]  rest1
            rest1 ::= "\?\"\'测试あc" "👀" "" [a-a] [b-b]

            """#
        let expected = #"""
            root ::= (([a-z] [A-z] "\u0234" "\u0345\xff" [\-A-Z] [\-\-] [^a] rest))
            rest ::= (([a-zA-Z0-9\-] [\u0234-\u0345] [\u6d4b-\u8bd5] [\--\]] rest1))
            rest1 ::= (("\?\"\'\u6d4b\u8bd5\u3042c" "\U0001f440" "a" "b"))

            """#
        #expect(try normalized(before) == expected)
    }

    @Test func whitespaceInsensitive() throws {
        let before = """


            root::="a"  "b" ("c""d"
            "e") |

            "f" | "g"

            """
        #expect(try full(before) == "root ::= ((\"a\" \"b\" \"c\" \"d\" \"e\") | (\"f\") | (\"g\"))\n")
    }

    @Test func nesting() throws {
        let before = "root::= \"a\" (\"b\" | \"c\" \"d\") | ((\"e\" \"f\"))\n"
        #expect(try full(before) == "root ::= ((\"a\" root_1) | (\"e\" \"f\"))\nroot_1 ::= ((\"b\") | (\"c\" \"d\"))\n")
    }

    @Test func emptyParentheses() throws {
        #expect(try full("root ::= \"a\" ( ) \"b\"\n") == "root ::= ((\"a\" \"b\"))\n")
        #expect(try full("root ::= \"a\" rule1\nrule1 ::= ( )\n") == "root ::= ((\"a\" rule1))\nrule1 ::= (\"\")\n")
    }

    @Test func flatten() throws {
        let before = """
            root ::= or_test sequence_test nested_test empty_test
            or_test ::= ([a] | "b") | "de" | "" | or_test | [^a-z]
            sequence_test ::= [a] "a" ("b" ("c" | "d")) ("d" "e") sequence_test ""
            nested_test ::= ("a" ("b" ("c" "d"))) | ("a" | ("b" | "c")) | nested_rest
            nested_rest ::= ("a" | ("b" "c" | ("d" | "e" "f"))) | ((("g")))
            empty_test ::= "d" | (("" | "" "") "" | "a" "") | ("" ("" | "")) "" ""

            """
        let expected = """
            root ::= ((or_test sequence_test nested_test empty_test))
            or_test ::= ("" | ("a") | ("b") | ("de") | (or_test) | ([^a-z]))
            sequence_test ::= (("a" "a" "b" sequence_test_1 "d" "e" sequence_test))
            nested_test ::= (("a" "b" "c" "d") | ("a") | ("b") | ("c") | (nested_rest))
            nested_rest ::= (("a") | ("b" "c") | ("d") | ("e" "f") | ("g"))
            empty_test ::= ("" | ("d") | ("a"))
            sequence_test_1 ::= (("c") | ("d"))

            """
        #expect(try normalized(before) == expected)
    }

    @Test func toStringRoundtrip() throws {
        let before = """
            root ::= ((b c) | (b root))
            b ::= ((b_1 d))
            c ::= ((c_1))
            d ::= ((d_1))
            b_1 ::= ("" | ("b" b_1)) (=(d))
            c_1 ::= (([acep-z] c_1) | ([acep-z])) (=("d"))
            d_1 ::= ("" | ("d"))

            """
        let first = try full(before)
        #expect(first == before)
        #expect(try full(first) == first)
    }

    @Test func rootRuleRenamed() throws {
        let grammar = try Grammar(ebnf: "start ::= root\nroot ::= \"a\"\n", rootRule: "start")
        #expect(grammar.rootRule.name == "root")
        #expect(grammar.description == "root ::= ((root_0))\nroot_0 ::= ((\"a\"))\n")
    }

    // MARK: Rule attributes and macros

    @Test func ruleAttributesRoundtrip() throws {
        let before = "root[max_tokens=3, temperature=0.5] ::= \"a\"*\n"
        let printed = try full(before)
        #expect(printed.hasPrefix("root[max_tokens=3, temperature=0.5] ::= "))
        #expect(try full(printed) == printed)

        let capture = "root ::= item (\",\" item)*\nitem[capture] ::= [0-9]+\n"
        let printedCapture = try full(capture)
        #expect(printedCapture.contains("item[capture=\"item\"] ::= "))
        #expect(try Grammar(ebnf: "name[lazy] ::= [a-z]+\nroot ::= name\n").rule(0).isLazy)
    }

    @Test func tagDispatchMacro() throws {
        let before = """
            root ::= TagDispatch(("<tool_call>", tool_call), ("<code>", code), loop_after_dispatch=false, excludes=("</answer>",))
            tool_call ::= "{" [^}]* "}"
            code ::= "```" [^`]* "```"

            """
        let expected = """
            root ::= TagDispatch(
              ("<tool_call>", tool_call),
              ("<code>", code),
              loop_after_dispatch=false,
              excludes=("</answer>")
            )
            tool_call ::= (("{" [^}]* "}"))
            code ::= (("```" [^`]* "```"))

            """
        let printed = try full(before)
        #expect(printed == expected)
        #expect(try full(printed) == printed)
    }

    @Test func tokenMacros() throws {
        let before = """
            root ::= Token(3, 1, 3) ExcludeToken(5) rest
            rest ::= TokenTagDispatch((7, body), excludes=(9,))
            body ::= "x"

            """
        let expected = """
            root ::= ((Token(1, 3) ExcludeToken(5) rest))
            rest ::= ((rest_1))
            body ::= (("x"))
            rest_1 ::= TokenTagDispatch(
              (7, body),
              loop_after_dispatch=true,
              excludes=(9)
            )

            """
        #expect(try full(before) == expected)
    }

    @Test func regexAndSubstringMacros() throws {
        let before = #"""
            root ::= "ID-" Regex("[0-9]{5}") Regex("\\S+", json_string=true) Substring("abc", "de")

            """#
        let expected = #"""
            root ::= (("ID-" root_1 root_2 root_3))
            root_1 ::= Regex("[0-9]{5}")
            root_2 ::= Regex("\\S+", json_string=true)
            root_3 ::= Substring("abc", "de")

            """#
        #expect(try full(before) == expected)
        #expect(try full("root ::= Regex(\"a.b\", flags=\"i\")\n") == #"root ::= Regex("(\?i)a[^\\n]b")"# + "\n")
    }

    // MARK: Errors

    @Test(arguments: [
        (#"root ::= "a" ""#, "EBNF lexer error at line 1, column 15: Expect \" in string literal"),
        ("root ::= [a\n]", "EBNF lexer error at line 1, column 12: Character class should not contain newline"),
        (#"root ::= "\@""#, "EBNF lexer error at line 1, column 11: Invalid escape sequence"),
        (#"root ::= "\uFF""#, "EBNF lexer error at line 1, column 11: Invalid escape sequence"),
        (#"::= "a""#, "EBNF lexer error at line 1, column 1: Assign should not be the first token"),
        ("root ::= a b", "EBNF parser error at line 1, column 10: Rule \"a\" is not defined"),
        (#"root ::= "a" |"#, "EBNF parser error at line 1, column 15: Expect element, but got "),
        ("root ::= [Z-A]", "EBNF parser error at line 1, column 11: Invalid character class: lower bound is larger than upper bound"),
        ("root ::= \"a\"\nroot ::= \"b\"", "EBNF parser error at line 2, column 1: Rule \"root\" is defined multiple times"),
        (#"a ::= "a""#, "EBNF parser error at line 1, column 1: The root rule with name \"root\" is not found"),
        (#"root ::= "a" (="a") (="b")"#, "EBNF parser error at line 1, column 21: Expect rule name"),
        ("root ::= \"a\"{1,3}{1,3}\n", "EBNF parser error at line 1, column 18: Expect element, but got {"),
        ("root ::= \"a\"++\n", "EBNF parser error at line 1, column 14: Expect element, but got +"),
        ("root ::= \"a\"??\n", "EBNF parser error at line 1, column 14: Expect element, but got ?"),
        ("root[temperature=-0.1] ::= \"a\"", "The temperature must be a finite non-negative number"),
        ("root[temperature=1e999] ::= \"a\"", "The temperature must be a finite non-negative number"),
        ("root[temperature=abc] ::= \"a\"", "Assign should be preceded by an identifier"),
        ("root ::= TagDispatch((\"<a>\", missing))", "Rule \"missing\" is not defined"),
        ("root ::= TagDispatch((\"<a>\", root), excludes=(\"<\",))", "Exclude string must not be a prefix of trigger string: <"),
        ("root ::= Token()", "Token() requires at least one integer argument"),
        ("root ::= [\\d]", "Character class escape is not supported yet in EBNF"),
        // Upstream raises from the normalizer; these used to trap in Swift.
        (#"root ::= "a" (= ("b" | "c"))"#, "EBNF parser error at line 1, column 14: Choices in lookahead assertion are not supported yet"),
        (#"root ::= "a" (= "")"#, "EBNF parser error at line 1, column 14: Empty string should not be in lookahead assertion"),
        (#"root ::= "a" (= (Regex("[a-z]")))"#, "EBNF parser error at line 1, column 14: Regex should not be in lookahead assertion"),
    ])
    func lexerAndParserErrors(_ ebnf: String, _ expected: String) {
        #expect(throws: GrammarError.self) {
            try GrammarTesting.parseWithoutNormalization(ebnf)
        }
        do {
            _ = try GrammarTesting.parseWithoutNormalization(ebnf)
            Issue.record("expected an error for \(ebnf)")
        } catch {
            #expect(error.description.contains(expected), "got: \(error.description)")
        }
    }
}
