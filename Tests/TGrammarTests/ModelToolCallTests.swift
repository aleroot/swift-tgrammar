import Foundation
import Testing
@testable import TGrammar

/// An upstream test case: a model's tool-call format built from Chat Completions inputs.
private struct ModelToolCallFixture: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let model: String
    let tools: String
    let toolChoice: String
    let reasoning: String
    let anyOrder: Bool
    let excludeSpecialTokens: Bool
    let maxWhitespaceCount: Int?
    let parallelToolCalls: Bool
    let input: String
    let accepted: Bool
    var testDescription: String { id }
}

private struct ModelToolCallError: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let model: String
    let invalidInput: String?
    let tools: String?
    let toolChoice: String?
    var testDescription: String { id }
}

private struct ModelToolCallFixtures: Decodable {
    let revision: String
    let cases: [ModelToolCallFixture]
    let errors: [ModelToolCallError]

    static var upstream: Self {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "ModelToolCalls", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }
    /// Python type errors (a non-list `tools`, a non-string reasoning mode) are unrepresentable
    /// in Swift; the remaining rows describe inputs the registry must reject.
    static var representableErrors: [ModelToolCallError] {
        get throws { try upstream.errors.filter { $0.invalidInput == nil || $0.invalidInput == "model" } }
    }
}

private func reasoningMode(_ key: String) throws -> ReasoningMode {
    switch key {
    case "enabled": .enabled
    case "disabled": .disabled
    case "auto": .optional
    default: throw GrammarError.conversion("Unknown reasoning mode \(key)")
    }
}

@Suite("Model tool-call formats (upstream)")
struct ModelToolCallTests {
    private static func format(_ fixture: ModelToolCallFixture) throws -> StructuralFormat {
        let model = try #require(ToolCallDialect(modelKey: fixture.model))
        return try StructuralFormat.toolCalls(try ToolDeclaration.tools(json: fixture.tools), model: model, choice: try ToolChoice(json: fixture.toolChoice),
                                              reasoning: try reasoningMode(fixture.reasoning), parallelCalls: fixture.parallelToolCalls,
                                              anyOrder: fixture.anyOrder, excludeSpecialTokens: fixture.excludeSpecialTokens,
                                              maxWhitespaceCount: fixture.maxWhitespaceCount)
    }

    static func accepts(_ format: StructuralFormat, _ input: String) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: format), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    @Test(arguments: try ModelToolCallFixtures.upstream.cases)
    fileprivate func upstream(_ fixture: ModelToolCallFixture) throws {
        #expect(try Self.accepts(try Self.format(fixture), fixture.input) == fixture.accepted)
    }

    @Test(arguments: try ModelToolCallFixtures.representableErrors)
    fileprivate func upstreamRejects(_ fixture: ModelToolCallError) throws {
        guard let model = ToolCallDialect(modelKey: fixture.model) else {
            #expect(fixture.invalidInput == "model")
            return
        }
        #expect(throws: GrammarError.self) {
            let tools = try ToolDeclaration.tools(json: fixture.tools ?? "[]")
            _ = try StructuralFormat.toolCalls(tools, model: model, choice: try ToolChoice(json: fixture.toolChoice ?? "\"auto\""))
        }
    }

    // MARK: Structure checks

    static let simpleSchema = JSONSchema.object(properties: [.init("q", .string())], additionalProperties: nil)
    static func tools(_ names: String..., schema: JSONSchema = simpleSchema) -> [ToolDeclaration] { names.map { .function(.init(name: $0, parameters: schema)) } }
    static let browserSearch = ToolDeclaration.builtin(.init(type: "web_search_preview", name: "browser.search",
                                                  parameters: .object(properties: [.init("query", .string())])))
    static let browserOpen = ToolDeclaration.builtin(.init(type: "code_interpreter", name: "browser.open",
                                                parameters: .object(properties: [.init("url", .string())])))

    // Onyx (`atem`) needs control tokens in the vocabulary; SwiftDialectTests covers it.
    @Test(arguments: ToolCallDialect.allCases.filter { ![.llama, .mimo, .gemma4, .harmony, .functionGemma, .atem].contains($0) })
    func optionalReasoningIsAnOptionalCompletePrefix(_ model: ToolCallDialect) throws {
        let format = try StructuralFormat.toolCalls([ToolDeclaration](), model: model, reasoning: .optional)
        guard case .sequence(let elements) = format, case .optional = elements.first else {
            Issue.record("\(model) does not start with an optional prefix")
            return
        }
        _ = try GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]())).compile(structuralFormat: format)
    }

    @Test func toolSelectionNormalisesChoices() throws {
        let named = try ToolSelection(Self.tools("get_weather", "get_time"), choice: .named("get_weather"))
        #expect(named.functions.map(\.name) == ["get_weather"] && named.builtins.isEmpty && named.policy == .forced)
        let allowed = try ToolSelection(Self.tools("get_weather", "get_time") + [Self.browserSearch, Self.browserOpen],
                                        choice: .allowed([.function("get_weather"), .builtin(type: "web_search_preview")], required: true))
        #expect(allowed.functions.map(\.name) == ["get_weather"] && allowed.builtins.map(\.outputName) == ["browser.search"] && allowed.policy == .required)
        let none = try ToolSelection(Self.tools("get_weather") + [Self.browserSearch], choice: .none)
        #expect(none.functions.isEmpty && none.builtins.isEmpty && none.policy == .automatic)
    }

    @Test func choicesFilterTagBegins() throws {
        let shapes = try StructuralFormat.toolCalls(Self.tools("get_weather", "get_time") + [Self.browserSearch], model: .harmony, reasoning: .disabled)
        #expect(["get_weather", "get_time", "browser.search"].allSatisfy { name in shapes.tagBegins.contains { $0.contains(name) } })
        let named = try StructuralFormat.toolCalls(Self.tools("get_weather", "get_time"), model: .llama, choice: .named("get_weather"), reasoning: .disabled)
        #expect(named.tagBegins.contains { $0.contains("get_weather") } && !named.tagBegins.contains { $0.contains("get_time") })
        let builtin = try StructuralFormat.toolCalls(Self.tools("get_weather") + [Self.browserSearch, Self.browserOpen], model: .harmony,
                                                     choice: .builtin(type: "web_search_preview"), reasoning: .disabled)
        #expect(builtin.tagBegins.contains { $0.contains("browser.search") })
        #expect(!builtin.tagBegins.contains { $0.contains("browser.open") || $0.contains("get_weather") })
        let allowed = try StructuralFormat.toolCalls(Self.tools("get_weather", "get_time") + [Self.browserSearch, Self.browserOpen], model: .harmony,
                                                     choice: .allowed([.function("get_weather"), .builtin(type: "web_search_preview")]), reasoning: .disabled)
        #expect(allowed.tagBegins.contains { $0.contains("get_weather") } && allowed.tagBegins.contains { $0.contains("browser.search") })
        #expect(!allowed.tagBegins.contains { $0.contains("get_time") || $0.contains("browser.open") })
    }

    @Test func missingParametersAreUnconstrained() throws {
        let format = try StructuralFormat.toolCalls([.function(.init(name: "ping"))], model: .llama, reasoning: .disabled)
        #expect(format.schemaNodes.map(\.schema) == [.any])
    }

    @Test func kimiAutoRequiresToolCallsSection() throws {
        let format = try StructuralFormat.toolCalls(Self.tools("get_weather"), model: .kimi, reasoning: .disabled)
        let call = "<|tool_call_begin|>functions.get_weather:0<|tool_call_argument_begin|>{\"q\": \"v\"}<|tool_call_end|>"
        #expect(try Self.accepts(format, "<|tool_calls_section_begin|>" + call + "<|tool_calls_section_end|>"))
        #expect(try !Self.accepts(format, call))
    }

    @Test func kimiK3NestedArgumentsAndAnyOrder() throws {
        let schema = try JSONSchema(json: #"{"type":"object","properties":{"query":{"type":"string"},"options":{"type":"object","properties":{"limit":{"type":"integer"},"filters":{"type":"array","items":{"type":"string"}}},"required":["limit","filters"],"additionalProperties":false},"records":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"active":{"type":"boolean"}},"required":["id","active"],"additionalProperties":false}}},"required":["query","options","records"],"additionalProperties":false}"#)
        let tools = Self.tools("process", schema: schema)
        func argument(_ key: String, _ type: String, _ value: String) -> String {
            "<|open|>argument key=\"\(key)\" type=\"\(type)\"<|sep|>\(value)<|close|>argument<|sep|>"
        }
        let arguments = argument("records", "array", #"[{"active": true, "id": 1}]"#) + argument("options", "object", #"{"filters": ["a", "b"], "limit": 2}"#) + argument("query", "string", "北京")
        func call(_ args: String) -> String {
            "<|close|>response<|sep|><|open|>tools<|sep|><|open|>call tool=\"process\" index=\"1\"<|sep|>\(args)<|close|>call<|sep|><|close|>tools<|sep|><|close|>message<|sep|>"
        }
        let anyOrder = try StructuralFormat.toolCalls(tools, model: .kimiK3, reasoning: .disabled, anyOrder: true)
        let ordered = try StructuralFormat.toolCalls(tools, model: .kimiK3, reasoning: .disabled)
        #expect(anyOrder.schemaNodes.first?.options.style == .kimiK3XML)
        #expect(try Self.accepts(anyOrder, call(arguments)))
        #expect(try !Self.accepts(ordered, call(arguments)))
        #expect(try !Self.accepts(anyOrder, call(arguments.replacingOccurrences(of: #"{"active": true, "id": 1}"#, with: #"{"active": true}"#))))
        #expect(try !Self.accepts(anyOrder, call(arguments.replacingOccurrences(of: "key=\"options\" type=\"object\"", with: "key=\"options\" type=\"array\""))))
        let nested = argument("limit", "number", "2") + argument("filters", "array", #"["a"]"#)
        #expect(try !Self.accepts(anyOrder, call(arguments.replacingOccurrences(of: #"{"filters": ["a", "b"], "limit": 2}"#, with: nested))))
    }

    @Test(arguments: [ToolChoice.automatic, .required])
    func kimiK3ExcludesControlTokens(_ choice: ToolChoice) throws {
        let on = try StructuralFormat.toolCalls(Self.tools("get_weather"), model: .kimiK3, choice: choice)
        let flat = on.excludeLists.flatMap { $0 }
        #expect(flat.contains("<|open|>") && flat.contains("<|close|>"))
        #expect(!on.schemaNodes.isEmpty && on.schemaNodes.allSatisfy { $0.options.excludes == ["<|open|>", "<|close|>", "<|sep|>"] })
        let off = try StructuralFormat.toolCalls(Self.tools("get_weather"), model: .kimiK3, choice: choice, excludeSpecialTokens: false)
        #expect(off.excludeLists.allSatisfy { $0.isEmpty })
    }

    @Test(arguments: [ToolCallDialect.qwen3, .qwen35])
    func qwenReasoningSuffixStaysInsideTheOptionalPrefix(_ model: ToolCallDialect) throws {
        let format = try StructuralFormat.toolCalls([ToolDeclaration](), model: model, reasoning: .optional)
        guard case .sequence(let elements) = format, case .optional(.sequence(let prefix)) = elements[0],
              case .tag(let think) = prefix[0], case .literal("\n\n") = prefix[1] else {
            Issue.record("unexpected prefix shape")
            return
        }
        #expect(think.ends == ["</think>"])
        #expect(try Self.accepts(format, "answer"))
        #expect(try Self.accepts(format, "<think>reasoning</think>\n\nanswer"))
        #expect(try !Self.accepts(format, "<think>reasoning</think>answer"))
    }

    static let excludeTokenModels: [ToolCallDialect] = [.llama, .kimi, .deepSeekR1, .deepSeekV31, .deepSeekV32, .deepSeekV4, .deepSeekV41, .qwen3, .qwen35, .miniMax, .glm47, .cohere, .exaone]

    @Test(arguments: excludeTokenModels, [true, false])
    func specialTokensAreExcludedByDefault(_ model: ToolCallDialect, withTools: Bool) throws {
        let tools = withTools ? Self.tools("search") : []
        let on = try StructuralFormat.toolCalls(tools, model: model, reasoning: .enabled)
        let flat = on.excludeLists.flatMap { $0 }
        let expected = model == .cohere ? ["<|START_THINKING|>", "<|END_THINKING|>"] : ["<think>", "</think>"]
        #expect(expected.allSatisfy(flat.contains))
        let off = try StructuralFormat.toolCalls(tools, model: model, reasoning: .enabled, excludeSpecialTokens: false)
        let allowed: [[String]] = model == .deepSeekV41 && !withTools ? [[], ["<｜DSML｜ calls>"]] : [[]]
        #expect(off.excludeLists.allSatisfy(allowed.contains))
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        _ = try compiler.compile(structuralFormat: off)
    }

    @Test(arguments: [true, false])
    func harmonyHasNoSpecialTokensToExclude(_ flag: Bool) throws {
        let format = try StructuralFormat.toolCalls(Self.tools("search"), model: .harmony, excludeSpecialTokens: flag)
        #expect(format.excludeLists.allSatisfy { $0.isEmpty })
    }

    @Test func miniMaxM3ReasoningDefaults() throws {
        let adaptive = try StructuralFormat.toolCalls([ToolDeclaration](), model: .miniMaxM3)
        guard case .sequence(let elements) = adaptive, case .optional = elements[0] else {
            Issue.record("MiniMax M3 defaults to an optional reasoning block")
            return
        }
        if case .sequence = try StructuralFormat.toolCalls([ToolDeclaration](), model: .miniMaxM3, reasoning: .disabled) { Issue.record("disabled reasoning adds no prefix") }
    }

    static let anyOrderModels: [ToolCallDialect] = [.llama, .kimi, .kimiK3, .qwen3, .qwen35, .deepSeekR1, .deepSeekV31, .deepSeekV32, .deepSeekV4, .deepSeekV41, .miniMax, .miniMaxM3, .glm47, .harmony, .exaone]
    static let anyOrderCases: [(ToolCallDialect, ToolChoice, Bool)] = anyOrderModels.flatMap { model in
        [ToolChoice.automatic, .required, .named("fn")].flatMap { choice in [(model, choice, true), (model, choice, false)] }
    }

    @Test(arguments: anyOrderCases)
    func anyOrderAppliesToEverySchema(_ model: ToolCallDialect, choice: ToolChoice, anyOrder: Bool) throws {
        let format = try StructuralFormat.toolCalls(Self.tools("fn"), model: model, choice: choice, anyOrder: anyOrder)
        let flags = format.schemaNodes.map(\.options.anyOrder)
        #expect(!flags.isEmpty && flags.allSatisfy { $0 == anyOrder })
    }

    @Test func anyOrderAndWhitespaceDefaultsAndPropagation() throws {
        #expect(try StructuralFormat.toolCalls(Self.tools("fn"), model: .qwen3).schemaNodes.map(\.options.anyOrder) == [false])
        let unbounded = try StructuralFormat.toolCalls(Self.tools("f", "g"), model: .qwen3, reasoning: .disabled).schemaNodes
        #expect(!unbounded.isEmpty && unbounded.allSatisfy { $0.options.maxWhitespaceCount == nil })
        let bounded = try StructuralFormat.toolCalls(Self.tools("f", "g"), model: .qwen3, reasoning: .disabled, maxWhitespaceCount: 2).schemaNodes
        #expect(!bounded.isEmpty && bounded.allSatisfy { $0.options.maxWhitespaceCount == 2 })
    }

    @Test(arguments: [ToolChoice.automatic, .required])
    func gemma4ArgumentsUseGemmaStyleAndExcludeMarkers(_ choice: ToolChoice) throws {
        let on = try StructuralFormat.toolCalls(Self.tools("get_weather"), model: .gemma4, choice: choice)
        #expect(!on.schemaNodes.isEmpty && on.schemaNodes.allSatisfy { $0.options.style == .gemma })
        #expect(on.schemaNodes.allSatisfy { $0.options.excludes == ["<|channel>", "<channel|>", "<|tool_call>", "<tool_call|>"] })
        let off = try StructuralFormat.toolCalls(Self.tools("get_weather"), model: .gemma4, choice: choice, excludeSpecialTokens: false)
        #expect(off.excludeLists.allSatisfy { $0.isEmpty })
        _ = try GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]())).compile(structuralFormat: off)
    }

    /// Gemma 4's markers are single tokens in its tokenizer; walk a call token by token so
    /// literal-versus-token matching is covered beyond byte-level tests.
    @Test func gemma4SingleTokenDelimiterWalk() throws {
        let vocab = ["<|tool_call>", "<tool_call|>", "<|\"|>", "<|channel>", "<channel|>", "call", ":", "get_weather", "{", "}", "city", "Seoul", "<eos>"]
        let info = try TokenizerInfo(encodedVocab: vocab, vocabType: .raw, stopTokenIDs: [Int32(vocab.count - 1)])
        let tools = Self.tools("get_weather", schema: .object(properties: [.init("city", .string(), required: true)], additionalProperties: nil))
        let format = try StructuralFormat.toolCalls(tools, model: .gemma4, choice: .required, reasoning: .disabled)
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(structuralFormat: format))
        for piece in ["<|tool_call>", "call", ":", "get_weather", "{", "city", ":", "<|\"|>", "Seoul", "<|\"|>", "}", "<tool_call|>"] {
            let mask = matcher.nextTokenBitmask()
            let token = Int32(try #require(vocab.firstIndex(of: piece)))
            #expect(mask.allows(token), "bitmask disallows \(piece)")
            if piece == "Seoul" {
                for marker in ["<|channel>", "<channel|>", "<|tool_call>", "<tool_call|>"] { #expect(!mask.allows(Int32(vocab.firstIndex(of: marker)!)), "\(marker) allowed inside a string") }
            }
            let accepted = matcher.acceptToken(token)
            #expect(accepted, "matcher rejected \(piece)")
        }
        #expect(matcher.nextTokenBitmask().allows(Int32(vocab.count - 1)))
    }

    @Test(arguments: [true, false])
    func deepSeekV41AndMiMoRespectWhitespaceLimitsAndOrder(_ anyOrder: Bool) throws {
        let schema = try JSONSchema(json: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1}},"required":["query","limit"],"additionalProperties":false}"#)
        let tools = Self.tools("search", "other", schema: schema)
        let v41 = try StructuralFormat.toolCalls(tools, model: .deepSeekV41, choice: .required, reasoning: .disabled, anyOrder: anyOrder, maxWhitespaceCount: 2)
        let call = "\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"search\">\n<｜DSML｜ parameter name=\"query\" string=\"true\">北京\n<code>\"hi\"</code></｜DSML｜ parameter>\n<｜DSML｜ parameter name=\"limit\" string=\"false\">2</｜DSML｜ parameter>\n</｜DSML｜ invoke>\n</｜DSML｜ calls>"
        #expect(try Self.accepts(v41, call))
        #expect(try !Self.accepts(v41, call.replacingOccurrences(of: "string=\"false\">2", with: "string=\"false\">   2")))
        let lines = call.split(separator: "\n", omittingEmptySubsequences: false)
        let reordered = (lines[0 ..< 4] + lines[6 ..< 7] + lines[4 ..< 6] + lines[7...]).joined(separator: "\n")
        #expect(try Self.accepts(v41, reordered) == anyOrder)
        let mimo = try StructuralFormat.toolCalls(tools, model: .mimo, choice: .required, reasoning: .disabled, anyOrder: anyOrder, maxWhitespaceCount: 2)
        let mimoCall = "<tool_call><function=search><parameter=query>北京 &amp;\n</parameter><parameter=limit>2</parameter></function></tool_call>"
        #expect(try Self.accepts(mimo, mimoCall))
        #expect(try !Self.accepts(mimo, mimoCall.replacingOccurrences(of: "<parameter=limit>", with: "   <parameter=limit>")))
        #expect(try Self.accepts(mimo, "<tool_call><function=search><parameter=limit>2</parameter><parameter=query>北京</parameter></function></tool_call>") == anyOrder)
    }

    /// Every format accepts the normalised inputs the public API produces: function and builtin
    /// tools together, no tools, missing or non-strict schemas, and a forced single tool.
    @Test(arguments: ToolCallDialect.allCases.filter { $0 != .mimo && $0 != .miniMaxM3 && $0 != .atem })
    func formatsAcceptEveryNormalisedInput(_ model: ToolCallDialect) throws {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        let cases: [([ToolDeclaration], ToolChoice)] = [
            ([.function(.init(name: "get_weather", parameters: .object(properties: [.init("location", .string())], additionalProperties: nil))), Self.browserSearch], .automatic),
            ([], .automatic),
            ([.function(.init(name: "ping"))], .automatic),
            ([.function(.init(name: "ping", parameters: Self.simpleSchema, strict: false))], .automatic),
            ([.function(.init(name: "ping"))], .named("ping")),
        ]
        for (tools, choice) in cases {
            let format = try StructuralFormat.toolCalls(tools, model: model, choice: choice, reasoning: .enabled)
            _ = try compiler.compile(structuralFormat: format)
        }
    }
}

private extension StructuralFormat {
    var children: [StructuralFormat] {
        switch self {
        case .sequence(let items), .choice(let items): items
        case .optional(let item), .oneOrMore(let item), .zeroOrMore(let item), .repeated(let item, _, _), .captured(_, let item), .temperature(_, let item): [item]
        case .tag(let tag): [tag.content]
        case .triggeredTags(_, let tags, _, _, _), .tagsWithSeparator(let tags, _, _, _), .tokenTriggeredTags(_, let tags, _, _, _): tags.map(\.content)
        case .dispatch(let rules, _, _): rules.map(\.content)
        case .tokenDispatch(let rules, _, _): rules.map(\.content)
        default: []
        }
    }
    var descendants: [StructuralFormat] { [self] + children.flatMap(\.descendants) }
    var tags: [StructuralTag] {
        descendants.flatMap { node -> [StructuralTag] in
            switch node {
            case .tag(let tag): [tag]
            case .triggeredTags(_, let tags, _, _, _), .tagsWithSeparator(let tags, _, _, _), .tokenTriggeredTags(_, let tags, _, _, _): tags
            default: []
            }
        }
    }
    var tagBegins: [String] { tags.compactMap { if case .text(let begin) = $0.begin { begin } else { nil } } }
    var schemaNodes: [(schema: JSONSchema, options: JSONSchemaOptions)] {
        descendants.compactMap { if case .jsonSchema(let schema, let options) = $0 { (schema, options) } else { nil } }
    }
    var excludeLists: [[String]] {
        descendants.compactMap { node in
            switch node {
            case .anyText(let excludes, _, _), .triggeredTags(_, _, _, _, let excludes), .dispatch(_, _, let excludes): excludes
            case .jsonSchema(_, let options): options.excludes
            default: nil
            }
        }
    }
}
