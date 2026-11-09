import Foundation
import Testing
@testable import TGrammar

/// The code in the DocC articles, compiled and run so that the documentation cannot drift from
/// the API.
@Suite("Documentation examples")
struct DocumentationExamplesTests {
    static let info = try! TokenizerInfo(
        encodedVocab: ["\t", "\n"] + (0x20 ... 0x7E).map { String(UnicodeScalar($0)!) } + ["</s>"],
        stopTokenIDs: [97])
    static let compiler = GrammarCompiler(tokenizerInfo: info)

    static func accepts(_ grammar: CompiledGrammar, _ text: String) -> Bool {
        var matcher = GrammarMatcher(grammar)
        return matcher.acceptString(text)
    }

    @Test func gettingStartedDynamicCompilation() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Self.info, dynamicCompilation: true)
        let grammar = try compiler.compile(regex: #"\d{4}-\d{2}-\d{2}"#)
        #expect(grammar.isDynamicallyCompiled)
        #expect(Self.accepts(grammar, "2026-10-07"))
    }

    @Test func gettingStarted() throws {
        let compiler = GrammarCompiler(tokenizerInfo: Self.info, maxCacheBytes: 64 << 20)
        let grammar = try compiler.compile(regex: #"\d{4}-\d{2}-\d{2}"#)

        var matcher = GrammarMatcher(grammar)
        var mask = TokenBitmask(vocabSize: Self.info.vocabSize)
        var logits = [Float](repeating: 0, count: Self.info.vocabSize)
        var output = ""
        let wanted = Array("2026-10-07").map(String.init) + ["</s>"]
        while !matcher.isTerminated {
            if matcher.fillNextTokenBitmask(&mask) {
                mask.apply(to: &logits)
            }
            let token = try #require(Self.info.tokenID(for: wanted[output.count < 10 ? output.count : 10]))
            #expect(mask.allows(token))
            guard matcher.acceptToken(token) else { break }
            if output.count < 10 { output += wanted[output.count] }
        }
        #expect(output == "2026-10-07" && matcher.isTerminated)

        let restored = try CompiledGrammar(serializedJSON: grammar.serializedJSON, tokenizerInfo: Self.info)
        #expect(Self.accepts(restored, "2026-10-07"))
    }

    @Test func structuredOutput() throws {
        let compiler = Self.compiler
        let event = JSONSchema.object(properties: [
            .init("title", .string(minLength: 1, maxLength: 80), required: true),
            .init("date", .string(format: "date"), required: true),
            .init("attendees", .array(items: .string(), maxItems: 10)),
            .init("priority", .enumeration(["low", "normal", "high"])),
        ])
        let grammar = try compiler.compile(jsonSchema: event)
        #expect(Self.accepts(grammar, #"{"title": "Launch", "date": "2026-10-07", "priority": "high"}"#))
        #expect(!Self.accepts(grammar, #"{"date": "2026-10-07"}"#))

        let fromSource = try compiler.compile(jsonSchema: #"{"type": "array", "items": {"type": "integer"}}"#)
        #expect(Self.accepts(fromSource, "[1, 2, 3]"))

        let arithmetic = try compiler.compile(ebnf: #"""
        root ::= expr
        expr ::= term (("+" | "-") term)*
        term ::= [0-9]+ | "(" expr ")"
        """#)
        #expect(Self.accepts(arithmetic, "(1+2)-30"))

        let date = try compiler.compile(regex: #"\d{4}-\d{2}-\d{2}"#)
        #expect(Self.accepts(date, "2026-10-07"))

        let command = try compiler.compile(lark: #"""
        start: verb " " NOUN
        verb: "open" | "close"
        NOUN: /[a-z]+/
        """#)
        #expect(Self.accepts(command, "open door"))

        let answer = StructuralFormat.triggeredTags(
            triggers: ["<data>"],
            tags: [StructuralTag(begin: "<data>", content: .jsonSchema(event), end: "</data>")]
        )
        let tagged = try compiler.compile(structuralFormat: answer)
        #expect(Self.accepts(tagged, #"Here: <data>{"title": "Launch", "date": "2026-10-07"}</data> done"#))
    }

    @Test func toolCalling() throws {
        let compiler = Self.compiler
        let weather = ToolDefinition(name: "get_weather", parameters: .object(properties: [
            .init("city", .string(), required: true),
            .init("unit", .enumeration(["celsius", "fahrenheit"])),
        ]))
        let grammar = try compiler.compile(toolCalls: [weather], model: .qwen3, choice: .automatic, reasoning: .disabled)
        #expect(Self.accepts(grammar, "<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>"))

        let tools = try ToolDeclaration.tools(json: #"[{"type": "function", "function": {"name": "get_weather"}}]"#)
        let choice = try ToolChoice(json: #"{"type": "function", "function": {"name": "get_weather"}}"#)
        #expect(tools.count == 1 && choice == .named("get_weather"))

        // <call name="get_weather">{"city": "Paris"}</call>
        let syntax = ToolCallSyntax(namePrefix: "<call name=\"", nameSuffix: "\">", end: "</call>",
                                    trigger: "<call ")
        let custom = try compiler.compile(toolCalls: [weather], syntax: syntax)
        #expect(Self.accepts(custom, #"<call name="get_weather">{"city": "Paris"}</call>"#))

        let city = JSONSchema.object(properties: [.init("city", .string(), required: true)])
        let answer = try compiler.compile(structuralFormat: .reasoning(.required, maxTokens: 512,
                                                                       then: .jsonSchema(city)))
        #expect(Self.accepts(answer, "<think>Paris it is.</think>\n\n" + #"{"city": "Paris"}"#))
    }
}
