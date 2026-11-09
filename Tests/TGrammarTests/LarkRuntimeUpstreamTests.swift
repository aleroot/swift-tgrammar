import Foundation
import Testing
@testable import TGrammar

/// Ports the runtime Lark attribute tests of upstream test_lark.py: `max_tokens` budgets,
/// captures, `lazy` + `capture`, and suffix/stop combined with captures, budgets and persistence.
/// Captures are compared as `name=text` strings.
@Suite("Lark runtime attributes (upstream)")
struct LarkRuntimeUpstreamTests {
    // 0 "ab ", 1 "cd", 2 " ", 3 "</t>", 4 "1", 5 "<t>", 6 "x"
    static let maxTokensVocab = ["ab ", "cd", " ", "</t>", "1", "<t>", "x"]
    // 0 "x", 1 "<", 2 ">", 3 "a!", 4 "b!", 5 "a", 6 "b", 7 "!"
    static let combinedVocab = ["x", "<", ">", "a!", "b!", "a", "b", "!"]
    static let anyTextBudget = "start: r \"<t>\"\nr[max_tokens=3]: TEXT\nTEXT: /(\\n|.)*/"
    static let budget = "start: \"<t>\" r \"</t>\" ans\nr[max_tokens=2]: /([a-z]* )+/\nans: \"1\""
    static let captureBudgetAnyText = "start: r \"<t>\"\nr[max_tokens=3, capture]: TEXT\nTEXT: /(\\n|.)*/"

    private func info(_ pieces: [String]) throws -> TokenizerInfo { try TokenizerInfo(encodedVocab: pieces) }
    private func compiler(_ pieces: [String] = [], cache: Bool = false) throws -> GrammarCompiler {
        GrammarCompiler(tokenizerInfo: try info(pieces), cacheEnabled: cache)
    }
    private func compileLark(_ source: String, _ pieces: [String] = []) throws -> CompiledGrammar {
        try compiler(pieces).compile(lark: source)
    }
    private func matcher(_ compiled: CompiledGrammar) -> GrammarMatcher {
        GrammarMatcher(compiled, terminateWithoutStopToken: true)
    }
    private func allowed(_ matcher: inout GrammarMatcher) -> [Int32] { matcher.nextTokenBitmask().allowedTokenIDs }
    private func accept(_ matcher: inout GrammarMatcher, _ tokens: [Int32]) -> Bool {
        for token in tokens where !matcher.acceptToken(token) { return false }
        return true
    }
    private func caps(_ matcher: GrammarMatcher, deduplicate: Bool = true) -> [String] {
        matcher.captures(deduplicate: deduplicate).map { "\($0.name)=\($0.text)" }
    }
    private func acceptsAndTerminates(_ compiled: CompiledGrammar, _ tokens: [Int32]) -> Bool {
        var m = matcher(compiled)
        return accept(&m, tokens) && m.isTerminated
    }
    /// Upstream `_get_captures`: accept the whole string and return the captures.
    private func captures(_ source: String, _ value: String) throws -> [String] {
        var m = matcher(try compileLark(source))
        let accepted = m.acceptString(value)
        #expect(accepted)
        return caps(m)
    }
    /// Upstream `_captures_for_string`.
    private func captures(_ grammar: Grammar, _ value: String, pieces: [String] = [], cache: Bool = false) throws -> [String] {
        var m = matcher(try compiler(pieces, cache: cache).compile(grammar))
        let accepted = m.acceptString(value)
        #expect(accepted && m.isTerminated)
        return caps(m)
    }
    private func larkError(_ source: String, _ pieces: [String]? = nil) -> String? {
        do {
            _ = try Grammar(lark: source, tokenizerInfo: try pieces.map(info))
            return nil
        } catch { return String(describing: error) }
    }
    private func suffixStopInfo(_ grammar: Grammar, rule: String) throws -> [Any] {
        let object = try #require(JSONSerialization.jsonObject(with: Data(grammar.serializedJSON.utf8)) as? [String: Any])
        let rules = try #require(object["rules"] as? [[Any]])
        let ruleID = try #require(rules.firstIndex { $0.first as? String == rule })
        let infos = try #require(object["suffix_stop_infos"] as? [[Any]])
        return try #require(infos.first { ($0.first as? Int) == ruleID })
    }

    // MARK: max_tokens

    @Test func maxTokensAnyTextBudget() throws {
        let compiled = try compileLark(Self.anyTextBudget, Self.maxTokensVocab)
        #expect(acceptsAndTerminates(compiled, [5]))
        #expect(acceptsAndTerminates(compiled, [0, 1, 2, 5]))
        var m = matcher(compiled)
        #expect(accept(&m, [0, 1, 2]))
        #expect(allowed(&m) == [5])
        let fourth = m.acceptToken(0)
        #expect(!fourth)
        let close = m.acceptToken(5)
        #expect(close && m.isTerminated)
    }

    @Test func maxTokensAnyTextKeepsBudgetMetadata() throws {
        let printed = try Grammar(lark: Self.anyTextBudget, tokenizerInfo: info(Self.maxTokensVocab)).description
        #expect(printed.contains("r[max_tokens=3] ::="))
        #expect(!printed.contains("ExcludeToken("))
    }

    @Test func budgetEnforcedAtClosablePosition() throws {
        var m = matcher(try compileLark(Self.budget, Self.maxTokensVocab))
        #expect(accept(&m, [5, 0, 0]))
        #expect(allowed(&m) == [3])
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3, 4]) && m.isTerminated)
    }

    @Test func budgetRelaxedWhenRegionCannotEnd() throws {
        var m = matcher(try compileLark(Self.budget, Self.maxTokensVocab))
        #expect(accept(&m, [5, 1, 1]))
        let relaxed = allowed(&m)
        #expect(!relaxed.contains(3) && relaxed.contains(1) && relaxed.contains(2))
        #expect(accept(&m, [2]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3, 4]) && m.isTerminated)
    }

    @Test func budgetRelaxedOverMultipleSteps() throws {
        let source = "start: \"<t>\" r \"</t>\" ans\nr[max_tokens=1]: /([a-z]* )+/\nans: \"1\""
        var m = matcher(try compileLark(source, Self.maxTokensVocab))
        #expect(accept(&m, [5, 1]))
        _ = m.nextTokenBitmask()
        #expect(accept(&m, [6]))
        _ = m.nextTokenBitmask()
        #expect(accept(&m, [6, 2]))
        #expect(allowed(&m) == [3])
    }

    @Test func budgetRollbackAcrossClose() throws {
        var m = matcher(try compileLark(Self.budget, Self.maxTokensVocab))
        #expect(accept(&m, [5, 0, 0]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3]))
        m.rollback(2)
        #expect(accept(&m, [1, 2]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3, 4]) && m.isTerminated)
    }

    @Test func budgetAcceptStringIsNotCounted() throws {
        var m = matcher(try compileLark(Self.budget, Self.maxTokensVocab))
        let prefix = m.acceptString("<t>ab ab ab ab ")
        #expect(prefix)
        #expect(accept(&m, [0, 0]))
        #expect(allowed(&m) == [3])
    }

    @Test func budgetResetAndFork() throws {
        var m = matcher(try compileLark(Self.budget, Self.maxTokensVocab))
        #expect(accept(&m, [5, 0, 0]))
        var forked = m.fork()
        #expect(allowed(&forked) == [3])
        m.reset()
        #expect(accept(&m, [5, 0]))
        let open = allowed(&m)
        #expect(open.contains(0) && open.contains(3))
        #expect(allowed(&forked) == [3])
    }

    @Test func budgetPerOccurrence() throws {
        let compiled = try compileLark("start: r+ \"1\"\nr[max_tokens=2]: /[a-z]+ /", Self.maxTokensVocab)
        var m = matcher(compiled)
        #expect(accept(&m, [0, 0, 0, 0, 0]))
        let loop = allowed(&m)
        #expect(loop.contains(0) && loop.contains(4))
        #expect(accept(&m, [4]) && m.isTerminated)
        var single = matcher(compiled)
        #expect(accept(&single, [1, 1]))
        #expect(!allowed(&single).contains(4))
        #expect(accept(&single, [2]))
        #expect(allowed(&single).contains(4))
    }

    @Test func budgetNestedRegionsTakeMinimum() throws {
        let source = "start: a \"1\"\na[max_tokens=3]: \"x\" b\nb[max_tokens=9]: /([a-z]* )+/"
        var m = matcher(try compileLark(source, Self.maxTokensVocab))
        #expect(accept(&m, [6, 0, 0]))
        #expect(allowed(&m) == [4])
    }

    @Test func budgetSharedSubrule() throws {
        let grammar = try Grammar(ebnf: "root ::= a \" \" b\na[max_tokens=1] ::= sub\nb ::= sub\nsub ::= [a-z] sub | [a-z]")
        var m = matcher(try compiler(Self.maxTokensVocab).compile(grammar))
        #expect(accept(&m, [1]))
        #expect(allowed(&m) == [2])
        #expect(accept(&m, [2, 1, 1]))
        #expect(m.isCompleted)
    }

    @Test func budgetRoundTripAndCache() throws {
        let grammar = try Grammar(lark: Self.budget, tokenizerInfo: info(Self.maxTokensVocab))
        let ebnf = grammar.description
        #expect(ebnf.contains("r[max_tokens=2] ::="))
        for candidate in [try Grammar(ebnf: ebnf), try Grammar(serializedJSON: grammar.serializedJSON)] {
            var m = matcher(try compiler(Self.maxTokensVocab).compile(candidate))
            #expect(accept(&m, [5, 0, 0]))
            #expect(allowed(&m) == [3])
        }
        var m = matcher(try compiler(Self.maxTokensVocab, cache: true).compile(grammar))
        #expect(accept(&m, [5, 0, 0]))
        #expect(allowed(&m) == [3])
    }

    @Test(arguments: [
        ("start[max_tokens=0]: TEXT\nTEXT: /(\\n|.)*/", "max_tokens must be positive"),
        ("start[max_tokens=3, max_tokens=4]: TEXT\nTEXT: /(\\n|.)*/", "max_tokens attribute is specified more than once"),
        ("TOK[max_tokens=3]: \"a\"\nstart: TOK", "attributes are only supported on rules"),
    ])
    func maxTokensErrors(_ source: String, _ message: String) throws {
        let error = try #require(larkError(source, Self.maxTokensVocab))
        #expect(error.contains(message), "\(error)")
        #expect(error.contains("Lark error at line ") && error.contains(", column "))
    }

    @Test func maxTokensWorksWithoutTokenizerInfo() throws {
        let grammar = try Grammar(lark: "start: r \"<t>\"\nr[max_tokens=2]: TEXT\nTEXT: /(\\n|.)*/")
        #expect(grammar.description.contains("r[max_tokens=2] ::="))
        var m = matcher(try compiler(["a", "<t>"]).compile(grammar))
        #expect(accept(&m, [0, 0]))
        #expect(allowed(&m) == [1])
        #expect(accept(&m, [1]) && m.isTerminated)
    }

    @Test func maxTokensWithLazyMarkerOrBudgetWins() throws {
        let pieces = ["x", "!", "z", "x!"]
        let grammar = try Grammar(lark: "start: head \"z\"\nhead[max_tokens=2, lazy, capture]: TEXT \"!\"\nTEXT: /(\\n|.)*/", tokenizerInfo: info(pieces))
        let compiled = try compiler(pieces).compile(grammar)
        var marker = matcher(compiled)
        #expect(accept(&marker, [3]))
        #expect(allowed(&marker) == [2])
        #expect(accept(&marker, [2]) && marker.isTerminated)
        #expect(caps(marker) == ["head=x!"])
        var budget = matcher(compiled)
        #expect(accept(&budget, [0, 0]))
        #expect(allowed(&budget) == [2])
        #expect(accept(&budget, [2]) && budget.isTerminated)
        #expect(caps(budget) == ["head=xx"])
    }

    // MARK: capture

    @Test func captureSimple() throws {
        #expect(try captures("start: \"a\" v \"b\"\nv[capture]: /[0-9]+/", "a123b") == ["v=123"])
    }

    @Test func captureRepeatedOccurrences() throws {
        #expect(try captures("start: (item \",\")* item\nitem[capture]: /[0-9]+/", "1,22,333") == ["item=1", "item=22", "item=333"])
    }

    @Test func captureRightRecursion() throws {
        #expect(try captures("start: lst\nlst[capture]: ITEM \",\" lst | ITEM\nITEM: /[0-9]+/", "1,2,3") == ["lst=3", "lst=2,3", "lst=1,2,3"])
    }

    @Test func captureOnRootRule() throws {
        #expect(try captures("start[capture=\"all\"]: \"a\" /[0-9]+/ \"b\"", "a12b") == ["all=a12b"])
    }

    @Test func captureRawEventsAndCoalescing() throws {
        var m = matcher(try compileLark("start: \"a\" v \"b\"\nv[capture]: /[0-9]+/"))
        let accepted = m.acceptString("a123b")
        #expect(accepted)
        #expect(caps(m) == ["v=123"])
        #expect(caps(m, deduplicate: false) == ["v=1", "v=12", "v=123"])
    }

    @Test func captureRollbackAndReaccept() throws {
        let compiled = try GrammarCompiler(tokenizerInfo: TokenizerInfo(encodedVocab: ["a", "1", "2", "b", "</s>"], stopTokenIDs: [4]), cacheEnabled: false)
            .compile(lark: "start: \"a\" v \"b\"\nv[capture]: /[0-9]+/")
        var m = GrammarMatcher(compiled)
        #expect(accept(&m, [0, 1, 3]))
        #expect(caps(m) == ["v=1"])
        m.rollback(2)
        #expect(accept(&m, [2, 3]))
        #expect(caps(m) == ["v=2"])
    }

    @Test func captureMaskComputationRecordsNothing() throws {
        let compiled = try GrammarCompiler(tokenizerInfo: TokenizerInfo(encodedVocab: ["a", "1", "b", "</s>"], stopTokenIDs: [3]), cacheEnabled: false)
            .compile(lark: "start: \"a\" v \"b\"\nv[capture]: /[0-9]+/")
        var m = GrammarMatcher(compiled)
        #expect(accept(&m, [0]))
        _ = m.nextTokenBitmask()
        #expect(caps(m, deduplicate: false).isEmpty)
        #expect(accept(&m, [1]))
        _ = m.nextTokenBitmask()
        let before = caps(m, deduplicate: false)
        _ = m.nextTokenBitmask()
        #expect(caps(m, deduplicate: false) == before)
        #expect(accept(&m, [2]))
        #expect(caps(m) == ["v=1"])
    }

    @Test func captureResetAndFork() throws {
        var m = matcher(try compileLark("start: \"a\" v \"b\"\nv[capture]: /[0-9]+/"))
        let first = m.acceptString("a5b")
        #expect(first)
        let forked = m.fork()
        #expect(caps(forked) == ["v=5"])
        m.reset()
        #expect(caps(m).isEmpty)
        let second = m.acceptString("a6b")
        #expect(second)
        #expect(caps(m) == ["v=6"])
        #expect(caps(forked) == ["v=5"])
    }

    @Test func captureSurvivesEBNFRoundTripAndCache() throws {
        let grammar = try Grammar(lark: "start: \"a\" v \"b\"\nv[capture=\"num\"]: /[0-9]+/")
        let ebnf = grammar.description
        #expect(ebnf.contains("v[capture=\"num\"] ::="))
        var m = matcher(try compiler().compile(try Grammar(ebnf: ebnf)))
        let a = m.acceptString("a77b")
        #expect(a)
        #expect(caps(m) == ["num=77"])
        var cached = matcher(try compiler(cache: true).compile(grammar))
        let b = cached.acceptString("a88b")
        #expect(b)
        #expect(caps(cached) == ["num=88"])
    }

    @Test func captureSerializationRoundTrip() throws {
        let grammar = try Grammar(lark: "start: \"a\" v \"b\"\nv[capture=\"num\"]: /[0-9]+/")
        #expect(try Grammar(serializedJSON: grammar.serializedJSON).description.contains("v[capture=\"num\"] ::="))
    }

    @Test func captureNoCaptureGrammarReturnsEmpty() throws {
        #expect(try captures("start: \"ab\"", "ab").isEmpty)
    }

    @Test func captureWithMaxTokensAnyText() throws {
        var m = matcher(try compileLark(Self.captureBudgetAnyText, Self.maxTokensVocab))
        #expect(accept(&m, [0, 1, 2]))
        #expect(allowed(&m) == [5])
        #expect(accept(&m, [5]) && m.isTerminated)
        #expect(caps(m) == ["r=ab cd "])
    }

    @Test func captureWithMaxTokensCFGBody() throws {
        let source = "start: \"<t>\" r \"</t>\" ans\nr[max_tokens=2, capture=\"think\"]: /([a-z]* )+/\nans[capture]: \"1\""
        var m = matcher(try compileLark(source, Self.maxTokensVocab))
        #expect(accept(&m, [5, 0, 0]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3, 4]) && m.isTerminated)
        #expect(caps(m) == ["think=ab ab ", "ans=1"])
    }

    @Test func captureInsideMaxTokensRegion() throws {
        let source = "start: outer \"1\"\nouter[max_tokens=3]: \"x\" inner\ninner[capture]: /([a-z]* )+/"
        var m = matcher(try compileLark(source, Self.maxTokensVocab))
        #expect(accept(&m, [6, 0, 0]))
        #expect(allowed(&m) == [4])
        #expect(accept(&m, [4]) && m.isTerminated)
        #expect(caps(m) == ["inner=ab ab "])
    }

    @Test func captureWithMaxTokensPerOccurrence() throws {
        let compiled = try compileLark("start: r+ \"1\"\nr[capture, max_tokens=2]: /[a-z]+ /", Self.maxTokensVocab)
        var m = matcher(compiled)
        #expect(accept(&m, [0, 0, 0, 0, 0, 4]) && m.isTerminated)
        #expect(caps(m) == Array(repeating: "r=ab ", count: 5))
        var single = matcher(compiled)
        #expect(accept(&single, [1, 1]))
        #expect(!allowed(&single).contains(4))
        #expect(accept(&single, [2]))
        #expect(allowed(&single).contains(4))
        #expect(accept(&single, [4]) && single.isTerminated)
        #expect(caps(single) == ["r=cdcd "])
    }

    @Test func captureWithMaxTokensRollback() throws {
        let source = "start: \"<t>\" r \"</t>\" ans\nr[max_tokens=2, capture]: /([a-z]* )+/\nans: \"1\""
        var m = matcher(try compileLark(source, Self.maxTokensVocab))
        #expect(accept(&m, [5, 0, 0]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3]))
        m.rollback(2)
        #expect(accept(&m, [1, 2]))
        #expect(allowed(&m) == [3])
        #expect(accept(&m, [3, 4]) && m.isTerminated)
        #expect(caps(m) == ["r=ab cd "])
    }

    @Test func captureWithMaxTokensRoundTripAndCache() throws {
        let grammar = try Grammar(lark: Self.captureBudgetAnyText, tokenizerInfo: info(Self.maxTokensVocab))
        let ebnf = grammar.description
        #expect(ebnf.contains("r[max_tokens=3, capture=\"r\"] ::="))
        #expect(try Grammar(ebnf: ebnf).description.contains("r[max_tokens=3, capture=\"r\"] ::="))
        var m = matcher(try compiler(Self.maxTokensVocab, cache: true).compile(grammar))
        #expect(accept(&m, [0, 1, 2]))
        #expect(allowed(&m) == [5])
        #expect(accept(&m, [5]) && m.isTerminated)
        #expect(caps(m) == ["r=ab cd "])
    }

    // MARK: lazy + capture

    @Test func lazyWithCaptureRecordsCommittedSpan() throws {
        #expect(try captures("start: r rest\nr[lazy, capture]: /[a-z]+/\nrest: /[a-z]*/", "abc") == ["r=a"])
        #expect(try captures("start: r rest\nr[capture]: /[a-z]+/\nrest: /[a-z]*/", "abc") == ["r=abc"])
    }

    @Test func lazyWithCaptureRoundTripAndCache() throws {
        let pieces = ["x", "<t>", ">", "a", "b", "ab"]
        let grammar = try Grammar(lark: "start: \"<\" r \">\"\nr[lazy, capture=\"x\"]: /[a-z]+/", tokenizerInfo: info(pieces))
        let printed = grammar.description
        #expect(printed.contains("r[capture=\"x\", lazy] ::="))
        #expect(try Grammar(ebnf: printed).description.contains("r[capture=\"x\", lazy] ::="))
        #expect(try Grammar(serializedJSON: grammar.serializedJSON).description == printed)
        let compiled = try compiler(pieces, cache: true).compile(grammar)
        var rejected = matcher(compiled)
        let long = rejected.acceptString("<ab>")
        #expect(!long)
        var m = matcher(compiled)
        let short = m.acceptString("<a>")
        #expect(short && m.isTerminated)
        #expect(caps(m) == ["x=a"])
    }

    // MARK: suffix / stop

    @Test(arguments: [("suffix", "outer=ab!!z"), ("stop", "outer=abz")])
    func suffixStopRegexMarkerCaptureAndStopCapture(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=/!!+/, stop_capture=\"marker\"]: /[a-z]*/")
        #expect(try captures(grammar, "ab!!z") == ["marker=!!", "inner=ab", outer])
    }

    @Test(arguments: [("suffix", "outer=baZ"), ("stop", "outer=bZ")])
    func suffixStopRegexMarkerRecoversValidBodySplit(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"Z\"\nr[capture=\"inner\", \(attribute)=/b?a/, stop_capture=\"marker\"]: \"b\"")
        #expect(try captures(grammar, "baZ") == ["marker=a", "inner=b", outer])
    }

    @Test(arguments: [("suffix", "outer=xy!z"), ("stop", "outer=xyz")])
    func suffixStopCaptureScope(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=\"!\"]: /[a-z]*/")
        #expect(try captures(grammar, "xy!z") == ["inner=xy", outer])
    }

    @Test(arguments: [("suffix", "outer=xy💥z"), ("stop", "outer=xyz")])
    func suffixStopCaptureMultibyteMarker(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=\"💥\"]: /[a-z]*/")
        #expect(try captures(grammar, "xy💥z") == ["inner=xy", outer])
    }

    @Test(arguments: [("suffix", "outer=a!b!z"), ("stop", "outer=abz")])
    func suffixStopHiddenEventsWithoutInnerCapture(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: item item \"z\"\nitem[\(attribute)=\"!\"]: /[ab]*/")
        #expect(try captures(grammar, "a!b!z") == [outer])
    }

    @Test(arguments: ["suffix", "stop"], [("\"!\"", "a!z", "!"), ("/!!+/", "a!!z", "!!")])
    func suffixStopAtomicTokenCrossesMarkerAndFollowingRule(_ attribute: String, _ marker: (String, String, String)) throws {
        let (source, value, markerCapture) = marker
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=\(source), stop_capture=\"marker\"]: /a*/",
                                  tokenizerInfo: info([value]))
        var m = matcher(try compiler([value]).compile(grammar))
        #expect(allowed(&m) == [0])
        #expect(accept(&m, [0]) && m.isTerminated)
        #expect(caps(m) == ["marker=\(markerCapture)", "inner=a", "outer=\(attribute == "suffix" ? value : "az")"])
    }

    @Test(arguments: [("suffix", "a!!z", "b!!z"), ("stop", "az", "bz")])
    func suffixStopVariableMarkerMaskCaptureRollbackAndFork(_ attribute: String, _ first: String, _ second: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=/!!+/, stop_capture=\"marker\"]: /[ab]*/")
        var m = matcher(try compiler(["a!!", "b!!", "z", "a!", "!"]).compile(grammar))
        #expect(allowed(&m).contains(0))
        #expect(accept(&m, [0]))
        #expect(allowed(&m) == [2])
        var forked = m.fork()
        m.rollback(1)
        #expect(caps(m).isEmpty)
        #expect(accept(&m, [1, 2]) && m.isTerminated)
        #expect(caps(m) == ["marker=!!", "inner=b", "outer=\(second)"])
        #expect(accept(&forked, [2]) && forked.isTerminated)
        #expect(caps(forked) == ["marker=!!", "inner=a", "outer=\(first)"])
    }

    @Test(arguments: ["suffix", "stop"], [false, true])
    func suffixStopRoundTripSerializationAndCache(_ attribute: String, _ tagDispatch: Bool) throws {
        let source = tagDispatch
            ? "start[capture=\"outer\"]: r\nr[capture=\"inner\", \(attribute)=\"!\"]: TEXT\nTEXT: /(\\n|.)*/"
            : "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=\"!\"]: /[a-z]*/"
        let value = tagDispatch ? "xy!" : "xy!z"
        let outer = tagDispatch ? (attribute == "suffix" ? "xy!" : "xy") : (attribute == "suffix" ? "xy!z" : "xyz")
        let grammar = try Grammar(lark: source)
        let printed = grammar.description
        let hidden = "capture_hidden_\(attribute)_bytes=1"
        #expect(printed.contains(hidden))
        #expect(try Grammar(ebnf: printed).description.contains(hidden))
        let info = try suffixStopInfo(grammar, rule: "r")
        #expect(info[attribute == "suffix" ? 1 : 2] as? Int == 1)
        for candidate in [grammar, try Grammar(ebnf: printed), try Grammar(serializedJSON: grammar.serializedJSON)] {
            #expect(try captures(candidate, value, cache: true) == ["inner=xy", "outer=\(outer)"])
        }
    }

    @Test(arguments: [("suffix", "outer=xy!!z"), ("stop", "outer=xyz")])
    func suffixStopVariableMarkerRoundTripSerializationAndCache(_ attribute: String, _ outer: String) throws {
        let grammar = try Grammar(lark: "start[capture=\"outer\"]: r \"z\"\nr[capture=\"inner\", \(attribute)=END, stop_capture=\"marker\"]: /[a-z]*/\nEND: /!!+/")
        let printed = grammar.description
        #expect(printed.contains("capture_hidden_body_rule_id="))
        #expect(printed.contains("capture_hidden_marker_rule_id="))
        #expect(printed.contains("stop_capture=\"marker\""))
        let info = try suffixStopInfo(grammar, rule: "r")
        #expect((info[3] as? Int ?? -1) >= 0 && (info[4] as? Int ?? -1) >= 0)
        #expect(info[5] as? String == "marker")
        for candidate in [grammar, try Grammar(ebnf: printed), try Grammar(serializedJSON: grammar.serializedJSON)] {
            #expect(try captures(candidate, "xy!!z", cache: true) == ["marker=!!", "inner=xy", outer])
        }
    }

    @Test(arguments: [("suffix", "all=xx<a!>"), ("stop", "all=xx<a>")])
    func suffixStopWithMaxTokensCaptureAndLazy(_ attribute: String, _ all: String) throws {
        let source = "start[capture=\"all\"]: reasoning \"<\" value \">\"\nreasoning[max_tokens=2, capture]: TEXT\nvalue[lazy, capture, \(attribute)=\"!\"]: /[ab]*/\nTEXT: /(\\n|.)*/"
        let grammar = try Grammar(lark: source, tokenizerInfo: info(Self.combinedVocab))
        var m = matcher(try compiler(Self.combinedVocab).compile(grammar))
        for token: Int32 in [0, 0] {
            #expect(allowed(&m).contains(token))
            #expect(accept(&m, [token]))
        }
        #expect(allowed(&m) == [1])
        #expect(accept(&m, [1]))
        #expect(allowed(&m).contains(3))
        #expect(accept(&m, [3]))
        #expect(allowed(&m) == [2])
        #expect(accept(&m, [2]) && m.isTerminated)
        #expect(caps(m) == ["reasoning=xx", "value=a", all])
    }

    @Test(arguments: [("suffix", "all=ab!>"), ("stop", "all=ab>")])
    func suffixStopSameRuleMaxTokens(_ attribute: String, _ markerOuter: String) throws {
        let source = "start[capture=\"all\"]: value \">\"\nvalue[max_tokens=2, capture=\"body\", \(attribute)=\"!\", stop_capture=\"marker\"]: /[ab]*/"
        let original = try Grammar(lark: source, tokenizerInfo: info(Self.combinedVocab))
        #expect(original.description.contains("max_tokens=2"))
        #expect(original.description.contains("capture_hidden_body_rule_id="))
        let compiled = try compiler(Self.combinedVocab).compile(try Grammar(serializedJSON: original.serializedJSON))

        var marker = matcher(compiled)
        #expect(accept(&marker, [3]))
        #expect(allowed(&marker) == [2])
        #expect(accept(&marker, [2]) && marker.isTerminated)
        #expect(caps(marker) == ["marker=!", "body=a", attribute == "suffix" ? "all=a!>" : "all=a>"])

        var m = matcher(compiled)
        #expect(accept(&m, [5, 6]))
        #expect(allowed(&m) == [2])
        let rejected = m.acceptToken(0)
        #expect(!rejected)
        #expect(allowed(&m) == [2])
        var forked = m.fork()
        #expect(accept(&m, [2]) && m.isTerminated)
        #expect(caps(m) == ["body=ab", "all=ab>"])
        #expect(accept(&forked, [2]) && forked.isTerminated)
        #expect(caps(forked) == ["body=ab", "all=ab>"])

        m.rollback(2)
        #expect(accept(&m, [4, 2]) && m.isTerminated)
        #expect(caps(m) == ["marker=!", "body=ab", markerOuter])
    }

    @Test(arguments: [("suffix", "all=a!!>"), ("stop", "all=a>")])
    func suffixStopMaxTokensMarkerCrossesTokenBoundary(_ attribute: String, _ outer: String) throws {
        let source = "start[capture=\"all\"]: value \">\"\nvalue[max_tokens=1, capture=\"body\", \(attribute)=END, stop_capture=\"marker\"]: /[ab]*/\nEND: /!!+/"
        let grammar = try Grammar(lark: source, tokenizerInfo: info(Self.combinedVocab))
        var m = matcher(try compiler(Self.combinedVocab).compile(grammar))
        #expect(accept(&m, [3]))
        #expect(allowed(&m) == [7])
        #expect(accept(&m, [7]))
        #expect(allowed(&m) == [2])
        #expect(accept(&m, [2]) && m.isTerminated)
        #expect(caps(m) == ["marker=!!", "body=a", outer])
    }
}
