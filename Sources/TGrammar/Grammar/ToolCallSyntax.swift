/// The text around a model's reasoning block: `<think>`, `</think>` and the separator before the
/// response, `"\n\n"`, by default.
public struct ReasoningDelimiters: Sendable, Hashable {
    public var begin: String
    public var end: String
    public var suffix: String

    public init(begin: String = "<think>", end: String = "</think>", suffix: String = "\n\n") {
        self.begin = begin
        self.end = end
        self.suffix = suffix
    }
}

/// A custom wire format for function calls, for models without a built-in `ToolCallDialect`.
/// Custom syntaxes use the same compiler and matcher as the built-in formats; applications do
/// not assemble or interpolate EBNF.
public struct ToolCallSyntax: Sendable, Hashable {
    public typealias Reasoning = ReasoningDelimiters

    public var namePrefix: String
    public var nameSuffix: String
    public var end: String
    public var trigger: String
    public var parameterStyle: JSONSchemaOptions.Style
    public var reasoning: Reasoning?

    public init(namePrefix: String, nameSuffix: String, end: String, trigger: String,
                parameterStyle: JSONSchemaOptions.Style = .json, reasoning: Reasoning? = nil) {
        self.namePrefix = namePrefix
        self.nameSuffix = nameSuffix
        self.end = end
        self.trigger = trigger
        self.parameterStyle = parameterStyle
        self.reasoning = reasoning
    }

    public static let qwen3 = Self(namePrefix: "<tool_call>\n{\"name\": \"",
                                  nameSuffix: "\", \"arguments\": ", end: "}\n</tool_call>",
                                  trigger: "<tool_call>", reasoning: .init())
    public static let qwenXML = Self(namePrefix: "<tool_call>\n<function=", nameSuffix: ">\n",
                                    end: "\n</function>\n</tool_call>", trigger: "<tool_call>\n<function=",
                                    parameterStyle: .qwenXML, reasoning: .init())
    public static let llama = Self(namePrefix: "{\"name\": \"", nameSuffix: "\", \"parameters\": ",
                                  end: "}", trigger: "{\"name\": ")
}

extension StructuralFormat {
    /// Builds constrained function calls using an explicit wire syntax.
    ///
    /// Arguments are captured under the function name when `captureArguments` is true. Captures
    /// describe completed parameter parses; dispatch a call only after its enclosing tag has
    /// completed. XML captures may include trailing whitespace. `.enabled` reasoning continues
    /// an opener already present in the prompt. Arguments accept any JSON whitespace by default,
    /// as ``ToolCallDialect`` grammars do, so each model keeps the spacing it was trained on.
    public static func toolCalls(_ tools: [ToolDefinition], syntax: ToolCallSyntax,
                                 choice: ToolChoice = .automatic, reasoning: ReasoningMode = .disabled,
                                 parallelCalls: Bool = true, schemaOptions: JSONSchemaOptions = .init(anyWhitespace: true),
                                 captureArguments: Bool = false) throws(GrammarError) -> Self {
        guard !syntax.trigger.isEmpty, syntax.namePrefix.hasPrefix(syntax.trigger), !syntax.end.isEmpty else {
            throw .conversion("Tool syntax needs a non-empty trigger prefix and end delimiter")
        }
        for tool in tools {
            guard tool.name.utf8.count <= 64,
                  tool.name.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 45 }) else {
                throw .conversion("Tool names must contain 1–64 ASCII letters, digits, underscores or hyphens")
            }
        }
        let selection = try ToolSelection(tools.map(ToolDeclaration.function), choice: choice)
        var options = schemaOptions
        options.style = syntax.parameterStyle
        let reasoningDelimiters = syntax.reasoning.map { [$0.begin, $0.end] } ?? []
        let tags = selection.functions.map { tool in
            var content = Self.jsonSchema(tool.argumentSchema, options: options)
            if captureArguments { content = .captured(tool.name, content) }
            return StructuralTag(begin: .text(syntax.namePrefix + tool.name + syntax.nameSuffix),
                                 content: content, end: .text(syntax.end))
        }
        let suffix: Self
        switch selection.policy {
        case .forced: suffix = .tag(tags[0])
        case .required:
            suffix = .triggeredTags(triggers: [syntax.trigger], tags: tags, atLeastOne: true,
                                    stopAfterFirst: !parallelCalls, excluding: reasoningDelimiters)
        case .automatic:
            suffix = tags.isEmpty ? .anyText(excluding: reasoningDelimiters + [syntax.trigger])
                : .triggeredTags(triggers: [syntax.trigger], tags: tags, stopAfterFirst: !parallelCalls, excluding: reasoningDelimiters)
        }
        guard let delimiters = syntax.reasoning else { return suffix }
        return try .reasoning(reasoning, delimiters: delimiters, then: suffix)
    }

    /// A reasoning block followed by `answer`, so a thinking model can reason before a
    /// constrained response such as `.jsonSchema(schema)`.
    ///
    /// `.required` and `.optional` generate the opener; `.enabled` and `.continuation` continue
    /// an opener the chat template already ended the prompt with; `.disabled` returns `answer`.
    /// The delimiters and `suffix` are matched exactly, so the answer starts right after them and
    /// no free whitespace is left for the model to loop on. `maxTokens` caps the reasoning, after
    /// which the block must close.
    public static func reasoning(_ mode: ReasoningMode, delimiters: ReasoningDelimiters = .init(), maxTokens: Int? = nil,
                                 then answer: Self) throws(GrammarError) -> Self {
        guard mode != .disabled else { return answer }
        guard !delimiters.begin.isEmpty, !delimiters.end.isEmpty else { throw .conversion("Reasoning delimiters must not be empty") }
        let continues = mode == .continuation || mode == .enabled
        var prefix = Self.tag(.init(begin: .text(continues ? "" : delimiters.begin),
                                    content: .anyText(excluding: [delimiters.begin], maxTokens: maxTokens), end: .text(delimiters.end)))
        if !delimiters.suffix.isEmpty { prefix = .sequence([prefix, .literal(delimiters.suffix)]) }
        if mode == .optional { prefix = .optional(prefix) }
        return .sequence([prefix, answer])
    }
}

extension GrammarCompiler {
    public func compile(toolCalls tools: [ToolDefinition], syntax: ToolCallSyntax,
                        choice: ToolChoice = .automatic, reasoning: ReasoningMode = .disabled,
                        parallelCalls: Bool = true, schemaOptions: JSONSchemaOptions = .init(anyWhitespace: true),
                        captureArguments: Bool = false) throws(GrammarError) -> CompiledGrammar {
        try compile(structuralFormat: .toolCalls(tools, syntax: syntax, choice: choice, reasoning: reasoning,
                                                parallelCalls: parallelCalls, schemaOptions: schemaOptions,
                                                captureArguments: captureArguments))
    }
}
