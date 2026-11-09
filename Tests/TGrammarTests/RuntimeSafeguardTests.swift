import Testing
@testable import TGrammar

/// Behavioral ports of test_max_chars.py and test_temperature.py. Swift optional temperatures
/// replace the tensor API's -1 sentinel, and value copies replace forked Python handles.
@Suite("Runtime safeguards (upstream)")
struct RuntimeSafeguardTests {
    private let text = "TEXT: /(\\n|.)*/"
    private func compile(_ source: String, _ pieces: [String] = []) throws -> CompiledGrammar {
        try GrammarCompiler(tokenizerInfo: TokenizerInfo(encodedVocab: pieces)).compile(lark: source)
    }
    private func allows(_ compiled: CompiledGrammar, prefix: String = "") -> [Int32] {
        var matcher = GrammarMatcher(compiled)
        _ = matcher.acceptString(prefix)
        return matcher.nextTokenBitmask().allowedTokenIDs
    }
    private func accepts(_ compiled: CompiledGrammar, tokens: [Int32], masked: Bool = true) -> Bool {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        for token in tokens {
            if matcher.isTerminated { return false }
            if masked, !matcher.nextTokenBitmask().allows(token) { return false }
            if !matcher.acceptToken(token) { return false }
        }
        return matcher.isTerminated
    }

    @Test func codepointsAndTransactionalStrings() throws {
        let value = try compile("start: reasoning \">\"\nreasoning[max_chars=2]: TEXT\n" + text,
                                ["a", "ab", "abc", "a>", "ab>", ">", "中", "中文", "中文>"])
        #expect(allows(value) == [0, 1, 3, 4, 5, 6, 7, 8])
        #expect(accepts(value, tokens: [4]) && accepts(value, tokens: [8]))
        var matcher = GrammarMatcher(value, terminateWithoutStopToken: true)
        let rejected = matcher.acceptString("中文a>"), accepted = matcher.acceptString("中文>")
        #expect(!rejected && accepted && matcher.isTerminated)
    }

    @Test func acceptedBitsetBoundary() throws {
        var pieces: [String] = []
        for index in 0 ..< 1024 { pieces.append(String(UnicodeScalar(0x1000 + index)!)); pieces.append(String(UnicodeScalar(0x2000 + index)!)) }
        pieces.append(">")
        let value = try compile("start: value \">\"\nvalue[max_chars=1]: /[\(pieces[0])-\(pieces[2046])]*/", pieces)
        #expect(allows(value) == stride(from: Int32(0), to: 2048, by: 2).map { $0 } + [2048])
    }

    @Test func zeroAndSplitUTF8() throws {
        let zero = try compile("start: value \">\"\nvalue[max_chars=0]: TEXT\n" + text, ["a", ">"])
        #expect(allows(zero) == [1])
        #expect(!accepts(zero, tokens: [0, 1]) && accepts(zero, tokens: [1]))
        let info = try TokenizerInfo(encodedVocab: [[UInt8(0xE4)], [0xB8], [0xAD], [62]])
        let value = try GrammarCompiler(tokenizerInfo: info).compile(lark: "start: reasoning \">\"\nreasoning[max_chars=1]: TEXT\n" + text)
        var matcher = GrammarMatcher(value, terminateWithoutStopToken: true)
        #expect(allows(value) == [0, 3])
        for token: Int32 in [0, 1, 2, 3] {
            let mask = matcher.nextTokenBitmask()
            #expect(mask.allows(token))
            let accepted = matcher.acceptToken(token)
            #expect(accepted)
        }
        #expect(matcher.isTerminated)
    }

    @Test func nestedAndRepeatedBudgets() throws {
        let nested = try compile("start: outer \">\"\nouter[max_chars=3]: \"x\" inner\ninner[max_chars=5]: TEXT\n" + text)
        var matcher = GrammarMatcher(nested, terminateWithoutStopToken: true)
        let a = matcher.acceptString("xab>")
        #expect(a && matcher.isTerminated)
        matcher.reset()
        let b = matcher.acceptString("xabc>")
        #expect(!b)
        let repeated = try compile("start: item \":\" item \">\"\nitem[max_chars=2]: /[a-z]*/")
        var other = GrammarMatcher(repeated, terminateWithoutStopToken: true)
        let c = other.acceptString("ab:ab>")
        #expect(c && other.isTerminated)
    }

    @Test func combinedTokenCharacterAndTemperatureBudgets() throws {
        let value = try compile("start: reasoning \">\"\nreasoning[max_tokens=2, max_chars=3]: TEXT\n" + text, ["a", "ab", ">"])
        #expect(accepts(value, tokens: [1, 0, 2]))
        #expect(!accepts(value, tokens: [0, 0, 0, 2]) && !accepts(value, tokens: [1, 1, 2]))
        let hot = try compile("start: value \">\"\nvalue[max_chars=2, temperature=0.7]: /[a-z]*/", ["a", "ab", "abc", ">"])
        var matcher = GrammarMatcher(hot)
        #expect(matcher.temperature == 0.7)
        let mask = matcher.nextTokenBitmask()
        #expect(mask.allowedTokenIDs == [0, 1, 3])
        let accepted = matcher.acceptToken(1)
        #expect(accepted && matcher.temperature == nil)
        let after = matcher.nextTokenBitmask()
        #expect(after.allowedTokenIDs == [3])
    }

    @Test func forcedMarkerCloseAndCaptureScope() throws {
        let value = try compile("start[capture=\"outer\"]: reasoning \"!\"\nreasoning[max_chars=2, capture=\"inner\", stop=\">\", stop_capture=\"marker\"]: TEXT\n" + text, ["aa!", "a>!", "aa>!"])
        #expect(accepts(value, tokens: [0], masked: false) && accepts(value, tokens: [1], masked: false))
        #expect(!accepts(value, tokens: [2], masked: false))
        for (token, expected) in [(Int32(0), ["aa", "aa!"]), (1, [">", "a", "a!"])] {
            var matcher = GrammarMatcher(value, terminateWithoutStopToken: true)
            let accepted = matcher.acceptToken(token)
            #expect(accepted && matcher.isTerminated)
            #expect(matcher.captures().map(\.text) == expected)
        }
    }

    @Test func rollbackResetForkAndAtomicBestEffort() throws {
        let value = try compile("start: reasoning \">\"\nreasoning[max_chars=2]: TEXT\n" + text, ["a", "b", ">"])
        var matcher = GrammarMatcher(value), fork = matcher
        let a = matcher.acceptToken(0)
        fork = matcher
        let b = matcher.acceptToken(1)
        #expect(a && b)
        let exhausted = matcher.nextTokenBitmask()
        #expect(exhausted.allowedTokenIDs == [2])
        matcher.rollback(1)
        let restored = matcher.nextTokenBitmask()
        #expect(restored.allows(0))
        let forkB = fork.acceptToken(1)
        let forkMask = fork.nextTokenBitmask()
        #expect(forkB && forkMask.allowedTokenIDs == [2])
        matcher.reset()
        let reset = matcher.nextTokenBitmask()
        #expect(reset.allows(0))
        let atomic = try compile("start: value \"!\"\nvalue[max_chars=1]: <|wide|>", ["<|wide|>", "!"])
        #expect(allows(atomic) == [0] && accepts(atomic, tokens: [0, 1]))
    }

    @Test func serializationAndLargeCharacterLimits() throws {
        for limit in [0, 1_000_001, Int(Int32.max)] {
            let grammar = try Grammar(lark: "start[max_chars=\(limit)]: /a*/")
            #expect(grammar.description.contains("max_chars=\(limit)"))
            let restored = try Grammar(serializedJSON: grammar.serializedJSON)
            #expect(restored.description == grammar.description)
        }
        let value = try compile("start: value \">\"\nvalue[max_chars=2]: /[a-z]*/", ["ab>", "abc"])
        let restored = try CompiledGrammar(serializedJSON: value.serializedJSON, tokenizerInfo: value.tokenizerInfo)
        #expect(allows(value) == [0] && allows(restored) == [0])
        #expect(accepts(restored, tokens: [0]))
    }

    @Test func tokenEdgesRetriedNearCharacterBoundary() throws {
        let info = try TokenizerInfo(encodedVocab: ["<s>", "</s>", "a", "b", "ab", "abcd", "<", ">", "<|x|>", "|", "\"", ","], stopTokenIDs: [1])
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let withTokens = try compiler.compile(ebnf: "root ::= \"<\" body \">\"\nbody[max_chars=8] ::= (Token(8) | [a-z])*")
        let plain = try compiler.compile(ebnf: "root ::= \"<\" body \">\"\nbody[max_chars=8] ::= [a-z]*")
        for (prefix, expected) in [("<", [Int32(2), 3, 4, 5, 7]), ("<abcdab", [2, 3, 4, 7]), ("<abcdabcd", [7])] {
            #expect(allows(plain, prefix: prefix) == expected)
            #expect(allows(withTokens, prefix: prefix) == expected + (prefix == "<abcdabcd" ? [] : [8]))
        }
    }

    @Test func tokenCrossesIntoBudgetedSibling() throws {
        let info = try TokenizerInfo(encodedVocab: ["<s>", "</s>", "a", "b", ",", "|", "a,bbb|", "a,bb|", ",bbb", "<"], stopTokenIDs: [1])
        let value = try GrammarCompiler(tokenizerInfo: info).compile(ebnf: "root ::= \"<\" t \",\" b \"|\"\nt ::= [a-z]*\nb[max_chars=2] ::= [a-z]*")
        for prefix in ["<", "<a"] {
            #expect(allows(value, prefix: prefix) == [2, 3, 4, 7])
            for token: Int32 in [6, 7, 8] {
                var matcher = GrammarMatcher(value)
                let initial = matcher.acceptString(prefix), accepted = matcher.acceptToken(token)
                #expect(initial && accepted == (token == 7))
            }
        }
    }

    @Test func nestedTemperaturesAndAmbiguity() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b", "x", "z", " "])
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let named: [String: NamedGrammar] = ["item": .lark("start[temperature=0.3]: \"x\"")]
        let value = try compiler.compile(lark: "start: \"a\" value \"z\"\nvalue[temperature=0.6]: @item", namedGrammars: named)
        var matcher = GrammarMatcher(value, defaultTemperature: 0.1)
        #expect(matcher.temperature == 0.1)
        let a = matcher.acceptString("a")
        #expect(a && matcher.temperature == 0.3)
        let x = matcher.acceptString("x")
        #expect(x && matcher.temperature == 0.1)
        let ambiguous = try compiler.compile(lark: "start: left | right\nleft[temperature=0.2]: \"a\"+\nright[temperature=0.9]: \"a\" \"b\"")
        var other = GrammarMatcher(ambiguous)
        #expect(other.temperature == 0.9)
        let first = other.acceptString("a")
        #expect(first && other.temperature == 0.9)
        let second = other.acceptString("a")
        #expect(second && other.temperature == 0.2)
    }

    @Test(arguments: ["0", "0.125", "1e-2", "2.0"])
    func temperatureNumberFormsAndPersistence(_ number: String) throws {
        let value = try compile("start[temperature=\(number)]: \"a\"", ["a"])
        let restored = try CompiledGrammar(serializedJSON: value.serializedJSON, tokenizerInfo: value.tokenizerInfo)
        #expect(GrammarMatcher(restored, defaultTemperature: 0.5).temperature == Float(number))
    }

    @Test(arguments: [1, 2])
    func batchMasksTemperatureAndPendingBudgetCommit(_ threads: Int) throws {
        let pieces = ["a", "b", ">"]
        let hot = try compile("start[temperature=0.2]: \"a\"", pieces), plain = try compile("start: \"b\"", pieces)
        let budgeted = try compile("start: value \">\"\nvalue[max_tokens=1]: /[ab]*/", pieces)
        var limited = GrammarMatcher(budgeted), terminated = GrammarMatcher(plain, terminateWithoutStopToken: true)
        let accepted = limited.acceptToken(0), done = terminated.acceptToken(1)
        #expect(accepted && done)
        var batch = [GrammarMatcher(hot, defaultTemperature: 0.8), GrammarMatcher(plain, defaultTemperature: 0.4), GrammarMatcher(plain), limited, terminated]
        let result = GrammarBatch.fillNextTokenMasks(for: &batch, maxThreads: threads)
        #expect(result.rows.map(\.temperature) == [0.2, 0.4, nil, nil, nil])
        #expect(result.masks[0].allowedTokenIDs == [0] && result.masks[1].allowedTokenIDs == [1] && result.masks[3].allowedTokenIDs == [2])
        #expect(result.rows[4].isTerminated && !result.masks[4].allowsAny)
        let rejected = batch[3].acceptToken(0), close = batch[3].acceptToken(2)
        #expect(!rejected && close && batch[3].isCompleted)
    }

    @Test func speculativeTemperatures() throws {
        let value = try compile("start: \"a\" value \"z\"\nvalue[temperature=0.6]: /x+/", ["a", "b", "x", "z", " "])
        let matcher = GrammarMatcher(value, defaultTemperature: 0.1)
        let tree = try DraftTokenTree(nodes: [.init(0, firstChild: 1), .init(0, firstChild: 2), .init(2, firstChild: 3), .init(3)])
        let result = matcher.traverseDraftTree(tree)
        #expect(result.didFinish && result.temperatures == [0.1, 0.6, 0.6, 0.1])
        #expect(matcher.temperature == 0.1)
    }
}
