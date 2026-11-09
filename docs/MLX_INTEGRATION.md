# Using TGrammar with mlx-swift-lm

TGrammar has no dependencies. It compiles grammars and produces a `TokenBitmask` of the tokens
allowed next; applying that mask to a model's logits is the application's job. This guide gives
the complete glue for [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)'s `ChatSession`,
to copy into the app that already depends on MLX and mlx-swift-lm.

The code was validated against MLX Swift **0.32.3** and mlx-swift-lm revisions
`5e46681b2adcef2db158e7b949aeae3896778e23` and `bb0d5b048f02e14dbf8f2d7bb1a20911a295470a` (its
newer `LogitProcessor` hooks have default implementations). `ChatSession` runs with
LFM2-2.6B-Exp-4bit and Qwen3-1.7B-4bit (greedy) produced schema-valid JSON, EBNF-conforming answers
and dispatched tool calls with default options.

| File | Purpose | Needed for |
| --- | --- | --- |
| `GrammarVocabulary.swift` | `TokenizerInfo` and `GrammarCompiler` from a loaded model | everything |
| `PackedTokenMask.swift` | Applies a mask to MLX logits on the device | everything |
| `GrammarLogitProcessor.swift` | mlx-swift-lm `LogitProcessor` driving a `GrammarMatcher` | everything |
| `GenerationComponents+Grammar.swift` | `.constrained(to:)` for `ChatSession` | everything |
| `ToolCallGrammar.swift` | Tool calls in the syntax `ChatSession` parses | tool calling only |

## Usage

```swift
import MLXLMCommon
import TGrammar

let compiler = try await GrammarCompiler(container)   // once per loaded model; reuse it

// Structured answers
let grammar = try compiler.compile(jsonSchema: schema)
let session = ChatSession(container, components: .constrained(to: grammar))

// Thinking models: reason first (capped), then answer in the schema. `.required` suits templates
// that leave the opener to the model (Qwen3); use `.continuation` when the prompt ends with it.
let thinking = try compiler.compile(structuralFormat: .reasoning(.required, maxTokens: 512,
                                                                 then: .jsonSchema(schema)))

// Tool calls in the format ChatSession parses for this model
let tools = [weatherTool.schema]
let toolGrammar = try await compiler.compile(toolCalls: tools, for: container)
let agent = ChatSession(container, components: .constrained(to: toolGrammar), tools: tools,
                        toolDispatch: { call in try await dispatch(call) })
```

## The code

### GrammarVocabulary.swift

The vocabulary must be read byte-exactly. Vocabulary pieces can hold partial UTF-8 or a leading
U+FEFF that Foundation's JSON parsing and `decode([id])` alter or drop (the Llama 2 vocabulary
loses 8 pieces that way), so the model's `tokenizer.json` is mapped and scanned by TGrammar
itself; the live tokenizer is only the fallback. The stop tokens must be exactly the ones
mlx-swift-lm's generation loop stops on, or a completed grammar cannot end the generation.

<!-- file: GrammarVocabulary.swift -->
```swift
import Foundation
import MLXLMCommon
import TGrammar

extension TokenizerInfo {
    /// The grammar vocabulary of a model loaded by mlx-swift-lm. Building it scans every piece:
    /// do it once per loaded model and share the result (or the compiler built on it).
    convenience init(configuration: ModelConfiguration, tokenizer: any Tokenizer) throws(TokenizerInfoError) {
        let stops = ModelVocabulary.stopTokenIDs(configuration: configuration, tokenizer: tokenizer)
        if let data = ModelVocabulary.tokenizerJSON(configuration: configuration) {
            try self.init(tokenizerJSON: data, stopTokenIDs: stops)
        } else {
            try self.init(tokenizer: ModelVocabulary(tokenizer: tokenizer), stopTokenIDs: stops)
        }
    }

    convenience init(_ context: ModelContext) throws(TokenizerInfoError) {
        try self.init(configuration: context.configuration, tokenizer: context.tokenizer)
    }
}

extension GrammarCompiler {
    /// A compiler for a loaded model's vocabulary and stop tokens. Create one per loaded model
    /// and reuse it: compiled grammars, and masks of rules shared between grammars, are cached.
    convenience init(_ context: ModelContext, maxThreads: Int? = nil, cacheEnabled: Bool = true,
                     maxCacheBytes: Int? = GrammarCompiler.defaultMaxCacheBytes) throws(TokenizerInfoError) {
        self.init(tokenizerInfo: try TokenizerInfo(context), maxThreads: maxThreads, cacheEnabled: cacheEnabled,
                  maxCacheBytes: maxCacheBytes)
    }

    /// The vocabulary is read outside the container's isolation, so loading does not hold up
    /// generation.
    convenience init(_ container: ModelContainer, maxThreads: Int? = nil, cacheEnabled: Bool = true,
                     maxCacheBytes: Int? = GrammarCompiler.defaultMaxCacheBytes) async throws(TokenizerInfoError) {
        let info = try TokenizerInfo(configuration: await container.configuration, tokenizer: await container.tokenizer)
        self.init(tokenizerInfo: info, maxThreads: maxThreads, cacheEnabled: cacheEnabled, maxCacheBytes: maxCacheBytes)
    }
}

/// Forwards a model tokenizer's vocabulary to `TokenizerInfo`.
struct ModelVocabulary: TokenizerVocabulary {
    let tokenizer: any Tokenizer

    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens) }
    var eosTokenId: Int? { tokenizer.eosTokenId }

    /// The token ids mlx-swift-lm stops generation on, or `nil` when there are none.
    static func stopTokenIDs(configuration: ModelConfiguration, tokenizer: any Tokenizer) -> [Int32]? {
        var ids = configuration.eosTokenIds
        if let eos = tokenizer.eosTokenId { ids.insert(eos) }
        for token in configuration.extraEOSTokens {
            if let id = tokenizer.convertTokenToId(token) { ids.insert(id) }
        }
        return ids.isEmpty ? nil : ids.sorted().map(Int32.init)
    }

    /// The contents of the model's local `tokenizer.json`, if any.
    static func tokenizerJSON(configuration: ModelConfiguration) -> Data? {
        let directory: URL
        switch (configuration.tokenizerSource, configuration.id) {
        case (.directory(let url)?, _), (nil, .directory(let url)): directory = url
        default: return nil
        }
        // Mapped, not read: the pages stay clean and are not charged to the app's footprint.
        return try? Data(contentsOf: directory.appending(component: "tokenizer.json"), options: .alwaysMapped)
    }
}
```

### PackedTokenMask.swift

Only `ceil(vocabSize / 32)` words cross to the device per step; the gather indices are built once
per sequence. Models often pad their output layer beyond the tokenizer (Qwen3: 151,936 logits for
151,669 tokens): columns past the vocabulary are always masked.

<!-- file: PackedTokenMask.swift -->
```swift
import MLX
import TGrammar

/// Applies packed grammar masks to MLX logits on the device. Keep a value on the same isolation
/// domain as the arrays it is applied to.
struct PackedTokenMask {
    let vocabSize: Int
    let logitWidth: Int
    private let wordIndices: MLXArray
    private let bitOffsets: MLXArray
    /// Whether columns past the vocabulary read an appended all-zero word.
    private let isPadded: Bool

    init(vocabSize: Int, logitWidth: Int? = nil) {
        let logitWidth = logitWidth ?? vocabSize
        precondition(vocabSize > 0 && vocabSize <= Int32.max && logitWidth > 0 && logitWidth <= Int32.max)
        self.vocabSize = vocabSize
        self.logitWidth = logitWidth
        isPadded = logitWidth > vocabSize
        let paddingWord = UInt32(TokenBitmask.wordCount(vocabSize: vocabSize))
        wordIndices = MLXArray((0 ..< logitWidth).map { $0 < vocabSize ? UInt32($0 >> 5) : paddingWord })
        bitOffsets = MLXArray((0 ..< logitWidth).map { UInt32($0 & 31) })
    }

    /// Applies one sequence's mask to `[..., logitWidth]` logits.
    func apply(_ mask: TokenBitmask, to logits: MLXArray) -> MLXArray {
        precondition(mask.vocabSize == vocabSize && logits.shape.last == logitWidth, "Mask and logits must match the plan")
        let packed = mask.withUnsafeWords { words in
            isPadded ? MLXArray(Array(words) + [0]) : MLXArray(words)
        }
        return select(packed.take(wordIndices), logits)
    }

    /// Applies independent row masks to `[rowCount, logitWidth]` logits (batches, speculative
    /// trees). Only needed outside `ChatSession`'s one-sequence loop.
    func apply(_ masks: TokenMaskBatch, to logits: MLXArray) -> MLXArray {
        precondition(masks.vocabSize == vocabSize && logits.shape == [masks.rowCount, logitWidth], "Batch masks and logit rows must match")
        let width = masks.wordsPerRow + (isPadded ? 1 : 0)
        let packed = masks.withUnsafeWords { words in
            guard isPadded else { return MLXArray(words, [masks.rowCount, width]) }
            var rows = [UInt32](repeating: 0, count: masks.rowCount * width)
            for row in 0 ..< masks.rowCount {
                for word in 0 ..< masks.wordsPerRow { rows[row * width + word] = words[row * masks.wordsPerRow + word] }
            }
            return MLXArray(rows, [masks.rowCount, width])
        }
        return select(packed.take(wordIndices, axis: 1), logits)
    }

    private func select(_ gathered: MLXArray, _ logits: MLXArray) -> MLXArray {
        let allowed = bitwiseAnd(rightShift(gathered, bitOffsets), UInt32(1)) .!= UInt32(0)
        return which(allowed, logits, MLXArray(-Float.infinity, dtype: logits.dtype))
    }
}
```

### GrammarLogitProcessor.swift

Three behaviours matter here:

- **Deferred token read.** `didSample(token:)` only keeps the `MLXArray`; the grammar advances at
  the next `process(logits:)`. Calling `token.item()` immediately makes the CPU wait for the GPU
  at every step and breaks `TokenIterator`'s `asyncEval` pipelining (Qwen3-1.7B-4bit, greedy:
  +2.6% per token immediate, +1.0% deferred).
- **No traps on model behaviour.** `TokenIterator` samples one token past a stop token, so after
  termination only stop tokens stay allowed and further tokens are ignored. A sampled token the
  grammar rejects (another processor forced it) is recorded and the rest of the sequence is left
  unconstrained.
- **`prompt(_:)` resets; it does not parse the prompt.** For a prefilled output prefix, seed a
  matcher and use `GrammarLogitProcessor(matcher:)`.

<!-- file: GrammarLogitProcessor.swift -->
```swift
import MLX
import MLXLMCommon
import TGrammar

/// Masks a model's logits so that sampled tokens follow a grammar. One instance per decoding
/// sequence; create it in a `GenerationComponents` processor factory.
final class GrammarLogitProcessor: LogitProcessor {
    /// The matcher for the current sequence, including its captures and temperature.
    var matcher: GrammarMatcher {
        settle()
        return currentMatcher
    }
    /// The first sampled token the grammar rejected; once set, masking stops until `prompt(_:)`.
    var rejectedToken: Int32? {
        settle()
        return currentRejectedToken
    }

    private var currentMatcher: GrammarMatcher
    private var currentRejectedToken: Int32?
    /// The last sampled token, not yet read from the device.
    private var pendingToken: MLXArray?
    private let initialMatcher: GrammarMatcher
    private var mask: TokenBitmask
    private var maskPlan: PackedTokenMask?

    /// - Parameter stopTokenIDs: Overrides the vocabulary's stop tokens; they must match the
    ///   tokens the generation loop stops on.
    convenience init(_ grammar: CompiledGrammar, stopTokenIDs: [Int32]? = nil) {
        self.init(matcher: GrammarMatcher(grammar, stopTokenIDs: stopTokenIDs))
    }

    /// Constrains the continuation from an already seeded matcher state.
    init(matcher: GrammarMatcher) {
        currentMatcher = matcher
        initialMatcher = matcher
        mask = TokenBitmask(vocabSize: matcher.compiledGrammar.tokenizerInfo.vocabSize)
    }

    private init(copying other: GrammarLogitProcessor) {
        currentMatcher = other.matcher
        currentRejectedToken = other.rejectedToken
        initialMatcher = other.initialMatcher
        mask = TokenBitmask(vocabSize: other.mask.vocabSize)
    }

    func prompt(_ prompt: MLXArray) {
        currentMatcher = initialMatcher
        currentRejectedToken = nil
        pendingToken = nil
    }

    /// Masks the logits of the next token. Accepts one row: `[vocabulary]` or `[1, vocabulary]`.
    func process(logits: MLXArray) -> MLXArray {
        settle()
        guard currentRejectedToken == nil, let width = logits.shape.last else { return logits }
        precondition(logits.size == width, "Each grammar processor handles one sequence")
        if maskPlan?.logitWidth != width { maskPlan = PackedTokenMask(vocabSize: mask.vocabSize, logitWidth: width) }
        if currentMatcher.isTerminated {
            mask.clearAll()
            for id in currentMatcher.stopTokenIDs { mask[id] = true }
        } else if !currentMatcher.fillNextTokenBitmask(&mask), width <= mask.vocabSize {
            return logits  // Everything is allowed: skip the device work.
        }
        return maskPlan!.apply(mask, to: logits)
    }

    func didSample(token: MLXArray) {
        precondition(token.size == 1, "Each grammar processor handles one sampled token")
        settle()
        guard currentRejectedToken == nil, !currentMatcher.isTerminated else { return }
        pendingToken = token
    }

    /// Advances the grammar by the pending token, waiting for the device if needed.
    private func settle() {
        guard let token = pendingToken else { return }
        pendingToken = nil
        let id = token.item(Int32.self)
        if !currentMatcher.acceptToken(id) { currentRejectedToken = id }
    }

    /// An independent processor with the same grammar state, for speculative verification.
    func copy() -> GrammarLogitProcessor {
        GrammarLogitProcessor(copying: self)
    }
}
```

### GenerationComponents+Grammar.swift

`GenerationComponents` takes a processor *factory*, so each generation gets fresh state; the
grammar runs after penalties and any processors already present.

<!-- file: GenerationComponents+Grammar.swift -->
```swift
import MLXLMCommon
import TGrammar

extension GenerationComponents {
    /// Returns a copy that constrains every generation to `grammar`.
    func constrained(to grammar: CompiledGrammar) -> Self {
        appendingLogitProcessor { GrammarLogitProcessor(grammar) }
    }

    /// Returns a copy that constrains every generation to a tool-call grammar. The turn state
    /// belongs to the returned value: give each `ChatSession` its own components.
    func constrained(to toolCalls: ToolCallGrammar) -> Self {
        let turn = ToolCallTurn()
        return appendingLogitProcessor { ToolCallLogitProcessor(toolCalls, turn: turn) }
    }

    static func constrained(to grammar: CompiledGrammar) -> Self {
        Self().constrained(to: grammar)
    }

    static func constrained(to toolCalls: ToolCallGrammar) -> Self {
        Self().constrained(to: toolCalls)
    }
}
```

If the app does not use tool calling, drop the two `ToolCallGrammar` overloads and skip the next
file.

### ToolCallGrammar.swift (tool calling only)

`ChatSession` parses calls with the model configuration's `ToolCallFormat`; this file maps each
format to the TGrammar dialect that emits exactly that syntax:

| mlx-swift-lm `ToolCallFormat` | `ToolCallDialect` |
| --- | --- |
| `.json` | `qwen3` |
| `.xmlFunction`, `.qwen35` | `qwen35` |
| `.glm4` | `glm47` |
| `.gemma4` | `gemma4` |
| `.kimiK2` | `kimi` |
| `.minimaxM2` | `miniMax` |
| `.llama3` | `llama` |
| `.gptOSS` | `harmony` |
| `.mistral`, `.gemma`, `.lfm2`, `.atem` | `mistral`, `functionGemma`, `lfm2`, `atem` (TGrammar-only dialects) |

`atem` (Onyx) matches its frame delimiters as control tokens, which the vocabulary must contain.

Two decisions depend on the conversation rather than on the tools, so a `ToolCallGrammar` holds
compiled variants and picks one per generation:

- **Reasoning.** Some chat templates end the prompt with `<think>`, some leave it to the model,
  and one template can do either depending on `enable_thinking`. Unless a `ReasoningMode` is given,
  a prompt that ends inside an open reasoning block uses the `.continuation` grammar, any other
  the `.optional` one.
- **Answers to tool results.** `ChatSession` generates again after dispatching a call, with the
  same components. A forced choice (`.required`, `.named`) applies to the first generation of a
  turn; later generations use `followUp` (automatic choice). Without this, a forced choice makes
  the model call the tool in every generation of the turn until it degenerates (seen with
  GLM-4-9B).

<!-- file: ToolCallGrammar.swift -->
```swift
import Foundation
import MLX
import MLXLMCommon
import Synchronization
import TGrammar

/// A tool-call grammar for one of mlx-swift-lm's tool-call formats.
final class ToolCallGrammar: Sendable {
    /// The mlx-swift-lm format whose parser reads the constrained output.
    let format: MLXLMCommon.ToolCallFormat
    let dialect: TGrammar.ToolCallDialect
    /// The grammar used unless the prompt ends inside an open reasoning block.
    let grammar: CompiledGrammar
    /// Continues an open reasoning block, closes it and follows `grammar`'s response. `nil` when
    /// the reasoning mode was chosen explicitly or the format has no reasoning block.
    let continuationGrammar: CompiledGrammar?
    /// The grammars for generations that follow a tool call in the same turn. `nil` when the
    /// choice does not force a call.
    let followUp: ToolCallGrammar?
    private let reasoningOpener: [UInt8]
    /// Text that appears in the output exactly when the model calls a tool.
    let callMarker: [UInt8]

    init(format: MLXLMCommon.ToolCallFormat, dialect: TGrammar.ToolCallDialect, grammar: CompiledGrammar,
         continuationGrammar: CompiledGrammar?, followUp: ToolCallGrammar?) {
        self.format = format
        self.dialect = dialect
        self.grammar = grammar
        self.continuationGrammar = continuationGrammar
        self.followUp = followUp
        reasoningOpener = continuationGrammar == nil ? [] : Array((dialect.promptReasoningOpener ?? "").utf8)
        callMarker = Array(dialect.callMarker.utf8)
    }

    /// The grammar for a generation whose prompt ends with `promptTail`.
    func grammar(forPromptTail promptTail: some Collection<Int32>, followsToolCall: Bool = false) -> CompiledGrammar {
        if followsToolCall, let followUp { return followUp.grammar(forPromptTail: promptTail) }
        guard let continuationGrammar, endsInsideReasoning(promptTail) else { return grammar }
        return continuationGrammar
    }

    /// A processor for a single generation, without turn tracking.
    func makeProcessor() -> ToolCallLogitProcessor {
        ToolCallLogitProcessor(self, turn: nil)
    }

    /// Whether the prompt's text, ignoring trailing whitespace, ends with the reasoning opener.
    private func endsInsideReasoning(_ tokens: some Collection<Int32>) -> Bool {
        guard !reasoningOpener.isEmpty else { return false }
        let vocabulary = grammar.tokenizerInfo.decodedVocab
        var text: [UInt8] = []
        for id in tokens where id >= 0 && Int(id) < vocabulary.count { text += vocabulary[Int(id)] }
        while let last = text.last, last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 { text.removeLast() }
        return text.count >= reasoningOpener.count && text.suffix(reasoningOpener.count).elementsEqual(reasoningOpener)
    }
}

/// Whether the latest generation of a turn called a tool; shared by the processors one
/// `GenerationComponents` value creates.
final class ToolCallTurn: Sendable {
    private let latestCalledTool = Mutex(false)

    /// Starts a generation; returns whether the previous one called a tool.
    func begin() -> Bool { latestCalledTool.withLock { called in defer { called = false }; return called } }
    func recordCall() { latestCalledTool.withLock { $0 = true } }
}

/// Constrains one generation to a `ToolCallGrammar`, choosing its variant from the prompt.
final class ToolCallLogitProcessor: LogitProcessor {
    let toolCalls: ToolCallGrammar
    /// Whether this generation has called a tool so far.
    var hasCalledTool: Bool {
        settle()
        return calledTool
    }
    private var calledTool = false
    /// The last sampled token, not yet inspected for the call marker.
    private var pendingToken: MLXArray?
    private var processor: GrammarLogitProcessor
    private let turn: ToolCallTurn?
    private var output: [UInt8] = []

    /// The number of trailing prompt tokens inspected for a reasoning opener.
    static let promptTailLength = 16

    init(_ toolCalls: ToolCallGrammar, turn: ToolCallTurn?) {
        self.toolCalls = toolCalls
        self.turn = turn
        processor = GrammarLogitProcessor(toolCalls.grammar)
    }

    private init(copying other: ToolCallLogitProcessor) {
        other.settle()
        toolCalls = other.toolCalls
        calledTool = other.calledTool
        processor = other.processor.copy()
        turn = nil  // Speculative copies must not report calls that are not accepted.
        output = other.output
    }

    var matcher: GrammarMatcher { processor.matcher }
    var rejectedToken: Int32? { processor.rejectedToken }

    func prompt(_ prompt: MLXArray) {
        let followsToolCall = turn?.begin() ?? false
        let tokens = prompt.reshaped(-1)
        let count = tokens.dim(0)
        let tail = count == 0 ? [] : tokens[max(0, count - Self.promptTailLength) ..< count].asType(.int32).asArray(Int32.self)
        processor = GrammarLogitProcessor(toolCalls.grammar(forPromptTail: tail, followsToolCall: followsToolCall))
        calledTool = false
        pendingToken = nil
        output = []
    }

    func process(logits: MLXArray) -> MLXArray {
        settle()
        return processor.process(logits: logits)
    }

    func didSample(token: MLXArray) {
        settle()
        processor.didSample(token: token)
        if !calledTool { pendingToken = token }
    }

    /// Looks for the call marker in the pending token (read lazily, like the grammar's).
    private func settle() {
        guard let token = pendingToken else { return }
        pendingToken = nil
        let marker = toolCalls.callMarker
        let vocabulary = toolCalls.grammar.tokenizerInfo.decodedVocab
        let id = Int(token.item(Int32.self))
        guard id >= 0 && id < vocabulary.count else { return }
        output += vocabulary[id]
        let window = output.suffix(marker.count + vocabulary.length(at: id) - 1)
        if window.count >= marker.count, window.indices.contains(where: { window[$0...].starts(with: marker) }) {
            calledTool = true
            output = []
            turn?.recordCall()
        } else {
            output.removeFirst(max(0, output.count - (marker.count - 1)))
        }
    }

    func copy() -> ToolCallLogitProcessor {
        ToolCallLogitProcessor(copying: self)
    }
}

extension TGrammar.ToolCallDialect {
    /// The grammar dialect whose output mlx-swift-lm parses with `format`.
    init(_ format: MLXLMCommon.ToolCallFormat) {
        switch format {
        case .json: self = .qwen3
        case .xmlFunction, .qwen35: self = .qwen35
        case .glm4: self = .glm47
        case .gemma4: self = .gemma4
        case .kimiK2: self = .kimi
        case .minimaxM2: self = .miniMax
        case .llama3: self = .llama
        case .gptOSS: self = .harmony
        case .mistral: self = .mistral
        case .gemma: self = .functionGemma
        case .lfm2: self = .lfm2
        case .atem: self = .atem
        }
    }

    /// The text that opens a reasoning block the chat template may have prefilled.
    var promptReasoningOpener: String? {
        switch self {
        case .qwen3, .qwen35, .qwen3Coder, .glm47, .kimi, .miniMax, .lfm2: "<think>"
        case .gemma4: "<|channel>thought"
        case .mistral: "[THINK]"
        case .atem: "to=self<|message|>"
        default: nil
        }
    }

    /// Text that appears in the output exactly when the model calls a tool.
    var callMarker: String {
        switch self {
        case .gemma4: "<|tool_call>"
        case .kimi: "<|tool_calls_section_begin|>"
        case .miniMax: "<minimax:tool_call>"
        case .llama: "{\"name\": \""
        case .harmony: "<|call|>"
        case .mistral: "[TOOL_CALLS]"
        case .functionGemma: "<start_function_call>"
        case .lfm2: "<|tool_call_start|>"
        case .atem: "<atem:function_calls>"
        default: "<tool_call>"
        }
    }
}

extension ToolDeclaration {
    /// Reads mlx-swift-lm tool specifications (`Tool.schema`, `ChatSession.tools`), which use
    /// the Chat Completions shape.
    static func tools(_ specs: [ToolSpec]) throws(GrammarError) -> [ToolDeclaration] {
        let object = specs as [Any]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { throw .conversion("Tool specifications must contain only JSON values") }
        return try tools(json: String(decoding: data, as: UTF8.self))
    }
}

extension GrammarCompiler {
    /// Compiles a tool-call grammar for mlx-swift-lm's `format` (the model configuration's
    /// `toolCallFormat`, which `ChatSession` defaults to `.json`). `reasoning: nil` adapts to
    /// each prompt; a choice that forces a call applies to the first generation of a turn.
    func compile(toolCalls tools: [ToolSpec], format: MLXLMCommon.ToolCallFormat = .json,
                 choice: ToolChoice = .automatic, reasoning: ReasoningMode? = nil, parallelCalls: Bool = true,
                 anyOrder: Bool = false, maxWhitespaceCount: Int? = nil) throws(GrammarError) -> ToolCallGrammar {
        let dialect = TGrammar.ToolCallDialect(format)
        let declarations = try ToolDeclaration.tools(tools)
        func build(_ choice: ToolChoice, followUp: ToolCallGrammar?) throws(GrammarError) -> ToolCallGrammar {
            func compile(_ reasoning: ReasoningMode?) throws(GrammarError) -> CompiledGrammar {
                try self.compile(toolCalls: declarations, model: dialect, choice: choice, reasoning: reasoning,
                                 parallelCalls: parallelCalls, anyOrder: anyOrder, maxWhitespaceCount: maxWhitespaceCount)
            }
            let adaptive = reasoning == nil && dialect.promptReasoningOpener != nil
            return ToolCallGrammar(format: format, dialect: dialect, grammar: try compile(adaptive ? .optional : reasoning),
                                   continuationGrammar: adaptive ? try compile(.continuation) : nil, followUp: followUp)
        }
        let forcesCall: Bool
        switch choice {
        case .automatic, .none, .allowed(_, required: false): forcesCall = false
        case .required, .named, .builtin, .allowed(_, required: true): forcesCall = true
        }
        guard forcesCall else { return try build(choice, followUp: nil) }
        let followUpChoice: ToolChoice = if case .allowed(let tools, _) = choice { .allowed(tools) } else { .automatic }
        return try build(choice, followUp: try build(followUpChoice, followUp: nil))
    }

    /// Compiles a tool-call grammar for the tool-call format of the model in `container`.
    func compile(toolCalls tools: [ToolSpec], for container: ModelContainer, choice: ToolChoice = .automatic,
                 reasoning: ReasoningMode? = nil, parallelCalls: Bool = true, anyOrder: Bool = false,
                 maxWhitespaceCount: Int? = nil) async throws(GrammarError) -> ToolCallGrammar {
        let format = await container.configuration.toolCallFormat ?? .json
        return try compile(toolCalls: tools, format: format, choice: choice, reasoning: reasoning,
                           parallelCalls: parallelCalls, anyOrder: anyOrder, maxWhitespaceCount: maxWhitespaceCount)
    }
}
```

## Pitfalls

- **JSON whitespace.** `compile(jsonSchema:)` generates one canonical layout by default. Do not
  switch on `JSONSchemaOptions(anyWhitespace: true)` without `maxWhitespaceCount`: with greedy
  decoding LFM2-2.6B then emitted whitespace before `}` until `maxTokens`. Likewise do not put an
  unbounded whitespace rule between a reasoning block and the answer; `.reasoning(_:then:)`
  matches the delimiters exactly. A JSON grammar without a reasoning block makes a thinking model
  answer directly, which is valid but skips its thinking.
- **Name clashes.** mlx-swift-lm's `MLXGuidedGeneration` module (behind its Foundation Models
  integration) also exports `GrammarError` and `VocabType`. In a file that imports both, write
  `TGrammar.GrammarError`. TGrammar's tool types are named `ToolDeclaration` and `ToolCallDialect`
  so they never clash with `MLXLMCommon.Tool` and `MLXLMCommon.ToolCallFormat`.
- **Streaming text.** Display output with the model tokenizer's decoder as usual; masks use
  vocabulary piece bytes independently of it.
- **Captures are not execution events.** With `captureArguments: true` a parameter grammar can
  complete before the closing call delimiter arrives; dispatch from `ChatSession`'s parsed call.
- **Temperature.** The processor exposes the matcher's current temperature; it does not change the
  sampler's.
- **SwiftPM command-line tests.** Xcode compiles MLX's Metal shaders; `swift test` does not, and
  MLX needs a shader library even for some CPU array paths. Compile
  `.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/**/*.metal` with
  `xcrun -sdk macosx metal -std=metal3.2 -c` (include path: that `metal` directory), link the
  `.air` files with the `metallib` next to `xcrun -f metal`, and set
  `GPU.metallib = URL(fileURLWithPath: path)` in the test suite's `init()` before any array work.

## What to test in the app

These cases are worth covering with tests in the app:

- Packed widths 1, 31, 32, 33, 65; a logit width larger than the vocabulary; float32, float16 and
  bfloat16 logits; CPU and GPU streams.
- A grammar that terminates: only stop tokens allowed afterwards, and a token sampled past the stop
  does not trap.
- A rejected token: recorded in `rejectedToken`, later logits unchanged.
- `prompt(_:)` resets; `copy()` is independent; both through `any LogitProcessor`.
- `TokenizerInfo(configuration:tokenizer:)` stop tokens equal mlx-swift-lm's stop set.
- For each `ToolCallFormat` in use: a constrained call parses with mlx-swift-lm's own tool-call
  parser, and the reasoning/follow-up variant selection.
