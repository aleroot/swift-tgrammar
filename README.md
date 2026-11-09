<p align="center">
  <h1 align="center">swift-tgrammar</h1>
  <p align="center">Structured generation for language models in pure Swift.</p>
</p>

<p align="center">
  <a href="https://github.com/aleroot/swift-tgrammar/actions/workflows/ci.yml"><img src="https://github.com/aleroot/swift-tgrammar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-blue" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License"></a>
</p>

swift-tgrammar is a native Swift 6 implementation of [XGrammar](https://github.com/mlc-ai/xgrammar),
the structured generation engine used by vLLM, SGLang and MLC LLM. From a **JSON Schema**, an **EBNF** or
**Lark** grammar, a **regular expression** or a model's **tool-call format**, it computes the
tokens a language model may emit next, so that every generated sequence is valid by construction.
The grammar compiler, automata, incremental Earley parser, tokenizer tables and packed token masks
are all Swift: no C++ bridge, no Python, no dependencies. It is built for on-device inference on
Apple platforms and integrates with [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).

```swift
import TGrammar

let info = try TokenizerInfo(tokenizerJSON: tokenizerData, stopTokenIDs: [151645])
let compiler = GrammarCompiler(tokenizerInfo: info)
let grammar = try compiler.compile(jsonSchema: .object(properties: [
    .init("city", .string(), required: true),
    .init("unit", .enumeration(["celsius", "fahrenheit"])),
]))

var matcher = GrammarMatcher(grammar)
var mask = TokenBitmask(vocabSize: info.vocabSize)
if matcher.fillNextTokenBitmask(&mask) { mask.apply(to: &logits) }   // disallowed logits become -inf
```

## Highlights

- **Fast.** Faster than XGrammar's C++ engine on every eager compilation, first-generation and
  decoding workload measured, up to 4x per decoded token on tool calls. See
  [Performance](#performance).
- **Tested against XGrammar.** XGrammar's own test suite, ported to Swift Testing: exact grammar
  and automaton snapshots, nearly 30,000 language cases from its JSON Schema, Lark,
  structural-tag, function-calling and grammar-language tests, and stateful matcher, budget,
  capture and serialization tests.
- **Every grammar source.** JSON Schema, built-in JSON, EBNF, Lark, regular expressions, substring
  extraction and typed structural formats, which compose sequences, choices, repetitions, tagged
  regions, token and character budgets, captures and temperature annotations.
- **Tool calling for real models.** The wire formats of Llama, Qwen 3 / 3.5 / Coder, Gemma 4,
  DeepSeek R1 / V3.1 / V3.2 / V4, GLM 4.7, Kimi, MiniMax, Harmony (gpt-oss), MiMo, Cohere and
  EXAONE, with Chat Completions tool and tool-choice inputs, reasoning blocks and argument
  captures.
- **Built for devices.** Bounded caches that empty under memory pressure, compact token masks,
  dynamic compilation that prepares a per-request tool set in a few milliseconds, and recursive
  front ends that throw instead of overflowing a thread's stack. Compilers and compiled grammars
  are `Sendable`; matchers are values that fork and roll back.
- **Compatible.** Compiled grammars, grammars and tokenizer descriptions persist in XGrammar's
  serialization format (version 18).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/aleroot/swift-tgrammar", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TGrammar", package: "swift-tgrammar"),
    ]),
]
```

Requires Swift 6.2. Supports macOS 15, iOS 18, tvOS 18, watchOS 11 and visionOS 2.

## Usage

Constrained decoding has three layers, each with its own lifetime:

| Value | Lifetime | Sharing |
|---|---|---|
| `TokenizerInfo` | one per model vocabulary | immutable, `Sendable` |
| `GrammarCompiler`, `CompiledGrammar` | one compiler per vocabulary; grammars are cached | immutable, `Sendable` |
| `GrammarMatcher` | one per generated sequence | value type; a copy forks the state |

```swift
import TGrammar

// The vocabulary, read byte-exactly from the model's tokenizer.json. Use the width of the
// model's logits, which may exceed the tokenizer vocabulary, and the generator's stop tokens.
let info = try TokenizerInfo(
    tokenizerJSON: tokenizerData,
    vocabSize: modelVocabularySize,
    stopTokenIDs: modelStopTokenIDs
)
let compiler = GrammarCompiler(tokenizerInfo: info, maxCacheBytes: 64 << 20)

// Grammar sources
let json = try compiler.compile(.builtinJSON)
let schema = try compiler.compile(jsonSchema: .array(items: .integer(minimum: 0)))
let ebnf = try compiler.compile(ebnf: #"root ::= "yes" | "no""#)
let regex = try compiler.compile(regex: #"[a-z]+@[a-z]+\.com"#)
let lark = try compiler.compile(lark: """
    start: "<" value ">"
    value[capture="value"]: /[a-z]+/
    """)
let extraction = try compiler.compile(Grammar.substring(of: "a source passage"))

// Decoding: mask, sample, accept
var matcher = GrammarMatcher(schema)
var mask = TokenBitmask(vocabSize: info.vocabSize)
while !matcher.isTerminated {
    var logits: [Float] = nextModelLogits()
    if matcher.fillNextTokenBitmask(&mask) {
        mask.apply(to: &logits)
    }
    guard matcher.acceptToken(sample(logits)) else { break }
}
```

`nextModelLogits` and `sample` stand for the application's model and sampler. A mask holds one bit
per token, LSB first, in `[UInt32]` words; `fillNextTokenBitmask` returns `false` when every token
is allowed, so the mask can be skipped. `isCompleted` means the grammar can end; `isTerminated`
means decoding has ended, normally on a stop token. Token and character budgets are enforced
through this mask, sample, accept cycle; `acceptString` and `acceptBytes` are for seeding and tests.

A copy of a matcher, or `fork()`, has independent state, and `rollback(_:)` undoes accepted tokens,
including budget decisions and capture events. `findJumpForwardString()` and
`findJumpForwardTokens()` return text the grammar forces next, which a generation loop can append
without sampling.

### Tool calls

```swift
let weather = ToolDefinition(name: "weather", parameters: .object(properties: [
    .init("city", .string(), required: true),
    .init("unit", .enumeration(["celsius", "fahrenheit"])),
]))

let grammar = try compiler.compile(
    toolCalls: [weather],
    model: .qwen3,
    choice: .required,
    reasoning: .disabled,
    captureArguments: true
)
```

For this model the output looks like:

```text
<tool_call>
{"name": "weather", "arguments": {"city":"Dubai","unit":"celsius"}}
</tool_call>
```

`ToolCallDialect` carries each model family's wire format: `.llama`, `.qwen3`, `.qwen35`,
`.qwen3Coder`, `.mimo`, `.gemma4`, `.glm47`, `.kimi`, `.kimiK3`, `.deepSeekR1`, `.deepSeekV31`,
`.deepSeekV32`, `.deepSeekV4`, `.deepSeekV41`, `.harmony`, `.miniMax`, `.miniMaxM3`, `.cohere`
and `.exaone`, plus the formats of mlx-swift-lm that XGrammar lacks. Arguments follow the model's
own encoding: JSON, XML parameter tags, DSML, Gemma's quoted strings and so on.
`ToolDeclaration.tools(json:)` and `ToolChoice(json:)` read Chat Completions request payloads
directly; `ToolChoice` supports `.automatic`, `.required`, `.none`, `.named("weather")`,
`.builtin(type:)` and `.allowed(_:required:)`, and `ReasoningMode` selects the model's thinking
mode. `ToolCallSyntax` covers custom delimiters. Tool descriptions still belong in the prompt.

`matcher.captures()` reports each call's name and argument bytes. Dispatch a tool only once its
whole call is complete; grammar acceptance does not implement permissions or business validation.

### Composing formats

```swift
// A thinking model reasons first, then answers in the schema
let answer = try compiler.compile(structuralFormat:
    .reasoning(.required, maxTokens: 512, then: .jsonSchema(schema)))
```

`StructuralFormat` builds sequences, choices, repetitions, tagged regions, text and token
dispatch, budgets, captures and temperature annotations without interpolating grammar source.
`Grammar.union(_:)` and `concatenating(_:)` combine grammars, and `Grammar.substring(chunks:)`
constrains extraction to whole supplied chunks.

### Dynamic compilation

When the grammar is only known at request time, such as a tool set chosen per request:

```swift
let compiler = GrammarCompiler(tokenizerInfo: info, dynamicCompilation: true)
```

The grammar is prepared in a fraction of the eager time (2.3 ms instead of 27 to 67 ms for an
eight-tool set) and each token mask is computed the first time a matcher needs it, then kept for
every later matcher.

### Batches, speculative decoding and persistence

```swift
var sequences = [GrammarMatcher(grammar), GrammarMatcher(grammar)]
let batch = GrammarBatch.fillNextTokenMasks(for: &sequences)    // in parallel, row-major masks

let tree = try DraftTokenTree(nodes: [
    .init(0, firstChild: 1),        // the root token is already committed
    .init(1, nextSibling: 2),
    .init(2),
])
let draft = sequences[0].traverseDraftTree(tree, timeLimit: .milliseconds(10))

let snapshot = grammar.serializedJSON
let restored = try CompiledGrammar(serializedJSON: snapshot, tokenizerInfo: info)
```

Snapshots are validated on load. Restore a compiled grammar with the exact vocabulary it was
compiled for.

### With mlx-swift-lm

TGrammar produces token masks; applying them to logits belongs to the app. The
[mlx-swift-lm integration guide](docs/MLX_INTEGRATION.md) has the code to add to an app that uses
`ChatSession`, about 230 lines plus 250 for tool calling:

```swift
let compiler = try await GrammarCompiler(container)    // vocabulary and stop tokens of the model
let session = ChatSession(container, components: .constrained(to: try compiler.compile(jsonSchema: schema)))

let grammar = try await compiler.compile(toolCalls: tools, for: container)
let agent = ChatSession(container, components: .constrained(to: grammar), tools: tools,
                        toolDispatch: { call in try await dispatch(call) })
```

To read the vocabulary from a live [swift-tokenizers](https://github.com/aleroot/swift-tokenizers)
tokenizer instead of `tokenizer.json`, adopt `TokenizerVocabulary`; see
[integration](docs/INTEGRATION.md).

## Supported features

| | |
|---|---|
| **Grammar sources** | JSON Schema, built-in JSON, EBNF (XGrammar dialect), Lark, regular expressions, substrings, structural formats and XGrammar structural-tag JSON |
| **JSON Schema** | objects (closed by default, optional `anyOrder`), `patternProperties`, `propertyNames`, property counts, arrays and `prefixItems`, `enum` / `const`, `anyOf` / `oneOf`, compatible `allOf`, `$ref` / `$defs`, string formats, patterns and lengths, integer and decimal ranges, `multipleOf`, value exclusions, and the argument styles of each model format (XML tags, Python keyword arguments, ...) |
| **Tool-call formats** | 19 XGrammar model formats plus `mistral`, `function_gemma`, `lfm2` and `atem`; custom delimiters with `ToolCallSyntax` |
| **Runtime** | token and character budgets, captures, temperature annotations, jump-forward decoding, rollback, batches, draft-tree traversal for speculative decoding |
| **Compilation** | parallel, cached across grammars at rule level, eager or dynamic |
| **Persistence** | grammars, tokenizer descriptions and compiled grammars, XGrammar serialization version 18 |

## Differences from XGrammar

- JSON Schema output defaults to one canonical layout, `{"key": value, "list": [1, 2]}`. XGrammar
  defaults to any whitespace, which lets a model whose preferred token is masked out emit
  whitespace until its token limit; opt in with
  `JSONSchemaOptions(anyWhitespace: true, maxWhitespaceCount: n)`. Tool-call grammars keep any
  whitespace inside arguments, so each model keeps its trained spacing.
- `GrammarCompiler` caches are bounded by default (`defaultMaxCacheBytes`, scaled to the device)
  and are dropped on memory pressure. XGrammar's are unbounded.
- `anyOrder` objects reject repeated declared keys and require required keys. XGrammar
  approximates by counting.
- Typed Swift values replace dictionaries and Python handles. There is no mutable model registry:
  `ToolCallDialect` is a closed enum, and other formats are a `ToolCallSyntax` or a
  `StructuralFormat`.
- Schema approximations that XGrammar reports as warnings, such as length bounds dropped under
  `excludes`, are applied silently.
- Lark lazy rules that XGrammar rejects as not terminal-like, such as `r[lazy]: /([a-z]+ )+/`,
  compile here as a single regular expression.

Grammars are generation constraints, not validators: unsupported JSON Schema keywords follow
XGrammar's approximations, and an accepted value still needs the application's own validation.

## Performance

Measured against XGrammar's C++ engine at the same revision, built with `-O3 -flto -mcpu=native`,
on the same workloads and Qwen 3's 151,669-token vocabulary, on an Apple M4 Pro. Compilation is
uncached on one thread, median of 7 runs. Decoding fills the mask and accepts the token over a
whole generation, median of 21 runs.

| Workload | Decode / token, XGrammar | Decode / token, swift-tgrammar | | Compile, XGrammar | Compile, swift-tgrammar | |
|---|---:|---:|---:|---:|---:|---:|
| Built-in JSON | 35.3 µs | 30.1 µs | **1.17x** | 21.7 ms | 20.3 ms | **1.06x** |
| JSON Schema (calendar event) | 16.9 µs | 13.8 µs | **1.23x** | 40.8 ms | 35.6 ms | **1.15x** |
| Qwen 3 tool calls | 2.6 µs | 0.7 µs | **3.96x** | 25.7 ms | 17.1 ms | **1.50x** |
| Prose, then a tool call | 2.1 µs | 0.9 µs | **2.44x** | 25.9 ms | 17.2 ms | **1.51x** |
| Eight-tool assistant set | 20.1 µs | 15.2 µs | **1.33x** | 162.6 ms | 67.1 ms | **2.42x** |
| Regex (ISO date-time) | 0.5 µs | 0.4 µs | **1.21x** | 0.14 ms | 0.13 ms | **1.08x** |

With 8 compilation threads the speed-up is 1.2x to 1.7x. Dynamic compilation prepares a tool
grammar 1.5x to 4.6x faster than XGrammar's, and the first generation that follows is 1.2x to 2.3x
faster. Dynamic compilation of very small EBNF and regex grammars is the exception, at 0.75x to
0.88x of XGrammar (20 to 30 µs of front-end work). The heap held by tokenizer information, compiled
grammars and matchers is at parity with XGrammar or smaller, by up to 4.5x. These timings cover
grammar work only, not model inference.

## Testing

```bash
swift test               # debug
swift test -c release    # also runs the pressure tests
```

The suite uses Swift Testing. Tests that need a real model vocabulary (Qwen 3, Qwen 2.5, Llama)
read it from the local Hugging Face cache and are skipped when it is absent; nothing is downloaded.
Set `TGRAMMAR_PRESSURE=1` to run the pressure tests in debug builds.

## License

[Apache License 2.0](LICENSE). Grammar semantics and the ported test fixtures come from
[XGrammar](https://github.com/mlc-ai/xgrammar), also Apache 2.0; see [NOTICE](NOTICE). No
XGrammar code is compiled into this package.
