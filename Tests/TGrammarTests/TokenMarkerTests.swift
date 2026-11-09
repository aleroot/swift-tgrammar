// Port of the `token_markers` / `_bind_marker_tokens` tests added to xgrammar's
// tests/python/test_builtin_structural_tag.py by upstream #940. They inspect the rewritten
// structural tags directly. `bind_marker_tokens` is
// ``StructuralFormat/bindingMarkerTokens(_:)``; upstream's `ValueError`s are
// ``GrammarError/conversion(_:)``. Swift has no mutable model registry, so
// `test_reregistering_without_marker_tokens_disables_token_markers` has no counterpart: a custom
// format opts in by calling `bindingMarkerTokens` itself.
//
// The tokenizer-backed rows run on Qwen3-0.6B, the cached stand-in for the Qwen 3 family (its
// vocabulary has the four Qwen markers as single tokens). Token ids come from the Hugging Face
// `tokenizers` library (snapshot c1899de289a0), as upstream's `_marker_encodings` builds them;
// the decoded texts of each atomic/split pair are equal. GLM-4.7-Flash, Qwen3-Coder and Qwen3.5
// are not cached here: their rows use the Qwen3 vocabulary for the Qwen grammars and are skipped
// for GLM.

import Testing

@testable import TGrammar

@Suite("Token markers (upstream #940)")
struct TokenMarkerTests {
    static let schema = try! JSONSchema(json: #"{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}"#)
    static let tools = ["get_weather", "get_time"].map { ToolDefinition(name: $0, parameters: schema) }

    static func format(_ model: ToolCallDialect, _ choice: ToolChoice, reasoning: ReasoningMode = .disabled) throws -> StructuralFormat {
        try .toolCalls(tools, model: model, choice: choice, reasoning: reasoning, tokenMarkers: true)
    }

    /// `test_token_markers_default_off_keeps_string_markers`.
    @Test func defaultOffKeepsStringMarkers() throws {
        let explicit = try StructuralFormat.toolCalls(Self.tools, model: .glm47, choice: .required, reasoning: .disabled, tokenMarkers: false)
        let `default` = try StructuralFormat.toolCalls(Self.tools, model: .glm47, choice: .required, reasoning: .disabled)
        #expect(explicit == `default`)
        guard case .triggeredTags = `default` else { Issue.record("expected triggered tags, got \(`default`)"); return }
    }

    /// `test_token_markers_required_dispatches_on_tool_call_token`.
    @Test(arguments: [ToolCallDialect.glm47, .qwen35, .qwen3Coder, .qwen3])
    func requiredDispatchesOnToolCallToken(_ model: ToolCallDialect) throws {
        guard case .tokenTriggeredTags(let triggers, let tags, let atLeastOne, _, let excluding) = try Self.format(model, .required) else {
            Issue.record("expected token-triggered tags"); return
        }
        #expect(triggers == [.piece("<tool_call>")])
        #expect(atLeastOne)
        #expect(excluding.contains(.piece("</think>")))
        #expect(tags.count == 2)
        for tag in tags {
            #expect(tag.begin == .token(.piece("<tool_call>")))
            #expect(tag.ends == [.token(.piece("</tool_call>"))])
            // The tool name and any template text stay literal inside the tag.
            guard case .sequence(let elements) = tag.content else { Issue.record("expected a sequence"); continue }
            if case .literal = elements[0] {} else { Issue.record("expected a leading literal, got \(elements[0])") }
            #expect(elements.contains { if case .jsonSchema = $0 { true } else { false } })
        }
    }

    /// `test_token_markers_glm_forced_and_reasoning_prefix`.
    @Test func glmForcedAndReasoningPrefix() throws {
        guard case .sequence(let elements) = try Self.format(.glm47, .named("get_weather"), reasoning: .enabled), elements.count == 2,
              case .tag(let prefix) = elements[0], case .tag(let call) = elements[1] else {
            Issue.record("expected a reasoning tag followed by a call tag"); return
        }
        // The reasoning block is closed by the dedicated </think> token.
        #expect(prefix.begin == .text(""))
        #expect(prefix.ends == [.token(.piece("</think>"))])
        #expect(call.begin == .token(.piece("<tool_call>")))
        #expect(call.content == .sequence([.literal("get_weather"), .jsonSchema(Self.schema, options: .init(anyWhitespace: true, style: .glmXML))]))
        #expect(call.ends == [.token(.piece("</tool_call>"))])
    }

    /// `test_token_markers_qwen_3_coder_keeps_function_wrapper_literal`.
    @Test func qwen3CoderKeepsFunctionWrapperLiteral() throws {
        guard case .tokenTriggeredTags(_, let tags, let atLeastOne, _, _) = try Self.format(.qwen3Coder, .automatic) else {
            Issue.record("expected token-triggered tags"); return
        }
        #expect(!atLeastOne)
        #expect(tags[0].content == .sequence([
            .literal("\n<function=get_weather>\n"),
            .jsonSchema(Self.schema, options: .init(anyWhitespace: true, style: .qwenXML)),
            .literal("\n</function>\n"),
        ]))
    }

    /// `test_token_markers_rejects_models_without_declared_markers`. (`test_token_markers_rejects_non_bool`
    /// has no counterpart: the parameter is a `Bool`.)
    @Test func rejectsModelsWithoutDeclaredMarkers() {
        #expect {
            try StructuralFormat.toolCalls(Self.tools, model: .llama, tokenMarkers: true)
        } throws: { ($0 as? GrammarError)?.message.contains("token_markers is not supported") == true }
    }

    /// `test_bind_marker_tokens_is_noop_without_occurrences`.
    @Test func bindIsNoOpWithoutOccurrences() throws {
        let format = try StructuralFormat.toolCalls(Self.tools, model: .llama)
        #expect(try format.bindingMarkerTokens(["<tool_call>"]) == format)
        #expect(try format.bindingMarkerTokens([]) == format)
    }

    /// `test_bind_marker_tokens_makes_free_text_under_token_end_token_level`.
    @Test(arguments: ["</think>", "\n</think>"])
    func bindMakesFreeTextUnderTokenEndTokenLevel(end: String) throws {
        let format = StructuralFormat.tag(.init(begin: "", content: .anyText(excluding: ["<think>"]), end: .text(end)))
        guard case .tag(let tag) = try format.bindingMarkerTokens(["<think>", "</think>"]) else { Issue.record("expected a tag"); return }
        #expect(tag.ends == [.token(.piece("</think>"))])
        var content = tag.content
        if case .sequence(let elements) = content { content = elements[0] }
        #expect(content == .anyTokens(excluding: [.piece("<think>")]))
    }

    /// `test_bind_marker_tokens_converts_nested_free_text_but_not_nested_tags`.
    @Test func bindConvertsNestedFreeTextButNotNestedTags() throws {
        let inner = StructuralTag(begin: "<a>", content: .anyText(), end: "</a>")
        let format = StructuralFormat.tag(.init(begin: "", content: .sequence([.optional(.anyText()), .tag(inner), .anyText()]), end: "</think>"))
        guard case .tag(let tag) = try format.bindingMarkerTokens(["</think>"]), case .sequence(let elements) = tag.content else {
            Issue.record("expected a tag over a sequence"); return
        }
        #expect(elements == [.optional(.anyTokens()), .tag(inner), .anyTokens()])
    }

    /// `test_bind_marker_tokens_rejects_string_excludes_under_token_end`.
    @Test func bindRejectsStringExcludesUnderTokenEnd() {
        let format = StructuralFormat.tag(.init(begin: "", content: .anyText(excluding: ["<|im_end|>"]), end: "</think>"))
        #expect { try format.bindingMarkerTokens(["</think>"]) } throws: { ($0 as? GrammarError)?.message.contains("must be markers") == true }
    }

    /// `test_bind_marker_tokens_keeps_only_marker_excludes`.
    @Test func bindKeepsOnlyMarkerExcludes() throws {
        let format = StructuralFormat.triggeredTags(triggers: ["<tool_call>"], tags: [.init(begin: "<tool_call>", content: .literal("x"), end: "</tool_call>")],
                                                    excluding: ["<think>", "</tool_call>"])
        guard case .tokenTriggeredTags(_, _, _, _, let excluding) = try format.bindingMarkerTokens(["<tool_call>", "</tool_call>"]) else {
            Issue.record("expected token-triggered tags"); return
        }
        #expect(excluding == [.piece("</tool_call>")])
    }

    /// `test_bind_marker_tokens_leaves_repeat_content_as_strings`: token formats beneath a
    /// repetition are not resolved upstream, so nothing is bound there.
    @Test func bindLeavesRepeatContentAsStrings() throws {
        let format = StructuralFormat.repeated(.literal("<tool_call>x"), minimum: 1, maximum: 2)
        #expect(try format.bindingMarkerTokens(["<tool_call>"]) == format)
    }

    /// `test_bind_marker_tokens_rejects_repeat_and_dispatch_under_token_end`.
    @Test(arguments: [StructuralFormat.repeated(.anyText(), minimum: 1, maximum: 2), .dispatch([.init("<a>", .literal("x"))])])
    func bindRejectsRepeatAndDispatchUnderTokenEnd(_ content: StructuralFormat) {
        let format = StructuralFormat.tag(.init(begin: "", content: content, end: "</think>"))
        #expect { try format.bindingMarkerTokens(["</think>"]) } throws: { ($0 as? GrammarError)?.message.contains("Repeat or Dispatch") == true }
    }

    /// `test_bind_marker_tokens_rejects_marker_in_alternative_ends`.
    @Test func bindRejectsMarkerInAlternativeEnds() throws {
        let format = StructuralFormat.tag(.init(begin: "<tool_call>", content: .literal("x"), ends: ["</tool_call>", "</tool_call>\n"]))
        #expect { try format.bindingMarkerTokens(["<tool_call>", "</tool_call>"]) } throws: {
            ($0 as? GrammarError)?.message.contains("list of alternatives") == true
        }
        let plain = StructuralFormat.tag(.init(begin: "<tool_call>", content: .literal("x"), ends: ["a", "b"]))
        guard case .tag(let bound) = try plain.bindingMarkerTokens(["<tool_call>"]) else { Issue.record("expected a tag"); return }
        #expect(bound.begin == .token(.piece("<tool_call>")))
        #expect(bound.ends == ["a", "b"])
    }

    // MARK: Qwen 3 vocabulary

    static let thinkEnd: Int32 = 151668
    static let qwen3Atomic: [Int32] = [151657, 198, 4913, 606, 788, 330, 455, 69364, 497, 330, 16370, 788, 5212, 8926, 788, 330, 71904, 95642, 151658]
    static let qwen3Split: [Int32] = [27, 14172, 13429, 29, 198, 4913, 606, 788, 330, 455, 69364, 497, 330, 16370, 788, 5212, 8926, 788, 330, 71904, 95642, 522, 14172, 13429, 29]
    static let xmlAtomic: [Int32] = [151657, 198, 27, 1688, 28280, 69364, 397, 27, 16181, 28, 8926, 397, 71904, 198, 522, 16181, 397, 522, 1688, 397, 151658]
    static let xmlSplit: [Int32] = [27, 14172, 13429, 29, 198, 27, 1688, 28280, 69364, 397, 27, 16181, 28, 8926, 397, 71904, 198, 522, 16181, 397, 522, 1688, 397, 522, 14172, 13429, 29]

    static func run(_ format: StructuralFormat, _ tokens: [Int32], info: TokenizerInfo) throws -> (accepted: Bool, completed: Bool) {
        let matcher = MatcherBox(GrammarMatcher(try GrammarCompiler(tokenizerInfo: info).compile(structuralFormat: format)))
        let accepted = tokens.allSatisfy { matcher.acceptToken($0) }
        return (accepted, accepted && matcher.isCompleted)
    }

    /// `test_token_markers_required_only_admits_dedicated_marker_tokens` (regression for the
    /// grammar/parser mismatch behind vllm-project/vllm#58315): with string markers the grammar
    /// accepts `<tool_call>` assembled from sub-tokens; with token markers only the dedicated
    /// tokens are admitted.
    @Test(.enabled(if: LocalTokenizers.has(.qwen3)), arguments: [ToolCallDialect.qwen3, .qwen35, .qwen3Coder], [false, true])
    func requiredOnlyAdmitsDedicatedMarkerTokens(_ model: ToolCallDialect, forced: Bool) throws {
        let info = try #require(LocalTokenizers.info(.qwen3))
        let (atomic, split) = model == .qwen3 ? (Self.qwen3Atomic, Self.qwen3Split) : (Self.xmlAtomic, Self.xmlSplit)
        let choice: ToolChoice = forced ? .named("get_weather") : .required
        let strings = try StructuralFormat.toolCalls(Self.tools, model: model, choice: choice, reasoning: .disabled)
        #expect(try Self.run(strings, atomic, info: info).accepted)
        #expect(try Self.run(strings, split, info: info).accepted)
        let tokens = try Self.format(model, choice)
        #expect(try Self.run(tokens, atomic, info: info).accepted)
        #expect(try !Self.run(tokens, split, info: info).accepted)
    }

    /// `test_token_markers_auto_keeps_free_text_and_parallel_calls`, on the Qwen 3 grammar
    /// (upstream uses GLM-4.7-Flash, which is not cached here).
    @Test(.enabled(if: LocalTokenizers.has(.qwen3)))
    func autoKeepsFreeTextAndParallelCalls() throws {
        let info = try #require(LocalTokenizers.info(.qwen3))
        let prose: [Int32] = [10061, 752, 1779, 13] // "Let me check."
        let format = try Self.format(.qwen3, .automatic)
        #expect(try Self.run(format, prose, info: info).accepted)
        #expect(try Self.run(format, prose + Self.qwen3Atomic + prose + Self.qwen3Atomic, info: info).accepted)
        // A stray control token in free text is still excluded (`</think>`: Qwen 3's free text
        // excludes only the think markers, where GLM's also excludes `</tool_call>`).
        #expect(try !Self.run(format, prose + [Self.thinkEnd], info: info).accepted)
    }

    /// `test_token_markers_reasoning_block_closes_on_dedicated_think_token` (upstream: Qwen3-Coder).
    @Test(.enabled(if: LocalTokenizers.has(.qwen3)))
    func reasoningBlockClosesOnDedicatedThinkToken() throws {
        let info = try #require(LocalTokenizers.info(.qwen3))
        let plan: [Int32] = [10393], nn: [Int32] = [271], spelledThinkEnd: [Int32] = [522, 26865, 29]
        let format = try Self.format(.qwen3Coder, .required, reasoning: .enabled)
        #expect(try Self.run(format, plan + [Self.thinkEnd] + nn + Self.xmlAtomic, info: info).completed)
        // The spelled form is reasoning text: accepted, but the block never closes.
        let spelled = try Self.run(format, plan + spelledThinkEnd + nn + Self.xmlAtomic, info: info)
        #expect(spelled.accepted)
        #expect(!spelled.completed)
    }

    /// `test_token_markers_without_special_token_excludes_terminates`, on the Qwen 3 grammar
    /// (upstream: GLM-4.7-Flash). Without excludes of its own the reasoning content must still
    /// stop at the dedicated `</think>` token so a valid response can complete.
    @Test(.enabled(if: LocalTokenizers.has(.qwen3)), arguments: [ToolChoice.required, .automatic])
    func withoutSpecialTokenExcludesTerminates(_ choice: ToolChoice) throws {
        let info = try #require(LocalTokenizers.info(.qwen3))
        let format = try StructuralFormat.toolCalls(Self.tools, model: .qwen3, choice: choice, reasoning: .enabled,
                                                    excludeSpecialTokens: false, tokenMarkers: true)
        #expect(try Self.run(format, [10393, Self.thinkEnd, 271] + Self.qwen3Atomic, info: info).completed)
    }
}
