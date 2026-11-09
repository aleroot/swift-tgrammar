// Port of the grammar-language tests of xgrammar's EBNF-level pytest modules
// (test_grammar_{regex,substring}_macro.py, test_grammar_union_concat.py,
// test_grammar_parser{,_macro}.py, test_grammar_matcher_ebnf.py, test_json_schema_converter.py,
// test_structural_tag_converter.py). Each fixture row names how upstream built a grammar (a
// "recipe") and what upstream expected of it.

import Foundation
import Testing

@testable import TGrammar

indirect enum Recipe: Decodable, Sendable, CustomStringConvertible {
    case ebnf(String, root: String, normalized: Bool)
    case regex(String)
    case jsonSchema(String, JSONSchemaOptions)
    case builtinJSON
    case structuralTag(String)
    case lark(String)
    case union([Recipe])
    case concat([Recipe])
    case reparse(Recipe, root: String)
    case roundtrip(Recipe)

    private enum Key: String, CodingKey {
        case kind, source, root, of, anyWhitespace, indent, separators, strict, maxWhitespaceCount, anyOrder
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "ebnf": self = .ebnf(try c.decode(String.self, forKey: .source), root: try c.decode(String.self, forKey: .root), normalized: true)
        case "ebnf_raw": self = .ebnf(try c.decode(String.self, forKey: .source), root: try c.decode(String.self, forKey: .root), normalized: false)
        case "regex": self = .regex(try c.decode(String.self, forKey: .source))
        case "builtin_json": self = .builtinJSON
        case "structural_tag": self = .structuralTag(try c.decode(String.self, forKey: .source))
        case "lark": self = .lark(try c.decode(String.self, forKey: .source))
        case "json_schema":
            let separators = try c.decodeIfPresent([String].self, forKey: .separators)
            let indent = try c.decodeIfPresent(Int.self, forKey: .indent)
            let options = JSONSchemaOptions(anyWhitespace: try c.decode(Bool.self, forKey: .anyWhitespace),
                                            strict: try c.decode(Bool.self, forKey: .strict),
                                            anyOrder: try c.decode(Bool.self, forKey: .anyOrder),
                                            maxWhitespaceCount: try c.decodeIfPresent(Int.self, forKey: .maxWhitespaceCount),
                                            indent: indent, itemSeparator: separators?[0], keySeparator: separators?[1])
            self = .jsonSchema(try c.decode(String.self, forKey: .source), options)
        case "union": self = .union(try c.decode([Recipe].self, forKey: .of))
        case "concat": self = .concat(try c.decode([Recipe].self, forKey: .of))
        case "reparse": self = .reparse(try c.decode(Recipe.self, forKey: .of), root: try c.decodeIfPresent(String.self, forKey: .root) ?? "root")
        case "roundtrip": self = .roundtrip(try c.decode(Recipe.self, forKey: .of))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown recipe \(kind)")
        }
    }

    /// The grammar, built as upstream does; `tokenizerInfo` resolves token references in
    /// structural tags and Lark (upstream's compiler passes its vocabulary).
    func build(tokenizerInfo: TokenizerInfo? = nil) throws -> Grammar {
        switch self {
        case let .ebnf(source, root, normalized):
            normalized ? try Grammar(ebnf: source, rootRule: root) : try GrammarTesting.parseWithoutNormalization(source, rootRule: root)
        case let .regex(source): try Grammar(regex: source)
        case let .jsonSchema(source, options): try Grammar(jsonSchema: source, options: options)
        case .builtinJSON: Grammar.builtinJSON
        case let .structuralTag(source): try Grammar(structuralTagJSON: source, tokenizerInfo: tokenizerInfo)
        case let .lark(source): try Grammar(lark: source, tokenizerInfo: tokenizerInfo)
        case let .union(parts): try Grammar.union(parts.map { try $0.build(tokenizerInfo: tokenizerInfo) })
        case let .concat(parts): Grammar.concatenating(try parts.map { try $0.build(tokenizerInfo: tokenizerInfo) })
        case let .reparse(recipe, root): try Grammar(ebnf: try recipe.build().description, rootRule: root)
        case let .roundtrip(recipe): try Grammar(serializedJSON: try recipe.build().serializedJSON)
        }
    }

    /// Whether the grammar comes (partly) from the structural-tag or JSON Schema converters,
    /// whose rule layout deliberately differs from upstream's.
    var involvesConverterLayout: Bool {
        switch self {
        case .structuralTag, .jsonSchema: true
        case let .union(parts), let .concat(parts): parts.contains { $0.involvesConverterLayout }
        case let .reparse(recipe, _), let .roundtrip(recipe): recipe.involvesConverterLayout
        case .ebnf, .regex, .builtinJSON, .lark: false
        }
    }

    var description: String {
        switch self {
        case let .ebnf(source, _, normalized): normalized ? source : "raw(\(source))"
        case let .regex(source): "regex(\(source))"
        case let .jsonSchema(source, _): "schema(\(source))"
        case .builtinJSON: "builtin_json"
        case let .structuralTag(source): "stag(\(source))"
        case let .lark(source): "lark(\(source))"
        case let .union(parts): "union(\(parts))"
        case let .concat(parts): "concat(\(parts))"
        case let .reparse(recipe, _): "reparse(\(recipe))"
        case let .roundtrip(recipe): "roundtrip(\(recipe))"
        }
    }
}

private struct LanguageFixtures: Decodable, Sendable {
    struct Group: Decodable, Sendable, CustomTestStringConvertible {
        struct Input: Decodable, Sendable {
            /// `nil` for supplemental instances that upstream did not decide.
            let text: String, accepted: Bool?
            init(text: String, accepted: Bool?) { self.text = text; self.accepted = accepted }
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                text = try c.decode(String.self); accepted = try c.decode(Bool.self)
            }
        }
        let id: String, recipe: Recipe, inputs: [Input]
        var testDescription: String { id }
    }
    struct ErrorCase: Decodable, Sendable, CustomTestStringConvertible {
        let id: String, recipe: Recipe, match: String?
        var testDescription: String { id }
        private enum Key: String, CodingKey { case id, match }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = try c.decode(String.self, forKey: .id); match = try c.decodeIfPresent(String.self, forKey: .match)
            recipe = try Recipe(from: decoder)
        }
    }
    struct Printed: Decodable, Sendable, CustomTestStringConvertible {
        let id: String, recipe: Recipe, expected: String
        var testDescription: String { id }
    }
    struct SamePrinted: Decodable, Sendable, CustomTestStringConvertible {
        let id: String, recipe: Recipe, other: Recipe
        var testDescription: String { id }
    }
    struct Contains: Decodable, Sendable, CustomTestStringConvertible {
        let id: String, recipe: Recipe, substring: String, present: Bool
        var testDescription: String { id }
    }
    struct Module: Decodable, Sendable {
        let cases: [Group], errors: [ErrorCase], printed: [Printed], samePrinted: [SamePrinted], contains: [Contains]
    }
    let modules: [String: Module]

    static let upstream: LanguageFixtures = {
        let url = Bundle.module.url(forResource: "GrammarLanguage", withExtension: "json")!
        return try! JSONDecoder().decode(LanguageFixtures.self, from: Data(contentsOf: url))
    }()

    /// Every instance of the grammar built by `recipe`.
    static func inputs(for recipe: Recipe) -> [Group.Input] {
        let key = recipe.description
        return upstream.modules.values.flatMap(\.cases).filter { $0.recipe.description == key }.flatMap(\.inputs)
    }

    static func all<Row>(_ rows: KeyPath<Module, [Row]>) -> [Row] {
        upstream.modules.keys.sorted().flatMap { upstream.modules[$0]![keyPath: rows] }
    }
}

@Suite("Grammar language (upstream)")
struct GrammarLanguageTests {
    /// Upstream's `any_order` only counts properties, so it accepts duplicate keys and objects
    /// missing a required key. This library keeps every declared key unique and every required
    /// key present (for up to 12 tracked properties): these instances are invalid for the schema.
    static let stricterAnyOrder: Set<String> = [
        #"{"a": 1, "a": 2}"#, #"{"a": 1, "b": "x", "c": true, "c": false}"#, #"{"a": 1, "a": 2, "b": "x"}"#,
    ]

    @Test(arguments: LanguageFixtures.all(\.cases))
    fileprivate func acceptance(_ group: LanguageFixtures.Group) throws {
        let compiled = try GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, cacheEnabled: false).compile(try group.recipe.build())
        for input in group.inputs {
            var matcher = GrammarMatcher(compiled, terminateWithoutStopToken: true)
            let accepted = matcher.acceptString(input.text) && matcher.isTerminated
            let expected = input.accepted! && !(group.id.contains("any_order") && Self.stricterAnyOrder.contains(input.text))
            #expect(accepted == expected, "\(group.recipe) on \(input.text.debugDescription)")
        }
    }

    /// Upstream's converter needs an end string to build unlimited content and rejects a tag
    /// whose ends are all empty. Here such content runs to the end of generation, as the
    /// Mistral dialect's calls do.
    static let unlimitedContentWithEmptyEnd: Set<String> = ["test_structural_tag_error[0]#1", "test_structural_tag_error[3]#1"]

    /// Upstream raises at construction or on first use (automaton construction); either is
    /// accepted here, and the message must match upstream's pattern.
    @Test(arguments: LanguageFixtures.all(\.errors).filter { !GrammarLanguageTests.unlimitedContentWithEmptyEnd.contains($0.id) })
    fileprivate func rejection(_ row: LanguageFixtures.ErrorCase) throws {
        let message: String
        do {
            _ = try Upstream.matcher(try row.recipe.build())
            Issue.record("\(row.recipe) was accepted")
            return
        } catch {
            message = String(describing: error)
        }
        if let pattern = row.match {
            // Python's `re` reads a bare `{` literally; ICU rejects it, so fall back to a literal match.
            let matches = if let regex = try? NSRegularExpression(pattern: pattern) {
                regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil
            } else {
                message.contains(pattern)
            }
            #expect(matches, "\(message) does not match \(pattern)")
        }
    }

    @Test(arguments: LanguageFixtures.all(\.printed))
    fileprivate func printed(_ row: LanguageFixtures.Printed) throws {
        let printed = try row.recipe.build().description
        guard printed != row.expected else { return }
        // The structural-tag and JSON Schema converters lay out some rules differently from
        // upstream (e.g. `plus` as a `{1, -1}` repetition rather than a recursive rule). There, upstream's
        // printed grammar, parsed by this library, must decide every instance upstream tested
        // for the same structural tag exactly as the converted grammar does.
        guard row.recipe.involvesConverterLayout else {
            #expect(printed == row.expected)
            return
        }
        // Upstream only compared the printed text of these; both grammars must agree on these
        // instances (upstream recorded no expected value for them).
        let supplemental: [String] = switch row.id {
        case "test_grammar_union_with_stag#1", "test_grammar_union_with_stag#2":
            ["", "abc", #"start{"arg": "x"}end"#, "start{}end", #"start{"arg": 1}end"#, #"xx start{"arg": "y"}end zz"#,
             "start{}endabc", "abcstart{}end", #"start{"arg":"x"}endq"#, "start{}en"]
        default: []
        }
        let inputs = LanguageFixtures.inputs(for: row.recipe) + supplemental.map { LanguageFixtures.Group.Input(text: $0, accepted: nil) }
        try #require(!inputs.isEmpty, "Layout differs from upstream and no instance checks it:\n\(printed)\nvs\n\(row.expected)")
        let compiler = GrammarCompiler(tokenizerInfo: Upstream.emptyTokenizer, cacheEnabled: false)
        let ours = try compiler.compile(try row.recipe.build())
        let reference = try compiler.compile(try Grammar(ebnf: row.expected))
        for input in inputs {
            var a = GrammarMatcher(ours, terminateWithoutStopToken: true), b = GrammarMatcher(reference, terminateWithoutStopToken: true)
            let accepted = a.acceptString(input.text) && a.isTerminated
            let upstream = b.acceptString(input.text) && b.isTerminated
            #expect(accepted == upstream && (input.accepted ?? accepted) == accepted, "\(input.text.debugDescription)")
        }
    }

    @Test(arguments: LanguageFixtures.all(\.samePrinted))
    fileprivate func samePrinted(_ row: LanguageFixtures.SamePrinted) throws {
        #expect(try row.recipe.build().description == row.other.build().description)
    }

    @Test(arguments: LanguageFixtures.all(\.contains))
    fileprivate func contains(_ row: LanguageFixtures.Contains) throws {
        // Converter-layout rows whose rule upstream names differently: the Swift rules stating the
        // same thing (here: an unknown string format leaves a K3 raw value unconstrained).
        let substrings: [String] = switch row.id {
        case "test_unrecognized_format_keeps_exclusions[1]#4":
            [#"root_value ::= ((root_value_characters{0, -1}))"#, #"root_value_characters ::= (([\0-\U0010ffff]))"#]
        default: [row.substring]
        }
        let printed = try row.recipe.build().description
        for substring in substrings { #expect(printed.contains(substring) == row.present, "\(substring)") }
    }
}
