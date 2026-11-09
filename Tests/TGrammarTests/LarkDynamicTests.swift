import Testing
@testable import TGrammar

@Suite("Lark dynamic dispatch and lazy state (upstream)")
struct LarkDynamicTests {
    private func compile(_ source: String, pieces: [String] = []) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: TokenizerInfo(encodedVocab: pieces)).compile(lark: source)
    }

    @Test(arguments: ["suffix", "stop"])
    func dynamicMarkersAndEnclosingCaptures(_ attribute: String) throws {
        let source = """
            start[capture="outer"]: tool* tail
            tail: TEXT
            head[\(attribute)="<t>", stop_capture="marker"]: TEXT
            tool: head "x"
            TEXT: /(\\n|.)*/
            """
        let original = try Grammar(lark: source)
        let restored = try Grammar(serializedJSON: original.serializedJSON)
        let reparsed = try Grammar(ebnf: original.description)
        for grammar in [original, restored, reparsed] {
            let info = try TokenizerInfo(encodedVocab: [String]())
            var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(grammar), terminateWithoutStopToken: true)
            let result = matcher.acceptString("a<t>xb<t>xc")
            #expect(result && matcher.isCompleted)
            #expect(matcher.captures().map(\.name) == ["marker", "marker", "outer"])
            #expect(matcher.captures().map(\.text) == ["<t>", "<t>", attribute == "suffix" ? "a<t>xb<t>xc" : "axbxc"])
        }
    }

    @Test(arguments: ["suffix", "stop"])
    func anyTextDoesNotSynthesizeUnconsumedMarker(_ attribute: String) throws {
        let compiled = try compile("start: r\nr[\(attribute)=\"<end>\", stop_capture=\"marker\"]: TEXT\nTEXT: /(\\n|.)*/")
        for (input, captures) in [("plain", [String]()), ("foo<end>", ["<end>"])] {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let accepted = matcher.acceptString(input)
            #expect(accepted && matcher.isCompleted)
            #expect(matcher.captures().map(\.text) == captures)
        }
    }

    @Test func importedDynamicStopHidesMarkerFromParent() throws {
        let source = "start: tool* tail\ntail: TEXT\nhead[stop=\"<t>\", stop_capture=\"marker\"]: TEXT\ntool: head \"x\"\nTEXT: /(\\n|.)*/"
        let info = try TokenizerInfo(encodedVocab: [String]())
        let compiled = try GrammarCompiler(tokenizerInfo: info).compile(lark: "start[capture=\"outer\"]: @dynamic", namedGrammars: ["dynamic": .lark(source)])
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let accepted = matcher.acceptString("a<t>xb")
        #expect(accepted && matcher.isCompleted)
        #expect(matcher.captures().map(\.text) == ["<t>", "axb"])
    }

    @Test func dynamicAtomicTriggerCommitsPayload() throws {
        let compiled = try compile("start: tool* tail\ntail: TEXT\ntool: TEXT <|tool|> %json {\"const\":1} \"</tool>\"\nTEXT: /(\\n|.)*/",
                                   pieces: ["plain", "<|tool|>", "1", "</tool>", "bad"])
        for (tokens, expected) in [([Int32(0)], true), ([1, 2, 3], true), ([0, 1, 2, 3, 0], true), ([1], false), ([1, 4], false)] {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let accepted = tokens.allSatisfy { matcher.acceptToken($0) } && matcher.isCompleted
            #expect(accepted == expected)
        }
    }

    @Test func lazyMasksCommitInsideTokensAndPreserveFork() throws {
        let compiled = try compile("start: \"<\" r \">\"\nr[lazy, capture=\"value\"]: /[a-z]+/",
                                   pieces: ["<", ">", "a", "b", "ab", "a>", "ab>", "b>", "bb", " "])
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let begin = matcher.acceptToken(0)
        #expect(begin)
        let mask = matcher.nextTokenBitmask(), again = matcher.nextTokenBitmask()
        #expect(mask.allowedTokenIDs == [2, 3, 5, 7] && again == mask)
        let value = matcher.acceptToken(2)
        #expect(value)
        let after = matcher.nextTokenBitmask()
        #expect(after.allowedTokenIDs == [1])
        var fork = matcher.fork()
        matcher.rollback()
        let retried = matcher.acceptToken(7), forkEnd = fork.acceptToken(1)
        #expect(retried && forkEnd && matcher.isTerminated && fork.isTerminated)
        #expect(matcher.captures().map(\.text) == ["b"])
        #expect(fork.captures().map(\.text) == ["a"])
    }

    @Test func reasoningBudgetAndLazyCaptureCompose() throws {
        let compiled = try compile("start: reasoning \"<t>\" val \">\"\nreasoning[max_tokens=2, capture]: TEXT\nval[lazy, capture=\"value\"]: /[ab]+/\nTEXT: /(\\n|.)*/",
                                   pieces: ["x", "<t>", ">", "a", "b", "ab"])
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        let one = matcher.acceptToken(0), two = matcher.acceptToken(0)
        #expect(one && two)
        let boundary = matcher.nextTokenBitmask()
        #expect(boundary.allowedTokenIDs == [1])
        let begin = matcher.acceptToken(1)
        #expect(begin)
        let value = matcher.nextTokenBitmask()
        #expect(value.allowedTokenIDs == [3, 4])
        let body = matcher.acceptToken(3)
        #expect(body)
        let exit = matcher.nextTokenBitmask()
        #expect(exit.allowedTokenIDs == [2])
        let end = matcher.acceptToken(2)
        #expect(end && matcher.isTerminated)
        #expect(matcher.captures().map(\.text) == ["xx", "a"])
    }
}
