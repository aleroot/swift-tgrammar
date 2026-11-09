// Model-family tool-call formats, ported from XGrammar's built-in structural tag registry.
// Each builder assembles a reasoning prefix and a model-specific suffix from the normalised tool
// selection; all string constants are the models' chat-template delimiters.
struct ToolCallBuilder {
    let format: ToolCallDialect
    let selection: ToolSelection
    let reasoning: ReasoningMode
    let parallelCalls: Bool
    let anyOrder: Bool
    let excludeSpecialTokens: Bool
    let maxWhitespaceCount: Int?
    let captureArguments: Bool

    private var functions: [ToolDefinition] { selection.functions }
    private var builtins: [BuiltinToolDefinition] { selection.builtins }
    private var policy: ToolSelection.Policy { selection.policy }
    private var stopAfterFirst: Bool { !parallelCalls }

    func build() throws(GrammarError) -> StructuralFormat {
        // Formats without builtin-tool syntax ignore builtin tools; a selection that leaves no
        // function tool to call cannot be satisfied.
        if !format.supportsBuiltinTools, functions.isEmpty {
            if policy == .forced { throw .conversion("Forced tool choice must resolve to exactly one tool.") }
            if policy == .required { throw .conversion("Required tool choice needs at least one function tool.") }
        }
        return switch format {
        case .llama: llama()
        case .kimi: kimi()
        case .kimiK3: kimiK3()
        case .deepSeekR1: deepSeekR1()
        case .deepSeekV31: deepSeekV31()
        case .deepSeekV32: deepSeekV32()
        case .deepSeekV4: deepSeekV4(v41: false)
        case .deepSeekV41: deepSeekV4(v41: true)
        case .qwen3: qwen3()
        case .qwen35, .qwen3Coder: qwen35()
        case .mimo: mimo()
        case .harmony: harmony()
        case .miniMax: miniMax()
        case .miniMaxM3: miniMaxM3()
        case .glm47: glm47()
        case .gemma4: gemma4()
        case .cohere: cohere()
        case .exaone: exaone()
        case .mistral: mistral()
        case .functionGemma: functionGemma()
        case .lfm2: lfm2()
        case .atem: atem()
        }
    }

    // MARK: Shared pieces

    private static let thinkTokens = ["<think>", "</think>"]

    /// The tokens to forbid inside free-text spans, unless the caller keeps them available.
    private func excludes(_ tokens: [String]) -> [String] { excludeSpecialTokens ? tokens : [] }

    private func arguments(_ schema: JSONSchema, name: String, style: JSONSchemaOptions.Style = .json, excludes: [String] = []) -> StructuralFormat {
        let content = StructuralFormat.jsonSchema(schema, options: .init(anyWhitespace: true, anyOrder: anyOrder, maxWhitespaceCount: maxWhitespaceCount, style: style, excludes: excludes))
        return captureArguments ? .captured(name, content) : content
    }

    private func arguments(_ tool: ToolDefinition, style: JSONSchemaOptions.Style = .json, excludes: [String] = []) -> StructuralFormat {
        arguments(tool.argumentSchema, name: tool.name, style: style, excludes: excludes)
    }

    private func tag(_ begin: String, _ content: StructuralFormat, _ end: String) -> StructuralTag {
        .init(begin: .text(begin), content: content, end: .text(end))
    }

    /// One tag per function: `prefix + name + suffix`, arguments, `end`.
    private func functionTags(prefix: String, suffix: String = "", end: String, style: JSONSchemaOptions.Style = .json,
                              excludes: [String] = []) -> [StructuralTag] {
        functions.map { tag(prefix + $0.name + suffix, arguments($0, style: style, excludes: excludes), end) }
    }

    /// A conventional leading reasoning block. `.enabled` continues an opener the prompt already
    /// ends with, or generates the whole block when the template does not prefill it.
    private func reasoningPrefix(begin: String, end: String, excludes reasoningExcludes: [String],
                                 promptEndsWithOpener: Bool = true, suffix: String = "") -> StructuralFormat? {
        let opener: String
        switch reasoning {
        case .disabled: return nil
        case .enabled: opener = promptEndsWithOpener ? "" : begin
        case .continuation: opener = ""
        case .required, .optional: opener = begin
        }
        var prefix = StructuralFormat.tag(tag(opener, .anyText(excluding: excludes(reasoningExcludes)), end))
        if !suffix.isEmpty { prefix = .sequence([prefix, .literal(suffix)]) }
        return reasoning == .optional ? .optional(prefix) : prefix
    }

    private func assemble(_ prefix: StructuralFormat?, _ suffix: StructuralFormat) -> StructuralFormat {
        prefix.map { .sequence([$0, suffix]) } ?? suffix
    }

    /// Free text that may dispatch into the tags at `trigger`; text only when no tool is left.
    private func triggered(_ tags: [StructuralTag], trigger: String, textExcludes: [String], noToolExcludes: [String]? = nil) -> StructuralFormat {
        switch policy {
        case .forced: return .tag(tags[0])
        case .required:
            return .triggeredTags(triggers: [trigger], tags: tags, atLeastOne: true, stopAfterFirst: stopAfterFirst, excluding: excludes(textExcludes))
        case .automatic:
            guard !tags.isEmpty else { return .anyText(excluding: excludes(noToolExcludes ?? textExcludes)) }
            return .triggeredTags(triggers: [trigger], tags: tags, stopAfterFirst: stopAfterFirst, excluding: excludes(textExcludes))
        }
    }

    /// Calls grouped inside a section that free text may open at `trigger`.
    private func sectioned(_ tags: [StructuralTag], begin: String, end: String, trigger: String, separator: String,
                           textExcludes: [String], forcedPrefix: String = "") -> StructuralFormat {
        let calls = StructuralFormat.tagsWithSeparator(policy == .forced ? [tags[0]] : tags, separator: separator, atLeastOne: true, stopAfterFirst: stopAfterFirst)
        switch policy {
        case .automatic:
            guard !tags.isEmpty else { return .anyText(excluding: excludes(textExcludes)) }
            return .triggeredTags(triggers: [trigger], tags: [tag(begin, calls, end)], stopAfterFirst: stopAfterFirst, excluding: excludes(textExcludes))
        case .forced: return .sequence([.literal(forcedPrefix + begin), .tag(tags[0]), .literal(end)])
        case .required: return .sequence([.literal(forcedPrefix + begin), calls, .literal(end)])
        }
    }

    // MARK: Models

    private func llama() -> StructuralFormat {
        let tags = functionTags(prefix: "{\"name\": \"", suffix: "\", \"parameters\": ", end: "}")
        return triggered(tags, trigger: "{\"name\": ", textExcludes: Self.thinkTokens)
    }

    private func kimi() -> StructuralFormat {
        let callBegin = "<|tool_call_begin|>", sectionBegin = "<|tool_calls_section_begin|>", sectionEnd = "<|tool_calls_section_end|>"
        let tags = functions.map { tool in
            tag(callBegin + "functions." + tool.name + ":",
                .sequence([.regex(#"\d+"#), .literal("<|tool_call_argument_begin|>"), arguments(tool)]), "<|tool_call_end|>")
        }
        let suffix: StructuralFormat
        switch policy {
        case .automatic where tags.isEmpty: suffix = .anyText(excluding: excludes(Self.thinkTokens))
        case .automatic:
            let calls = StructuralFormat.tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst)
            suffix = .triggeredTags(triggers: [sectionBegin], tags: [tag(sectionBegin, calls, sectionEnd)], stopAfterFirst: stopAfterFirst,
                                    excluding: excludes(Self.thinkTokens + [callBegin]))
        case .forced: suffix = .sequence([.literal(sectionBegin), .tag(tags[0]), .literal(sectionEnd)])
        case .required:
            suffix = .sequence([.literal(sectionBegin), .tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst), .literal(sectionEnd)])
        }
        // Kimi K2 does not prefill <think>; enabled mode keeps accepting it as text.
        let prefix = reasoningPrefix(begin: "<think>", end: "</think>", excludes: reasoning == .optional ? Self.thinkTokens : [])
        return assemble(prefix, suffix)
    }

    private func kimiK3() -> StructuralFormat {
        let open = "<|open|>", close = "<|close|>", sep = "<|sep|>"
        let specialTokens = [open, close]
        func call(_ tool: ToolDefinition) -> StructuralTag {
            // <|open|>call tool="NAME" index="N"<|sep|>arguments<|close|>call<|sep|>
            tag(open + "call tool=\"" + tool.name + "\" index=\"",
                .sequence([.regex(#"\d+"#), .literal("\"" + sep), arguments(tool, style: .kimiK3XML, excludes: excludes([open, close, sep]))]),
                close + "call" + sep)
        }
        let tags = functions.map(call)
        let calls = StructuralFormat.tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst)
        let section = tag(open + "tools" + sep, calls, close + "tools" + sep)
        let tools: StructuralFormat?
        switch policy {
        case .automatic: tools = tags.isEmpty ? nil : .optional(.tag(section))
        case .forced: tools = .sequence([.literal(section.begin.text), .tag(tags[0]), .literal(close + "tools" + sep)])
        case .required: tools = .sequence([.literal(section.begin.text), calls, .literal(close + "tools" + sep)])
        }
        // The generation prompt already emitted the first block's opening marker, so output
        // starts inside its body: the think body in reasoning mode, the response body otherwise.
        var elements: [StructuralFormat] = []
        if let prefix = reasoningPrefix(begin: open + "think" + sep, end: close + "think" + sep, excludes: specialTokens) { elements.append(prefix) }
        elements.append(.tag(tag(reasoning == .disabled ? "" : open + "response" + sep, .anyText(excluding: excludes(specialTokens)), close + "response" + sep)))
        if let tools { elements.append(tools) }
        elements.append(.literal(close + "message" + sep))
        return .sequence(elements)
    }

    private func deepSeekR1() -> StructuralFormat {
        let callsBegin = "<｜tool▁calls▁begin｜>", callsEnd = "<｜tool▁calls▁end｜>", callBegin = "<｜tool▁call▁begin｜>", callEnd = "<｜tool▁call▁end｜>"
        let tags = functionTags(prefix: callBegin + "function<｜tool▁sep｜>", suffix: "\n```json\n", end: "\n```" + callEnd)
        let suffix: StructuralFormat
        switch policy {
        case .forced:
            suffix = .tag(.init(begin: .text(callsBegin + tags[0].begin.text), content: tags[0].content, end: .text(tags[0].ends[0].text + callsEnd)))
        default:
            let calls = StructuralFormat.tagsWithSeparator(tags, separator: "\n", atLeastOne: true, stopAfterFirst: stopAfterFirst)
            if policy == .required { suffix = .tag(tag(callsBegin, calls, callsEnd)) }
            else if tags.isEmpty { suffix = .anyText(excluding: excludes(Self.thinkTokens)) }
            else { suffix = .triggeredTags(triggers: [callsBegin], tags: [tag(callsBegin, calls, callsEnd)], stopAfterFirst: stopAfterFirst, excluding: excludes(Self.thinkTokens)) }
        }
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens), suffix)
    }

    private func deepSeekV31() -> StructuralFormat {
        let callsBegin = "<｜tool▁calls▁begin｜>", callsEnd = "<｜tool▁calls▁end｜>", callBegin = "<｜tool▁call▁begin｜>", callEnd = "<｜tool▁call▁end｜>"
        let tags = functionTags(prefix: callBegin, suffix: "<｜tool▁sep｜>", end: callEnd)
        let suffix: StructuralFormat
        switch policy {
        case .forced:
            suffix = .tag(.init(begin: .text(callsBegin + tags[0].begin.text), content: tags[0].content, end: .text(callEnd + callsEnd)))
        default:
            let calls = StructuralFormat.tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst)
            if policy == .required { suffix = .tag(tag(callsBegin, calls, callsEnd)) }
            else if tags.isEmpty { suffix = .anyText(excluding: excludes(Self.thinkTokens)) }
            else { suffix = .triggeredTags(triggers: [callsBegin], tags: [tag(callsBegin, calls, callsEnd)], stopAfterFirst: stopAfterFirst, excluding: excludes(Self.thinkTokens)) }
        }
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens), suffix)
    }

    private func deepSeekV32() -> StructuralFormat {
        // The invoke end keeps a trailing newline so the final invoke is followed by a single
        // newline before the closing tag; consecutive invokes therefore need no separator.
        let tags = functionTags(prefix: "<｜DSML｜invoke name=\"", suffix: "\">\n", end: "</｜DSML｜invoke>\n", style: .deepSeekXML)
        let suffix = sectioned(tags, begin: "<｜DSML｜function_calls>\n", end: "</｜DSML｜function_calls>", trigger: "<｜DSML｜function_calls>",
                               separator: "", textExcludes: Self.thinkTokens, forcedPrefix: "\n\n")
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens), suffix)
    }

    private func deepSeekV4(v41: Bool) -> StructuralFormat {
        let invoke = v41 ? " invoke" : "invoke", calls = v41 ? " calls" : "tool_calls"
        let trigger = "<｜DSML｜\(calls)>"
        let tags = functionTags(prefix: "<｜DSML｜\(invoke) name=\"", suffix: "\">\n", end: "</｜DSML｜\(invoke)>\n", style: v41 ? .deepSeekV41XML : .deepSeekXML)
        let suffix: StructuralFormat
        if policy == .automatic, tags.isEmpty {
            // With no available tools a calls block must not slip through as unconstrained text.
            suffix = .anyText(excluding: excludes(Self.thinkTokens) + (v41 ? [trigger] : []))
        } else if policy == .automatic {
            // Both V4 and V4.1 end the assistant turn after one calls block.
            let block = tag(trigger + "\n", .tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst), "</｜DSML｜\(calls)>")
            suffix = .triggeredTags(triggers: [trigger], tags: [block], stopAfterFirst: true, excluding: excludes(Self.thinkTokens))
        } else {
            suffix = sectioned(tags, begin: trigger + "\n", end: "</｜DSML｜\(calls)>", trigger: trigger, separator: "", textExcludes: Self.thinkTokens, forcedPrefix: "\n\n")
        }
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens), suffix)
    }

    private func qwen3() -> StructuralFormat {
        let tags = functionTags(prefix: "<tool_call>\n{\"name\": \"", suffix: "\", \"arguments\": ", end: "}\n</tool_call>")
        let suffix = triggered(tags, trigger: "<tool_call>", textExcludes: Self.thinkTokens)
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens, suffix: "\n\n"), suffix)
    }

    private func qwen35() -> StructuralFormat {
        let tags = functionTags(prefix: "<tool_call>\n<function=", suffix: ">\n", end: "\n</function>\n</tool_call>", style: .qwenXML)
        let suffix = triggered(tags, trigger: "<tool_call>\n<function=", textExcludes: Self.thinkTokens)
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens, suffix: "\n\n"), suffix)
    }

    private func mimo() -> StructuralFormat {
        let textExcludes = ["<think>", "</think>", "</tool_call>", "<function="]
        let reasoningExcludes = ["<tool_call>"] + textExcludes
        let tags = functionTags(prefix: "<tool_call><function=", suffix: ">", end: "</function></tool_call>", style: .qwenXML)
        let suffix = triggered(tags, trigger: "<tool_call>", textExcludes: textExcludes, noToolExcludes: reasoningExcludes)
        // The template ends the generation prompt before <think>, so enabled mode generates it.
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: reasoningExcludes, promptEndsWithOpener: false), suffix)
    }

    private func harmony() -> StructuralFormat {
        let callEnd = "<|call|>", separator = "<|start|>assistant"
        let messageEnds: [TagBoundary] = ["<|end|>", "<|return|>"]
        func functionTags(_ tool: ToolDefinition) -> [StructuralTag] {
            let content = arguments(tool)
            return ["<|channel|>commentary to=functions.\(tool.name)<|constrain|>json<|message|>",
                    " to=functions.\(tool.name)<|channel|>commentary <|constrain|>json<|message|>",
                    " to=functions.\(tool.name)<|channel|>commentary json<|message|>"].map { tag($0, content, callEnd) }
        }
        func builtinTags(_ tool: BuiltinToolDefinition) -> [StructuralTag] {
            let content = arguments(tool.argumentSchema, name: tool.outputName)
            return ["<|channel|>commentary to=\(tool.outputName) code<|message|>",
                    " to=\(tool.outputName)<|channel|>commentary code<|message|>"].map { tag($0, content, callEnd) }
        }
        var tags: [StructuralTag] = []
        switch policy {
        case .automatic:
            tags = functions.flatMap(functionTags) + builtins.flatMap(builtinTags)
            tags.append(.init(begin: "<|channel|>final<|message|>", content: .anyText(), ends: messageEnds))
        case .forced:
            tags = builtins.isEmpty ? functionTags(functions[0]) : builtinTags(builtins[0])
        case .required:
            tags = builtins.flatMap(builtinTags) + functions.flatMap(functionTags)
        }
        if reasoning != .disabled {
            tags.append(.init(begin: "<|channel|>analysis<|message|>", content: .anyText(), ends: messageEnds))
        }
        let callTags = tags.filter { $0.ends == [.text(callEnd)] }
        let messageTags = tags.filter { $0.ends != [.text(callEnd)] }
        if parallelCalls || callTags.isEmpty { return .tagsWithSeparator(tags, separator: separator) }
        // Harmony carries tool calls, analysis and final messages in one stream, so capping the
        // stream at one message would also forbid an ordinary reasoning or final message. Cap
        // the tool-call messages alone: any other messages, then at most one call, which ends
        // the turn.
        let oneCall = StructuralFormat.tagsWithSeparator(callTags, separator: separator, atLeastOne: true, stopAfterFirst: true)
        if messageTags.isEmpty { return .optional(oneCall) }
        let messagesThenCall = StructuralFormat.sequence([.tagsWithSeparator(messageTags, separator: separator, atLeastOne: true), .literal(separator), oneCall])
        return .choice([.tagsWithSeparator(messageTags, separator: separator), oneCall, messagesThenCall])
    }

    private func miniMax() -> StructuralFormat {
        let tags = functionTags(prefix: "<invoke name=\"", suffix: "\">\n", end: "</invoke>\n", style: .miniMaxXML)
        let suffix = sectioned(tags, begin: "<minimax:tool_call>\n", end: "</minimax:tool_call>", trigger: "<minimax:tool_call>",
                               separator: "", textExcludes: Self.thinkTokens, forcedPrefix: "\n")
        if reasoning == .disabled { return .sequence([.literal("\n</think>\n\n"), .literal("\n\n"), suffix]) }
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: reasoning == .enabled ? [] : Self.thinkTokens, suffix: "\n\n"), suffix)
    }

    private func miniMaxM3() -> StructuralFormat {
        let namespace = "]<]minimax[>["
        let callBegin = namespace + "<tool_call>\n", callEnd = namespace + "</tool_call>", trigger = namespace + "<tool_call>"
        let thinkBegin = "<mm:think>", thinkEnd = "</mm:think>"
        // The bare namespace is not excluded: every M3 element and the tool-call trigger share it.
        let strayMarkers = [callEnd, namespace + "<invoke", namespace + "</invoke>"]
        let suffixExcludes = [thinkBegin, thinkEnd] + strayMarkers
        let reasoningExcludes = [trigger] + suffixExcludes
        let invokes = functionTags(prefix: namespace + "<invoke name=\"", suffix: "\">", end: namespace + "</invoke>\n", style: .miniMaxM3XML)
        func toolCall(_ tags: [StructuralTag], allowMultiple: Bool = true) -> StructuralTag {
            tag(callBegin, allowMultiple ? .tagsWithSeparator(tags, separator: "", atLeastOne: true, stopAfterFirst: stopAfterFirst) : .tag(tags[0]), callEnd)
        }
        let suffix: StructuralFormat
        switch policy {
        case .automatic where invokes.isEmpty: suffix = .anyText(excluding: excludes([trigger] + suffixExcludes))
        case .automatic:
            suffix = .triggeredTags(triggers: [trigger], tags: [toolCall(invokes)], stopAfterFirst: stopAfterFirst, excluding: excludes(suffixExcludes))
        case .forced: suffix = .tag(toolCall([invokes[0]], allowMultiple: false))
        case .required:
            suffix = .triggeredTags(triggers: [trigger], tags: [toolCall(invokes)], atLeastOne: true, stopAfterFirst: stopAfterFirst, excluding: excludes(suffixExcludes))
        }
        // The generation prompt already emitted the first block's opening marker, so output
        // starts inside its body. The adaptive template may emit a lone closing marker when
        // skipping reasoning.
        var prefix = reasoningPrefix(begin: thinkBegin, end: thinkEnd, excludes: reasoningExcludes)
        if case .optional(let block)? = prefix { prefix = .optional(.choice([block, .literal(thinkEnd)])) }
        return assemble(prefix, suffix)
    }

    private func glm47() -> StructuralFormat {
        // Tool-call control tokens are only valid inside a call: free text after </think> may
        // start a call through the trigger, reasoning may not contain any of them.
        let argTokens = ["<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"]
        let reasoningExcludes = Self.thinkTokens + ["<tool_call>", "</tool_call>"] + argTokens
        let textExcludes = Self.thinkTokens + ["</tool_call>"] + argTokens
        let tags = functionTags(prefix: "<tool_call>", end: "</tool_call>", style: .glmXML)
        let suffix = triggered(tags, trigger: "<tool_call>", textExcludes: textExcludes, noToolExcludes: reasoningExcludes)
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: reasoningExcludes), suffix)
    }

    private func gemma4() -> StructuralFormat {
        let trigger = "<|tool_call>", callEnd = "<tool_call|>"
        // <|tool_response> is the template's halt signal after a call and is handled as a stop
        // sequence rather than excluded. The trigger stays allowed in triggered free text.
        let channelTokens = ["<|channel>", "<channel|>"]
        // A call cannot start where its arguments would be unconstrained: the thought channel
        // and tool-less free text exclude the trigger. Argument strings exclude every marker.
        let reasoningExcludes = channelTokens + [trigger]
        let argumentExcludes = channelTokens + [trigger, callEnd]
        let tags = functionTags(prefix: trigger + "call:", end: callEnd, style: .gemma, excludes: excludes(argumentExcludes))
        let suffix = triggered(tags, trigger: trigger, textExcludes: channelTokens, noToolExcludes: reasoningExcludes)
        return assemble(reasoningPrefix(begin: "<|channel>thought\n", end: "<channel|>", excludes: reasoningExcludes, promptEndsWithOpener: false), suffix)
    }

    private func cohere() -> StructuralFormat {
        let thinkTokens = ["<|START_THINKING|>", "<|END_THINKING|>"]
        let tags = functions.map { tool in
            tag("<cofl:tool_call id=\"",
                .sequence([.regex(#"\d+"#), .literal("\" name=\"" + tool.name + "\">"), arguments(tool, style: .cohereXML)]),
                "</cofl:tool_call>")
        }
        let suffix = sectioned(tags, begin: "<cofl:tool_calls>", end: "</cofl:tool_calls>", trigger: "<cofl:tool_calls>", separator: "", textExcludes: thinkTokens)
        return assemble(reasoningPrefix(begin: thinkTokens[0], end: thinkTokens[1], excludes: reasoning == .enabled ? [] : thinkTokens), suffix)
    }

    private func exaone() -> StructuralFormat {
        let tags = functionTags(prefix: "<tool_call>{\"name\": \"", suffix: "\", \"arguments\": ", end: "}</tool_call>")
        let suffix = triggered(tags, trigger: "<tool_call>", textExcludes: Self.thinkTokens)
        return assemble(reasoningPrefix(begin: "<think>", end: "</think>", excludes: reasoning == .enabled ? [] : Self.thinkTokens, suffix: "\n\n"), suffix)
    }

    // MARK: Formats beyond XGrammar's registry

    private func mistral() -> StructuralFormat {
        // Calls have no closing tag: they end the response, and each further call repeats the
        // [TOOL_CALLS] opener. Free text may not follow a call.
        let callsBegin = "[TOOL_CALLS]", thinkTokens = ["[THINK]", "[/THINK]"]
        let tags = functions.map { tag($0.name + "[ARGS]", arguments($0), "") }
        let calls = StructuralFormat.tagsWithSeparator(policy == .forced ? [tags[0]] : tags, separator: callsBegin,
                                                       atLeastOne: true, stopAfterFirst: stopAfterFirst)
        let suffix: StructuralFormat
        switch policy {
        case .automatic where tags.isEmpty: suffix = .anyText(excluding: excludes(thinkTokens + [callsBegin, "[ARGS]"]))
        case .automatic:
            suffix = .triggeredTags(triggers: [callsBegin], tags: [tag(callsBegin, calls, "")], stopAfterFirst: true,
                                    excluding: excludes(thinkTokens + ["[ARGS]"]))
        case .forced, .required: suffix = .sequence([.literal(callsBegin), calls])
        }
        let prefix = reasoningPrefix(begin: thinkTokens[0], end: thinkTokens[1], excludes: thinkTokens + [callsBegin, "[ARGS]"],
                                     promptEndsWithOpener: false)
        return assemble(prefix, suffix)
    }

    private func functionGemma() -> StructuralFormat {
        let trigger = "<start_function_call>", callEnd = "<end_function_call>"
        // Argument strings exclude both call markers besides the `<escape>` delimiter; a call
        // cannot start in tool-less free text, where its arguments would be unconstrained.
        let tags = functionTags(prefix: trigger + "call:", end: callEnd, style: .functionGemma, excludes: excludes([trigger, callEnd]))
        return triggered(tags, trigger: trigger, textExcludes: [callEnd, "<escape>"], noToolExcludes: [trigger, callEnd, "<escape>"])
    }

    private func lfm2() -> StructuralFormat {
        let callBegin = "<|tool_call_start|>", callEnd = "<|tool_call_end|>"
        let tags = functions.map { tag($0.name + "(", arguments($0, style: .pythonic), ")") }
        let suffix = sectioned(tags, begin: callBegin + "[", end: "]" + callEnd, trigger: callBegin, separator: ", ",
                               textExcludes: Self.thinkTokens + [callEnd])
        let prefix = reasoningPrefix(begin: "<think>", end: "</think>", excludes: Self.thinkTokens + [callBegin, callEnd],
                                     promptEndsWithOpener: false)
        return assemble(prefix, suffix)
    }

    /// Onyx frames. The prompt ends with `<|start|>assistant`, so output starts inside the first
    /// frame's header. mlx-swift-lm's frame parser compares control tokens by id, so frame
    /// delimiters are matched as tokens and payload text excludes their spelling.
    private func atem() -> StructuralFormat {
        let message = StructuralFormat.token(.piece("<|message|>"))
        let nextFrame = StructuralFormat.sequence([.token(.piece("<|eom|>")), .token(.piece("<|start|>")), .literal("assistant")])
        let payloadExcludes = excludes(["<|start|>", "<|message|>", "<|eom|>", "<|eot|>", "<|end_of_text|>"])
        let space = StructuralFormat.regex(#"[ \t\r\n]*"#)
        // A tool frame is addressed to the tool and carries exactly one invoke of it.
        let frames = functions.map { tool -> StructuralFormat in
            .sequence([.literal(" to=" + tool.name), message, space, .literal("<atem:function_calls>"), space,
                       .literal("<atem:invoke name=\"" + tool.name + "\">"), arguments(tool, style: .atemXML, excludes: payloadExcludes),
                       space, .literal("</atem:invoke>"), space, .literal("</atem:function_calls>"), space])
        }
        let call = StructuralFormat.choice(policy == .forced ? [frames[0]] : frames)
        let calls = stopAfterFirst || policy == .forced ? call : .sequence([call, .zeroOrMore(.sequence([nextFrame, call]))])
        let response = StructuralFormat.sequence([.choice([message, .sequence([.literal(" to=user"), message])]), .anyText(excluding: payloadExcludes)])
        let suffix: StructuralFormat = switch policy {
        case .automatic: frames.isEmpty ? response : .choice([response, calls])
        case .required, .forced: calls
        }
        let thought = StructuralFormat.anyText(excluding: payloadExcludes)
        let prefix: StructuralFormat? = switch reasoning {
        case .disabled: nil
        case .continuation: .sequence([thought, nextFrame])
        case .enabled, .required: .sequence([.literal(" to=self"), message, thought, nextFrame])
        case .optional: .optional(.sequence([.literal(" to=self"), message, thought, nextFrame]))
        }
        return assemble(prefix, suffix)
    }
}

private extension TagBoundary {
    var text: String { if case .text(let value) = self { value } else { "" } }
}
