// Ports of upstream tests/python/test_lark.py cases not covered by LarkTests.swift, the
// Lark.json fixture, LarkDynamicTests.swift or LarkMarkerTests.swift: named and nested
// grammars, serialization/EBNF round trips, special-token sets, lazy masks and located errors.
import Testing
@testable import TGrammar

@Suite("Lark language (upstream)")
struct LarkLanguageUpstreamTests {
    // Tokens: 0 "<", 1 ">", 2 "a", 3 "b", 4 "ab", 5 "abb", 6 " "
    static let lazyPieces = ["<", ">", "a", "b", "ab", "abb", " "]
    // Tokens: 0 "<", 1 ">", 2 "a", 3 "b", 4 "ab", 5 "a>", 6 "ab>", 7 "b>", 8 "bb", 9 " "
    static let lazyMaskPieces = ["<", ">", "a", "b", "ab", "a>", "ab>", "b>", "bb", " "]
    // Tokens: 0 "x", 1 "<t>", 2 ">", 3 "a", 4 "b", 5 "ab"
    static let combinedPieces = ["x", "<t>", ">", "a", "b", "ab"]
    static let allThreeGrammar = """
        start: reasoning "<t>" val ">"
        reasoning[max_tokens=2, capture]: TEXT
        val[lazy, capture="value"]: /[ab]+/
        TEXT: /(\\n|.)*/
        """

    private static func info(_ pieces: [String] = []) throws -> TokenizerInfo { try TokenizerInfo(encodedVocab: pieces) }

    private static func matcher(_ grammar: Grammar, _ pieces: [String] = []) throws -> GrammarMatcher {
        GrammarMatcher(try GrammarCompiler(tokenizerInfo: info(pieces), cacheEnabled: false).compile(grammar), terminateWithoutStopToken: true)
    }

    private static func matches(_ compiled: CompiledGrammar, _ value: String) -> Bool {
        var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
        return matcher.acceptString(value) && matcher.isTerminated
    }

    private static func expectLanguage(_ grammar: Grammar, _ accepted: [String], _ rejected: [String], pieces: [String] = [],
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let compiled = try GrammarCompiler(tokenizerInfo: info(pieces), cacheEnabled: false).compile(grammar)
        for value in accepted { #expect(matches(compiled, value), "\(value)", sourceLocation: sourceLocation) }
        for value in rejected { #expect(!matches(compiled, value), "\(value)", sourceLocation: sourceLocation) }
    }

    private static func expectLanguage(lark: String, _ accepted: [String], _ rejected: [String],
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        try expectLanguage(Grammar(lark: lark), accepted, rejected, sourceLocation: sourceLocation)
    }

    private static func expectTokenLanguage(_ lark: String, pieces: [String], _ accepted: [[Int32]], _ rejected: [[Int32]],
                                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let compiled = try GrammarCompiler(tokenizerInfo: info(pieces), cacheEnabled: false).compile(lark: lark)
        func run(_ tokens: [Int32]) -> Bool {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            for token in tokens where !matcher.acceptToken(token) { return false }
            return matcher.isTerminated
        }
        for tokens in accepted { #expect(run(tokens), "\(tokens)", sourceLocation: sourceLocation) }
        for tokens in rejected { #expect(!run(tokens), "\(tokens)", sourceLocation: sourceLocation) }
    }

    /// `_assert_lark_error`: `Grammar.from_lark` fails with a located Lark error containing `message`.
    @discardableResult
    private static func expectLarkError(_ lark: String, _ message: String, pieces: [String]? = nil,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let tokenizer = try pieces.map { try info($0) }
        do {
            _ = try Grammar(lark: lark, tokenizerInfo: tokenizer)
            Issue.record("expected error containing \(message)", sourceLocation: sourceLocation)
            return ""
        } catch {
            let text = String(describing: error)
            #expect(text.contains(message), "\(text)", sourceLocation: sourceLocation)
            #expect(text.contains("Lark error at line ") && text.contains(", column "), "\(text)", sourceLocation: sourceLocation)
            return text
        }
    }

    private static func allowed(_ matcher: inout GrammarMatcher) -> [Int32] { matcher.nextTokenBitmask().allowedTokenIDs }

    // test_compile_lark_named_grammar_argument_validation: not applicable (Python TypeError checks;
    // `[String: NamedGrammar]` enforces the dictionary, key and value types statically).

    @Test func structuredRegexRoundTripAndSerialization() throws {
        let grammar = try Grammar(lark: #"start: "A" %regex {"substring_chunks":["foo"," bar"," baz"]} "B""#)
        let accepted = ["AB", "AfooB", "A bar bazB", "Afoo bar bazB"], rejected = ["AfoB", "Afoo bazB"]
        try Self.expectLanguage(grammar, accepted, rejected)
        try Self.expectLanguage(Grammar(ebnf: grammar.description), accepted, rejected)
        try Self.expectLanguage(Grammar(serializedJSON: grammar.serializedJSON), accepted, rejected)
    }

    @Test func nestedLarkHasAnIndependentNamespace() throws {
        try Self.expectLanguage(lark: """
            start: item %lark {
              start: item
              item: "b"
            } item
            item: "a"
            """, ["aba"], ["aaa", "abb", "bbb"])
    }

    @Test func nestedLarkSupportsRecursionJSONAndIgnore() throws {
        try Self.expectLanguage(lark: #"""
            start: "[" %lark {
              %grammar_options {"allow_initial_skip": true}
              %import common.WS
              %ignore WS
              start: item ":" %json {"type":"integer"}
              item: "x" | "(" item ")"
            } "]"
            """#, ["[x:1]", "[ ((x)) : -2 ]"], ["[():1]", #"[x:"1"]"#, "[x 1]"])
    }

    @Test func multipleNestedGrammars() throws {
        try Self.expectLanguage(lark: #"start: %lark { start: "a" | "b" } %lark { start: "1" | "2" }"#,
                                ["a1", "a2", "b1", "b2"], ["", "a", "1a", "c1"])
    }

    @Test(arguments: [
        ("start: <[0-2,1-3,3]>", [[Int32(0)], [1], [2], [3]], [[Int32(4)]]),
        ("start: <[^1,3]>", [[0], [2], [4]], [[1], [3]]),
        ("start: <[*]>", [[0], [1], [2], [3], [4]], []),
        ("start: <[0]> <[2-3]>", [[0, 2], [0, 3]], [[0], [2, 0]]),
    ])
    func numericSpecialTokenSets(_ grammar: String, _ accepted: [[Int32]], _ rejected: [[Int32]]) throws {
        try Self.expectTokenLanguage(grammar, pieces: ["a", "b", "c", "d", "e"], accepted, rejected)
    }

    @Test func regexFlagsEBNFAndSerializationRoundTrip() throws {
        let grammar = try Grammar(lark: "start: /Żółw[^k]/isu")
        let accepted = ["Żółwz", "ŻółwZ", "Żółw\n"], rejected = ["żółwz", "Żółwk", "ŻółwK", "Żółw"]
        try Self.expectLanguage(grammar, accepted, rejected)
        try Self.expectLanguage(Grammar(ebnf: grammar.description), accepted, rejected)
        try Self.expectLanguage(Grammar(serializedJSON: grammar.serializedJSON), accepted, rejected)
    }

    @Test func grammarUnionAndConcatIntegration() throws {
        let left = try Grammar(lark: #"start: "a" | "b""#), right = try Grammar(lark: "start: /[0-9]+/")
        try Self.expectLanguage(Grammar.union([left, right]), ["a", "b", "0", "123"], ["a1", "c"])
        try Self.expectLanguage(Grammar.concatenating([left, right]), ["a0", "b123"], ["a", "1", "c1"])
    }

    @Test func namedGrammarReferences() throws {
        let item = try Grammar(lark: #"start: "x" | "y""#)
        let grammar = try Grammar(lark: #"start: "[" @item ("," @item)* "]""#, namedGrammars: ["item": .grammar(item)])
        try Self.expectLanguage(grammar, ["[x]", "[y,x]", "[x,y,x]"], ["[]", "[z]", "[x,]"])
    }

    @Test func namedGrammarReferenceInNestedLark() throws {
        let value = try Grammar(regex: "[0-9]+")
        let grammar = try Grammar(lark: #"start: "outer:" %lark { start: "inner:" @value }"#, namedGrammars: ["value": .grammar(value)])
        try Self.expectLanguage(grammar, ["outer:inner:0", "outer:inner:123"], ["inner:1", "outer:1"])
    }

    @Test func namedGrammarStringCycle() {
        do {
            _ = try Grammar(lark: "start: @left", namedGrammars: ["left": .lark("start: @right"), "right": .lark("start: @left")])
            Issue.record("expected a circular reference error")
        } catch {
            #expect(String(describing: error).contains("circular named grammar reference: @left -> @right -> @left"), "\(error)")
        }
    }

    /// Only the last case of test_lark_named_grammar_argument_validation applies; the others are
    /// Python TypeError checks enforced statically by `[String: NamedGrammar]`.
    @Test func namedGrammarArgumentValidation() throws {
        let item = try Grammar(lark: #"start: "x""#)
        do {
            _ = try Grammar(lark: "start: @item", namedGrammars: ["bad name": .grammar(item)])
            Issue.record("expected an invalid name error")
        } catch {
            #expect(String(describing: error).contains("Invalid named grammar name"), "\(error)")
        }
    }

    @Test func largeChoiceGrammar() throws {
        let options = (0 ..< 256).map { "option-" + String(repeating: "0", count: max(0, 3 - String($0).count)) + String($0) }
        let grammar = "start: option\noption: " + options.map { "\"\($0)\"" }.joined(separator: " | ")
        try Self.expectLanguage(lark: grammar, [options[0], options[127], options[255]], ["", "option-256", "option-12"])
    }

    static let errorCases: [(id: String, grammar: String, message: String)] = [
        ("missing-start", "item: \"a\"", "no start rule"),
        ("unknown-rule", "start: missing", "unknown name 'missing'"),
        ("duplicate-rule", "start: foo\nfoo: \"a\"\nfoo: \"b\"", "duplicate rule or terminal 'foo'"),
        ("duplicate-terminal", "start: FOO\nFOO: \"a\"\nFOO: \"b\"", "duplicate rule or terminal 'FOO'"),
        ("terminal-cycle", "start: FOO\nFOO: BAR\nBAR: FOO", "circular reference in terminal"),
        ("terminal-references-rule", "start: TOKEN\nTOKEN: rule\nrule: \"a\"", "terminal 'TOKEN' cannot reference rule 'rule'"),
        ("unknown-attribute", "start[budget=10]: \"a\"", "attribute 'budget' is not supported"),
        ("empty-capture-name", "start[capture=\"\"]: \"a\"", "capture name must not be empty"),
        ("invalid-capture-name", "start[capture=\"a b\"]: \"a\"", "capture name must only contain letters, digits"),
        ("duplicate-capture-attribute", "start[capture, capture]: \"a\"", "capture attribute is specified more than once"),
        ("terminal-attribute", "TOKEN[lazy]: /a/\nstart: TOKEN", "attributes are only supported on rules"),
        ("priority", "start.1: \"a\"", "priorities are not supported"),
        ("template-definition", "start{x}: \"a\"", "Lark templates are not supported"),
        ("template-reference", "start: foo{x}\nfoo: \"a\"", "Lark templates are not supported"),
        ("parametric-definition", "start::0: \"a\"", "parametric grammar is not supported"),
        ("parametric-reference", "start: foo::0", "parametric grammar is not supported"),
        ("parametric-if", "start: \"a\" %if enabled", "parametric %if conditions are not supported"),
        ("intersection", "start: A & B\nA: \"a\"\nB: \"b\"", "intersection '&' is not supported"),
        ("complement", "start: ~/[a]/", "complement '~' is not supported"),
        ("non-ascii-string-flag", "start: \"\\u00c4\"i", "case-insensitive string literals currently support ASCII characters only"),
        ("unsupported-regex-flag", "start: /abc/m", "regular-expression flag 'm' is not supported"),
        ("unsupported-l-flag", "start: /abc/l", "regular-expression flag 'l' is not supported"),
        ("unsupported-verbose-regex-flag", "start: /abc/x", "regular-expression flag 'x' is not supported"),
        ("case-insensitive-regex-suffix", "start: item\nitem[suffix=/end/i]: /[a-z]*/", "regular-expression flag 'i' is not supported with suffix or stop attributes"),
        ("range-start-flag", "start: \"a\"i..\"z\"", "flags are not allowed on character ranges"),
        ("range-end-flag", "start: \"a\"..\"z\"i", "flags are not allowed on character ranges"),
        ("invalid-regex", "start: /[abc/", "failed to compile regular expression"),
        ("regex-word-boundary-error", "start: /a\\b/i", "Word boundary assertion"),
        ("regex-unicode-property-error", "start: /\\p{L}/i", "Unicode property escape"),
        ("regex-backreference-error", "start: /(a)\\1/i", "Backreference"),
        ("regex-empty-class-error", "start: /[]/i", "Empty character class"),
        ("regex-lookbehind-error", "start: /(?<=a)b/i", "Lookbehind assertion"),
        ("regex-bad-unicode-escape-error", "start: /\\uZZ/i", "must be followed by four hexadecimal digits"),
        ("invalid-string-escape", "start: \"\\q\"", "invalid string literal"),
        ("unterminated-string", "start: \"unterminated", "unterminated string literal"),
        ("unterminated-regex", "start: /unterminated", "unterminated regular expression"),
        ("unterminated-special-token", "start: <unterminated", "unterminated special token"),
        ("special-token-whitespace", "start: <bad token>", "invalid special token"),
        ("empty-grammar-reference", "start: @", "empty grammar reference"),
        ("unexpected-character", "start: $", "unexpected character '$'"),
        ("unexpected-minus", "start: -", "unexpected '-' character"),
        ("unexpected-bang", "start: !", "unexpected '!' character"),
        ("missing-colon", "start \"a\"", "expected ':' after rule name"),
        ("unclosed-group", "start: (\"a\"", "expected ')' after group"),
        ("unclosed-optional", "start: [\"a\"", "expected ']' after optional group"),
        ("missing-alias-name", "start: \"a\" ->", "expected alias name after '->'"),
        ("declare-directive", "%declare TOKEN\nstart: TOKEN", "directive %declare is not supported"),
        ("override-directive", "%override start\nstart: \"a\"", "directive %override is not supported"),
        ("unknown-common-import", "%import common.UNKNOWN\nstart: UNKNOWN", "unknown common import"),
        ("import-name-conflict", "%import common.INT\nINT: \"x\"\nstart: INT", "duplicate rule or terminal 'INT'"),
        ("repetition-reversed", "start: \"a\"{3,2}", "repetition end must be greater"),
        ("negative-repetition", "start: \"a\"{-1,}", "invalid repetition count"),
        ("repetition-overflow", "start: \"a\"{999999999999999999999}", "invalid repetition count"),
        ("range-start-too-long", "start: \"ab\"..\"c\"", "range endpoints must be one character"),
        ("range-end-too-long", "start: \"a\"..\"bc\"", "range endpoints must be one character"),
        ("range-reversed", "start: \"z\"..\"a\"", "range start must not exceed end"),
        ("malformed-json-directive", "start: %json {", "failed to parse JSON value after %json"),
        ("invalid-json-schema", "start: %json []", "failed to compile inline JSON schema"),
        ("nested-no-start", "start: %lark { item: \"a\" }", "failed to compile nested Lark grammar"),
        ("substring-words", "start: %regex {\"substring_words\":\"abc def\"}", "substring_words is not supported yet"),
        ("structured-regex-not-object", "start: %regex []", "%regex value must be an object"),
        ("structured-regex-unknown-field", "start: %regex {\"unknown\":\"abc\"}", "unknown field 'unknown' in %regex"),
        ("structured-regex-no-fields", "start: %regex {}", "no fields set on %regex"),
        ("structured-regex-multiple-fields", "start: %regex {\"substring_chars\":\"abc\",\"substring_chunks\":[\"a\"]}", "only one field can be set on %regex"),
        ("structured-regex-chars-type", "start: %regex {\"substring_chars\":[\"a\"]}", "substring_chars must be a string"),
        ("structured-regex-chunks-type", "start: %regex {\"substring_chunks\":\"abc\"}", "substring_chunks must be an array of strings"),
        ("structured-regex-chunk-type", "start: %regex {\"substring_chunks\":[\"a\",1]}", "substring_chunks must be an array of strings"),
        ("unknown-named-grammar", "start: @other", "unknown named grammar '@other'"),
        ("special-in-terminal", "start: TOKEN\nTOKEN: <[1]>", "special tokens cannot be used in terminals"),
        ("json-in-terminal", "start: TOKEN\nTOKEN: %json {}", "%json cannot be used in terminals"),
        ("nested-lark-in-terminal", "start: TOKEN\nTOKEN: %lark { start: \"a\" }", "nested %lark cannot be used in terminals"),
        ("multiple-range-dashes", "start: <[1-2-3]>", "invalid numeric special-token range"),
        ("numeric-range-reversed", "start: <[3-1]>", "invalid numeric special-token range"),
        ("empty-token-range", "start: <[,]>", "empty numeric special-token range"),
        ("wildcard-needs-tokenizer", "start: <[*]>", "wildcard special token requires tokenizer_info"),
        ("negated-wildcard", "start: <[^*]>", "negated wildcard special token is not supported"),
        ("mixed-wildcard-range", "start: <[*,1]>", "wildcard cannot be mixed"),
        ("named-needs-tokenizer", "start: <|tool|>", "named special token <|tool|> requires tokenizer_info"),
        ("token-range-too-large", "start: <[0-1000001]>", "special-token range is too large"),
        ("initial-skip-type", "%grammar_options {\"allow_initial_skip\": 1}\nstart: \"a\"", "allow_initial_skip must be a boolean"),
        ("no-forcing-option", "%grammar_options {\"no_forcing\": true}\nstart: \"a\"", "%grammar_options option 'no_forcing' is not supported"),
        ("invalid-utf8-option", "%grammar_options {\"allow_invalid_utf8\": true}\nstart: \"a\"", "%grammar_options option 'allow_invalid_utf8' is not supported"),
        ("unknown-grammar-options-option", "%grammar_options {\"unknown\": false}\nstart: \"a\"", "unknown %grammar_options option 'unknown'"),
        ("grammar-options-not-object", "%grammar_options []\nstart: \"a\"", "%grammar_options value must be an object"),
        ("lazy-rule-reference", "start: thing\nthing[lazy]: \"a\" thing | \"b\"", "terminal cannot reference rule"),
        ("empty-suffix", "start: head\nhead[suffix=\"\"]: TEXT\nTEXT: /(\\n|.)*/", "suffix must not be empty"),
        ("lowercase-suffix-terminal", "start: head\nhead[suffix=end]: TEXT\nTEXT: /(\\n|.)*/", "suffix terminal name must be uppercase"),
        ("duplicate-suffix", "start: head\nhead[suffix=\"x\",suffix=\"y\"]: TEXT\nTEXT: /(\\n|.)*/", "suffix attribute is specified more than once"),
        ("unknown-suffix-terminal", "start: head\nhead[suffix=MISSING]: TEXT\nTEXT: /(\\n|.)*/", "unknown name 'MISSING'"),
        ("empty-stop", "start: head\nhead[stop=\"\"]: TEXT\nTEXT: /(\\n|.)*/", "stop must not be empty"),
        ("lowercase-stop-terminal", "start: head\nhead[stop=end]: TEXT\nTEXT: /(\\n|.)*/", "stop terminal name must be uppercase"),
        ("duplicate-stop", "start: head\nhead[stop=\"x\",stop=\"y\"]: TEXT\nTEXT: /(\\n|.)*/", "stop attribute is specified more than once"),
        ("stop-capture-without-marker", "start: head\nhead[stop_capture=\"marker\"]: TEXT\nTEXT: /(\\n|.)*/", "stop_capture requires stop or suffix"),
        ("invalid-stop-capture-name", "start: head\nhead[stop=\"x\", stop_capture=\"bad name\"]: TEXT\nTEXT: /(\\n|.)*/", "capture name must only contain"),
        ("non-string-stop-capture", "start: head\nhead[stop=\"x\", stop_capture=MARKER]: TEXT\nTEXT: /(\\n|.)*/", "expected string literal after stop_capture="),
        ("duplicate-stop-capture", "start: head\nhead[stop=\"x\", stop_capture=\"a\", stop_capture=\"b\"]: TEXT\nTEXT: /(\\n|.)*/", "stop_capture attribute is specified more than once"),
        ("stop-then-suffix", "start: head\nhead[stop=\"x\", suffix=\"y\"]: TEXT\nTEXT: /(\\n|.)*/", "suffix cannot be combined with stop"),
        ("suffix-then-stop", "start: head\nhead[suffix=\"y\", stop=\"x\"]: TEXT\nTEXT: /(\\n|.)*/", "stop cannot be combined with suffix"),
        ("stop-on-terminal", "STOP[stop=\"x\"]: /a/\nstart: STOP", "attributes are only supported on rules"),
        ("standalone-lazy-regex-suffix", "start: head\nhead[lazy]: /(\\n|.)*END/", "lazy regex suffix is only supported on a head used by dynamic dispatch"),
        ("unknown-ignore-name", "%ignore MISSING\nstart: \"a\"", "unknown name 'MISSING'"),
        // test_lark_max_tokens_rejected_on_dispatch_rules
        ("max-tokens-on-dispatch-rule", "start: tool* tail\ntail: TEXT\ntool_head[lazy]: TEXT \"<t>\"\ntool[max_tokens=3]: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "max_tokens is not supported on rules consumed by dynamic dispatch"),
        // test_lark_capture_on_dispatch_consumed_rule_is_rejected
        ("capture-on-dispatch-rule", "start: tool* tail\ntail: TEXT\ntool_head[lazy]: TEXT \"<t>\"\ntool[capture]: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "capture is not supported on rules consumed by dynamic dispatch"),
        // Same check (lark_converter.cc) on the head and tail, which dispatch also consumes.
        ("capture-on-dispatch-head", "start: tool* tail\ntail: TEXT\ntool_head[lazy, capture=\"h\"]: TEXT \"<t>\"\ntool: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "capture is not supported on rules consumed by dynamic dispatch"),
        ("max-tokens-on-dispatch-tail", "start: tool* tail\ntail[max_tokens=2]: TEXT\ntool_head[lazy]: TEXT \"<t>\"\ntool: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "max_tokens is not supported on rules consumed by dynamic dispatch"),
        ("max-tokens-on-dispatch-start", "start[max_tokens=4]: tool* tail\ntail: TEXT\ntool_head[lazy]: TEXT \"<t>\"\ntool: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "max_tokens is not supported on a dynamic dispatch start rule"),
        // Upstream skips dispatch for a temperature start and compiles its body as a terminal.
        ("temperature-on-dispatch-shaped-start", "start[temperature=0.5]: tool* tail\ntail: TEXT\ntool_head[lazy]: TEXT \"<t>\"\ntool: tool_head /[0-9]+/ \"</t>\"\nTEXT: /(\\n|.)*/", "temperature is only supported on terminals and subgrammars"),
    ]

    /// Rows where TGrammar diverges from upstream (see the file's final report for details).
    /// Rows where TGrammar diverges from upstream.
    static let knownErrorDivergences: [String: String] = [:]

    @Test(arguments: errorCases.indices)
    func errorsAreExplicitAndLocated(_ index: Int) throws {
        let row = Self.errorCases[index]
        if let diagnosis = Self.knownErrorDivergences[row.id] {
            withKnownIssue("\(row.id): \(diagnosis)") { try Self.expectLarkError(row.grammar, row.message) }
        } else {
            try Self.expectLarkError(row.grammar, row.message)
        }
    }

    @Test func namedSpecialTokenErrorWithTokenizer() throws {
        try Self.expectLarkError("start: <unknown>", "unknown special token <unknown>", pieces: ["<known>", "text"])
    }

    @Test func dynamicTriggerLevelsCannotBeMixed() throws {
        try Self.expectLarkError(#"""
            start: (foo | bar)* tail
            tail: TEXT
            foo_head[lazy]: TEXT "<foo>"
            foo: foo_head "x"
            bar: TEXT <|bar|> "x"
            TEXT: /(\n|.)*/
            """#, "cannot mix string and token triggers", pieces: ["<|bar|>", "x"])
    }

    @Test func errorReportsCRLFLineColumnAndSourceContext() throws {
        let error = try Self.expectLarkError("# comment\r\nstart: \"a\"\r\nitem missing", "expected ':' after rule name")
        #expect(error.contains("line 3, column 6"), "\(error)")
        #expect(error.contains("item missing"), "\(error)")
        #expect(error.contains("     ^"), "\(error)")
    }

    @Test func ebnfLazyCommittedShortestAndPlusDesugar() throws {
        for body in ["[a-z] [a-z]*", "[a-z]+"] {
            try Self.expectLanguage(Grammar(ebnf: "root ::= \"<\" r \">\"\nr[lazy] ::= \(body)"), ["<a>"], ["<ab>", "<>"])
        }
    }

    @Test func lazyMaskIsExitOnlyAfterCommit() throws {
        let grammar = try Grammar(lark: "start: \"<\" r \"b\"\nr[lazy]: /[ab]+/")
        var matcher = try Self.matcher(grammar, Self.lazyPieces)
        let open = matcher.acceptToken(0)
        #expect(open)
        // "ab" = one region char then the closing literal; "abb" would extend the region past the commit.
        let allowed = Self.allowed(&matcher)
        #expect(allowed.contains(4) && !allowed.contains(5), "\(allowed)")
        let close = matcher.acceptToken(4)
        #expect(close && matcher.isTerminated)
        matcher = try Self.matcher(grammar, Self.lazyPieces)
        let first = matcher.acceptToken(0), second = matcher.acceptToken(2)
        #expect(first && second)
        #expect(Self.allowed(&matcher) == [3])
    }

    @Test func lazyRootAnchoredOccurrence() throws {
        let grammar = try Grammar(lark: "start: \"<\" r\nr[lazy]: /[a-z]+/")
        var matcher = try Self.matcher(grammar, Self.lazyPieces)
        let first = matcher.acceptToken(0), second = matcher.acceptToken(2)
        #expect(first && second)
        #expect(Self.allowed(&matcher) == [])
        try Self.expectLanguage(grammar, ["<a"], ["<ab", "<"])
    }

    @Test func lazyNonTerminalLikeBodiesAreRejected() throws {
        try Self.expectLarkError("start: \"<\" r \">\"\nr[lazy]: \"a\" r | \"b\"", "terminal cannot reference rule")
        try Self.expectLarkError("start: r\nR[lazy]: /[a-z]+/\nr: R", "attributes are only supported")
        let grammars = [
            (try Grammar(lark: "start: \"<\" r \">\"\nr[lazy]: /([a-z]+ )+/"), true),
            (try Grammar(lark: "start: \"<\" r \">\"\nr[lazy]: T* \"x\"\nT: /ab/"), true),
            (try Grammar(ebnf: "root ::= \"<\" r \">\"\nr[lazy] ::= sub\nsub ::= sub [a-z] | [a-z]"), false),
        ]
        for (grammar, diverges) in grammars {
            withKnownIssue("lazy body compiles: Swift flattens Lark terminal compositions and regexes into one FSM, whereas upstream builds rule references (FromRegex repeat rules, T*) that fail its terminal-like check") {
                do {
                    _ = try GrammarCompiler(tokenizerInfo: Self.info(Self.lazyPieces), cacheEnabled: false).compile(grammar)
                    Issue.record("expected a terminal-like error for \(grammar)")
                } catch {
                    #expect(String(describing: error).contains("terminal-like"), "\(error)")
                }
            } when: { diverges }
        }
    }

    @Test func lazyMaskChoicesCommitKillsLongerAlternative() throws {
        var matcher = try Self.matcher(Grammar(lark: "start: \"<\" r \">\"\nr[lazy]: \"ab\" | \"abb\""), Self.lazyMaskPieces)
        let first = matcher.acceptToken(0), second = matcher.acceptToken(2)
        #expect(first && second)
        #expect(Self.allowed(&matcher) == [3, 7])
        let longer = matcher.acceptToken(8)
        #expect(!longer)
        let close = matcher.acceptToken(7)
        #expect(close && matcher.isTerminated)
    }

    @Test func ebnfLazyMaskMatchesLarkForm() throws {
        var matcher = try Self.matcher(Grammar(ebnf: "root ::= \"<\" r \">\"\nr[lazy] ::= [a-z] [a-z]*"), Self.lazyMaskPieces)
        let open = matcher.acceptToken(0)
        #expect(open)
        #expect(Self.allowed(&matcher) == [2, 3, 5, 7])
        let body = matcher.acceptToken(2)
        #expect(body)
        #expect(Self.allowed(&matcher) == [1])
    }

    @Test func ebnfAllThreeAttributesRoundTrip() throws {
        let grammar = try Grammar(ebnf: "root ::= \"<\" r \">\"\nr[max_tokens=3, capture=\"x\", lazy] ::= [a-z] [a-z]*")
        #expect(grammar.description.contains("r[max_tokens=3, capture=\"x\", lazy] ::="), "\(grammar)")
        let reordered = try Grammar(ebnf: "root ::= \"<\" r \">\"\nr[lazy, capture=\"x\", max_tokens=3] ::= [a-z] [a-z]*")
        #expect(reordered.description == grammar.description)
        #expect(try Grammar(serializedJSON: grammar.serializedJSON).description == grammar.description)
    }

    @Test func allThreeFeaturesSerializationRoundTrip() throws {
        let grammar = try Grammar(lark: Self.allThreeGrammar, tokenizerInfo: Self.info(Self.combinedPieces))
        let printed = grammar.description
        #expect(printed.contains("reasoning[max_tokens=2, capture=\"reasoning\"] ::="), "\(printed)")
        #expect(printed.contains("val[capture=\"value\", lazy] ::="), "\(printed)")
        var matcher = try Self.matcher(Grammar(serializedJSON: grammar.serializedJSON), Self.combinedPieces)
        let one = matcher.acceptToken(0), two = matcher.acceptToken(0)
        #expect(one && two)
        #expect(Self.allowed(&matcher) == [1])
        for token: Int32 in [1, 3, 2] {
            let accepted = matcher.acceptToken(token)
            #expect(accepted)
        }
        #expect(matcher.isTerminated)
        #expect(matcher.captures().map(\.name) == ["reasoning", "value"])
        #expect(matcher.captures().map(\.text) == ["xx", "a"])
    }

    /// test_json_directive_depth_is_bounded_per_value. Brackets outside the %json value must not
    /// count towards its depth. The second half (`xgr.max_recursion_depth(50)` rejecting a 60-deep
    /// value) has no counterpart: TGrammar bounds nesting by stack usage, not a configurable depth.
    @Test func jsonDirectiveDepthIsBoundedPerValue() throws {
        _ = try Grammar(lark: "start: %json true\n# " + String(repeating: "[", count: 100))
    }

}
