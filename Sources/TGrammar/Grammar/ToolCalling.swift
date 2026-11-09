/// A function the model may invoke, in the Chat Completions shape. Descriptions belong in the
/// chat template; only the name and parameter schema affect constrained generation.
public struct ToolDefinition: Sendable, Hashable {
    public var name: String
    /// The argument schema. `nil` leaves the arguments syntactically constrained but
    /// schema-unconstrained, as does `strict == false`.
    public var parameters: JSONSchema?
    public var strict: Bool

    public init(name: String, parameters: JSONSchema? = nil, strict: Bool = true) {
        self.name = name
        self.parameters = parameters
        self.strict = strict
    }

    /// The schema used for constrained arguments.
    var argumentSchema: JSONSchema { strict ? parameters ?? .any : .any }
}

/// A hosted or server tool whose call arguments should be constrained, such as a Harmony
/// `browser.search`. `type` is the provider-facing tool type; `name` is the name that appears
/// in model output when it differs from the type.
public struct BuiltinToolDefinition: Sendable, Hashable {
    public var type: String
    public var name: String?
    public var parameters: JSONSchema?

    public init(type: String, name: String? = nil, parameters: JSONSchema? = nil) {
        self.type = type
        self.name = name
        self.parameters = parameters
    }

    /// The name the model emits.
    public var outputName: String { name ?? type }
    var argumentSchema: JSONSchema { parameters ?? .any }
}

/// A tool available to the model.
public enum ToolDeclaration: Sendable, Hashable {
    case function(ToolDefinition)
    case builtin(BuiltinToolDefinition)

    /// Reads one Chat Completions function tool (`{"type":"function","function":{...}}`) or
    /// builtin tool (`{"type":<builtin type>,"name":...,"parameters":...}`).
    public init(json: String) throws(GrammarError) {
        try self.init(try JSONValue.parse(json))
    }

    /// Reads a Chat Completions `tools` array.
    public static func tools(json: String) throws(GrammarError) -> [ToolDeclaration] {
        guard let items = try JSONValue.parse(json).array else { throw .conversion("tools must be an array") }
        return try items.map { item throws(GrammarError) in try ToolDeclaration(item) }
    }

    init(_ value: JSONValue) throws(GrammarError) {
        guard let members = value.members else { throw .conversion("A tool must be an object") }
        func schema(_ raw: JSONValue?) throws(GrammarError) -> JSONSchema? {
            guard let raw, raw != .null else { return nil }
            guard raw.members != nil else { throw .conversion("Tool parameters must be a JSON Schema object") }
            return JSONSchema(raw)
        }
        let type = value["type"]?.string
        if let function = value["function"] ?? (type == "function" ? .object([]) : nil) {
            guard type == nil || type == "function" else { throw .conversion("A function tool must have type \"function\"") }
            guard let name = function["name"]?.string else { throw .conversion("A function tool requires a name") }
            let strict: Bool
            switch function["strict"] {
            case nil, .null?: strict = true
            case .bool(let value)?: strict = value
            default: throw .conversion("strict must be a boolean")
            }
            self = .function(.init(name: name, parameters: try schema(function["parameters"]), strict: strict))
            return
        }
        guard let type, !type.isEmpty else { throw .conversion("A builtin tool requires a type") }
        _ = members
        if let name = value["name"], name != .null, name.string == nil { throw .conversion("Builtin tool name must be a string") }
        self = .builtin(.init(type: type, name: value["name"]?.string, parameters: try schema(value["parameters"])))
    }
}

/// A reference to an available tool, as used by an allowed-tools choice.
public enum ToolReference: Sendable, Hashable {
    case function(String)
    case builtin(type: String)
}

/// Controls whether the model may or must call tools, following the Chat Completions API.
public enum ToolChoice: Sendable, Hashable {
    /// Free text, interleaved with calls to any supplied tool.
    case automatic
    /// Begin with a call to at least one of the supplied tools.
    case required
    /// Free text with tool-call openers excluded.
    case none
    /// Produce exactly one call to the named function tool.
    case named(String)
    /// Produce exactly one call to the builtin tool of the given type.
    case builtin(type: String)
    /// Limit the available tools, then apply `required` or automatic selection.
    case allowed([ToolReference], required: Bool = false)

    /// Reads a Chat Completions `tool_choice` value: `"auto"`, `"none"`, `"required"`,
    /// `{"type":"function","function":{"name":...}}`, `{"type":<builtin type>}` or
    /// `{"type":"allowed_tools","allowed_tools":{"mode":...,"tools":[...]}}`.
    public init(json: String) throws(GrammarError) {
        try self.init(try JSONValue.parse(json))
    }

    init(_ value: JSONValue) throws(GrammarError) {
        switch value {
        case .null, .string("auto"): self = .automatic
        case .string("none"): self = .none
        case .string("required"): self = .required
        case .string(let other): throw .conversion("Unknown tool choice \"\(other)\"")
        default:
            guard let type = value["type"]?.string else { throw .conversion("A tool choice object requires a type") }
            switch type {
            case "function":
                guard let name = value["function"]?["name"]?.string ?? value["name"]?.string else { throw .conversion("A function tool choice requires a name") }
                self = .named(name)
            case "allowed_tools":
                let allowed = value["allowed_tools"] ?? value
                guard let mode = allowed["mode"]?.string, mode == "auto" || mode == "required" else { throw .conversion("allowed_tools mode must be \"auto\" or \"required\"") }
                guard let tools = allowed["tools"]?.array else { throw .conversion("allowed_tools requires a tools array") }
                self = .allowed(try tools.map { tool throws(GrammarError) in
                    guard let type = tool["type"]?.string else { throw .conversion("An allowed tool reference requires a type") }
                    if type == "function" {
                        guard let name = tool["function"]?["name"]?.string ?? tool["name"]?.string else { throw .conversion("Allowed function tool references must include a name") }
                        return .function(name)
                    }
                    return .builtin(type: type)
                }, required: mode == "required")
            default: self = .builtin(type: type)
            }
        }
    }
}

/// How a model's reasoning block is handled before its response or tool call.
public enum ReasoningMode: Sendable, Hashable {
    case disabled
    /// The model's native thinking mode: continue the opener the chat template has already
    /// emitted, or generate the whole block for templates that do not prefill it.
    case enabled
    /// An optional complete reasoning block before the response or tool call.
    case optional
    /// A required complete reasoning block, including its opener.
    case required
    /// The prompt already contains the reasoning opener; generate its continuation and end.
    case continuation
}

/// A model family's reasoning and tool-call wire format. Raw values are XGrammar's model keys;
/// `mistral`, `functionGemma`, `lfm2` and `atem` are Swift additions for formats XGrammar has no
/// entry for, keyed by their mlx-swift-lm/mlx-lm names.
public enum ToolCallDialect: String, Sendable, Hashable, CaseIterable {
    /// Llama 3, 3.1 and 3.2: `{"name": "f", "parameters": {...}}`.
    case llama
    /// Kimi K2 and K2.5 token-delimited call sections.
    case kimi
    /// Kimi K3 `<|open|>`/`<|close|>` blocks with typed XML arguments.
    case kimiK3 = "kimi_k3"
    /// DeepSeek R1: JSON arguments in a fenced block.
    case deepSeekR1 = "deepseek_r1"
    /// DeepSeek V3.1 and V3.2-Exp.
    case deepSeekV31 = "deepseek_v3_1"
    /// DeepSeek V3.2 DSML invokes.
    case deepSeekV32 = "deepseek_v3_2"
    /// DeepSeek V4 DSML tool_calls block.
    case deepSeekV4 = "deepseek_v4"
    /// DeepSeek V4.1 space-prefixed DSML calls block.
    case deepSeekV41 = "deepseek_v4_1"
    /// Qwen3 and Qwen3-Next: `<tool_call>` JSON.
    case qwen3 = "qwen_3"
    /// Qwen3.5, Qwen3.6, Qwen3-Coder: `<tool_call><function=f>` XML parameters.
    case qwen35 = "qwen_3_5"
    /// Alias of `qwen35`.
    case qwen3Coder = "qwen_3_coder"
    /// MiMo V2.6: Qwen XML parameters without wrapper newlines.
    case mimo
    /// gpt-oss Harmony channels.
    case harmony
    /// MiniMax M2.5 and M2.7 `<minimax:tool_call>` invokes.
    case miniMax = "minimax"
    /// MiniMax M3 namespace-prefixed recursive XML.
    case miniMaxM3 = "minimax_m3"
    /// GLM-4.7 and GLM-5 `<arg_key>`/`<arg_value>` calls.
    case glm47 = "glm_4_7"
    /// Gemma 4 channel markers and Gemma-style arguments.
    case gemma4 = "gemma_4"
    /// Cohere Command `<cofl:tool_call>` XML.
    case cohere
    /// EXAONE 4.0 inline `<tool_call>` JSON.
    case exaone
    /// Mistral V13 (Mistral 3, Ministral 3, Magistral, Devstral 2): `[TOOL_CALLS]f[ARGS]{...}`
    /// calls that end the response, with an optional `[THINK]` block.
    case mistral
    /// FunctionGemma (Gemma 3): `<start_function_call>call:f{key:<escape>value<escape>}<end_function_call>`.
    case functionGemma = "function_gemma"
    /// LFM2 and LFM2.5: `<|tool_call_start|>[f(key="value")]<|tool_call_end|>` Python calls,
    /// with an optional `<think>` block.
    case lfm2
    /// Muse Glimmer's Onyx frames: `<|start|>assistant to=f<|message|>` followed by ATEM
    /// `<atem:function_calls>` XML, with `to=self` reasoning and `to=user` response frames.
    /// Frame delimiters are matched as the model's control tokens, so the vocabulary must
    /// contain `<|start|>`, `<|message|>` and `<|eom|>`.
    case atem

    /// The format keyed by an XGrammar model name.
    public init?(modelKey: String) { self.init(rawValue: modelKey) }

    /// Whether this format can constrain builtin tools.
    var supportsBuiltinTools: Bool { self == .harmony }
    var rejectsBuiltinTools: Bool { self == .mimo || self == .miniMaxM3 }
    /// The model-specific default: `optional` for MiniMax M3's adaptive template, for the
    /// Mistral and LFM2 families, whose reasoning and instruct variants share one format, and for
    /// Onyx, whose reasoning frame is never prefilled.
    public var defaultReasoning: ReasoningMode {
        switch self {
        case .miniMaxM3, .mistral, .lfm2, .atem: .optional
        default: .enabled
        }
    }

    /// The control markers that are single tokens in the family's tokenizers, which
    /// `tokenMarkers: true` matches as tokens; `nil` when the format does not declare them.
    public var markerTokens: [String]? {
        switch self {
        case .qwen3, .qwen35, .qwen3Coder: ["<think>", "</think>", "<tool_call>", "</tool_call>"]
        case .glm47: ["<think>", "</think>", "<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"]
        default: nil
        }
    }
}

extension StructuralFormat {
    /// Builds a model family's reasoning and tool-call format, following the Chat Completions
    /// tool and tool-choice semantics.
    ///
    /// - Parameters:
    ///   - tools: Function and builtin tools available to the model. Tools without a parameter
    ///     schema, and non-strict function tools, produce syntactically valid but unconstrained
    ///     arguments.
    ///   - model: The model family's wire format.
    ///   - choice: Whether tools may, must or must not be called. `.none` disables all tools.
    ///   - reasoning: How the model's reasoning block is handled. `nil` selects the model's
    ///     ``ToolCallDialect/defaultReasoning``.
    ///   - parallelCalls: Whether more than one call may be emitted in a response. When false,
    ///     generation ends once the single call is closed.
    ///   - anyOrder: Allow tool-argument properties in any order.
    ///   - excludeSpecialTokens: Forbid the model's special tokens (such as `<think>`) inside
    ///     free-text spans. Harmony has no such tokens.
    ///   - maxWhitespaceCount: Cap on consecutive whitespace inside tool arguments.
    ///   - captureArguments: Capture each call's arguments under the tool's output name.
    ///   - tokenMarkers: Match the control markers (`<tool_call>`, `</think>`, ...) as their
    ///     dedicated tokens instead of as text, for output parsers that recognise markers by token
    ///     id. Requires ``ToolCallDialect/markerTokens``; see
    ///     ``StructuralFormat/bindingMarkerTokens(_:)``.
    public static func toolCalls(_ tools: [ToolDeclaration], model: ToolCallDialect, choice: ToolChoice = .automatic,
                                 reasoning: ReasoningMode? = nil, parallelCalls: Bool = true, anyOrder: Bool = false,
                                 excludeSpecialTokens: Bool = true, maxWhitespaceCount: Int? = nil,
                                 captureArguments: Bool = false, tokenMarkers: Bool = false) throws(GrammarError) -> Self {
        let markers = model.markerTokens
        if tokenMarkers, markers == nil {
            let supported = ToolCallDialect.allCases.filter { $0.markerTokens != nil }.map(\.rawValue)
            throw .conversion("token_markers is not supported for model \(model.rawValue), supported models: \(supported)")
        }
        let normalized = try ToolSelection(tools, choice: choice)
        if model.rejectsBuiltinTools, !normalized.builtins.isEmpty { throw .conversion("\(model.rawValue) does not support builtin tools") }
        let builder = ToolCallBuilder(format: model, selection: normalized, reasoning: reasoning ?? model.defaultReasoning,
                                      parallelCalls: parallelCalls, anyOrder: anyOrder, excludeSpecialTokens: excludeSpecialTokens,
                                      maxWhitespaceCount: maxWhitespaceCount, captureArguments: captureArguments)
        let format = try builder.build()
        guard tokenMarkers, let markers else { return format }
        return try format.bindingMarkerTokens(markers)
    }

    /// Builds a model family's tool-call format for function tools.
    public static func toolCalls(_ tools: [ToolDefinition], model: ToolCallDialect, choice: ToolChoice = .automatic,
                                 reasoning: ReasoningMode? = nil, parallelCalls: Bool = true, anyOrder: Bool = false,
                                 excludeSpecialTokens: Bool = true, maxWhitespaceCount: Int? = nil,
                                 captureArguments: Bool = false, tokenMarkers: Bool = false) throws(GrammarError) -> Self {
        try toolCalls(tools.map(ToolDeclaration.function), model: model, choice: choice, reasoning: reasoning, parallelCalls: parallelCalls,
                      anyOrder: anyOrder, excludeSpecialTokens: excludeSpecialTokens, maxWhitespaceCount: maxWhitespaceCount,
                      captureArguments: captureArguments, tokenMarkers: tokenMarkers)
    }
}

extension GrammarCompiler {
    public func compile(toolCalls tools: [ToolDeclaration], model: ToolCallDialect, choice: ToolChoice = .automatic,
                        reasoning: ReasoningMode? = nil, parallelCalls: Bool = true, anyOrder: Bool = false,
                        excludeSpecialTokens: Bool = true, maxWhitespaceCount: Int? = nil,
                        captureArguments: Bool = false, tokenMarkers: Bool = false) throws(GrammarError) -> CompiledGrammar {
        try compile(structuralFormat: .toolCalls(tools, model: model, choice: choice, reasoning: reasoning, parallelCalls: parallelCalls,
                                                anyOrder: anyOrder, excludeSpecialTokens: excludeSpecialTokens,
                                                maxWhitespaceCount: maxWhitespaceCount, captureArguments: captureArguments,
                                                tokenMarkers: tokenMarkers))
    }

    public func compile(toolCalls tools: [ToolDefinition], model: ToolCallDialect, choice: ToolChoice = .automatic,
                        reasoning: ReasoningMode? = nil, parallelCalls: Bool = true, anyOrder: Bool = false,
                        excludeSpecialTokens: Bool = true, maxWhitespaceCount: Int? = nil,
                        captureArguments: Bool = false, tokenMarkers: Bool = false) throws(GrammarError) -> CompiledGrammar {
        try compile(toolCalls: tools.map(ToolDeclaration.function), model: model, choice: choice, reasoning: reasoning, parallelCalls: parallelCalls,
                    anyOrder: anyOrder, excludeSpecialTokens: excludeSpecialTokens, maxWhitespaceCount: maxWhitespaceCount,
                    captureArguments: captureArguments, tokenMarkers: tokenMarkers)
    }
}

/// The model-independent part of tool-choice handling: the tools that remain available and
/// whether a call is optional, required or forced.
struct ToolSelection {
    enum Policy { case automatic, required, forced }

    var functions: [ToolDefinition]
    var builtins: [BuiltinToolDefinition]
    var policy: Policy

    init(_ tools: [ToolDeclaration], choice: ToolChoice) throws(GrammarError) {
        functions = tools.compactMap { if case .function(let tool) = $0 { tool } else { nil } }
        builtins = tools.compactMap { if case .builtin(let tool) = $0 { tool } else { nil } }
        var names = Set<String>()
        for tool in functions {
            guard !tool.name.isEmpty else { throw .conversion("Tool names must not be empty") }
            guard names.insert(tool.name).inserted else { throw .conversion("Duplicate tool name: \(tool.name)") }
        }
        switch choice {
        case .automatic: policy = .automatic
        case .required: policy = .required
        case .none:
            // Builders already treat automatic selection without tools as text only.
            functions = []
            builtins = []
            policy = .automatic
        case .named(let name):
            functions = functions.filter { $0.name == name }
            guard !functions.isEmpty else { throw .conversion("The tool with name '\(name)' is not found in the tools list.") }
            builtins = []
            policy = .forced
        case .builtin(let type):
            functions = []
            builtins = builtins.filter { $0.type == type }
            guard builtins.count == 1 else { throw .conversion("Builtin tool choice must match exactly one builtin tool, got \(builtins.count) matches.") }
            policy = .forced
        case .allowed(let references, let required):
            var allowedNames = Set<String>(), allowedTypes = Set<String>()
            for reference in references {
                switch reference {
                case .function(let name): allowedNames.insert(name)
                case .builtin(let type): allowedTypes.insert(type)
                }
            }
            let missingNames = allowedNames.subtracting(functions.map(\.name))
            guard missingNames.isEmpty else { throw .conversion("Allowed function tools are not found in the tools list: \(missingNames.sorted()).") }
            builtins = builtins.filter { allowedTypes.contains($0.type) }
            let missingTypes = allowedTypes.subtracting(builtins.map(\.type))
            guard missingTypes.isEmpty else { throw .conversion("Allowed builtin tools are not found in the tools list: \(missingTypes.sorted()).") }
            functions = functions.filter { allowedNames.contains($0.name) }
            policy = required ? .required : .automatic
        }
        if policy == .required, functions.isEmpty, builtins.isEmpty {
            throw .conversion("The 'tools' list is empty, which is not allowed when 'tool_choice' is 'required'.")
        }
        if policy == .forced, functions.count + builtins.count != 1 { throw .conversion("Forced tool choice must resolve to exactly one tool.") }
    }
}
