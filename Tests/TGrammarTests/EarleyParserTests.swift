// Direct checks of the Earley parser on optimized grammars: byte-level acceptance, rollback
// and completion, independent of the token layer.

import Testing

@testable import TGrammar

@Suite("Earley parser")
struct EarleyParserTests {
    private func parser(_ ebnf: String) throws -> EarleyParser {
        EarleyParser(grammar: try GrammarTesting.optimize(try Grammar(ebnf: ebnf)))
    }

    private func accepts(_ ebnf: String, _ input: String) throws -> Bool {
        var parser = try parser(ebnf)
        for byte in input.utf8 where !parser.advance(byte) { return false }
        return parser.isCompleted
    }

    @Test(arguments: [
        ("root ::= \"a\" [0-9] \"b\"", "a5b", true),
        ("root ::= \"a\" [0-9] \"b\"", "ab", false),
        ("root ::= \"a\" [0-9] \"b\"", "a5", false),
        ("root ::= \"<\" [a-c]* \">\"", "<>", true),
        ("root ::= \"<\" [a-c]* \">\"", "<abcabc>", true),
        ("root ::= \"<\" [a-c]* \">\"", "<d>", false),
        ("root ::= \"a\" mid \"c\"\nmid ::= \"b\" | \"x\" | \"\"", "ac", true),
        ("root ::= \"a\" mid \"c\"\nmid ::= \"b\" | \"x\" | \"\"", "axc", true),
        ("root ::= \"a\" mid \"c\"\nmid ::= \"b\" | \"x\" | \"\"", "abxc", false),
        ("root ::= \"(\" root \")\" | \"\"", "((()))", true),
        ("root ::= \"(\" root \")\" | \"\"", "(()", false),
        ("root ::= \"a\" [xy]{1, 3} \"z\"", "axyz", true),
        ("root ::= \"a\" [xy]{1, 3} \"z\"", "axyxyz", false),
        ("root ::= \"a\" [xy]{2, 100} \"z\"", "a" + String(repeating: "x", count: 100) + "z", true),
        ("root ::= \"a\" [xy]{2, 100} \"z\"", "a" + String(repeating: "x", count: 101) + "z", false),
        ("root ::= \"你\" [好世] \"界\"", "你好界", true),
        ("root ::= \"你\" [好世] \"界\"", "你界", false),
        ("root ::= \"x\" [^0-9] \"y\" [^a-z]* \"z\"", "x你y😀z", true),
        ("root ::= \"x\" [^0-9] \"y\" [^a-z]* \"z\"", "xéyaz", false),
        ("root ::= Regex(\"[0-9]+(\\\\.[0-9]+)?\")", "3.14", true),
        ("root ::= Regex(\"[0-9]+(\\\\.[0-9]+)?\")", "3.", false),
        ("root ::= \"\"", "", true),
        ("root ::= \"\"", "a", false),
    ])
    func acceptance(_ ebnf: String, _ input: String, _ expected: Bool) throws {
        #expect(try accepts(ebnf, input) == expected, "\(ebnf) on \(input)")
    }

    @Test func rollback() throws {
        var parser = try parser("root ::= \"abc\" | \"abd\"")
        let a = parser.advance(UInt8(ascii: "a"))
        let b = parser.advance(UInt8(ascii: "b"))
        let c = parser.advance(UInt8(ascii: "c"))
        #expect(a && b && c)
        #expect(parser.isCompleted)
        parser.popLastStates(1)
        #expect(!parser.isCompleted)
        let d = parser.advance(UInt8(ascii: "d"))
        #expect(d)
        #expect(parser.isCompleted)
        let extra = parser.advance(UInt8(ascii: "d"))
        #expect(!extra)
        parser.reset()
        #expect(parser.historyCount == 1)
        #expect(!parser.isCompleted)
    }

    @Test func invalidUTF8Rejected() throws {
        for bytes: [UInt8] in [[0x78, 0xC0, 0x80, 0x79, 0x7A], [0x78, 0xC1, 0xBF, 0x79, 0x7A], [0x78, 0x41, 0x79, 0xF4, 0x90, 0x80, 0x80, 0x7A]] {
            var parser = try parser("root ::= \"x\" [^0-9] \"y\" [^a-z]* \"z\"")
            var accepted = true
            for byte in bytes where !parser.advance(byte) {
                accepted = false
                break
            }
            #expect(!(accepted && parser.isCompleted), "\(bytes)")
        }
    }
}
