import Foundation
import Testing
@testable import TGrammar

@Suite("Tool calling")
struct ToolCallingTests {
    let tools: [ToolDefinition] = [.init(name: "weather", parameters: .object(properties: [
        .init("city", .string(), required: true),
        .init("unit", .enumeration(["celsius", "fahrenheit"])),
    ]))]
    let call = "<tool_call>\n{\"name\": \"weather\", \"arguments\": {\"city\":\"Dubai\"}}\n</tool_call>"

    private func matcher(_ format: StructuralFormat) throws -> GrammarMatcher {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        return GrammarMatcher(try compiler.compile(structuralFormat: format), terminateWithoutStopToken: true)
    }

    @Test func automaticRequiredAndForcedChoices() throws {
        for (choice, accepted, rejected) in [
            (ToolChoice.automatic, ["Sunny.", call, "Checking. " + call, call + "\n" + call], [call.replacingOccurrences(of: "weather", with: "unknown")]),
            (.required, [call, call + "\n" + call], ["Sunny.", "Checking. " + call]),
            (.named("weather"), [call], ["Sunny.", call + call]),
            (.none, ["Sunny."], [call]),
        ] {
            let format = try StructuralFormat.toolCalls(tools, syntax: .qwen3, choice: choice)
            for input in accepted + rejected {
                var matcher = try matcher(format)
                let result = matcher.acceptString(input) && matcher.isCompleted
                #expect(result == accepted.contains(input))
            }
        }
    }

    @Test func reasoningModesAndSingleCall() throws {
        for (mode, accepted, rejected) in [
            (ReasoningMode.disabled, [call], ["<think>hmm</think>\n\n" + call]),
            (.optional, [call, "<think>hmm</think>\n\n" + call], ["hmm</think>\n\n" + call]),
            (.required, ["<think>hmm</think>\n\n" + call], [call]),
            (.continuation, ["hmm</think>\n\n" + call], [call, "<think>hmm</think>\n\n" + call]),
        ] {
            let format = try StructuralFormat.toolCalls(tools, syntax: .qwen3, choice: .required, reasoning: mode, parallelCalls: false)
            for input in accepted + rejected + [accepted[0] + call] {
                var matcher = try matcher(format)
                let result = matcher.acceptString(input) && matcher.isCompleted
                #expect(result == accepted.contains(input))
            }
        }
    }

    @Test func reasoningBeforeAConstrainedAnswer() throws {
        let answer = StructuralFormat.jsonSchema(.object(properties: [.init("city", .string(), required: true)]))
        let json = #"{"city": "Rome"}"#
        for (mode, accepted, rejected) in [
            (ReasoningMode.disabled, [json], ["<think>hmm</think>\n\n" + json]),
            (.required, ["<think>hmm</think>\n\n" + json], [json, "<think>hmm</think>" + json, "<think>hmm</think>\n\n\n" + json, "<think>a<think>b</think>\n\n" + json]),
            (.optional, [json, "<think>hmm</think>\n\n" + json], ["hmm</think>\n\n" + json]),
            (.enabled, ["hmm</think>\n\n" + json], [json, "<think>hmm</think>\n\n" + json]),
            (.continuation, ["hmm</think>\n\n" + json], [json]),
        ] {
            let format = try StructuralFormat.reasoning(mode, then: answer)
            for input in accepted + rejected {
                var matcher = try matcher(format)
                let result = matcher.acceptString(input) && matcher.isCompleted
                #expect(result == accepted.contains(input), "\(mode) \(input.debugDescription)")
            }
        }
        var matcher = try matcher(.reasoning(.required, delimiters: .init(begin: "[THINK]", end: "[/THINK]", suffix: ""), then: answer))
        let delimited = matcher.acceptString("[THINK]x[/THINK]" + json) && matcher.isCompleted
        #expect(delimited)
        #expect(throws: GrammarError.self) { try StructuralFormat.reasoning(.required, delimiters: .init(begin: ""), then: answer) }
    }

    @Test func modelSyntaxesAndArgumentCaptures() throws {
        for (syntax, input, arguments) in [
            (ToolCallSyntax.qwen3, call, #"{"city":"Dubai"}"#),
            (.llama, #"{"name": "weather", "parameters": {"city":"Dubai"}}"#, #"{"city":"Dubai"}"#),
            (.qwenXML, "<tool_call>\n<function=weather>\n<parameter=city>Dubai</parameter>\n</function>\n</tool_call>", "<parameter=city>Dubai</parameter>\n"),
        ] {
            var matcher = try matcher(.toolCalls(tools, syntax: syntax, choice: .named("weather"), captureArguments: true))
            let accepted = matcher.acceptString(input)
            #expect(accepted)
            #expect(matcher.isCompleted)
            #expect(matcher.captures().map(\.name) == ["weather"])
            #expect(matcher.captures().map(\.text) == [arguments])
        }
    }

    @Test func rejectsInvalidDefinitions() throws {
        #expect(throws: GrammarError.self) { try StructuralFormat.toolCalls(tools, syntax: .qwen3, choice: .named("missing")) }
        #expect(throws: GrammarError.self) { try StructuralFormat.toolCalls([], syntax: .qwen3, choice: .required) }
        #expect(throws: GrammarError.self) { try StructuralFormat.toolCalls(tools + tools, syntax: .qwen3) }
        #expect(throws: GrammarError.self) { try StructuralFormat.toolCalls([.init(name: "bad\"name", parameters: .any)], syntax: .qwen3) }
    }
}
