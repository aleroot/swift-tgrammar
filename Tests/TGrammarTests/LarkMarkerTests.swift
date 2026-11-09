import Testing
@testable import TGrammar

/// Ports the suffix/stop seams in upstream test_lark.py: hidden capture scope, shortest
/// completion, variable markers, token boundaries, speculative forks, budgets and persistence.
@Suite("Lark suffix and stop (upstream)")
struct LarkMarkerTests {
    private func compiler(_ pieces: [String] = []) throws -> GrammarCompiler {
        GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: pieces))
    }

    @Test(arguments: ["suffix", "stop"])
    func captureScopes(_ attribute: String) throws {
        let compiler = try compiler()
        for (marker, input, body, capturedMarker) in [("\"!\"", "xy!z", "xy", "!"),
                                                     ("\"💥\"", "xy💥z", "xy", "💥"),
                                                     ("/!!+/", "ab!!z", "ab", "!!"),
                                                     ("/b?a/", "baZ", "b", "a"),
                                                     ("/x?/", "az", "a", "")] {
            let requiredBody = input == "baZ" ? "\"b\"" : input == "az" ? "\"a\"" : "/[a-z]*/"
            let last = input == "baZ" ? "Z" : "z"
            let source = "start[capture=\"outer\"]: r \"\(last)\"\nr[capture=\"inner\", \(attribute)=\(marker), stop_capture=\"marker\"]: \(requiredBody)"
            var matcher = GrammarMatcher(try compiler.compile(lark: source), terminateWithoutStopToken: true)
            let accepted = matcher.acceptString(input)
            #expect(accepted && matcher.isTerminated)
            #expect(matcher.captures().map(\.name) == ["marker", "inner", "outer"])
            #expect(matcher.captures().map(\.text) == [capturedMarker, body, attribute == "suffix" ? input : body + last])
        }
    }

    @Test(arguments: ["suffix", "stop"])
    func hiddenEventsAndUnrelatedBranches(_ attribute: String) throws {
        let compiler = try compiler()
        let source = "start[capture=\"outer\"]: r r \"z\"\nr[\(attribute)=\"!\"]: /[ab]*/"
        var matcher = GrammarMatcher(try compiler.compile(lark: source), terminateWithoutStopToken: true)
        let accepted = matcher.acceptString("a!b!z")
        #expect(accepted && matcher.isTerminated)
        #expect(matcher.captures().map(\.text) == [attribute == "suffix" ? "a!b!z" : "abz"])
        let branches = "start: a | c\na[capture=\"a\"]: b \"q\"\nb[stop=\"!\"]: \"x\"\nc[capture=\"c\"]: \"x!\""
        var other = GrammarMatcher(try compiler.compile(lark: branches), terminateWithoutStopToken: true)
        let otherAccepted = other.acceptString("x!")
        #expect(otherAccepted && other.isTerminated)
        for deduplicate in [false, true] { #expect(other.captures(deduplicate: deduplicate).map(\.text) == ["x!"]) }
    }

    @Test(arguments: ["suffix", "stop"])
    func masksAcrossCommit(_ attribute: String) throws {
        let compiler = try compiler(["<", ">", "a", "b", "ab", "a>", "ab>", "b>", "bb", " "])
        var matcher = GrammarMatcher(try compiler.compile(lark: "start: r \"b\"\nr[\(attribute)=\">\"]: /[ab]*/"), terminateWithoutStopToken: true)
        let initial = matcher.nextTokenBitmask()
        #expect(initial.allowedTokenIDs == [1, 2, 3, 4, 5, 6, 7, 8])
        let accepted = matcher.acceptToken(6)
        #expect(accepted)
        let after = matcher.nextTokenBitmask()
        #expect(after.allowedTokenIDs == [3])
        let final = matcher.acceptToken(3)
        #expect(final && matcher.isTerminated)
    }

    @Test(arguments: ["suffix", "stop"])
    func variableMarkerRollbackForkAndSerialization(_ attribute: String) throws {
        let compiler = try compiler(["a!!", "b!!", "z", "a!", "!"])
        let compiled = try compiler.compile(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=END, stop_capture=\"marker\"]: /[ab]*/\nEND: /!!+/")
        let restored = try CompiledGrammar(serializedJSON: compiled.serializedJSON, tokenizerInfo: compiler.tokenizerInfo)
        #expect(restored.grammar.description == compiled.grammar.description)
        for grammar in [compiled, restored] {
            var matcher = GrammarMatcher(grammar, terminateWithoutStopToken: true)
            let initial = matcher.nextTokenBitmask()
            #expect(initial.allows(0))
            let accepted = matcher.acceptToken(0)
            #expect(accepted)
            let mask = matcher.nextTokenBitmask()
            #expect(mask.allowedTokenIDs == [2])
            var fork = matcher.fork()
            matcher.rollback(1)
            #expect(matcher.captures().isEmpty)
            let b = matcher.acceptToken(1), z = matcher.acceptToken(2), forkZ = fork.acceptToken(2)
            #expect(b && z && forkZ && matcher.isTerminated && fork.isTerminated)
            #expect(matcher.captures().map(\.text) == ["!!", "b", attribute == "suffix" ? "b!!z" : "bz"])
            #expect(fork.captures().map(\.text) == ["!!", "a", attribute == "suffix" ? "a!!z" : "az"])
        }
    }

    @Test(arguments: ["suffix", "stop"])
    func budgetMarkerCrossesTokenBoundary(_ attribute: String) throws {
        let compiler = try compiler(["x", "<", ">", "a!", "b!", "a", "b", "!"])
        let source = "start[capture=\"all\"]: value \">\"\nvalue[max_tokens=1, capture=\"body\", \(attribute)=END, stop_capture=\"marker\"]: /[ab]*/\nEND: /!!+/"
        var matcher = GrammarMatcher(try compiler.compile(lark: source), terminateWithoutStopToken: true)
        let first = matcher.acceptToken(3)
        #expect(first)
        let boundary = matcher.nextTokenBitmask()
        #expect(boundary.allowedTokenIDs == [7])
        let marker = matcher.acceptToken(7)
        #expect(marker)
        let after = matcher.nextTokenBitmask()
        #expect(after.allowedTokenIDs == [2])
        let final = matcher.acceptToken(2)
        #expect(final && matcher.isTerminated)
        #expect(matcher.captures().map(\.text) == ["!!", "a", attribute == "suffix" ? "a!!>" : "a>"])
    }

    @Test func malformedAttributes() throws {
        for attrs in ["suffix=\"\"", "stop=\"\"", "suffix=\"a\", stop=\"b\"", "stop_capture=\"marker\"", "capture=\"\"", "capture=\"bad name\"", "max_tokens=0", "max_tokens=1000001", "temperature=-1", "capture, capture", "suffix=child"] {
            #expect(throws: GrammarError.self) { try Grammar(lark: "start[\(attrs)]: \"a\"") }
        }
    }
}
