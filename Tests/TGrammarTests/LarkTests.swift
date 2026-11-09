import Foundation
import Testing
@testable import TGrammar

private struct LarkFixture: Decodable, Sendable, CustomTestStringConvertible {
    var id: String
    var grammar: String
    var input: String
    var accepted: Bool
    var testDescription: String { id }
    static var upstream: [Self] {
        get throws {
            struct File: Decodable { var cases: [LarkFixture] }
            let url = try #require(Bundle.module.url(forResource: "Lark", withExtension: "json"))
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
        }
    }
}

@Suite("Lark (upstream)")
struct LarkTests {
    @Test(arguments: try LarkFixture.upstream)
    fileprivate func upstream(_ fixture: LarkFixture) throws {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(lark: fixture.grammar), terminateWithoutStopToken: true)
        let accepted = matcher.acceptString(fixture.input) && matcher.isCompleted
        #expect(accepted == fixture.accepted)
    }

    @Test func inlineSchemasNestedAndNamedGrammars() throws {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        let source = "start: \"[\" %lark { start: item \":\" %json {\"type\":\"integer\"} } \"]\"\nitem: \"x\""
        #expect(throws: GrammarError.self) { try compiler.compile(lark: source) } // Nested scopes are independent.
        let valid = "start: \"[\" %lark { start: \"x\" \":\" %json {\"type\":\"integer\"} } \"]\""
        for (input, expected) in [("[x:42]", true), ("[x:\"bad\"]", false), ("[y:42]", false)] {
            var matcher = GrammarMatcher(try compiler.compile(lark: valid), terminateWithoutStopToken: true)
            let result = matcher.acceptString(input) && matcher.isCompleted
            #expect(result == expected)
        }
        let named: [String: NamedGrammar] = ["pair": .lark("start: @item \":\" @item"), "item": .lark("start: /[a-z]+/")]
        var matcher = GrammarMatcher(try compiler.compile(lark: "start: @pair", namedGrammars: named), terminateWithoutStopToken: true)
        let accepted = matcher.acceptString("a:xyz")
        #expect(accepted && matcher.isCompleted)
        #expect(throws: GrammarError.self) { try compiler.compile(lark: "start: @a", namedGrammars: ["a": .lark("start: @b"), "b": .lark("start: @a")]) }
    }

    @Test func atomicTokensAndDuplicateVocabularyPieces() throws {
        let info = try TokenizerInfo(encodedVocab: ["<dup>", "x", "<dup>", "dup", "<other>"])
        let compiler = GrammarCompiler(tokenizerInfo: info)
        for (source, ids) in [("start: <dup>", [Int32(0), 2]), ("start: <[0-2,1-3,3]>", [0, 1, 2, 3]), ("start: <[^1,3]>", [0, 2, 4]), ("start: <[*]>", [0, 1, 2, 3, 4])] {
            var matcher = GrammarMatcher(try compiler.compile(lark: source))
            let mask = matcher.nextTokenBitmask()
            #expect(mask.allowedTokenIDs == ids)
        }
    }

    @Test func capturesAndTemperatureWithIgnoredWhitespace() throws {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: ["a", "x", "z", " "]))
        let grammar = "%import common.WS\n%ignore WS\nstart: \"a\" hot \"z\"\nhot[capture=\"value\", temperature=0.6]: /x+/"
        var matcher = GrammarMatcher(try compiler.compile(lark: grammar), defaultTemperature: 0.1)
        let a = matcher.acceptString("a ")
        #expect(a && matcher.temperature == 0.6)
        let x = matcher.acceptString("xxz")
        #expect(x && matcher.temperature == 0.1)
        #expect(matcher.captures().map(\.text) == ["xx"])
    }

    @Test func rejectsTerminalCyclesAndUndefinedNames() throws {
        for source in ["start: missing", "start: A\nA: B\nB: A", "start: A\nA: child\nchild: \"a\"", "start: \"a\"\nstart: \"b\""] {
            #expect(throws: GrammarError.self) { try Grammar(lark: source) }
        }
    }
}
